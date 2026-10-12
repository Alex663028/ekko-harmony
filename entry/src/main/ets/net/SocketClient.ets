/**
 * Socket.IO 客户端（Engine.IO v4 / WebSocket 传输）。
 *
 * 用途：当老板的 PC 上跑着 Ekko Studio 服务端时，鸿蒙端可作为另一个客户端接入，
 * 复用服务端已有的 CLI Agent 能力。命名空间与原版一致：
 *   /chat-run      单聊流式对话
 *   /group-chat    群聊
 *
 * 鉴权：handshake.auth.token 传 JWT（原版中间件 kn(token) 只认合法 HS256 JWT）。
 *
 * 本文件不依赖 @kit.*，协议编解码部分是纯逻辑，已被 Node 回归测试覆盖。
 */

import webSocket from '@ohos.net.webSocket';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NetConfig } from './Http';

/** 引擎事件（不依赖具体命名空间） */
export type EngineEvent = 'open' | 'message' | 'close' | 'error';

export interface SocketLike {
  connect(url: string, opts?: Record<string, string>): Promise<boolean>;
  send(data: string): Promise<boolean>;
  close(): Promise<boolean>;
  on(type: EngineEvent, cb: (d: string) => void): void;
  off(type: EngineEvent): void;
}

/** 对接点：便于把真实 WebSocket 换成内存假实现做测试。
 *  ⚠ ArkTS 禁止结构化类型 —— 必须显式 implements SocketLike，
 *    且 connect 的 Promise 返回类型要完全一致（不能一个写 boolean 一个写 Promise<boolean>）。 */
export class SocketBridge implements SocketLike {
  private ws: webSocket.WebSocket | null = null;
  private handlers = new Map<string, Array<(d: string) => void>>();

  connect(url: string, headers: Record<string, string>): Promise<boolean> {
    const ws = webSocket.createWebSocket();
    this.ws = ws;

    // 🔴🔴 实测踩坑（2026-10-07）—— 同 TerminalClient 的坑，别再踩第二次
//   SDK 签名：`on(type: 'message', callback: AsyncCallback<string | ArrayBuffer>)`
//   `AsyncCallback<T>` 在 @ohos.base.d.ts 的定义是 **(err, data)** —— err 在前！
//   ⇒ 只写 `(data) => {}` 拿到的是 err（成功时 undefined），
//     服务端 /chat-run 事件一条也收不到（表现为「连接上了但没有回复」）。
//   ⇒ 正确：第一个形参接 err，第二个才是载荷。
ws.on('message', (err: BusinessError<void>, data: string | ArrayBuffer): void => {
      if (data === undefined || data === null) {
        SocketClient.log(`message 无载荷（err=${err !== undefined ? err.code : 'nil'}）`);
        return;
      }
      if (typeof data === 'string') {
        this.emit('message', data);
        return;
      }
      if (data instanceof ArrayBuffer) {
        this.emit('message', bytesToString(data));
        return;
      }
      // 其余类型（Blob 等）本项目用不到，忽略即可
    });
    ws.on('close', () => this.emit('close', ''));
    ws.on('error', (err: BusinessError) => this.emit('error', `${err.code}:${err.message}`));

    const options: webSocket.WebSocketRequestOptions = { header: headers };
    return ws.connect(url, options);
  }

  send(data: string): Promise<boolean> {
    if (this.ws === null) {
      return Promise.reject(new Error('socket 未连接'));
    }
    return this.ws.send(data);
  }

  close(): Promise<boolean> {
    if (this.ws === null) {
      return Promise.resolve(true);
    }
    return this.ws.close();
  }

  on(type: EngineEvent, cb: (d: string) => void): void {
    const arr = this.handlers.get(type);
    if (arr === undefined) {
      this.handlers.set(type, [cb]);
    } else {
      arr.push(cb);
    }
  }

  off(type: EngineEvent): void {
    this.handlers.delete(type);
  }

  private emit(type: EngineEvent, data: string): void {
    const arr = this.handlers.get(type);
    if (arr === undefined) {
      return;
    }
    for (const cb of arr) {
      cb(data);
    }
  }
}

// ───────────────────────── Engine.IO / Socket.IO 协议编解码 ─────────────────────────

/** Engine.IO 帧类型 */
export enum EnginePacket {
  OPEN = '0',
  CLOSE = '1',
  PING = '2',
  PONG = '3',
  MESSAGE = '4',
  UPGRADE = '5',
  NOOP = '6'
}

/** 解析 "4<ns>,<ack>,<json>" 形式的一帧 */
export interface EngineFrame {
  type: string;
  namespace: string;
  /** socket.io 子类型：0=CONNECT 1=DISCONNECT 2=EVENT 3=ACK 4=CONNECT_ERROR 5=BINARY_EVENT 6=BINARY_ACK */
  subType: string;
  /** socket.io ack id，-1 表示无 ack */
  ackId: number;
  /** MESSAGE 帧里的事件 JSON */
  payload: string;
}

