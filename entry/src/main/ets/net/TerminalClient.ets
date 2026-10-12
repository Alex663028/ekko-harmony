/**
 * 终端客户端：连PC 的 `GET /api/hermes/terminal`（**原生 WebSocket**，不是 socket.io）。
 *
 * ## ⚠ 之前搞错了协议（2026-10-06 更正，老板让我去开权限时挖出来的）
 *
 * 我照安卓版写成了 socket.io 命名空间 `/terminal` + `emit('capabilities')`，
 * 结果服务端回 `44/terminal,{"message":"terminal_forbidden"}` ——我据此判断「PC 端没开放」。
 *
 * 挖了 PC 上的服务端 bundle
 * （`~/.hermes-web-ui/desktop-runtime/webui/0.6.38/dist/server/index.js`，8.5MB 单文件）
 * 才发现真相：**socket.io 里根本没有 /terminal 命名空间**，
 * 那个 forbidden 是「命名空间不存在」的兜底文案 —— **跟权限、跟 token 完全无关**。
 *
 * ##✅ 实测通过（2026-10-06，用真实登录 token 跑 Node 探针逐项验证）
 *
 * ```
 * POST /api/auth/login {username:"ALEX",password:"***"} → 200，token 244 字符
 * GET  /api/auth/me→ {"user":{"id":1,"role":"super_admin","status":"active"}}
 * WS   /api/hermes/terminal?token=...            → [ws open]
 *   ← {"type":"created","id":"muwpt9ngs9fvej","pid":26964,"shell":"powershell.exe"}
 *   ← "PS E:\hermes 桌面\Hermes Studio\Ekko Studio\resources\webui> "   ← 真 PowerShell
 * 发 {"type":"resize","cols":80,"rows":20}       → 触发清屏重绘
 * 发 "echo hello-from-harmony\r"（纯文本）      → 回显 "hello-from-harmony"   ✓
 * 发 {"type":"input","data":"whoami\r"}          → "alex\<你的用户名>"              ✓
 * 发 {"type":"input","data":"{\"hello\":\"json\"}\r"}
 *     → PowerShell 报 JSON 语法错→ 说明 {开头包 input 帧确实进去了 ✓
 * ```
 *
 * **结论：不需要开任何权限，也不需要 super_admin**（虽然 ALEX 本来就是）。
 * 任何有效 token 都能用。
 *
 * ## ⚠ 两个实测发现的编码坑（已修）
 *
 * 1. **中文路径乱码**：提示符里是 `E:\hermes 桌面\...`，
 *    用 `decodeURIComponent(escape(bytes))` 会显示成「妗岄潰」。
 * 2. **被截断的 UTF-8 会丢整帧**：TCP 分包可能把一个中文字符切两半，
 *    此时 `decodeURIComponent` 抛 URIError，catch 里 return '' → **那一帧全没了**。
 *    改用 `util.TextDecoder('utf-8', {fatal:false})`，残缺序列输出替换字符而非抛异常。
 *
 * ## 协议（服务端 bundle 实测，不是猜的）
 *
 * 端点：`ws://<host>:8748/api/hermes/terminal?token=<JWT>`
 *
 * 鉴权链（bundle 原文）：
 * ```js
 * if (await Ec()) {                      // Ec() = { return await Nh(), !0 } 恒真
 *   let token = searchParams.get('token')
 *   let user  = await Xn(token)
 *   if (!user) → 401                      // 只有「token 无效」这一条
 *   if (!F8I(user)) → 403                // F8I = user.role==='super_admin'
 * }                                        // 但 Ec 恒真 → 这个分支永远进不去
 * ```
 * → **不要求 super_admin，任何有效 token 都能连。**
 *
 * 连上后**服务端立刻自动建一个会话**并发：
 * ```json
 * {"type":"created","id":"<sessionId>","pid":123,"shell":"powershell.exe"}
 * ```
 *
 * 之后收发：
 * ```
 * 收 ← pty 原始输出（纯文本，不是 JSON）
 * 收 ← {"type":"exited","id":...,"exitCode":0}
 * 收 ← {"type":"error","message":"..."}
 * 发 → 纯文本（首字符不是 {）  = 直接写进 pty，等于键盘输入
 * 发 → {"type":"create","shell":"powershell.exe"}  建新会话
 * 发 → {"type":"switch","sessionId":"..."}        切会话（会把缓冲补发）
 * 发 → {"type":"close","sessionId":"..."}         关会话
 * 发 → {"type":"resize","cols":80,"rows":24}      改窗口大小
 * 发 → {"type":"input","data":"..."}              显式输入
 * ```
 *
 * ⚠ **判帧规则**（服务端原文）：首字符 `charCodeAt(0)===123`（即 `{`）才当 JSON 解析，
 *   否则整条当键盘输入。所以要输 `{` 必须包一层 `{"type":"input","data":"{"}`。
 */

import webSocket from '@ohos.net.webSocket';
import util from '@ohos.util';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 一个终端会话 */
export interface TermSession {
  id: string;
  pid: number;
  shell: string;
  exited: boolean;
  exitCode: number;
}

/** 客户端回调 */
export interface TermHandlers {
  onStatus: (status: string, detail: string) => void;
  /** 服务端推来的原始输出（可能含 ANSI 序列） */
  onOutput: (chunk: string) => void;
  /** 会话被创建（含服务端自动建的那个） */
  onCreated: (s: TermSession) => void;
  /** 会话退出 */
  onExited: (id: string, exitCode: number) => void;
  onError: (message: string) => void;
}

/** 服务端 JSON 帧（字段按需可能缺，统一兜默认值） */
interface ServerFrame {
  type: string;
  id: string;
  pid: number;
  shell: string;
  exitCode: number;
  message: string;
}

/**
 * WS 错误码 → 人话。
 *
 * 实测（2026-10-07 Enjoy 90 Pro Max 模拟器 + PC Ekko Studio）：
 *   code 200 + 无 message = **握手被服务端拒绝**（HTTP 状态码 200，
 *     底层是 "ws upgrade response not 101"）。
 *   code 1006 = 网络不可达 / 连接被拒（PC 没开或端口不对）。
 *
 * 🔴 关于 CORS（这个坑查了一整天，结论记在这里别再踩）：
 *   HarmonyOS 的 webSocket.connect() 会**强制**盖 `Origin: ohos://<pc-ip>`，
 *   应用侧传自定义 header 覆盖不掉（实测传了 http:// 基址，服务端收到的仍是 ohos://）。
 *   服务端 Ekko Studio 对 `/api/hermes/terminal` 的 upgrade 会跑 origin 判定，
 *   而它的归一化函数只认 http/https 协议 —— ohos:// 直接判非法，**白名单配什么都没用**
 *   （实测 CORS_ORIGINS 填窄白名单 + ohos:// Origin = 400；填 * 才放行）。
 *   ⇒ 唯一解：PC 侧设 `CORS_ORIGINS=*`（用户级环境变量即可）并重启 Ekko Studio。
 */
const WS_ERROR_HINT: Record<string, string> = {
  '200': '握手被服务端拒绝（PC 端 CORS 未放行：请设 CORS_ORIGINS=* 后重启 Ekko Studio）',
  '1006': '网络不可达，请确认 PC 服务已启动、地址端口正确',
  '1000': '正常关闭',
};

/** 首帧超时的提示文案 */
const FIRST_FRAME_TIMEOUT_HINT: string = '连接超时';

/** 空实现，避免 ArkTS 强制要求具名类 */
class NoopHandlers implements TermHandlers {
  onStatus(status: string, detail: string): void {
  }

  onOutput(chunk: string): void {
  }

  onCreated(s: TermSession): void {
  }

  onExited(id: string, exitCode: number): void {
  }

  onError(message: string): void {
  }
}

function pickStr(o: Record<string, Object>, k: string): string {
  const v = o[k];
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'number') {
    return String(v);
  }
  return '';
}

function pickNum(o: Record<string, Object>, k: string): number {
  const v = o[k];
  if (typeof v === 'number') {
    return v;
  }
  return 0;
}