/** socket.io-parser protocol 5 子类型：
 *  0=CONNECT 1=DISCONNECT 2=EVENT 3=ACK 4=CONNECT_ERROR 5=BINARY_EVENT 6=BINARY_ACK
 *  ⚠ CONNECT_ERROR 是 4 不是 1 —— protocol v4 起如此，v5 沿用。
 *    之前误写成 '1'（=DISCONNECT），导致服务端下发的
 *    `44/group-chat,{"message":"Unauthorized"}` 在 onFrame 里永远比对不上，
 *    auth 被拒时 UI 拿不到原因只能空等 8s 超时。*/
export const SUB_CONNECT = '0';
export const SUB_DISCONNECT = '1';
export const SUB_EVENT = '2';
export const SUB_ACK = '3';
export const SUB_CONNECT_ERROR = '4';

/**
 * 解一帧。解析失败返回 null（不要抛：脏帧直接丢）。
 *
 * ⚠ v4 的 `4`(MESSAGE) 帧结构是：
 *     4 [ <namespace>, ] [ <ackId> ] <subType> <json>
 *   subType: 0=CONNECT 1=DISCONNECT 2=EVENT 3=ACK 4=CONNECT_ERROR 5=BINARY_EVENT 6=BINARY_ACK
 *   关键：**只有 subType 为 2/3/5/6 时才可能有 ackId**；
 *   subType 为 0/1/4（CONNECT / DISCONNECT / CONNECT_ERROR）后面直接就是 json。
 *
 *   之前没区分这个，把 `40{"sid":...}` 里的 `0` 当成 ackId 起始，
 *   一路找到 json 内部的第一个逗号才停 → payload 被截断成半截字符串。
 *   用真实抓的帧验证：
 *     0{"sid":"...","pingInterval":25000,...}   open
 *     40{"sid":"...","pid":"..."}              CONNECT ack
 *     42["message_stream_delta",{...}]         EVENT
 *     42123["ev",{...}]                        EVENT with ackId=123
 */
export function decodeFrame(raw: string): EngineFrame | null {
  if (raw.length === 0) {
    return null;
  }
  const type = raw.charAt(0);
  if (type !== EnginePacket.MESSAGE) {
    // 非消息帧（open/close/ping/pong/upgrade/noop）：只有类型有意义
    return { type: type, namespace: '/', subType: '', ackId: -1, payload: '' };
  }

  let i = 1;
  let namespace = '/';
  let ackId = -1;
  let sub = '';

  // ① socket.io v5 的 MESSAGE 帧有两种等价写法，**都要能解**：
  //     A. 服务端下行（实测抓包）：`4<subType><ns>,<ackId><payload>`
  //        例 42/chat-run,["ev",data]  40/group-chat,{"sid":...}
  //     B. 客户端上行（socket.io 官方库如此）：`4<ns>,<ackId><subType><payload>`
  //        例 4/group-chat,72["join",{}]
  //
  //  ⚠ 这里之前只按 B 解析，结果**服务端下行的 A 形式全部解错**：
  //    `40/group-chat,{...}` 的 ns 恒为 '/'、payload 把 "/group-chat,{...}" 整个吞掉，
  //    于是群聊的命名空间回执永远收不到 → join 被丢弃 → 界面一条消息都没有。
  //  ⇒ 先按 A 试（下一个字符是数字），不成立再退回 B。
  const two = raw.charAt(i);
  if (two >= '0' && two <= '9') {
    // A：4<subType><ns>,...
    sub = two;
    i += 1;
    if (raw.charAt(i) === '/') {
      const comma = raw.indexOf(',', i);
      if (comma < 0) {
        return null;
      }
      namespace = raw.slice(i, comma);
      i = comma + 1;
    }
  } else if (two === '/') {
    // B：4<ns>,<ackId><subType><payload>
    const comma = raw.indexOf(',', i);
    if (comma < 0) {
      return null;
    }
    namespace = raw.slice(i, comma);
    i = comma + 1;
    if (i >= raw.length) {
      return null;
    }
    // ns 之后是一串数字：可能是纯 subType（`2["ev"]`），
    // 也可能是「ackId + subType」（`72["join",{}]` → ackId=7 subType=2）。
    let num = '';
    let j = i;
    while (j < raw.length && raw.charAt(j) >= '0' && raw.charAt(j) <= '9') {
      num += raw.charAt(j);
      j++;
    }
    if (num.length === 0) {
      return null;
    }
    sub = num.charAt(num.length - 1);
    if (num.length > 1) {
      const n = Number(num.substring(0, num.length - 1));
      if (isFinite(n)) {
        ackId = n;
      }
    }
    i = j;
  } else {
    return null;
  }

  // ③ 可选的 ackId：ns 之后、payload 之前的连续数字。
  //    A 形式里数字段是「ackId + subType」合并（末位归 subType，已读走）；
  //    B 形式里 subType 已单独读过，数字段整体就是 ackId。
  if (i < raw.length) {
    const c = raw.charAt(i);
    if (c >= '0' && c <= '9') {
      let num = '';
      let j = i;
      while (j < raw.length && raw.charAt(j) >= '0' && raw.charAt(j) <= '9') {
        num += raw.charAt(j);
        j++;
      }
      if (num.length > 0) {
        const n = Number(num);
        if (isFinite(n)) {
          ackId = n;
        }
      }
      i = j;
    }
  }

  const payload = raw.slice(i);
  // payload 必须是完整 JSON：截断的报文直接判废，
  // 否则上层会拿到半截字符串而悄悄出错。
  if (payload.length > 0 && !isCompleteJson(payload)) {
    return null;
  }
  return { type: type, namespace: namespace, subType: sub, ackId: ackId, payload: payload };
}