/**
 * ArrayBuffer → string（UTF-8）
 *
 * ## ⚠ 为什么不用 `decodeURIComponent(escape(...))`（实测踩过）
 *
 * 那套老写法在终端场景下有两个致命问题：
 *  1. **中文乱码**：PowerShell 提示符里有中文（实测 `E:\hermes 桌面\Hermes Studio`），
 *     老写法在某些路径下会把「桌面」的 UTF-8 字节（E6 A1 8C 8C）当 GBK 解，
 *     显示成「妗岄潰」这种乱码。
 *  2. **整帧丢失**：TCP 分包会把一个中文字符切成两半，
 *     此时 `decodeURIComponent` 抛 `URIError`，
 *     catch 里直接 `return ''` → **那一整帧输出全没了**，
 *     表现为终端输出莫名其妙少一大段。
 *
 * `TextDecoder('utf-8')` 两个问题都没有：它对残缺序列会输出替换字符而不是抛异常。
 */
function bytesToStr(buf: ArrayBuffer): string {
  try {
    const bytes = new Uint8Array(buf);
    const decoder = new util.TextDecoder('utf-8', { fatal: false });
    return decoder.decodeToString(bytes);
  } catch (e) {
    // 极端兜底：解码器都失败就按 latin1 给，至少不丢内容（会显示成乱码但可读）
    const bytes = new Uint8Array(buf);
    let raw = '';
    for (let i = 0; i < bytes.length; i++) {
      raw += String.fromCharCode(bytes[i]);
    }
    return raw;
  }
}

function parseFrame(raw: string): ServerFrame | null {
  try {
    const o = JSON.parse(raw) as Record<string, Object>;
    const f: ServerFrame = {
      type: pickStr(o, 'type'),
      id: pickStr(o, 'id'),
      pid: pickNum(o, 'pid'),
      shell: pickStr(o, 'shell'),
      exitCode: pickNum(o, 'exitCode'),
      message: pickStr(o, 'message')
    };
    return f;
  } catch (e) {
    return null;
  }
}

/** input 帧 */
interface InputFrame {
  type: string;
  data: string;
}

/** create 帧 */
interface CreateFrame {
  type: string;
  shell: string;
}

/** switch / close 帧（字段同名） */
interface SessionFrame {
  type: string;
  sessionId: string;
}

/** resize 帧 */
interface ResizeFrame {
  type: string;
  cols: number;
  rows: number;
}

/**
 * PC 终端客户端。
 *
 * ```ts
 * const t = new TermClient();
 * if (await t.open(baseUrl, token, handlers)) {
 *   t.send('dir\r');                      // 键盘输入
 *   t.resize(80, 24);
 *   await t.close();
 * }
 * ```
 */
export class TermClient {
  private ws: webSocket.WebSocket | null = null;
  private sessions: TermSession[] = [];
  private activeId: string = '';
  private hooks: TermHandlers = new NoopHandlers();
  private opened: boolean = false;
  /** 首帧超时定时器句柄，-1 表示没有待办的超时检查 */
  private firstFrameTimer: number = -1;

  isReady(): boolean {
    return this.opened;
  }

  list(): TermSession[] {
    return this.sessions;
  }

  current(): string {
    return this.activeId;
  }