/** 括号配平检查：只判完整性，不判语法（语法交给上层 JSON.parse）。 */
export function isCompleteJson(s: string): boolean {
  let depthSquare = 0;
  let depthCurly = 0;
  let inString = false;
  let escaped = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s.charAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
    } else if (ch === '[') {
      depthSquare++;
    } else if (ch === ']') {
      depthSquare--;
    } else if (ch === '{') {
      depthCurly++;
    } else if (ch === '}') {
      depthCurly--;
    }
    // 出现负深度说明结构已损坏
    if (depthSquare < 0 || depthCurly < 0) {
      return false;
    }
  }
  return !inString && depthSquare === 0 && depthCurly === 0;
}

/**
 * 编码一条事件消息。
 *
 * 帧结构（对齐服务端实测抓包，2026-10-07）：
 * ```
 *   4<subType><ns>,<ackId><payload>
 * ```
 * 例：
 *   42["ev",data]默认 ns，无 ack
 *   42/group-chat,["join",{...}]     命名空间，无 ack
 *   42/group-chat,7["ack",data]      命名空间，带 ackId=7
 *
 * ⚠ 之前非默认命名空间生成的是 `4<ns>,<ackId><subType>`（B 格式），
 *   实测服务端**解析不了、发完直接关连接**（群聊 join 后 2ms 就断）。
 *   正确格式里 subType 紧跟 Engine.IO 的 `4`，ns 在其后。
 */
export function encodeMessage(namespace: string, ackId: number, json: string): string {
  const SUB_EVENT = '2';
  const isDefault = namespace.length === 0 || namespace === '/';
  if (isDefault) {
    if (ackId < 0) {
      return `${EnginePacket.MESSAGE}${SUB_EVENT}${json}`;
    }
    return `${EnginePacket.MESSAGE}${SUB_EVENT}${ackId}${json}`;
  }
  if (ackId < 0) {
    return `${EnginePacket.MESSAGE}${SUB_EVENT}${namespace},${json}`;
  }
  return `${EnginePacket.MESSAGE}${SUB_EVENT}${namespace},${ackId}${json}`;
}

/**
 * 编码 CONNECT 包（客户端 → 服务端 建立命名空间）。
 *
 * 帧格式是 `4<子类型><ns>,<ackId>`，子类型 0 = CONNECT。
 * ⇒ 非默认命名空间必须发 `40/chat-run,`。
 *
 * ⚠ 实测踩过的坑（2026-10-07）：早先写成 `4/chat-run,`（漏了子类型 0），
 *   服务端回 `44/chat-run,{"message":"Authentication failed"}` 并拒绝入命名空间，
 *   症状是「socket 连上了但消息全被丢弃 / auth 一直超时」。
 *   Node 探针（_test/probe_sio2.js）复现确认了同样的帧序列与错误。
 *
 * 🔴 命名空间 CONNECT **也必须带 auth**（2026-10-07 实测）。
 *   带 auth（`40/chat-run,{"token":...}`）→ 服务端回 `40/chat-run,{"sid":...}` 并开始推送
 *   不带 auth（`40/chat-run,`）        → 服务端回 `44/chat-run,{"message":"Authentication failed"}`
 *   握手 query 里带了 token **不算**，命名空间这层要单独再交一次。
 *
 * 默认命名空间就是 `/`，此时帧就是裸的 `40`（实测服务端回 `40{"sid":...}`）。
 */
export function encodeConnect(namespace: string, token: string = ''): string {
  if (namespace.length === 0 || namespace === '/') {
    return token.length > 0
      ? `${EnginePacket.MESSAGE}${SUB_CONNECT}${JSON.stringify(newAuthPayload(token))}`
      : `${EnginePacket.MESSAGE}${SUB_CONNECT}`;
  }
  const ns = namespace.startsWith('/') ? namespace : `/${namespace}`;
  return token.length > 0
    ? `${EnginePacket.MESSAGE}${SUB_CONNECT}${ns},${JSON.stringify(newAuthPayload(token))}`
    : `${EnginePacket.MESSAGE}${SUB_CONNECT}${ns},`;
}

/** 构造 CONNECT 用的 auth 载荷 */
function newAuthPayload(token: string): AuthPayload {
  const a: AuthPayload = { token: token };
  return a;
}