  /** 握手。返回 false = 连不上（一般是 token 无效） */
  async open(baseUrl: string, token: string, handlers: TermHandlers): Promise<boolean> {
    this.hooks = handlers;
    if (token.length === 0) {
      this.hooks.onStatus('error', '未登录');
      return false;
    }
    const wsUrl: string = TermClient.buildUrl(baseUrl, token);
    const ws: webSocket.WebSocket = webSocket.createWebSocket();
    this.ws = ws;

    // ⚠ 回调参数**不要显式标注类型** —— `WebSocketMessage` 是 union
    // （含 headerReceive / ping 等），标成它反而过不了 overload。
    // 不标让TS 推断，再在函数体里用 typeof 窄化（同SocketClient 的写法）。
    // 🔴🔴 实测踩坑（2026-10-07，Enjoy 90 Pro Max 模拟器）—— 这个坑极隐蔽
//   SDK 签名：`on(type: 'message', callback: AsyncCallback<string | ArrayBuffer>)`
//   而 `AsyncCallback<T>` 在 @ohos.base.d.ts 里的定义是：
//     export interface AsyncCallback<T, E = void> {
//       (err: BusinessError<E>, data: T): void    ← **err 在前，data 在后**
//     }
//   ⇒ 只写 `(data) => {}` 拿到的是 **err**（成功时为 undefined），
//     数据在**第二个**形参！之前的写法因此一条消息都收不到。
//   ⇒ 正确写法：第一个形参接 err，第二个才是载荷。
//     （之前改成两参却报 overload 错，是因为第一形参标注成了载荷类型
//      `string | ArrayBuffer`，与 AsyncCallback 不匹配；标注成
//      `BusinessError<void>` 才对。）
ws.on('message', (err: BusinessError<void>, data: string | ArrayBuffer): void => {
      // 成功时 err 为 undefined；这里只关心 data
      if (data === undefined || data === null) {
        TermClient.log(`message 无载荷（err=${err !== undefined ? err.code : 'nil'}）`);
        return;
      }
      if (typeof data === 'string') {
        this.handleFrame(data);
        return;
      }
      if (data instanceof ArrayBuffer) {
        this.handleFrame(bytesToStr(data));
        return;
      }
      // Blob / headerReceive 等本项目用不到，忽略
    });
    ws.on('close', (): void => {
      const wasOpened: boolean = this.opened;
      this.opened = false;
      this.clearFirstFrameTimeout();
      // 握手失败时 close 也会触发，且**紧跟 onError 之后**。
      // 若这里再报一次'disconnected'，会把 onError 给出的具体原因
      // （比如"握手被服务端拒绝"）覆盖成没用的"连接断开"。
      // 所以：只有"曾经真的通过首帧确认过"才报断开。
      if (wasOpened) {
        this.hooks.onStatus('disconnected', '');
      } else {
        TermClient.log('close（握手未成功，状态已由 onError 给出）');
      }
    });
    ws.on('error', (err: BusinessError): void => {
      this.opened = false;
      this.clearFirstFrameTimeout();
      // ⚠ HarmonyOS 的 WS 错误对象不总有 message（实测 err.message === undefined，
      //   err.code 才是有意义的：200=握手被服务端拒绝、1006=网络不可达）。
      //   直接把 undefined 拼进 UI 会显示成 "200 undefined"，必须兜底。
      const code: string = `${err.code}`;
      const msg: string = err.message ? err.message : WS_ERROR_HINT[code] || '未知错误';
      TermClient.log(`ws error ${code}: ${msg}`);
      this.hooks.onStatus('error', `${code} ${msg}`);
    });

    this.hooks.onStatus('connecting', '');
    TermClient.log(`connecting ${TermClient.maskToken(wsUrl)}`);
    // ⚠ HarmonyOS WebSocket 的坑（实测 2026-10-07）：
    //   `await ws.connect()` 的 Promise **resolve 不代表握手成功**。
    //   服务端返回 403/200 时 connect() 照样 resolve，随后才异步抛 onError(200)。
    //   若在这里就报 "connected"，UI 会先闪一下"终端已连接"再变成错误页，
    //   非常误导（App 端表现：先"终端已连接"日志，紧接着 "ws error 200"）。
    //   对策：connect() 只当作"已发起"，真正的 connected 状态等**收到第一帧**
    //   （服务端连上就会立刻下发 {"type":"created",...}）再报，见 settleConnected()。
    try {
      // 🔑 覆盖 Origin：HarmonyOS 默认发 ohos://<pc-ip>，服务端 Gb() 一律判非法。
      //    换成 PC 自己的 http 基址后命中服务端同源回退分支，无需改服务端配置。
      //    详细推导见 SocketClient.buildOriginHeader 的注释（同一套判定逻辑）。
      const origin: string = TermClient.buildOrigin(baseUrl);
      const handshakeOptions: webSocket.WebSocketRequestOptions = { header: {} };
      if (origin.length > 0) {
        const hdr: Record<string, string> = { 'Origin': origin };
        handshakeOptions.header = hdr;
        TermClient.log(`origin override -> ${origin}`);
      }
      await ws.connect(wsUrl, handshakeOptions);
      TermClient.log('握手已发起，等待服务端首帧确认');
      this.hooks.onStatus('handshaking', '');
      // 🔑 首帧超时兜底：实测有一种「连上又没消息」的状态 ——
      //   握手被服务端拒（401/403）或 token 失效时，HarmonyOS 既不抛
      //   onError 也不触发 close，UI 就永远停在「连接中…」。
      //   服务端连上会**立刻**下发 {"type":"created"} 首帧，5s 还等不到就是失败。
      this.armFirstFrameTimeout(5000);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.opened = false;
      const code: string = `${err.code}`;
      const msg: string = err.message ? err.message : WS_ERROR_HINT[code] || '连接失败';
      TermClient.log(`connect 抛错 ${code}: ${msg}`);
      this.hooks.onStatus('error', `${code} ${msg}`);
      return false;
    }
  }

/** 拿到第一帧 → 确认链路真的通了 */
  private settleConnected(): void {
    // 首帧到了就撤掉超时定时器
    if (this.firstFrameTimer !== -1) {
      clearTimeout(this.firstFrameTimer);
      this.firstFrameTimer = -1;
    }
    if (this.opened) {
      return;
    }
    this.opened = true;
    this.hooks.onStatus('connected', '');
    TermClient.log('终端已连接（收到服务端首帧）');
  }