/**
 * 编码 **带 auth 的CONNECT**（socket.io 的 CONNECT with auth）。
 *
 * 🔑 这是真机连不上的**真正原因**（实测 2026-10-06，Node 探针复现）：
 *   只发裸 `40/group-chat,` 时，服务端立刻回
 *     44/group-chat,{"message":"Unauthorized"}
 *   然后**优雅关闭连接**（close code 1005, wasClean=true）——
 *   表现就是「Websocket Unknown Other Error」。
 *
 *   socket.io 客户端的标准做法是：连接建立后先发一条
 *     40{"token":"xxx"}
 *   把凭证交给 socket.io 的 auth 通道，服务端中间件校验通过后才允许进命名空间。
 *   注意这条 40 是**默认命名空间的 CONNECT + auth**，
 *   之后再发 `40<ns>,` 进命名空间。
 *
 * @param namespace 非默认命名空间时，先发默认 ns 的 auth CONNECT，
 *                  服务端回 40{"sid":...} 后再由调用方发 encodeConnect(namespace)
 */
/**
 * 编码默认命名空间的 CONNECT with auth。
 *
 * ⚠ 帧必须是 `40{"token":...}` —— 4 后面那个**子类型 0 不能漏**。
 *   漏了会变成 `4{"token":...}`，服务端 socket.io 解析不出CONNECT，
 *   静默丢弃（server.log 里完全看不到该连接），症状就是 auth 永远超时。
 *   同一个坑在 encodeConnect 里也踩过，两处现在都带 SUB_CONNECT。
 *
 * @param namespace 保留参数（签名兼容）；默认 ns 的帧里不带 ns
 * @param token    登录令牌，会放进 socket.io 的 auth 字段
 */
export function encodeConnectAuth(namespace: string, token: string): string {
  return `${EnginePacket.MESSAGE}${SUB_CONNECT}${JSON.stringify(newAuthPayload(token))}`;
}

/** socket.io 的 auth 载荷。ArkTS 不允许内联对象字面量类型，必须具名 */
export interface AuthPayload {
  token: string;
}

/** 从 Socket.IO 事件 JSON 里取出事件名 */
export function eventNameOf(payload: string): string {
  try {
    const arr = JSON.parse(payload) as Object[];
    if (Array.isArray(arr) && arr.length > 0 && typeof arr[0] === 'string') {
      return arr[0];
    }
  } catch (e) {
    return '';
  }
  return '';
}

/** 取出事件的业务参数（去掉事件名本身） */
export function eventArgsOf(payload: string): Object[] {
  try {
    const arr = JSON.parse(payload) as Object[];
    if (Array.isArray(arr)) {
      return arr.slice(1);
    }
  } catch (e) {
    return [];
  }
  return [];
}

/** 心跳包 */
export function pingFrame(): string {
  return EnginePacket.PING;
}

export function pongFrame(): string {
  return EnginePacket.PONG;
}

/**
 * 构造握手 URL。
 *
 * ⚠ 这里踩过一个坑：之前把 namespace 当成路径段拼上去，生成
 *   ws://host:8748/chat-run?token=xxx
 * 完全连不上。socket.io 的路径**恒为 /socket.io/**，namespace 是握手之后
 * 在消息帧里表达的（默认命名空间就是 `/`，不需要额外协商）。
 *
 * Engine.IO v4 必需的两个 query 参数（缺一个服务端就不认）：
 *   EIO=4        协议版本
 *   transport    传输方式（本项目只用 websocket，不做 polling 降级）
 *
 * ⚠ token **不走 query**：URL 会出现在代理日志、访问日志、抓包工具里，
 *   拼在 query 里等于把登录凭证写进传输路径。实测服务端只认
 *   socket.io 的 auth 帧（connect() 里 sendAuthConnectWhenOpen 发送），
 *   query 里的 token 服务端根本不读，纯属多余。
 *
 * @param baseUrl   http(s) 基址
 * @param namespace 命名空间，**仅用于帧层**，不参与 URL
 */
export function buildWsUrl(baseUrl: string, namespace: string): string {
  const cleaned = baseUrl.replace(/^http/, 'ws').replace(/\/+$/, '');
  return `${cleaned}/socket.io/?EIO=4&transport=websocket`;
}

/**
 * 构造握手要用的 Origin 头。
 *
 * 🔴 这段逻辑在实测中被证明**对 HarmonyOS 无效**，保留仅为兼容其它 WebSocket 栈
 *   （以及将来若系统允许覆盖 Origin 的场景）。
 *
 * 问题背景（2026-10-07 实测定位）
 *   HarmonyOS 的 `webSocket.connect()` 会**强制**盖一个 Origin 头，
 *   值是 `ohos://<pc-ip>`（从 PC 端 server.log 的
 *   `[Socket.IO] rejected upgrade origin` 告警里的 origin 字段拿到）。
 *   传自定义 header 想覆盖它 → **无效**，服务端仍收到 ohos://（已实测验证）。
 *
 *   服务端 Ekko Studio 的 origin 判定（反编译 resources/webui/dist/server/index.js）：
 *     ```js
 *     function sP(t) {                    // 归一化 Origin
 *       let n = new URL(t);
 *       return n.protocol !== "http:" && n.protocol !== "https:" ? null : n.origin;
 *     }
 *     function C0e(t, e, n = "") {        // 是否允许
 *       let o = sP(t);
 *       return o ? (白名单命中 || 同源回退) : 仅当 CORS_ORIGINS="*" 才为真;
 *     }
 *     ```
 *   `sP()` 对非 http/https 协议**一律返回 null**，于是 `ohos://` 走不到
 *   白名单分支，也走不到同源回退分支。
 *
 * 实测对照（_test/probe2.js，RFC6455 裸握手打 8748）
 *     Origin=http://192.168.1.10:8748  → 101（命中同源回退，无需任何配置）
 *     Origin=http://localhost:8748    → 400（同源回退要求 host 完全一致）
 *     Origin=ohos://192.168.1.10       → 400
 *
 * ⇒ 唯一解：PC 侧设用户级环境变量 `CORS_ORIGINS=*` 并重启 Ekko Studio。
 *   实测设完之后上面三种 Origin 全部返回 101。
 *
 * @param baseUrl http(s) 基址，如 `http://192.168.1.10:8748`
 * @returns       握手 header 里要用的 Origin 值；基址不合法时返回空串（不覆盖）
 */