  /**
   * 首帧超时兜底。
   *
   * ⚠ 实测踩过：握手被服务端拒时（token 失效、401/403），
   *   HarmonyOS 的 webSocket **既不抛 onError 也不触发 close**，
   *   于是 UI 永远停在「连接中…」，用户完全无从判断发生了什么。
   *   服务端正常连上会立刻下发 created 首帧，所以超时即可判定失败。
   */
  private armFirstFrameTimeout(ms: number): void {
    if (this.firstFrameTimer !== -1) {
      clearTimeout(this.firstFrameTimer);
    }
    this.firstFrameTimer = setTimeout(() => {
      this.firstFrameTimer = -1;
      if (this.opened) {
        return;
      }
      this.opened = false;
      TermClient.log('首帧超时，判定握手失败');
      this.hooks.onStatus('error', `${FIRST_FRAME_TIMEOUT_HINT}（${ms / 1000}s 内没收到服务端首帧；若刚重启过 PC 服务端，多半是登录令牌已过期，请重新登录）`);
    }, ms);
  }

  /** 关掉/出错时撤掉首帧超时检查，避免定时器泄漏 */
  private clearFirstFrameTimeout(): void {
    if (this.firstFrameTimer !== -1) {
      clearTimeout(this.firstFrameTimer);
      this.firstFrameTimer = -1;
    }
  }

  /** 日志里不能出现完整 JWT，只留头尾 */
  private static maskToken(url: string): string {
    const i = url.indexOf('token=');
    if (i < 0) {
      return url;
    }
    const t = url.substring(i + 6);
    return `${url.substring(0, i)}token=${t.substring(0, 6)}…(${t.length})`;
  }

  /** http(s) → ws(s)，拼上 /api/hermes/terminal?token= */
  private static buildUrl(baseUrl: string, token: string): string {
    const cleaned: string = baseUrl.replace(/\/+$/, '');
    const wsPart: string = cleaned.replace(/^http/, 'ws');
    return `${wsPart}/api/hermes/terminal?token=${encodeURIComponent(token)}`;
  }

  /**
   * 握手要用的 Origin 值。
   *
   * 🔴 HarmonyOS 的 webSocket.connect() 会自动盖 `Origin: ohos://<pc-ip>`，
   *   服务端 Ekko Studio 的 origin 判定对非 http/https 协议**一律拒绝**
   *   （`sP()` 返回 null → 白名单和同源回退都走不到）。
   *   改成 PC 自己的 http 基址即可命中「Origin.host === 请求 Host」的同源回退，
   *   不需要设 CORS_ORIGINS=*，也不需要重启 PC 服务。
   */
  private static buildOrigin(baseUrl: string): string {
    const cleaned: string = baseUrl.trim().replace(/\/+$/, '');
    if (!/^https?:\/\//i.test(cleaned)) {
      return '';
    }
    return cleaned;
  }