export function buildOriginHeader(baseUrl: string): string {
  const cleaned = baseUrl.trim().replace(/\/+$/, '');
  // 只接受 http/https 基址；其它形态交给服务端默认值处理
  if (!/^https?:\/\//i.test(cleaned)) {
    return '';
  }
  return cleaned;
}

/** 空实现的 hooks：ArkTS 不允许对象字面量里写带类型的箭头函数，用类实现接口 */
class NoopHooks implements SocketClientHooks {
  onEvent(name: string, args: Object[]): void {
  }

  onStatus(status: string, detail: string): void {
  }
}

function bytesToString(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    s += String.fromCharCode(bytes[i]);
  }
  // 兜底解码 UTF-8（中文占多字节）
  try {
    return decodeURIComponent(escape(s));
  } catch (e) {
    return s;
  }
}

// ───────────────────────── 高层客户端 ─────────────────────────

export interface SocketClientHooks {
  /** 事件名 + 参数数组。ArkTS 禁止 unknown[]，统一用 Object[] */
  onEvent(name: string, args: Object[]): void;
  onStatus(status: string, detail: string): void;
}

export class SocketClient {
  private bridge: SocketLike | null = null;
  private namespace: string = '/';
  private baseUrl: string = '';
  private token: string = '';
  private connected: boolean = false;
  /** auth CONNECT 是否已被服务端确认（收到 40{"sid":...}） */
  private authOk: boolean = false;
  /** waitAuthAck 的等待者队列 */
  private authWaiters: Array<() => void> = [];
  /** 是否已收到 Engine.IO OPEN 帧（`0{...}`）；发 auth CONNECT 前必须等它 */
  private openReceived: boolean = false;
  /** auth CONNECT 是否在 OPEN 之前就发了（收到 OPEN 后需要补发） */
  private authSentBeforeOpen: boolean = false;
  /** 目标命名空间是否已回执（`40/<ns>,{"sid":...}`） */
  private nsOk: boolean = false;
  /** 等命名空间回执的等待者队列 */
  private nsWaiters: Array<() => void> = [];
  /** 等 OPEN 的等待者队列 */
  private openWaiters: Array<() => void> = [];
  /** ack 自增序号；**必须从 1 起**（0 会被 socket.io 当作"不要 ack"） */
  private ackSeq: number = 1;
  private pendingAcks = new Map<number, (args: Object[]) => void>();
  private retry: number = 0;
  private hooks: SocketClientHooks = new NoopHooks();

  static statusValues: string[] = ['disconnected', 'connecting', 'connected', 'error', 'reconnecting'];

  setHooks(h: SocketClientHooks): void {
    this.hooks = h;
  }

  isConnected(): boolean {
    return this.connected;
  }

  /**
   * 连上并建立命名空间。
   *
   * @param namespace socket.io 命名空间。**实测群聊必须是 /group-chat** ——
   *              默认 `/` 能连上但收不到任何消息事件。
   * @param baseUrl  http(s) 基址，内部会转成 ws(s)
   * @param token    登录令牌，走 query（可选，服务端连接本身不校验）
   */
  async connect(namespace: string, baseUrl: string, token: string): Promise<boolean> {
    this.namespace = namespace;
    // 传空串就回退到全局配置，调用方不用自己判断
    this.baseUrl = baseUrl.length > 0 ? baseUrl : NetConfig.getBaseUrl();
    this.token = token;
    this.hooks.onStatus('connecting', '');
    // 每次重连都要重置握手状态
    this.openReceived = false;
    this.authSentBeforeOpen = false;
    this.nsOk = false;
    this.nsWaiters = [];
    this.openWaiters = [];
    this.authOk = false;
    this.authWaiters = [];
    // ⚠ 重连前必须清掉旧 bridge：否则旧 ws 的 message/close/error 回调仍挂在上层，
    //   服务端一旦再推送，旧回调会以已失效的 namespace/状态继续触发 onFrame。
    //   off 各事件类型移除 handler，再关掉旧 ws 连接（SocketBridge.off 按类型整删）。
    if (this.bridge !== null) {
      this.bridge.off('message');
      this.bridge.off('close');
      this.bridge.off('error');
      this.bridge.off('open');
      await this.bridge.close();
      this.bridge = null;
    }
    const bridge = new SocketBridge();
    this.bridge = bridge;

    bridge.on('message', (d) => {
      const raw = typeof d === 'string' ? d : bytesToString(d);
      this.onFrame(raw);
    });
    bridge.on('close', () => {
      this.connected = false;
      SocketClient.log(`底层 WS 关闭 ns=${this.namespace}`);
      this.hooks.onStatus('disconnected', '');
    });
    bridge.on('error', (d) => {
      this.connected = false;
      this.hooks.onStatus('error', d);
    });

    const url = buildWsUrl(this.baseUrl, this.namespace);
    SocketClient.log(`connect ns=${namespace} url=${url}`);

    // 尝试覆盖 Origin。注意：HarmonyOS 会强制覆盖掉这个头（实测无效），
//  真正放行靠 PC 侧 CORS_ORIGINS=*。详见 buildOriginHeader 注释。
    const origin = buildOriginHeader(this.baseUrl);
    const handshakeHeaders: Record<string, string> = {};
    if (origin.length > 0) {
      handshakeHeaders['Origin'] = origin;
      SocketClient.log(`origin override -> ${origin}`);
    }

    try {
      await bridge.connect(url, handshakeHeaders);
      this.connected = true;
      this.retry = 0;
      this.hooks.onStatus('connected', '');
      // 🔑 token 走 socket.io 的 auth 帧（实测 2026-10-06）：
      //   服务端不回 token 时对 /group-chat 直接回
      //     44/group-chat,{"message":"Unauthorized"}
      //   帧格式就是 `40` + JSON，即 socket.io 的 CONNECT with auth。
      //
      // ⚠ 时序：必须**等收到 Engine.IO 的 OPEN 帧（`0{...}`）再发**。
      //   实测（2026-10-07）在 connect() resolve 后立刻发，服务端**收不到**
      //   （server.log 里没有该连接的 namespace 记录），auth 永远超时；
      //   等 OPEN 到达后再发则正常。用 Node 探针（_test/probe_sio.js）
      //   复现验证过：延后发 → 收到 `40{"sid":...}` 回执。
      await this.sendAuthConnectWhenOpen(bridge, token);
      SocketClient.log(`sent 40 with auth frame=${encodeConnectAuth(this.namespace, token).substring(0, 40)}…`);
      return true;
    } catch (e) {
      const err = e as Error;
      SocketClient.log(`connect failed: ${err.message ?? 'connect failed'}`);
      // 失败路径必须清理半开的 bridge，否则旧对象仍挂在 this.bridge 上，
      // 它的 on('close')/on('error') 回调可能在下次 connect 后继续触发脏回调。
      if (this.bridge !== null) {
        this.bridge.off('message');
        this.bridge.off('close');
        this.bridge.off('error');
        this.bridge.off('open');
        try {
          await this.bridge.close();
        } catch (x) {
          // 已销毁则忽略
        }
        this.bridge = null;
      }
      this.hooks.onStatus('error', err.message ?? 'connect failed');
      return false;
    }
  }