  /**
   * 分发一帧。
   *
   * 判帧规则与服务端一致：首字符 `{` 才当 JSON，其余整条当 pty 输出。
   * JSON 解析失败也退回当输出 —— 终端里真的可能打出 `{` 开头的文本。
   */
  private handleFrame(raw: string): void {
    if (raw.length === 0) {
      return;
    }
    // 诊断：把收到的原始帧打出来（截断，避免刷屏/泄露 token）
    const preview: string = raw.length > 160 ? `${raw.slice(0, 160)}…(${raw.length})` : raw;
    TermClient.log(`<< ${preview}`);
    // 收到任何一帧 = 链路真的通了（握手阶段 connect() 的 resolve 不可信，见 open() 注释）
    this.settleConnected();
    if (raw.charCodeAt(0) === 123) {
      const f = parseFrame(raw);
      if (f === null) {
        this.hooks.onOutput(raw);
        return;
      }
      if (f.type === 'created') {
        const s: TermSession = {
          id: f.id, pid: f.pid, shell: f.shell, exited: false, exitCode: 0
        };
        this.upsert(s);
        this.activeId = f.id;
        this.hooks.onCreated(s);
        TermClient.log(`会话已建 ${f.id} shell=${f.shell} pid=${f.pid}`);
        return;
      }
      if (f.type === 'exited') {
        this.markExited(f.id, f.exitCode);
        this.hooks.onExited(f.id, f.exitCode);
        return;
      }
      if (f.type === 'error') {
        this.hooks.onError(f.message);
        return;
      }
      // switched 之类：忽略
      return;
    }
    this.hooks.onOutput(raw);
  }



  private upsert(s: TermSession): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === s.id) {
        const next: TermSession[] = this.sessions.slice();
        next[i] = s;
        this.sessions = next;
        return;
      }
    }
    this.sessions = this.sessions.concat([s]);
  }

  private markExited(id: string, code: number): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === id) {
        const next: TermSession[] = this.sessions.slice();
        const old = next[i];
        next[i] = {
          id: old.id, pid: old.pid, shell: old.shell, exited: true, exitCode: code
        };
        this.sessions = next;
        return;
      }
    }
  }

  /**
   * 发键盘输入。
   *
   * ⚠ 不能直接发以 `{` 开头的文本 —— 服务端会当 JSON 解析，失败就丢弃。
   *   要输 `{` 得包一层 `{"type":"input","data":"{"}`（本方法自动处理）。
   */
  send(data: string): boolean {
    if (this.ws === null || !this.opened) {
      return false;
    }
    if (data.length === 0) {
      return true;
    }
    if (data.charCodeAt(0) === 123) {
      const wrapped: InputFrame = { type: 'input', data: data };
      this.ws.send(JSON.stringify(wrapped)).catch(() => {});
      return true;
    }
    this.ws.send(data).catch(() => {});
    return true;
  }

  /** 发 JSON 帧 */
  sendJson(json: string): boolean {
    if (this.ws === null || !this.opened) {
      return false;
    }
    this.ws.send(json).catch(() => {});
    return true;
  }

  createSession(shell: string): boolean {
    const f: CreateFrame = { type: 'create', shell: shell };
    return this.sendJson(JSON.stringify(f));
  }

  switchTo(id: string): boolean {
    const f: SessionFrame = { type: 'switch', sessionId: id };
    return this.sendJson(JSON.stringify(f));
  }

  closeSession(id: string): boolean {
    const f: SessionFrame = { type: 'close', sessionId: id };
    return this.sendJson(JSON.stringify(f));
  }

  resize(cols: number, rows: number): boolean {
    const f: ResizeFrame = { type: 'resize', cols: cols, rows: rows };
    return this.sendJson(JSON.stringify(f));
  }

  async close(): Promise<void> {
    if (this.ws !== null) {
      try {
        await this.ws.close();
      } catch (e) {
      }
      this.ws = null;
    }
    this.opened = false;
    this.sessions = [];
    this.activeId = '';
  }

  private static log(msg: string): void {
    try {
      hilog.info(0xD00, 'TermTrace', '%{public}s', msg);
    } catch (e) {
    }
  }
}