  /**
   * 发 auth CONNECT。
   *
   *为什么要等 OPEN：Engine.IO 协议里客户端应先收到 OPEN(`0{...}`)
   *  再发 socket.io 的 CONNECT。提前发**大概率**被丢弃（连接建了但 auth 没进中间件）。
   *
   * ⚠ 但也不能死等：实测 PC 负载高时 OPEN 可能 3秒以后才到（群聊握手实测 3.3s），
   *   等太久则 auth 一直超时。两头都要顾到，做法是：
   *     1. 最多等 OPEN 8 秒（覆盖慢场景）；
   *     2. 超时也先发一次，不让连接卡死；
   *     3. 若OPEN 之后才发过（即超时分支），收到 OPEN 时**补发一次**
   *        （socket.io 允许重复 CONNECT，服务端按最新处理）。
   *
   * @param bridge 底层 WS
   * @param token  登录令牌
   * @returns 是否等到了 OPEN（仅日志用）
   */
  private async sendAuthConnectWhenOpen(bridge: SocketBridge, token: string): Promise<boolean> {
    const gotOpen: boolean = await new Promise<boolean>((resolve) => {
      if (this.openReceived) {
        resolve(true);
        return;
      }
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve(false);
        }
      }, 8000);
      this.openWaiters.push(() => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(true);
        }
      });
    });
    // 等到了 OPEN → 正常发；没等到 → 也发（并标记需要补发）
    if (!gotOpen) {
      this.authSentBeforeOpen = true;
      SocketClient.log('OPEN 未到，先发 auth CONNECT，等 OPEN 到达后补发');
    }
    await bridge.send(encodeConnectAuth(this.namespace, token));
    return gotOpen;
  }

  /** 调试日志：hdc shell "hilog -x | grep SockTrace" */
  static log(msg: string): void {
    try {
      hilog.info(0xD00, 'SockTrace', '%{public}s', msg);
    } catch (e) {
    }
  }

  /**
   * 等 auth CONNECT 被服务端确认（收到 `40{"sid":...}`）。
   *
   * 🔑 为什么必须等：connect() 返回 true 只代表 **WebSocket 通道建好了**，
   *   但此时命名空间还没放行 —— 服务端要先验 auth 通过才回
   *   `40{"sid":...,"pid":...}`。不等就发事件，服务端按未认证处理。
   *
   * @param timeoutMs 等待上限。超时返回 false（调用方要能降级）
   */
  waitAuthAck(timeoutMs: number = 8000): Promise<boolean> {
    if (this.authOk) {
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          SocketClient.log(`auth ack timeout after ${timeoutMs}ms`);
          resolve(this.authOk);
        }
      }, timeoutMs);
      // 复用 pendingAcks 的机制不行（ackId 走的是 socket.io 层），
      // 这里注册一个一次性回调，由 onFrame 在收到 40{"sid"} 时触发
      this.authWaiters.push(() => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(this.authOk);
        }
      });
    });
  }

  /** 收到默认 ns 的 CONNECT ack 时唤醒等待者 */
  private notifyAuthOk(): void {
    const list = this.authWaiters.slice();
    this.authWaiters = [];
    for (const cb of list) {
      cb();
    }
  }

  /** 命名空间回执到达时唤醒等待者 */
  private notifyNsOk(ns: string): void {
    const list = this.nsWaiters.slice();
    this.nsWaiters = [];
    for (const cb of list) {
      cb();
    }
  }

  /**
   * 等目标命名空间的 CONNECT 回执。
   *
   * ⚠ 为什么必须等（实测 2026-10-07 群聊）：
   *   `waitAuthAck` 只保证**默认命名空间**的 auth 过了，
   *   此时 `40/<ns>,{token}` 刚发出去、服务端还没回执。
   *   立刻发 join 会被当未入命名空间丢弃，界面一直收不到消息，
   *   而且服务端不报错，排查起来极其隐蔽。
   *
   * @param timeoutMs 等待上限；超时也放行，避免连接彻底卡死
   * @returns 是否真的收到了回执
   */
  async waitNamespaceAck(timeoutMs: number = 6000): Promise<boolean> {
    if (this.namespace === '/' || this.namespace.length === 0) {
      return true;
    }
    if (this.nsOk) {
      return true;
    }
    return new Promise<boolean>((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          SocketClient.log(`命名空间回执超时 ns=${this.namespace}`);
          resolve(this.nsOk);
        }
      }, timeoutMs);
      this.nsWaiters.push(() => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(true);
        }
      });
    });
  }

  private async onFrame(raw: string): Promise<void> {
    SocketClient.log(`<< ${raw.length > 220 ? raw.slice(0, 220) + '…' : raw}`);
    const frame = decodeFrame(raw);
    if (frame === null) {
      return;
    }
    // Engine.IO OPEN（`0{...}`）—— 收到后才允许发 socket.io 的 CONNECT。
    if (frame.type === EnginePacket.OPEN) {
      this.openReceived = true;
      // 若之前是「没等到 OPEN 就先发了」，这里补发一次（见 sendAuthConnectWhenOpen）
      if (this.authSentBeforeOpen && this.bridge !== null) {
        this.authSentBeforeOpen = false;
        SocketClient.log('OPEN 已到，补发 auth CONNECT');
        this.bridge.send(encodeConnectAuth(this.namespace, this.token)).catch(() => {});
      }
      const list = this.openWaiters.slice();
      this.openWaiters = [];
      for (const cb of list) {
        cb();
      }
      return;
    }
    if (frame.type === EnginePacket.PONG) {
      return;
    }
    if (frame.type === EnginePacket.PING) {
      // 服务端要心跳，回 PONG
      if (this.bridge !== null) {
        this.bridge.send(pongFrame()).catch(() => {});
      }
      return;
    }
    if (frame.type === EnginePacket.MESSAGE) {
      // 按 socket.io 子类型分派，不能靠 payload 是否为空来判断 ——
      // CONNECT ack 的 payload 是 {"sid":...}，非空。
      if (frame.subType === SUB_CONNECT) {
        if (frame.namespace === '/') {
          // 默认命名空间的 CONNECT ack = `40{"sid":...,"pid":...}`
          // 这是**auth CONNECT 的回执** —— 通过了才进目标命名空间。
          this.authOk = true;
          SocketClient.log(`auth ok, entering ns ${this.namespace}`);
          if (this.bridge !== null && this.namespace !== '/' && this.namespace.length > 0) {
            // ⚠ 必须带 token：命名空间这层要单独再交一次 auth，
            //   只在握手 query 里带了 token 不算（实测见 encodeConnect 注释）。
            this.bridge.send(encodeConnect(this.namespace, this.token)).catch(() => {});
          }
          this.notifyAuthOk();
        } else {
          // 目标命名空间的 CONNECT ack = `40/<ns>,{"sid":...}`
          // 收到它才算真正进了这个命名空间，之后才能发 join / emit。
          // ⚠ 实测（2026-10-07 群聊）：不等这一帧就发 join 的话，
          //   join 会被服务端当未入命名空间丢弃，界面永远收不到消息。
          this.nsOk = true;
          SocketClient.log(`ns ok: ${frame.namespace}`);
          this.notifyNsOk(frame.namespace);
        }
        this.hooks.onStatus('connected', frame.namespace);
        return;
      }
      if (frame.subType === SUB_CONNECT_ERROR) {
        let msg = '连接被服务端拒绝';
        try {
          const o = JSON.parse(frame.payload) as Record<string, string>;
          if (o && typeof o['message'] === 'string') {
            msg = o['message'];
          }
        } catch (e) {
          // 保留默认文案
        }
        SocketClient.log(`CONNECT_ERROR ns=${frame.namespace} msg=${msg}`);
        this.connected = false;
        this.hooks.onStatus('error', msg);
        return;
      }
      if (frame.subType === SUB_ACK) {
        const cb = this.pendingAcks.get(frame.ackId);
        if (cb !== undefined) {
          this.pendingAcks.delete(frame.ackId);
          cb(eventArgsOf(frame.payload));
        }
        return;
      }
      if (frame.subType === SUB_EVENT) {
        // 我们自己 emit 时带了 ack 的回执
        if (frame.ackId >= 0) {
          const cb = this.pendingAcks.get(frame.ackId);
          if (cb !== undefined) {
            this.pendingAcks.delete(frame.ackId);
            cb(eventArgsOf(frame.payload));
            return;
          }
        }
        const name = eventNameOf(frame.payload);
        if (name.length > 0) {
          this.hooks.onEvent(name, eventArgsOf(frame.payload));
        }
      }
    }
  }

  /** 发一条带 ack 的事件 */
  /**
   * 发一条带 ack 的事件。
   *
   * ⚠ 必须有超时：socket 连不上 / 服务端不回 ack 时，
   *   Promise 会**永远挂起**，调用方（页面 await）就一直卡住 ——
   *   实测症状是「进群聊后消息区一直空着，什么都不发生，也不报错」。
   *   超时后 reject，调用方能给出明确提示，而不是静默卡死。
   */
  emitWithAck(event: string, data: Object, timeoutMs: number = 12000): Promise<Object[]> {
    // ⚠ ackId 必须从 **1** 开始。
    //   socket.io v5 约定 ackId=0 表示「这条不要 ack」，若从 0 起发，
    //   第一条带 ack 的事件会被当成无 ack 请求，服务端**静默不回ack**
    //   （实测 2026-10-07 群聊 join：ackSeq 初值 0 → 12 秒超时）。
    const ackId = this.ackSeq++;
    const json = JSON.stringify([event, data]);
    return new Promise<Object[]>((resolve, reject) => {
      let settled = false;
      // ArkTS 不允许在 setTimeout 回调里直接改外层变量语义，这里用标记位
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          this.pendingAcks.delete(ackId);
          reject(new Error(`${event} 超时（${timeoutMs}ms 无响应），请检查与电脑的连接`));
        }
      }, timeoutMs);

      this.pendingAcks.set(ackId, (args: Object[]) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(args);
      });
      if (this.bridge === null) {
        settled = true;
        clearTimeout(timer);
        reject(new Error('未连接'));
        return;
      }
      this.bridge.send(encodeMessage(this.namespace, ackId, json)).catch((e: Error) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        this.pendingAcks.delete(ackId);
        reject(e);
      });
    });
  }

  /** 发一条不带 ack 的事件 */
  emit(event: string, data: Object): void {
    if (this.bridge === null) {
      return;
    }
    const json = JSON.stringify([event, data]);
    this.bridge.send(encodeMessage(this.namespace, -1, json)).catch(() => {});
  }

  /**
   * 发一条**不期待 ack** 的事件（fire-and-forget）。
   *
   * ⚠ 为什么群聊的 join / message 不用 emitWithAck（实测 2026-10-07）：
   *   本服务端对**带 ackId 的上行帧不回 ack** ——
   *   `4<ns>,<ackId><subType>[...]` 发出去后，服务端既不回 ack，
   *   连普通推送都不再下发（Node 探针与 App 两侧都复现）。
   *   而**不带 ack 的同一事件完全正常**：
   *     join → 服务端立刻开始推 room_agent_activity / message
   *     message → 消息入库并广播，Agent 正常回复
   *   ⇒ 所以这里显式区分「要不要 ack」，避免调用方等一个永远不会来的回执。
   *
   * @returns 是否成功送入发送队列
   */
  emitNoAck(event: string, data: Object): boolean {
    if (this.bridge === null || !this.connected) {
      return false;
    }
    const json = JSON.stringify([event, data]);
    this.bridge.send(encodeMessage(this.namespace, -1, json)).catch(() => {});
    SocketClient.log(`emit(no-ack) ${event}`);
    return true;
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    this.pendingAcks.clear();
    if (this.bridge !== null) {
      await this.bridge.close();
      this.bridge = null;
    }
    SocketClient.log(`disconnect() 主动断开 ns=${this.namespace}`);
    this.hooks.onStatus('disconnected', '');
  }
}