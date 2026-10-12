/**
 * Studio API：对接运行在 PC 上的 Ekko Studio 服务端（可选通路）。
 *
 * 鸿蒙端两条数据通路，可共存：
 *  A. 本地优先（默认）：数据落手机 SQLite，Agent 直连模型 API。
 *     见 data/Repos.ets + net/LlmEngine.ets。
 *  B. 连接服务端：填 PC 上的 Ekko Studio 地址登录，复用服务端已有的 Agent 运行时。
 *     见本文件 + net/SocketClient.ets。
 *
 * ArkTS 要点：所有 JSON.parse 结果都 as 成 model/Json.ets 里的显式 interface。
 */

import { Net, getOpts, postOpts, postOptsSlow, putOpts, deleteOpts, errorMessage, NetConfig, HttpError } from './Http';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SocketClient, SocketClientHooks } from './SocketClient';
import {
  AuthStatusPayload, CurrentUserPayload, HealthPayload, LoginPayload,
  emptyModelList, emptySessionList, emptyRoomList, emptyRoomAgentList,
  emptyAgentList, emptyProviderList, emptyMessageList,
  SessionListPayload, MessageListPayload, RoomListPayload, RoomAgentListPayload,
  AgentListPayload, ProviderListPayload,
  UserPayload, SessionPayload, MessagePayload, RoomPayload, RoomDetailPayload,
  RoomAgentPayload, AgentProfilePayload, ProviderPayload,
  ChatRunBody, ChatRunPayload,
  JobListPayload, KanbanListPayload, UsagePayload, MemoryListPayload,
  ModelsConfigPayload, ModelItemLike, RemoteProviderBody, RemoteProviderResult,
  ProfilePayload, ProfileListPayload, ProfileCreateBody, DefaultModelBody, ModelsConfig,
  strOf, numOf, boolOf
} from '../model/Json';
import {
  CurrentUser, SessionSummary, ChatMessage, GroupMessage, RoomInfo, RoomAgent, AgentProfile, Provider,
  ProviderApiMode, AgentRuntime, UserRole, MessageRole, ConnectionStatus, AgentMode,
  RemoteProfile
} from '../model/Types';
import { RoomAgent as RoomAgentModel } from '../model/Types';

  /** 群聊消息载荷（实测字段） */
export interface GcMessage {
  id: string;
  roomId: string;
  senderId: string;
  senderName: string;
  content: string;
  timestamp: number;
  role: string;
}
/** 流式增量载荷：delta 拼到 id 对应的那条消息上 */
export interface GcDelta {
  roomId: string;
  id: string;
  delta: string;
}
/** @ 提及引用（发给服务端的形状） */
export interface GcMention {
  type: string;
  participantId: string;
  displayName: string;
}
/** join 的 ack 形状（房间详情，节选） */
export interface GcJoinAck {
  error?: string;
  roomId?: string;
  roomName?: string;
  totalTokens?: number;
}
/** message emit 的 ack 形状 */
export interface GcSendAck {
  error?: string;
  id?: string;
}
/**
 * 群聊 socket 的回调集合。
 *
 * ⚠ ArkTS 不允许在方法参数位置写内联函数类型
 *   （`onEvent: (name: string, args: Object[]) => void` 会报
 *    arkts-no-untyped-obj-literals + arkts-no-implicit-return-types），
 *   函数类型只能声明在 interface 里，所以这里用对象传回调。
 */
/**
 * ⚠ 直接复用 SocketClient 的 hooks 类型，**不要自己定义一份结构相同的**：
 *   ArkTS 禁止结构化类型（arkts-no-structural-typing），
 *   两个字段完全一样但名字不同的 interface 也不能互传。
 */
export type GcHandlers = SocketClientHooks;
/** join / message emit 的请求体（对象字面量必须对应具名 interface） */
export interface GcJoinBody {
  roomId: string;
}
export interface GcMessageBody {
  roomId: string;
  id: string;
  content: string;
  mentions: GcMention[];
}
export interface GcHistoryBody {
  roomId: string;
  before: number;
  limit: number;
  history: boolean;
}
export interface GcTypingBody {
  roomId: string;
}

/** 群聊审批响应 body */
export interface GcApprovalRespondBody {
  roomId: string;
  approvalId: string;
  choice: string;
}

/** 群聊澄清响应 body */
export interface GcClarifyRespondBody {
  roomId: string;
  clarifyId: string;
  response: string;
}
/** load_messages 的 ack 形状 */
export interface GcHistoryAck {
  messages?: GcMessage[];
  error?: string;
}

export interface ServerProbe {
  ok: boolean;
  message: string;
}

// ── 阶段二只读 ViewModel ──
// 只用于展示，不需要完整的领域语义，所以放在 net 层而不是 model/Types.ets。

/** 服务端定时任务 */
export interface RemoteJob {
  id: string;
  name: string;
  schedule: string;
  prompt: string;
  enabled: boolean;
  nextRunAt: number;
  lastRunAt: number;
  lastStatus: string;
  runCount: number;
}

/** 服务端看板任务 */
export interface RemoteTask {
  id: string;
  title: string;
  status: string;
  priority: string;
  assignee: string;
  boardSlug: string;
  description: string;
  blockedReason: string;
  updatedAt: number;
}

/** 用量：按模型拆分的单行 */
export interface UsageRow {
  model: string;
  provider: string;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  cost: number;
  requests: number;
}

/** 服务端用量汇总 */
export interface RemoteUsage {
  totalInputTokens: number;
  totalOutputTokens: number;
  totalTokens: number;
  totalCost: number;
  sessions: number;
  byModel: UsageRow[];
}

/** 服务端记忆条目 */
export interface RemoteMemory {
  id: string;
  content: string;
  scope: string;
  source: string;
  tags: string;
  pinned: boolean;
  importance: number;
  updatedAt: number;
}

/** 服务端技能（只读，字段来自实测，openapi 无 schema） */
export interface RemoteSkill {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
  source: string;
  version: string;
  updatedAt: number;
}

/** 服务端 MCP 服务器（只读） */
export interface RemoteMcpServer {
  name: string;
  transport: string;
  command: string;
  /** 命令行参数，数组会被拼成空格分隔的字符串 */
  args: string;
  envCount: number;
  enabled: boolean;
  status: string;
}

/** 服务端模型分组（按供应商，Models 页用） */
export interface RemoteModelGroup {
  provider: string;
  models: string[];
}

/** PC 工作区里的一个文件夹 */
export interface RemoteFolder {
  name: string;
  path: string;
}

// ───────────────────────── 单聊 socket（/chat-run）─────────────────────────

/**
 * 单聊 socket 传给 connectChatRun 的回调。
 *
 * ⚠ 必须是 `SocketClientHooks` 的**类型别名**，不能另起一个 interface ——
 *   ArkTS 禁止结构化类型（arkts-no-structural-typing），
 *   两个形状相同的 interface 也不能互传。
 *   所以这里跟GcHandlers 一样用 type别名，页面侧再用 ChatRunBridge
 *   实现 SocketClientHooks 后把事件翻译成具名回调。
 */
export type CrHandlers = SocketClientHooks;

/**
 * 单聊 socket 的具名事件回调集合（页面侧实现这个）。
 *
 * 设计成「按事件名分开」而不是一个泛化的 onEvent ——
 * 页面要处理 20+ 种事件，用具名方法比 switch 事件名字符串清晰得多，
 * 也避免拼错字符串静默失效。
 */
export interface CrEventSink {
  /** 任意事件（用于日志与调试） */
  onAny: (name: string, args: Object[]) => void;
  /** 连接状态变化 */
  onStatus: (status: string, detail: string) => void;
  /** 运行开始 */
  onRunStarted: (args: Object[]) => void;
  /** 文本增量（打字机） */
  onDelta: (args: Object[]) => void;
  /** 运行结束（ok=true 完成，false 失败） */
  onRunDone: (ok: boolean, args: Object[]) => void;
  /** 需要审批 */
  onApproval: (req: CrApprovalRequest) => void;
  /** 审批已解决 */
  onApprovalResolved: (args: Object[]) => void;
  /** 需要澄清（Agent 反问） */
  onClarify: (req: CrClarifyRequest) => void;
  /** 澄清已解决 */
  onClarifyResolved: (args: Object[]) => void;
  /** 子 Agent 文本（多 Agent 委派链） */
  onSubagent: (name: string, args: Object[]) => void;
  /** 用量更新 */
  onUsage: (args: Object[]) => void;
}

/** run 事件的 payload */
export interface CrRunBody {
  session_id: string;
  profile: string;
  input: string;
}

/** 只带 session_id 的事件 payload（abort 等） */
export interface CrSessionBody {
  session_id: string;
}

/** approval.respond 的 payload（形状来自安卓版实测） */
export interface CrApprovalRespond {
  session_id: string;
  approval_id: string;
  choice: string;
}

/** clarify.respond 的 payload（形状来自安卓版实测） */
export interface CrClarifyRespond {
  session_id: string;
  clarify_id: string;
  response: string;
}

/**
 * 审批请求。
 *
 * ⚠ 字段名以真机实测为准 —— 安卓版里存的是 requestId，
 *   但发回去时用 approval_id，所以两个都要认。
 */
export interface CrApprovalRequest {
  sessionId: string;
  approvalId: string;
  title: string;
  detail: string;
  /** 备选项，服务端给的话优先显示成按钮 */
  choices: string[];
}

/** 澄清请求（Agent 反问） */
export interface CrClarifyRequest {
  sessionId: string;
  clarifyId: string;
  question: string;
  /** 候选项（可为空 = 自由输入） */
  choices: string[];
}

/** 服务端运行日志（只读） */
export interface RemoteLog {
  id: string;
  /** 毫秒时间戳 */
  ts: number;
  level: string;
  scope: string;
  message: string;
}

export class StudioApi {
  // ArkTS 不支持 X['key'] 这种索引访问类型做断言，
  // 所以角色/运行时/协议枚举都走具名收敛函数，白名单放行。
  static toUserRole(s: string): UserRole {
    if (s === 'super_admin' || s === 'admin' || s === 'user') {
      return s;
    }
    return 'user';
  }

  static toRuntime(s: string): AgentRuntime {
    const known: string[] = [
      'hermes', 'ekko', 'claude-code', 'codex', 'pi', 'grok', 'opencode',
      'dsh', 'cursor', 'antigravity', 'qwen', 'kimi', 'codebuddy', 'qoder', 'copilot', 'zcode'
    ];
    if (known.indexOf(s) >= 0) {
      return s as AgentRuntime;
    }
    return 'ekko';
  }

  static toApiMode(s: string): ProviderApiMode {
    if (s === 'anthropic' || s === 'gemini' || s === 'openai_responses' || s === 'responses') {
      return s as ProviderApiMode;
    }
    return 'chat_completions';
  }

  static toAgentMode(s: string): AgentMode {
    return s === 'global' ? 'global' : 'scoped';
  }

  static toConnStatus(s: string): ConnectionStatus {
    return s === 'offline' ? 'offline' : 'online';
  }

  /** 服务端是否需要登录 */
  static async authStatus(): Promise<AuthStatusPayload> {
    const res = await Net.send(getOpts('/api/auth/status', ''));
    return StudioApi.parseAuthStatus(res.body);
  }

  static parseAuthStatus(body: string): AuthStatusPayload {
    const payload = JSON.parse(body) as AuthStatusPayload;
    return {
      hasPasswordLogin: payload.hasPasswordLogin === true,
      hasUsers: payload.hasUsers === true
    };
  }

  static async login(username: string, password: string): Promise<LoginPayload> {
    const body = JSON.stringify(newLoginBody(username, password));
    const res = await Net.send(postOpts('/api/auth/login', body, ''));
    const payload = JSON.parse(res.body) as LoginPayload;
    return payload;
  }

  static async me(token: string): Promise<CurrentUser> {
    const res = await Net.send(getOpts('/api/auth/me', token));
    const payload = JSON.parse(res.body) as CurrentUserPayload;
    return StudioApi.toCurrentUser(payload);
  }

  static toCurrentUser(payload: CurrentUserPayload): CurrentUser {
    const u: UserPayload = payload.user;
    return {
      id: typeof u.id === 'number' ? u.id : 0,
      username: typeof u.username === 'string' ? u.username : '',
      role: StudioApi.toUserRole(typeof u.role === 'string' ? u.role : ''),
      status: typeof u.status === 'string' ? u.status : '',
      createdAt: typeof u.created_at === 'number' ? u.created_at : 0,
      lastLoginAt: typeof u.last_login_at === 'number' ? u.last_login_at : null,
      avatar: typeof u.avatar === 'string' ? u.avatar : ''
    };
  }

  /** 健康检查（连接状态指示灯） */
  static async ping(): Promise<boolean> {
    try {
      const opts = getOpts('/api/health', '');
      opts.timeout = 5000;
      await Net.send(opts);
      return true;
    } catch (e) {
      return false;
    }
  }

  static async listSessions(token: string): Promise<SessionSummary[]> {
    const res = await Net.send(getOpts('/api/studio/sessions', token));
    const payload = JSON.parse(res.body) as SessionListPayload;
    const list = payload.sessions;
    if (list === undefined || list === null) {
      return [];
    }
    const out: SessionSummary[] = [];
    for (const s of list) {
      out.push(StudioApi.toSession(s));
    }
    return out;
  }

  /**
   * GET /api/studio/search/sessions?q=&limit=&source= —— 服务端搜索会话。
   *
   * 为什么必须有（部署形态是「PC 当服务端 + 手机远程控制」）：
   * 台式机上会攒几百个会话，手机端只能顺序滚动，根本找不到想要的。
   * 这个端点是**服务端侧**搜索，比手机端把全部拉下来再过滤快得多，也不受列表长度限制。
   *
   * 参数（openapi 实测）：q（搜索词）/ limit / source（按来源过滤）
   * ⚠ 响应 schema 是空的，形状按 {sessions:[...]} / 裸数组 两种都兜，
   *   复用 toSession 解析。
   */
  static async searchSessions(token: string, q: string, limit: number,
    source: string = ''): Promise<SessionSummary[]> {
    let path = `/api/studio/search/sessions?limit=${limit}`;
    if (q.length > 0) {
      path += `&q=${encodeURIComponent(q)}`;
    }
    if (source.length > 0) {
      path += `&source=${encodeURIComponent(source)}`;
    }
    const res = await Net.send(getOpts(path, token));
    const body = res.body.trim();
    if (body.length === 0) {
      return [];
    }
    if (body.startsWith('{')) {
      const obj = JSON.parse(body) as Record<string, Object>;
      const arr = obj['sessions'] ?? obj['items'] ?? obj['data'] ?? obj['results'];
      if (Array.isArray(arr)) {
        return StudioApi.toSessions(arr as SessionPayload[]);
      }
      return [];
    }
    return StudioApi.toSessions(JSON.parse(body) as SessionPayload[]);
  }

  private static toSessions(list: SessionPayload[]): SessionSummary[] {
    const out: SessionSummary[] = [];
    for (const s of list) {
      if (s === null || s === undefined) {
        continue;
      }
      out.push(StudioApi.toSession(s));
    }
    return out;
  }

  /**
   * GET /api/studio/files/read?path= —— 读电脑上的工作区文件。
   *
   * 部署形态是「PC 当服务端 + 手机远程控制」，Agent 干活的工作区在 PC 上，
   * 手机端要看 Agent 改了哪些文件，就必须能读 PC 的磁盘，不能只看手机本地。
   *
   * ⚠ path 是**相对于 PC 工作区根**的（openapi 参数名就叫 path，不是绝对路径）——
   *   手机端不传绝对路径，避免越权读到工作区外。
   */
  static async readRemoteFile(token: string, path: string): Promise<string> {
    const res = await Net.send(
      getOpts(`/api/studio/files/read?path=${encodeURIComponent(path)}`, token));
    const body = res.body;
    // 端点可能返回裸文本，也可能返回 {content:"..."}
    if (body.startsWith('{')) {
      const obj = JSON.parse(body) as Record<string, Object>;
      const c = obj['content'] ?? obj['text'] ?? obj['data'];
      if (typeof c === 'string') {
        return c;
      }
    }
    return body;
  }

  /** GET /api/studio/workspace/folders?path= —— PC 工作区里的文件夹 */
  static async listRemoteFolders(token: string, path: string): Promise<RemoteFolder[]> {
    const res = await Net.send(
      getOpts(`/api/studio/workspace/folders?path=${encodeURIComponent(path)}`, token));
    let arr: Object[] = [];
    const body = res.body.trim();
    if (body.length === 0) {
      return [];
    }
    if (body.startsWith('[')) {
      arr = JSON.parse(body) as Object[];
    } else {
      const obj = JSON.parse(body) as Record<string, Object>;
      for (const k of ['folders', 'items', 'data', 'list', 'entries']) {
        const v = obj[k];
        if (Array.isArray(v)) {
          arr = v as Object[];
          break;
        }
      }
    }
    const out: RemoteFolder[] = [];
    for (const raw of arr) {
      if (raw === null || raw === undefined) {
        continue;
      }
      const it = raw as Record<string, Object>;
      out.push({
        name: StudioApi.pickStr(it, ['name', 'folder', 'dir']),
        path: StudioApi.pickStr(it, ['path', 'fullPath', 'full_path'])
      });
    }
    return out;
  }

  /**
   * 字段映射依据是**真实响应**（账号 ALEX，2026-10-06 实测），不是 OpenAPI ——
   * 那个端点只声明了 `sessions: [{}]`，元素 schema 是空的。
   *
   * 踩过的坑：之前按直觉写了 pinned / created_at / updated_at / channel / active，
   * 实测服务端一个都没有，导致会话列表里
   *   · 置顶状态恒为「未置顶」
   *   · 排序全靠 0（本地兜底），PC 上新建的会话会排到最末尾
   * 正确名字：is_pinned / started_at / ended_at / last_active。
   */
  static toSession(s: SessionPayload): SessionSummary {
    const lastActive = numOf(s.last_active);
    return {
      id: strOf(s.id),
      title: strOf(s.title),
      source: strOf(s.source, 'api_server'),
      categoryId: typeof s.category_id === 'number' ? s.category_id : null,
      workspace: strOf(s.workspace),
      model: strOf(s.model),
      provider: strOf(s.provider),
      channel: strOf(s.channel),
      // 会话级 agent（codebuddy/claude/codex），气泡上要显示「这条是谁说的」
      agent: strOf(s.agent),
      // profile：切 agent =切 active profile
      profile: strOf(s.profile, 'default'),
      // 实测字段就叫 preview（不是 last_message_preview），
      // 之前没读它，会话列表一直显示「暂无消息」
      lastMessagePreview: strOf(s.preview),
      // 服务端是 0/1 数字，numOf + 比较，避免 undefined 被当真
      pinned: numOf(s.is_pinned) > 0,
      active: s.active === true,
      messageCount: numOf(s.message_count),
      // 时间戳是**秒级**，本地库存的是毫秒 —— 不换算会导致 1970 排序
      createdAt: numOf(s.started_at) * 1000,
      updatedAt: (lastActive > 0 ? lastActive : numOf(s.started_at)) * 1000
    };
  }

  static async sessionMessages(token: string, sessionId: string, limit: number): Promise<ChatMessage[]> {
    // ⚠ 必须走 /conversations/ 这一层。实测对照（2026-06）：
    //   /api/studio/sessions/{id}/messages              → 404
    //   /api/studio/sessions/conversations/{id}/messages → 200
    //
    // ⚠⚠ 空会话（建了但一条消息都没发）服务端**没有 conversation 记录**，
    //   会返回 404 {"error":"Conversation not found"}。
    //   这**不是错误**，就该显示空列表 —— 之前一律当失败抛出去，
    //   于是用户点开任何空会话都看到「加载失败：HTTP404」。
    try {
      const res = await Net.send(
        getOpts(`/api/studio/sessions/conversations/${sessionId}/messages?limit=${limit}`, token));
      const payload = JSON.parse(res.body) as MessageListPayload;
      const list = payload.messages;
      if (list === undefined || list === null) {
        return [];
      }
      const out: ChatMessage[] = [];
      for (const m of list) {
        out.push(StudioApi.toMessage(m));
      }
      return out;
    } catch (e) {
      // 404 = 空会话，返回空列表（显示引导语），不当作加载失败
      const err = e as HttpError;
      if (err.code === 404) {
        return [];
      }
      throw new Error(err.message ?? '加载失败');
    }
  }


  static toMessage(m: MessagePayload): ChatMessage {
    const msg: ChatMessage = {
      // ⚠ id 服务端是数字（实测 104149），必须 String() 转换。
      //   用 typeof 判断会全变空串，ForEach key 重复 → 只渲染一个气泡。
      id: m.id === null || m.id === undefined ? '' : String(m.id),
      sessionId: typeof m.session_id === 'string' ? m.session_id : '',
      role: StudioApi.toRole(typeof m.role === 'string' ? m.role : ''),
      content: typeof m.content === 'string' ? m.content : '',
      timestamp: typeof m.timestamp === 'number' ? m.timestamp : 0
    };
    // P2-9：服务端单聊消息还带 blocks / usage / toolTrace / reasoning / error，
    // 之前只搬 role/content/timestamp，工具调用轨迹、token 用量、错误详情全丢。
    if (m.blocks !== undefined && m.blocks !== null) {
      msg.blocks = m.blocks;
    }
    if (m.usage !== undefined && m.usage !== null) {
      msg.usage = m.usage;
    }
    if (m.toolTrace !== undefined && m.toolTrace !== null) {
      msg.toolTrace = m.toolTrace;
    }
    if (typeof m.reasoning === 'string' && m.reasoning.length > 0) {
      msg.reasoning = m.reasoning;
    }
    if (typeof m.error === 'string' && m.error.length > 0) {
      msg.error = m.error;
    }
    return msg;
  }

  static toRole(s: string): MessageRole {
    if (s === 'user' || s === 'assistant' || s === 'system' || s === 'tool') {
      return s;
    }
    return 'assistant';
  }

  static async listRooms(token: string): Promise<RoomInfo[]> {
    const res = await Net.send(getOpts('/api/studio/group-chat/rooms', token));
    const payload = JSON.parse(res.body) as RoomListPayload;
    const list = payload.rooms;
    if (list === undefined || list === null) {
      return [];
    }
    const out: RoomInfo[] = [];
    for (const r of list) {
      out.push(StudioApi.toRoom(r));
    }
    return out;
  }

  static toRoom(r: RoomPayload): RoomInfo {
    return {
      id: typeof r.id === 'string' ? r.id : '',
      name: typeof r.name === 'string' ? r.name : '',
      inviteCode: typeof r.inviteCode === 'string' ? r.inviteCode : null,
      ownerMemberId: '',
      summaryProfile: '',
      summaryProvider: '',
      summaryModel: '',
      summaryApiMode: '',
      summaryEveryTurns: 0,
      totalTokens: typeof r.totalTokens === 'number' ? r.totalTokens : 0,
      workspace: typeof r.workspace === 'string' ? r.workspace : '',
      agentHandoffEnabled: false,
      agentHandoffUnlimited: false,
      createdAt: typeof r.createdAt === 'number' ? r.createdAt : 0,
      lastActiveAt: typeof r.lastActiveAt === 'number' ? r.lastActiveAt : 0
    };
  }

  /**
   * 单个群聊详情（实测 2026-06：GET /api/studio/group-chat/rooms/{roomId} → 200）。
   * 房间不存在时服务端返回 404，这里转成 null（调用方按「不存在」处理）。
   */
  /**
   * 群聊详情（实测 2026-06）。
   *
   * ⚠ 端点：GET /api/studio/group-chat/rooms/{roomId}  → 200
   *
   * ⚠⚠ 响应**不是** `{rooms:[...]}` 也不是裸房间对象，而是**聚合包**：
   *   { room:{...26 个字段}, messages:[...], agents:[...], members:[...],
   *     handoffChains:[...], total, offset, limit, hasMore, historyTruncated }
   *   （一次把房间+消息+成员全给了，比「list 再逐个拉 agents/messages」省很多往返）
   *
   * 之前按「{rooms:[...]} / 裸对象」两种形状去猜，都不匹配 → 返回 null
   * → 页面提示「群聊不存在」，而后端其实一直返回 200。
   * **教训：响应形状必须实测，别猜。**
   *
   * @param withDetail true 时顺带把 agents 填进 RoomInfo，省掉页面再拉一次
   *                   （messages 走 socket load_messages，这里不塞）
   */
  static async getRoom(token: string, roomId: string, withDetail: boolean = false): Promise<RoomInfo | null> {
    try {
      const res = await Net.send(getOpts(`/api/studio/group-chat/rooms/${roomId}`, token));
      const p = JSON.parse(res.body) as RoomDetailPayload;
      const r = p.room;
      if (r === null || r === undefined || strOf(r.id).length === 0) {
        return null;
      }
      const payload: RoomPayload = {
        id: strOf(r.id),
        name: strOf(r.name),
        inviteCode: strOf(r.inviteCode),
        workspace: strOf(r.workspace),
        totalTokens: numOf(r.totalTokens),
        createdAt: numOf(r.createdAt),
        lastActiveAt: numOf(r.lastActiveAt)
      };
      const room = StudioApi.toRoom(payload);
      if (withDetail) {
        const agents = p.agents;
        if (Array.isArray(agents)) {
          room.agents = [];
          for (const a of agents) {
            room.agents.push(StudioApi.toRoomAgent(a as RoomAgentPayload));
          }
        }
      }
      return room;
    } catch (e) {
      const err = e as Error;
      // 只有 404 才算「房间不存在」；网络/鉴权错误必须照抛，
      // 否则会把「连不上 PC」误报成「房间被删了」。
      if (err instanceof HttpError && err.code === 404) {
        return null;
      }
      throw err;
    }
  }

  /**
   * 群聊消息（**HTTP 版**，不依赖 socket）。
   *
   * 为什么不走 socket（实测 2026-06）：
   *   鸿蒙 `@ohos.net.webSocket` 对 `?transport=websocket` 的请求，
   *   服务端返回 **code=200**（当成普通 HTTP 处理），没进 WebSocket 升级流程；
   *   而 socket.io 客户端能连是因为它先走 `transport=polling` 握手拿 sid 再升级。
   *   完整实现两阶段握手工作量大，所以历史消息改走这个 HTTP 聚合端点。
   *
   * 端点实测：GET /api/studio/group-chat/rooms/{roomId}
   *   → { room, messages[150], agents[8], members, handoffChains, total, ... }
   *   id 全部唯一（150/150），可以直接当 ForEach key。
   *
   * 代价：没有实时打字机（新消息要手动刷新）。等 socket 两阶段握手做好再切回。
   */
  static async listRoomMessages(token: string, roomId: string, limit: number = 150): Promise<GcMessage[]> {
    const res = await Net.send(getOpts(`/api/studio/group-chat/rooms/${roomId}`, token));
    const p = JSON.parse(res.body) as RoomDetailPayload;
    const msgs = p.messages;
    if (!Array.isArray(msgs)) {
      return [];
    }
    // 端点按升序返回消息（旧→新）。取**末尾** limit 条，即最新 limit 条历史。
    // ⚠ 之前从头部取 limit 条，会把最新消息丢掉（端点 150 条、limit 100 时丢最新 50 条）。
    const start = msgs.length > limit ? msgs.length - limit : 0;
    const out: GcMessage[] = [];
    for (let i = start; i < msgs.length; i++) {
      // ArkTS 禁止结构化类型：GcMessageLike 与 GcMessage 同构但不能直接互传，
      // 逐字段搬一遍（实测服务端消息的字段与 GcMessage 一致）。
      const m = msgs[i];
      out.push({
        id: strOf(m.id),
        roomId: strOf(m.roomId),
        senderId: strOf(m.senderId),
        senderName: strOf(m.senderName),
        content: strOf(m.content),
        timestamp: numOf(m.timestamp),
        role: strOf(m.role, 'assistant')
      });
    }
    return out;
  }

  static async roomAgents(token: string, roomId: string): Promise<RoomAgent[]> {
    const res = await Net.send(
      getOpts(`/api/studio/group-chat/rooms/${roomId}/agents`, token));
    const payload = JSON.parse(res.body) as RoomAgentListPayload;
    const list = payload.agents;
    if (list === undefined || list === null) {
      return [];
    }
    const out: RoomAgent[] = [];
    for (const a of list) {
      out.push(StudioApi.toRoomAgent(a));
    }
    return out;
  }

  static toRoomAgent(a: RoomAgentPayload): RoomAgent {
    return {
      id: typeof a.id === 'string' ? a.id : '',
      roomId: typeof a.roomId === 'string' ? a.roomId : '',
      agentId: typeof a.agentId === 'string' ? a.agentId : '',
      agent: StudioApi.toRuntime(typeof a.agent === 'string' ? a.agent : ''),
      agentMode: StudioApi.toAgentMode(typeof a.agentMode === 'string' ? a.agentMode : ''),
      profile: typeof a.profile === 'string' ? a.profile : '',
      provider: typeof a.provider === 'string' ? a.provider : '',
      model: typeof a.model === 'string' ? a.model : '',
      apiMode: typeof a.apiMode === 'string' ? a.apiMode : '',
      agentPreset: '',
      reasoningEffort: typeof a.reasoningEffort === 'string' ? a.reasoningEffort : '',
      name: typeof a.name === 'string' ? a.name : '',
      description: typeof a.description === 'string' ? a.description : '',
      avatar: '',
      invited: typeof a.invited === 'number' ? a.invited : 0,
      executorType: 'server',
      connectionStatus: StudioApi.toConnStatus(typeof a.connectionStatus === 'string' ? a.connectionStatus : '')
    };
  }

  /**
   * Agent 列表。
   *
   * ⚠ 数据源踩了个大坑，走了三步才找对：
   *   1. /api/studio/coding-agents  → 404（多了 studio/ 前缀）
   *   2. /api/coding-agents         → 200，但返回的是 **{tools:[...]}**
   *      那是**编码 CLI 工具**（qwen / claude-code / codex…），
   *      不是 Agent 配置；按 {agents:[...]} 解析会得到 undefined → 列表永远空
   *      （这就是之前「只有通用助手」的原因之一）
   *   3. /api/studio/group-chat/agent-presets → 200 但 presets 为空（还没建预设）
   *
   * **正确做法**：Agent 实际存在于**群聊房间的成员**里，
   * 所以遍历所有房间把成员去重聚合。实测该账号有 8 个（hermes/codex/dsh/grok…）。
   */
  static async listAgents(token: string): Promise<AgentProfile[]> {
    const rooms = await StudioApi.listRooms(token);
    const seen: string[] = [];
    const out: AgentProfile[] = [];
    for (const r of rooms) {
      // listRooms 不带 members，这里逐个房间拉
      const members = await StudioApi.roomAgents(token, r.id);
      for (const m of members) {
        // agentId 可能重复（同一 Agent 在多个房间），按它去重
        const key = m.agentId.length > 0 ? m.agentId : m.name;
        let dup = false;
        for (const s of seen) {
          if (s === key) {
            dup = true;
            break;
          }
        }
        if (dup) {
          continue;
        }
        seen.push(key);
        out.push(StudioApi.roomAgentToProfile(m));
      }
    }
    return out;
  }

  /** 房间成员 → 本地 AgentProfile（Agent 管理页展示用） */
  static roomAgentToProfile(m: RoomAgent): AgentProfile {
    return {
      id: m.agentId.length > 0 ? m.agentId : m.id,
      name: m.name.length > 0 ? m.name : m.agent,
      runtime: m.agent,
      provider: m.provider,
      model: m.model,
      apiMode: StudioApi.toApiMode(m.apiMode),
      systemPrompt: m.description,
      reasoningEffort: m.reasoningEffort,
      toolsEnabled: false,
      enabled: true,
      updatedAt: 0
    };
  }


  static toAgent(a: AgentProfilePayload): AgentProfile {
    return {
      id: typeof a.id === 'string' ? a.id : '',
      name: typeof a.name === 'string' ? a.name : '',
      runtime: StudioApi.toRuntime(typeof a.runtime === 'string' ? a.runtime : ''),
      provider: typeof a.provider === 'string' ? a.provider : '',
      model: typeof a.model === 'string' ? a.model : '',
      apiMode: StudioApi.toApiMode(typeof a.apiMode === 'string' ? a.apiMode : ''),
      systemPrompt: typeof a.systemPrompt === 'string' ? a.systemPrompt : '',
      reasoningEffort: typeof a.reasoningEffort === 'string' ? a.reasoningEffort : '',
      toolsEnabled: false,
      enabled: a.enabled !== false,
      updatedAt: 0
    };
  }

  /**
   * 读服务端的模型/供应商配置。
   *
   * ⚠ 路径和结构都是**实测**出来的，之前写的 `/api/studio/providers` 是错的
   *   （实测返回 404 Not Found）。
   * 真实可用：`GET /api/hermes/config/models`
   *   → { default: "模型 id", groups: [ { provider: "Custom", models: [{id,label}, ...] } ] }
   *   另有 `GET /api/hermes/available-models`（带 default_provider / 分组计数，更轻）
   *
   * 映射成本地 Provider[]：一个 group 一个 Provider，models 取组内全部模型 id。
   * 这样「设置 → 供应商」里看到的就直接是 PC 上配好的那些。
   */
  static async listProviders(token: string): Promise<Provider[]> {
    const res = await Net.send(getOpts('/api/hermes/config/models', token));
    const p = JSON.parse(res.body) as ModelsConfigPayload;
    const groups = p.groups;
    if (!Array.isArray(groups) || groups.length === 0) {
      return [];
    }
    const out: Provider[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      if (g === null || g === undefined) {
        continue;
      }
      const models: string[] = [];
      const ms = g.models;
      if (Array.isArray(ms)) {
        for (const m of ms) {
          const id = (m as ModelItemLike).id;
          if (typeof id === 'string' && id.length > 0) {
            models.push(id);
          }
        }
      }
      const name = strOf(g.provider, '供应商');
      out.push({
        id: 'srv-' + i.toString() + '-' + name,
        name: name,
        baseUrl: '',
        // ⚠ 服务端不下发 api key（也不该下发），留空 —— 手机端不会拿它去调模型，
        //   模型调用统一走 POST /api/studio/chat-run/runs，由服务端执行。
        apiKey: '',
        apiKeyState: 'empty',
        apiMode: 'chat_completions',
        models: models,
        enabled: true,
        builtin: false,
        updatedAt: 0
      });
    }
    return out;
  }

  static toProvider(p: ProviderPayload): Provider {
    const models: string[] = [];
    if (Array.isArray(p.models)) {
      for (const m of p.models) {
        if (typeof m === 'string') {
          models.push(m);
        }
      }
    }
    return {
      id: typeof p.id === 'string' ? p.id : '',
      name: typeof p.name === 'string' ? p.name : '',
      baseUrl: typeof p.baseUrl === 'string' ? p.baseUrl : '',
      apiKey: typeof p.apiKey === 'string' ? p.apiKey : '',
      // 服务端 ProviderPayload 不带状态位：按明文长度推断两态。
      // 服务端不会下发密文，非空即 'ok'，空即 'empty'（服务端模式下本字段不用于本地校验）。
      apiKeyState: (typeof p.apiKey === 'string' && p.apiKey.length > 0) ? 'ok' : 'empty',
      apiMode: StudioApi.toApiMode(typeof p.apiMode === 'string' ? p.apiMode : ''),
      models: models,
      enabled: p.enabled !== false,
      builtin: false,
      updatedAt: 0
    };
  }

  /** 校验服务端地址（登录页「测试连接」用） */
  /**
   * 发消息并等待完成。
   *
   * 端点：POST /api/studio/chat-run/runs
   * 注意：这是**等待式**接口（summary: "Run chat and wait for completion"），
   * 返回时才拿到完整 output，中途没有增量。
   * 想要打字机效果必须另接 socket.io 的 message_stream_delta 事件
   * （见 net/SocketClient.ets 的 subscribeStream）。
   */
  static async chatRun(token: string, body: ChatRunBody): Promise<ChatRunPayload> {
    // ⚠ session_id 是**可选字段**（实测 2026-10）：
    //   "Optional session id. Omit this to create a new session automatically."
    // 新建对话时 body 里根本没有这个键（不是空串），
    // 空串会被服务端当成 id='' 去查 → 404。
    //
    // 超时给15 分钟：服务端 timeout_ms 上限 1800000（30 分钟），
    // 默认 30 秒一定会超时（实测跑 coding agent 就要几分钟）。
    const res = await Net.send(
      postOptsSlow('/api/studio/chat-run/runs', JSON.stringify(body), token, 900000));
    const p = JSON.parse(res.body) as ChatRunPayload;
    return {
      ok: p.ok === true,
      status: typeof p.status === 'string' ? p.status : '',
      session_id: typeof p.session_id === 'string' ? p.session_id : '',
      run_id: typeof p.run_id === 'string' ? p.run_id : '',
      output: typeof p.output === 'string' ? p.output : '',
      reasoning: typeof p.reasoning === 'string' ? p.reasoning : ''
    };
  }

  // ───────────────────────────────────────────────────────────
  // 群聊 Socket 通道（实测 2026-10-06，账号 ALEX + 房间「工具」）
  //
  // ⚠ 三个关键点全是实测踩出来的：
  //
  // 1. **命名空间是 /group-chat，不是默认 /**
  //    三个命名空间同时连做对照：默认 / 连上但收不到任何事件；
  //    /chat-run 只有 session.activity.snapshot；只有 /group-chat 收得到消息。
  //
  // 2. **必须先 join，服务端按房间分发**
  //    emit('join', {roomId}) 带 ack，ack 里是房间详情
  //    （roomName / members / totalTokens…）。roomId 错了 ack 会带 error。
  //
  // 3. **发消息也是 emit，不是 HTTP**
  //    emit('message', {roomId, id, content, mentions}, ack)
  //      → ack = {id}                 服务端已接收
  //      → 紧接着广播 message 事件    自己那条也回来了（senderId:'auth:1'）
  //      → Agent 干活时陆续推 message_stream_delta（一个字的增量）
  //
  // 消息 id 形如 gcmsg_<roomId>_<profile>_<ts>_<q>_<rand>_part_0，
  // 流式分片共用同一个 id —— 用它把 delta 拼成完整消息。
  // ───────────────────────────────────────────────────────────












/** 群聊 socket 事件名（实测拼写） */
  static readonly GC_JOIN = 'join';
  static readonly GC_MESSAGE = 'message';
  static readonly GC_LOAD_MESSAGES = 'load_messages';
  static readonly GC_TYPING = 'typing';
  static readonly GC_STREAM_DELTA = 'message_stream_delta';
  // start / end 是安卓版订阅的（之前只处理 delta，缺这两个导致流式气泡收尾不对）
  static readonly GC_STREAM_START = 'message_stream_start';
  static readonly GC_STREAM_END = 'message_stream_end';
  static readonly GC_REASONING_DELTA = 'message_reasoning_delta';
  static readonly GC_ROOM_UPDATED = 'room_updated';
  static readonly GC_QUEUE_UPDATED = 'execution_queue_updated';
  static readonly GC_MESSAGE_RETRACTED = 'message_retracted';
  static readonly GC_MEMBERS = 'members_updated';

  /**
   * 群聊侧还有一批 `group.*` 前缀的事件（从服务端打包产物 grep 出来的全集，
   * 2026-10-07）。群聊的审批/澄清走这里，不是 chat-run 那套。
   */
  static readonly GC_GROUP_MESSAGE_CREATED = 'group.message.created';
  static readonly GC_GROUP_RUN_UPDATED = 'group.run.updated';
  static readonly GC_GROUP_RUN_FAILED = 'group.run.failed';
  static readonly GC_GROUP_PLAN_UPDATED = 'group.plan.updated';
  static readonly GC_GROUP_APPROVAL_REQ = 'group.approval.requested';
  static readonly GC_GROUP_APPROVAL_RESOLVED = 'group.approval.resolved';
  static readonly GC_GROUP_CLARIFY_REQ = 'group.clarification.requested';
  static readonly GC_GROUP_CLARIFY_RESOLVED = 'group.clarification.resolved';
  /** 客户端 → 服务端：回复群聊审批 */
  static readonly GC_GROUP_APPROVAL_RESPOND = 'group.approval.respond';
  /** 客户端 → 服务端：回复群聊澄清 */
  static readonly GC_GROUP_CLARIFY_RESPOND = 'group.clarification.respond';

  /** 群聊命名空间：实测唯一能收到消息的 */
  static readonly NS_GROUP_CHAT = '/group-chat';
  /**
   * 单聊命名空间。
   *
   * ⚠ 之前注释写「实测只有 session.activity.snapshot，消息不在这里」——
   *   那个结论**不完整**。从安卓版反编译（AppSingleChatView.vue）确认：
   *   单聊走的就是这个命名空间，且支持**真流式 + 交互**：
   *     收 run.started / run.delta? / subagent.* / usage.updated
   *       approval.requested / clarify.requested   ← Agent 反向提问
   *     发 run / abort / insert_queued_run / cancel_queued_run
   *       approval.respond / clarify.respond
   *   所以单聊**能打字机**，不必用等待式 chat-run（那是降级方案）。
   */
  static readonly NS_CHAT_RUN = '/chat-run';

  // ── 单聊 socket 事件名（从安卓版 AppSingleChatView.vue 的订阅列表抄下来）──

  /** 发起一次运行。payload: {session_id, profile, input, ...} */
  static readonly CR_RUN = 'run';
  /** 中断当前运行 */
  static readonly CR_ABORT = 'abort';
  /** 运行开始 */
  static readonly CR_RUN_STARTED = 'run.started';
  /**
   * 文本增量。
   *
   * ⚠ 事件名是 **`message.delta`**，不是 `run.delta`（实测 2026-10-07 抓包确认）。
   *   之前按安卓版逆向写成 run.delta，结果 App 一个字都收不到，
   *   界面一直停在「Agent 正在处理」。
   *   同一序列里还有：
   *     thinking.delta      {text}                思考增量
   *     reasoning.available                      思考结果可取
   *     usage.updated        {inputTokens,outputTokens,contextTokens}
   *     session.activity    {status}              running / completed
   *   完整序列见 _test/probe_events.js 的输出。
   */
  static readonly CR_RUN_DELTA = 'message.delta';
  /** 思考增量 */
  static readonly CR_THINKING_DELTA = 'thinking.delta';
  /** 思考结果可用 */
  static readonly CR_REASONING_AVAILABLE = 'reasoning.available';
  /** 运行完成 */
  static readonly CR_RUN_COMPLETED = 'run.completed';

  /**
   * 中止完成事件。
   *
   * ⚠ 服务端收到 abort 后会回这两个事件（真机 21:13 实测）：
   *   abort.started → abort.completed
   * 页面**必须处理** —— 中止的 run 不会有 run.completed，
   * 不监听 abort.completed 的话气泡会一直停在「正在处理」。
   */
  static readonly CR_ABORT_STARTED = 'abort.started';
  static readonly CR_ABORT_COMPLETED = 'abort.completed';
  /** 运行失败 */
  static readonly CR_RUN_FAILED = 'run.failed';
  /** 子 Agent 开始（多 Agent 委派链） */
  static readonly CR_SUBAGENT_START = 'subagent.start';
  static readonly CR_SUBAGENT_TEXT = 'subagent.text';
  static readonly CR_SUBAGENT_THINKING = 'subagent.thinking';
  static readonly CR_SUBAGENT_TOOL = 'subagent.tool';
  static readonly CR_SUBAGENT_COMPLETE = 'subagent.complete';
  /** 委派状态更新 */
  static readonly CR_DELEGATION_UPDATED = 'delegation.updated';
  /** 用量更新 */
  static readonly CR_USAGE_UPDATED = 'usage.updated';

  // ── 审批 / 澄清（Agent 反向向用户提问）──
  //
  // ⚠ 这是安卓版有、鸿蒙版完全没做的能力。
  //   场景：Agent 跑着跑着要写文件 / 要钱 / 拿不准，要问你。
  //   服务端会挂起 run 等你回答，5 分钟不答就超时。
  //   payload（安卓版实测）：
  //     收 approval.requested → {session_id, requestId(approval_id), ...}
  //     发 approval.respond  → {session_id, approval_id, choice}
  //     收 clarify.requested  → {session_id, requestId(clarify_id), question, choices?}
  //     发 clarify.respond   → {session_id, clarify_id, response}

  /** 需要人工审批 */
  static readonly CR_APPROVAL_REQ = 'approval.requested';
  static readonly CR_APPROVAL_RESOLVED = 'approval.resolved';
  /** 回审批 */
  static readonly CR_APPROVAL_RESPOND = 'approval.respond';
  /** 需要澄清（Agent 反问） */
  static readonly CR_CLARIFY_REQ = 'clarify.requested';
  static readonly CR_CLARIFY_RESOLVED = 'clarify.resolved';
  /** 回澄清 */
  static readonly CR_CLARIFY_RESPOND = 'clarify.respond';

  private gcSocket: SocketClient | null = null;
  /** connectGroupChat 是否正在建连（互斥用，见该方法注释） */
  private gcConnecting: boolean = false;
  private gcRoom: string = '';

  // ── 单聊 socket ──
  private crSocket: SocketClient | null = null;
  /** connectChatRun 是否正在建连（互斥用，见该方法注释） */
  private crConnecting: boolean = false;
  private crSession: string = '';

  /** 单聊 socket 是否已连上 */
  isChatRunConnected(): boolean {
    return this.crSocket !== null && this.crSocket.isConnected();
  }

  /**
   * 连上单聊命名空间（/chat-run）。
   *
   * 复用 SocketClient —— auth CONNECT + 等 ack 的那套已经在群聊上验证过。
   * 连上后**不自动订阅会话**，调用方按需发 `run` 时带 session_id，
   * 或用 attachSession 让服务端开始推送该会话的事件。
   */
  async connectChatRun(baseUrl: string, token: string, handlers: CrHandlers): Promise<boolean> {
    if (this.crSocket !== null && this.crSocket.isConnected()) {
      return true;
    }
    //⚠ 互斥：connectChatRun 要等 8 秒auth ack，期间 crSocket 还是 null。
    //   ChatPage 在 aboutToAppear 和首帧渲染时会各调一次，
    //   没有这把锁就会**并发建两条 socket**（实测日志里两个不同 sid）。
    //   后果：同一会话被订阅两次，事件翻倍、白白占两条连接。
    if (this.crConnecting) {
      return false;
    }
    this.crConnecting = true;
    try {
      await this.disconnectChatRun();

      const sock = new SocketClient();
      sock.setHooks(handlers);
      const ok = await sock.connect(StudioApi.NS_CHAT_RUN, baseUrl, token);
      if (!ok) {
        return false;
      }
      // 和群聊一样：必须等 auth 通过，否则后续事件全被当未认证丢弃
      const authed = await sock.waitAuthAck(8000);
      if (!authed) {
        StudioApi.sockLog('单聊 auth 未通过');
        await sock.disconnect();
        return false;
      }
      this.crSocket = sock;
      StudioApi.sockLog('单聊 socket 已连接');
      return true;
    } finally {
      this.crConnecting = false;
    }
  }

  /** 断开单聊 socket */
  async disconnectChatRun(): Promise<void> {
    this.crSession = '';
    if (this.crSocket !== null) {
      await this.crSocket.disconnect();
      this.crSocket = null;
    }
  }

  /**
   * 通过 socket 发起一次运行（真流式的正路）。
   *
   * payload 字段名取自安卓版 AppSingleChatView.vue 的调用点。
   * ⚠ 没有 ack 就当成功发出 —— 服务端对 run 不回 ack，
   *   真正的结果从 run.started / run.completed 事件回来。
   */
  emitChatRun(sessionId: string, profile: string, input: string): boolean {
    if (this.crSocket === null || !this.crSocket.isConnected()) {
      return false;
    }
    const body: CrRunBody = {
      session_id: sessionId,
      profile: profile,
      input: input
    };
    // 记下当前 session，abort 事件要带（之前没记，导致中止发的是空 session_id）
    this.crSession = sessionId;
    this.crSocket.emit(StudioApi.CR_RUN, body);
    return true;
  }

  /** 中断当前运行（页面点「中止」用这个）。
   *
   * ⚠ 之前页面点中止只清了本地状态，没告诉服务端 ——
   *   服务端那边模型还在跑、还会继续推 delta，界面却以为结束了。
   *   真正的中止必须发 abort 事件（服务端会回 abort.started / abort.completed）。
   */
  emitChatAbort(sessionId: string): boolean {
    if (this.crSocket === null || !this.crSocket.isConnected()) {
      return false;
    }
    const body: CrSessionBody = { session_id: sessionId };
    this.crSocket.emit(StudioApi.CR_ABORT, body);
    return true;
  }

  /** 回复审批（choice 传同意/拒绝的具体值，由服务端定义） */
  emitApprovalRespond(sessionId: string, approvalId: string, choice: string): boolean {
    if (this.crSocket === null || !this.crSocket.isConnected()) {
      return false;
    }
    const body: CrApprovalRespond = {
      session_id: sessionId,
      approval_id: approvalId,
      choice: choice
    };
    this.crSocket.emit(StudioApi.CR_APPROVAL_RESPOND, body);
    return true;
  }

  /** 回复澄清（Agent 反问的回答） */
  emitClarifyRespond(sessionId: string, clarifyId: string, response: string): boolean {
    if (this.crSocket === null || !this.crSocket.isConnected()) {
      return false;
    }
    const body: CrClarifyRespond = {
      session_id: sessionId,
      clarify_id: clarifyId,
      response: response
    };
    this.crSocket.emit(StudioApi.CR_CLARIFY_RESPOND, body);
    return true;
  }

  /** socket 层调试日志（与 SocketClient 的 SockTrace 同 tag） */
  private static sockLog(msg: string): void {
    try {
      hilog.info(0xD00, 'SockTrace', '%{public}s', msg);
    } catch (e) {
    }
  }

  /** 当前群聊 socket 是否已连上 */
  isGroupChatConnected(): boolean {
    return this.gcSocket !== null && this.gcSocket.isConnected();
  }

  currentGroupRoom(): string {
    return this.gcRoom;
  }

  /**
   * 连上群聊并加入房间。已连上且房间未变则直接复用，不重复 join。
   * 返回 false 表示没连上/没进房，调用方应提示用户。
   */
  async connectGroupChat(baseUrl: string, token: string, roomId: string,
    handlers: GcHandlers): Promise<boolean> {
    if (this.gcSocket !== null && this.gcSocket.isConnected() && this.gcRoom === roomId) {
      return true;
    }
    // ⚠ 互斥：同connectChatRun —— 建连要等 auth + 命名空间回执，
    //   期间 gcSocket 还是 null，并发调用会建出两条 socket。
    //   ⚠ 撞上正在进行的建连时**不能直接返回 false**（实测 2026-10-07 群聊）：
    //   页面会判定「未连接」→ 提示未连接 → 消息发不出去。
    //   这里改成等对方建完，再看成功与否。
    if (this.gcConnecting) {
      StudioApi.sockLog('connectGroupChat 并发，等待进行中的建连');
      let waited = 0;
      while (this.gcConnecting && waited < 12000) {
        await new Promise<void>((r) => setTimeout(r, 200));
        waited += 200;
      }
      // 建连方可能已经进了同一个房间
      if (this.gcSocket !== null && this.gcSocket.isConnected() && this.gcRoom === roomId) {
        return true;
      }
      StudioApi.sockLog('connectGroupChat 等待后仍未连上');
      return false;
    }
    this.gcConnecting = true;
    try {
      StudioApi.sockLog(`connectGroupChat 入口 room=${roomId} 有旧连接=${this.gcSocket !== null}`);
      await this.disconnectGroupChat();

      const sock = new SocketClient();
      sock.setHooks(handlers);
      const ok = await sock.connect(StudioApi.NS_GROUP_CHAT, baseUrl, token);
      if (!ok) {
        return false;
      }
      // 🔑 必须等 auth 通过再进命名空间，否则 join 会被当未认证请求丢掉。
      // （connect 返回 true 只代表 WebSocket 通道建好了）
      const authed = await sock.waitAuthAck(8000);
      if (!authed) {
        StudioApi.sockLog('auth 未通过，放弃 join');
        await sock.disconnect();
        return false;
      }
      // ⚠ 还必须等**命名空间** CONNECT 的回执（`40/<ns>,{"sid":...}`）。
      //   waitAuthAck 只保证默认 ns 的 auth 过了，此时 `40/<ns>` 刚发出去、
      //   服务端还没回执，立刻 join 会被当未入命名空间丢弃
      //   （实测 2026-10-07：服务端不报错，但界面永远没消息，极难排查）。
      const nsAcked = await sock.waitNamespaceAck(6000);
      if (!nsAcked) {
        StudioApi.sockLog('命名空间未确认，放弃 join');
        await sock.disconnect();
        return false;
      }
      this.gcSocket = sock;

      try {
        const joinBody: GcJoinBody = { roomId: roomId };
        // ⚠ 必须用 emitNoAck，**不能**用 emitWithAck（实测 2026-10-07）：
        //   本服务端对带 ackId 的上行帧不回 ack，而且发完连普通推送都不再下发
        //   （Node 探针与 App 两侧都复现：join 带 ack → 界面空白）；
        //   不带 ack 的同一事件完全正常，join 之后立刻能收到 room_agent_activity。
        //   ⇒ 只能 fire-and-forget。
        if (!sock.emitNoAck(StudioApi.GC_JOIN, joinBody)) {
          StudioApi.sockLog('join 发送失败（未连接）');
          await this.disconnectGroupChat();
          return false;
        }
        StudioApi.sockLog('join 已发出（不等 ack）');
        this.gcRoom = roomId;
        return true;
      } catch (e) {
        await this.disconnectGroupChat();
        return false;
      }
    } finally {
      this.gcConnecting = false;
    }
  }

  /**
   * 发群聊消息。content 传纯文本。
   * 返回服务端确认的 message id（失败会 throw，错误信息来自 ack.error）。
   */
  async sendGroupMessage(roomId: string, id: string, content: string,
    mentions: GcMention[]): Promise<string> {
    if (this.gcSocket === null || !this.gcSocket.isConnected()) {
      throw new Error('未连接到服务端');
    }
    const body: GcMessageBody = {
      roomId: roomId, id: id, content: content, mentions: mentions
    };
    // ⚠ 同 join：用 emitNoAck。带 ack 的帧服务端不回 ack（实测 2026-10-07），
    //   干等 12 秒只会让界面卡在"发送中"。
    //   成败判断交给服务端广播 —— 自己那条 message 事件回来即代表入库成功。
    if (!this.gcSocket.emitNoAck(StudioApi.GC_MESSAGE, body)) {
      throw new Error('发送失败：未连接到服务端');
    }
    StudioApi.sockLog(`message 已发出 id=${id}`);
    return id;
  }

  /** 拉群聊历史（实测 body: {roomId, before, limit, history:true}） */
  async loadGroupMessages(roomId: string, before: number, limit: number): Promise<GcMessage[]> {
    if (this.gcSocket === null || !this.gcSocket.isConnected()) {
      return [];
    }
    const hBody: GcHistoryBody = {
      roomId: roomId, before: before, limit: limit, history: true
    };
    const ack = await this.gcSocket.emitWithAck(StudioApi.GC_LOAD_MESSAGES, hBody);
    if (ack.length > 0) {
      const rec = ack[0] as GcHistoryAck;
      if (Array.isArray(rec.messages)) {
        return rec.messages;
      }
    }
    return [];
  }

  /** 广播「我在输入」——群聊体感提升明显 */
  sendGroupTyping(roomId: string): void {
    if (this.gcSocket !== null && this.gcSocket.isConnected()) {
      const tBody: GcTypingBody = { roomId: roomId };
      this.gcSocket.emit(StudioApi.GC_TYPING, tBody);
    }
  }

  /**
   * 回复群聊里的审批请求。
   *
   * ⚠ 用 `emit`（不带 ack）：本服务端不支持带 ackId 的上行帧（实测 2026-10-07）。
   *
   * @param roomId    房间 id
   * @param approvalId 审批 id（从 group.approval.requested 的 payload 取）
   * @param choice    选项值（原样回传服务端给的 choice，**不要自己编**）
   * @returns 是否成功送入发送队列
   */
  respondGroupApproval(roomId: string, approvalId: string, choice: string): boolean {
    if (this.gcSocket === null || !this.gcSocket.isConnected()) {
      return false;
    }
    const body: GcApprovalRespondBody = {
      roomId: roomId,
      approvalId: approvalId,
      choice: choice
    };
    const ok: boolean = this.gcSocket.emitNoAck(StudioApi.GC_GROUP_APPROVAL_RESPOND, body);
    StudioApi.sockLog(`群聊审批响应已发出 approval=${approvalId} choice=${choice} ok=${ok}`);
    return ok;
  }

  /**
   * 回复群聊里的澄清提问。
   *
   * @param roomId     房间 id
   * @param clarifyId  澄清 id
   * @param response   用户填的回答
   */
  respondGroupClarify(roomId: string, clarifyId: string, response: string): boolean {
    if (this.gcSocket === null || !this.gcSocket.isConnected()) {
      return false;
    }
    const body: GcClarifyRespondBody = {
      roomId: roomId,
      clarifyId: clarifyId,
      response: response
    };
    const ok: boolean = this.gcSocket.emitNoAck(StudioApi.GC_GROUP_CLARIFY_RESPOND, body);
    StudioApi.sockLog(`群聊澄清响应已发出 clarify=${clarifyId} ok=${ok}`);
    return ok;
  }

  async disconnectGroupChat(): Promise<void> {
    this.gcRoom = '';
    if (this.gcSocket !== null) {
      await this.gcSocket.disconnect();
      this.gcSocket = null;
    }
  }

  // ───────────────────────────────────────────────────────────
  // 阶段二：定时 / 看板 / 用量 / 记忆（只读）
  //
  // 这些数据在手机端只做展示，不改动，所以不引入 model/Types.ets
  // 的新领域模型，直接在 net 层定义轻量 ViewModel，避免污染本地模型。
  // ───────────────────────────────────────────────────────────

  /**
   * 定时任务（只读）。
   *
   * 字段按**真实响应**映射（实测 2026-10-06）：
   *   · cron 直接用平铺的 `schedule_display`（`schedule` 是对象，用它要多一层解包）
   *   · `next_run_at` / `last_run_at` 是 **ISO 字符串**，得先转成毫秒才能排序
   *   · 运行次数在 `repeat.completed`（实测 21）
   */
  static async listJobs(token: string): Promise<RemoteJob[]> {
    const res = await Net.send(getOpts('/api/hermes/jobs', token));
    const payload = JSON.parse(res.body) as JobListPayload;
    const list = payload.jobs;
    if (!Array.isArray(list)) {
      return [];
    }
    const out: RemoteJob[] = [];
    for (const j of list) {
      if (j === null || j === undefined) {
        continue;
      }
      const rep = j.repeat;
      // 服务端 job id 是数字（实测），strOf 只收 string 会回落成 ''，
      // ForEach key 全重复 → 定时任务列表渲染异常或只剩一项。
      const rawId = j.id;
      out.push({
        id: typeof rawId === 'number' ? `${rawId}` : strOf(rawId),
        name: strOf(j.name),
        schedule: strOf(j.schedule_display),
        prompt: strOf(j.prompt),
        enabled: boolOf(j.enabled, false),
        nextRunAt: StudioApi.isoToMs(strOf(j.next_run_at)),
        lastRunAt: StudioApi.isoToMs(strOf(j.last_run_at)),
        lastStatus: strOf(j.last_status),
        runCount: rep !== undefined && rep !== null ? numOf(rep.completed) : 0
      });
    }
    return out;
  }

  /**
   * ISO 8601 → 毫秒时间戳。解析不了就返回 0（显示成「—」而不是 1970）。
   *
   * ArkTS 没有内置 Date 解析，这里手动处理服务端实际会返回的形状：
   *   2026-10-05T10:00:00+08:00
   *   2026-06-06T16:50:20.350107+08:00
   *   2026-10-05T10:00:00Z
   */
  static isoToMs(iso: string): number {
    if (iso.length < 10) {
      return 0;
    }
    const y = Number(iso.substring(0, 4));
    const mo = Number(iso.substring(5, 7));
    const d = Number(iso.substring(8, 10));
    const h = Number(iso.substring(11, 13));
    const mi = Number(iso.substring(14, 16));
    const se = Number(iso.substring(17, 19));
    if (!isFinite(y) || !isFinite(mo) || !isFinite(d)) {
      return 0;
    }
    // 时区偏移：+08:00 / -05:30 / Z
    let offsetMin = 0;
    const tzAt = iso.indexOf('T') > 0 ? (iso.length >= 25 ? iso.substring(19) : '') : '';
    if (tzAt.length >= 6) {
      const sign = tzAt.charAt(0) === '-' ? -1 : 1;
      const oh = Number(tzAt.substring(1, 3));
      const om = Number(tzAt.substring(4, 6));
      if (isFinite(oh) && isFinite(om)) {
        offsetMin = sign * (oh * 60 + om);
      }
    }
    const utc = Date.UTC(y, mo - 1, d, isFinite(h) ? h : 0, isFinite(mi) ? mi : 0,
      isFinite(se) ? se : 0);
    return utc - offsetMin * 60 * 1000;
  }

  /** GET /api/hermes/kanban */
  static async listKanban(token: string): Promise<RemoteTask[]> {
    const res = await Net.send(getOpts('/api/hermes/kanban', token));
    const payload = JSON.parse(res.body) as KanbanListPayload;
    const list = payload.tasks;
    if (list === undefined || list === null) {
      return [];
    }
    const out: RemoteTask[] = [];
    for (const t of list) {
      out.push({
        id: strOf(t.id),
        title: strOf(t.title),
        status: strOf(t.status),
        priority: strOf(t.priority),
        assignee: strOf(t.assignee),
        boardSlug: strOf(t.board_slug),
        description: strOf(t.description),
        blockedReason: strOf(t.blocked_reason),
        // 实测服务端时间是 ISO 字符串，不是数字时间戳
        updatedAt: StudioApi.isoToMs(strOf(t.updated_at))
      });
    }
    return out;
  }

  /** GET /api/studio/sessions/usage */
  static async sessionUsage(token: string): Promise<RemoteUsage> {
    const res = await Net.send(getOpts('/api/studio/sessions/usage', token));
    const p = JSON.parse(res.body) as UsagePayload;
    const rows: UsageRow[] = [];
    const raw = p.by_model;
    if (Array.isArray(raw)) {
      for (const m of raw) {
        rows.push({
          model: strOf(m.model),
          provider: strOf(m.provider),
          inputTokens: numOf(m.input_tokens),
          outputTokens: numOf(m.output_tokens),
          totalTokens: numOf(m.total_tokens),
          cost: numOf(m.cost),
          requests: numOf(m.requests)
        });
      }
    }
    return {
      totalInputTokens: numOf(p.total_input_tokens),
      totalOutputTokens: numOf(p.total_output_tokens),
      totalTokens: numOf(p.total_tokens),
      totalCost: numOf(p.total_cost),
      sessions: numOf(p.sessions),
      byModel: rows
    };
  }

  /** GET /api/ekko/memory */
  static async listMemory(token: string): Promise<RemoteMemory[]> {
    const res = await Net.send(getOpts('/api/ekko/memory', token));
    const payload = JSON.parse(res.body) as MemoryListPayload;
    const list = payload.memories;
    if (list === undefined || list === null) {
      return [];
    }
    const out: RemoteMemory[] = [];
    for (const m of list) {
      out.push({
        id: strOf(m.id),
        content: strOf(m.content),
        scope: strOf(m.scope),
        source: strOf(m.source),
        tags: strOf(m.tags),
        pinned: boolOf(m.pinned, false),
        importance: numOf(m.importance),
        updatedAt: StudioApi.isoToMs(strOf(m.updated_at))
      });
    }
    return out;
  }

  // ───────────────────────────────────────────────────────────
  // 阶段三：技能 / MCP / 日志（只读）
  //
  // ⚠ 这三个端点在 openapi 里**响应 schema 全空**，字段名只能实测。
  //   所以统一走「候选键逐个挑」的容错解析：
  //   挑不到就留空串 —— 宁可少显示一个字段，也不要显示错的。
  //   （反面教训：之前按直觉写 pinned/created_at，服务端一个都没有）
  // ───────────────────────────────────────────────────────────

  /** 通用 GET：响应可能是数组，也可能是 {logs|items|x|data|list|rows:[]} */
  private static async fetchList(token: string, path: string,
    wrapKeys: string[]): Promise<Object[]> {
    const res = await Net.send(getOpts(path, token));
    const body = res.body.trim();
    if (body.length === 0) {
      return [];
    }
    if (body.startsWith('[')) {
      const parsed = JSON.parse(body) as Object[];
      return parsed;
    }
    const obj = JSON.parse(body) as Record<string, Object>;
    for (const k of wrapKeys) {
      const v = obj[k];
      if (Array.isArray(v)) {
        return v as Object[];
      }
    }
    // 也可能是 { data: { items: [...] } } 这种再包一层
    for (const k of wrapKeys) {
      const v = obj[k];
      if (v !== undefined && v !== null && typeof v === 'object') {
        const inner = v as Record<string, Object>;
        for (const k2 of wrapKeys) {
          const v2 = inner[k2];
          if (Array.isArray(v2)) {
            return v2 as Object[];
          }
        }
      }
    }
    return [];
  }

  /** 从候选键里取第一个非空字符串 */
  private static pickStr(o: Record<string, Object>, keys: string[]): string {
    for (const k of keys) {
      const v = o[k];
      if (typeof v === 'string' && v.length > 0) {
        return v;
      }
      if (typeof v === 'number') {
        return String(v);
      }
    }
    return '';
  }

  private static pickNum(o: Record<string, Object>, keys: string[]): number {
    for (const k of keys) {
      const v = o[k];
      if (typeof v === 'number') {
        return v;
      }
      if (typeof v === 'string' && v.length >= 10) {
        const ms = StudioApi.isoToMs(v);
        if (ms > 0) {
          return ms;
        }
      }
    }
    return 0;
  }

  private static pickBool(o: Record<string, Object>, keys: string[], dflt: boolean): boolean {
    for (const k of keys) {
      const v = o[k];
      if (typeof v === 'boolean') {
        return v;
      }
      if (v === 1) {
        return true;
      }
      if (v === 0) {
        return false;
      }
    }
    return dflt;
  }

  /** GET /api/hermes/skills —— 技能列表（只读） */
  static async listSkills(token: string): Promise<RemoteSkill[]> {
    const arr = await StudioApi.fetchList(token, '/api/hermes/skills',
      ['skills', 'items', 'data', 'list', 'rows']);
    const out: RemoteSkill[] = [];
    for (const raw of arr) {
      if (raw === null || raw === undefined) {
        continue;
      }
      const it = raw as Record<string, Object>;
      const name = StudioApi.pickStr(it, ['name', 'title', 'display_name', 'id', 'slug']);
      out.push({
        id: StudioApi.pickStr(it, ['id', 'slug', 'name']),
        name: name,
        description: StudioApi.pickStr(it, ['description', 'summary', 'desc', 'detail']),
        enabled: StudioApi.pickBool(it, ['enabled', 'active'], true)
          && !StudioApi.pickBool(it, ['disabled'], false),
        source: StudioApi.pickStr(it, ['source', 'origin', 'kind', 'type']),
        version: StudioApi.pickStr(it, ['version', 'rev', 'revision']),
        updatedAt: StudioApi.pickNum(it, ['updated_at', 'updatedAt', 'created_at', 'createdAt', 'mtime'])
      });
    }
    return out;
  }

  /** GET /api/hermes/mcp/servers —— MCP 服务器（只读） */
  static async listMcpServers(token: string): Promise<RemoteMcpServer[]> {
    const arr = await StudioApi.fetchList(token, '/api/hermes/mcp/servers',
      ['servers', 'items', 'data', 'list', 'rows']);
    const out: RemoteMcpServer[] = [];
    for (const raw of arr) {
      if (raw === null || raw === undefined) {
        continue;
      }
      const it = raw as Record<string, Object>;
      const argsVal = it['args'];
      let argsText = '';
      if (Array.isArray(argsVal)) {
        const parts: string[] = [];
        for (const a of argsVal as Object[]) {
          parts.push(String(a));
        }
        argsText = parts.join(' ');
      } else if (typeof argsVal === 'string') {
        argsText = argsVal;
      }
      let envCount = 0;
      const envVal = it['env'];
      if (envVal !== undefined && envVal !== null && typeof envVal === 'object') {
        envCount = Object.keys(envVal).length;
      }
      out.push({
        name: StudioApi.pickStr(it, ['name', 'id']),
        transport: StudioApi.pickStr(it, ['transport', 'type', 'kind']),
        command: StudioApi.pickStr(it, ['command', 'cmd', 'url', 'endpoint']),
        args: argsText,
        envCount: envCount,
        enabled: StudioApi.pickBool(it, ['enabled', 'active'], true)
          && !StudioApi.pickBool(it, ['disabled'], false),
        status: StudioApi.pickStr(it, ['status', 'state', 'health'])
      });
    }
    return out;
  }

  /** GET /api/studio/logs —— 运行日志（只读） */
  static async listLogs(token: string, limit: number): Promise<RemoteLog[]> {
    const arr = await StudioApi.fetchList(token, `/api/studio/logs?limit=${limit}`,
      ['logs', 'items', 'entries', 'data', 'list']);
    const out: RemoteLog[] = [];
    for (const raw of arr) {
      if (raw === null || raw === undefined) {
        continue;
      }
      const it = raw as Record<string, Object>;
      let level = StudioApi.pickStr(it, ['level', 'severity', 'lvl']);
      if (level.length === 0) {
        level = 'info';
      }
      out.push({
        id: StudioApi.pickStr(it, ['id', 'key', '_id']),
        ts: StudioApi.pickNum(it, ['ts', 'time', 'timestamp', 'at', 'created_at']),
        level: level,
        scope: StudioApi.pickStr(it, ['scope', 'source', 'logger', 'module', 'tag']),
        message: StudioApi.pickStr(it, ['message', 'msg', 'text', 'body'])
      });
    }
    return out;
  }

  /**
   * 新建/更新服务端供应商。
   *
   * 端点（实测 2026-06）：
   *   POST   /api/hermes/config/providers   新建。body 必填 {name, base_url, model}，
   *         缺任一报 "Missing name, base_url, or model"；成功返回 {success:true}
   *   PUT    /api/hermes/config/providers/{poolKey}  更新
   *   DELETE /api/hermes/config/providers/{poolKey}  删除
   *
   * ⚠ **poolKey 带 `custom:` 前缀** —— 实测新建 `probe_test_tmp` 后，
   *   只有 `custom:probe_test_tmp` 能删掉，`probe_test_tmp` 报 404。
   * ⚠ body 是**下划线**风格（base_url / api_key），与本地 Provider 的驼峰不同。
   */
  static async createRemoteProvider(token: string, name: string, baseUrl: string,
    model: string, apiKey?: string): Promise<string> {
    const body: RemoteProviderBody = {
      name: name, base_url: baseUrl, model: model
    };
    // P1-10：apiKey 可选。服务端模式下手机端不需要配 key（Repos.ets:1044-1046
    // 的占位 Provider 逻辑），省略 api_key 让服务端复用已有配置，
    // 避免明文 POST 到 PC 端被记录到日志或数据库。
    if (apiKey !== undefined && apiKey.length > 0) {
      body.api_key = apiKey;
    }
    const res = await Net.send(
      postOpts('/api/hermes/config/providers', JSON.stringify(body), token));
    const p = JSON.parse(res.body) as RemoteProviderResult;
    if (p.success !== true) {
      throw new Error(p.error ?? '创建失败');
    }
    return 'custom:' + name;
  }

  /** 删除服务端供应商。poolKey 必须带 `custom:` 前缀 */
  static async deleteRemoteProvider(token: string, poolKey: string): Promise<void> {
    await Net.send(deleteOpts(`/api/hermes/config/providers/${poolKey}`, token));
  }

  // ───────────────────────────────────────────────────────────
  // Profile（= 用户认知里的 Agent）
  //
  // ⚠ 服务端**没有 per-request 选 agent 的参数**。chat-run 请求体里
  //   唯一相关的是 profile，但实测真正生效的是
  //   `PUT /api/hermes/profiles/active`（body: {name}）——
  //   也就是「切当前激活的 profile」。
  //   所以「新建对话选 agent」= 先切 active profile，再发首条消息。
  //
  // ⚠ openapi 里这两个端点的响应 schema 都是空的（只声明了路径），
  //   下面的解析按「数组」和「{profiles:[...]}」两种形状都兜。
  // ───────────────────────────────────────────────────────────

  /** GET /api/hermes/profiles —— 列出 PC 上的所有 profile */
  static async listProfiles(token: string): Promise<RemoteProfile[]> {
    const res = await Net.send(getOpts('/api/hermes/profiles', token));
    const out: RemoteProfile[] = [];
    const body = res.body;
    if (body.length === 0) {
      return out;
    }

    // 形状 A：顶层就是数组
    let raw: ProfilePayload[] = [];
    const trimmed = body.trim();
    if (trimmed.startsWith('[')) {
      const arr = JSON.parse(body) as ProfilePayload[];
      raw = arr;
    } else {
      // 形状 B：{profiles:[...]} / {items:[...]} / {data:[...]}
      const obj = JSON.parse(body) as ProfileListPayload;
      if (Array.isArray(obj.profiles)) {
        raw = obj.profiles;
      } else {
        const alt = JSON.parse(body) as Record<string, Object[]>;
        if (Array.isArray(alt['items'])) {
          raw = alt['items'] as ProfilePayload[];
        } else if (Array.isArray(alt['data'])) {
          raw = alt['data'] as ProfilePayload[];
        }
      }
    }

    for (const p of raw) {
      out.push(StudioApi.toProfile(p));
    }
    return out;
  }

  private static toProfile(p: ProfilePayload): RemoteProfile {
    const name = strOf(p.name);
    const disp = strOf(p.display_name, name);
    // agent 可能是字符串，也可能是个嵌套对象（两种形状都实测过）
    let agentName = strOf(p.agent);
    let model = strOf(p.model);
    if (p.agent_profile !== undefined && p.agent_profile !== null) {
      if (agentName.length === 0) {
        agentName = strOf(p.agent_profile.name);
      }
      if (model.length === 0) {
        model = strOf(p.agent_profile.model);
      }
    }
    if (model.length === 0) {
      model = strOf(p.model);
    }
    const label = agentName.length > 0 ? agentName : disp;
    return {
      name: name,
      displayName: disp.length > 0 ? disp : name,
      description: strOf(p.description),
      model: model,
      provider: strOf(p.provider),
      // 服务端没标 active 就按 name==="default" 兜（实测 default 是内置项）
      active: name === 'default',
      initial: (disp.length > 0 ? disp : name).substring(0, 1)
    };
  }

  /** PUT /api/hermes/profiles/active —— 切换当前激活的 profile */
  static async switchProfile(token: string, name: string): Promise<void> {
    await Net.send(putOpts('/api/hermes/profiles/active', JSON.stringify({ name: name }), token));
  }

  /** POST /api/hermes/profiles —— 新建 profile（body: {name, clone}） */
  static async createProfile(token: string, name: string, clone: boolean): Promise<void> {
    const body: ProfileCreateBody = { name: name, clone: clone };
    await Net.send(postOpts('/api/hermes/profiles', JSON.stringify(body), token));
  }

  /**
   * POST /api/hermes/profiles/{name}/restart —— 重启该 profile 的 runtime。
   *
   * 切换 active 之后配置不一定立刻生效（runtime 缓存），
   * 这个端点用来在 PC 侧强制重载。失败不阻塞切换流程，只是提示。
   */
  static async restartProfile(token: string, name: string): Promise<void> {
    const enc: string = encodeURIComponent(name);
    await Net.send(postOpts(`/api/hermes/profiles/${enc}/restart`, '', token));
  }

  /** PUT /api/hermes/config/model —— 改服务端默认模型（body: {default, provider}） */
  static async setDefaultModel(token: string, model: string, provider: string): Promise<void> {
    const body: DefaultModelBody = { default: model, provider: provider };
    await Net.send(putOpts('/api/hermes/config/model', JSON.stringify(body), token));
  }

  /**
   * GET /api/hermes/config/models —— 读电脑上的模型配置（Models 页用）。
   *
   * 真实形状（实测 2026-10）：{ default: "模型id", groups: [{provider, models:[{id,label}]}] }
   * ⚠ 和 listProviders 返回的是同一个端点，区别在于：
   *   listProviders 转成 Provider 领域模型（本机直连场景要用 baseUrl/apiKey）；
   *   这里保留原始分组，只给「远程切默认模型」用。
   */
  static async modelsConfig(token: string): Promise<ModelsConfig> {
    const res = await Net.send(getOpts('/api/hermes/config/models', token));
    const p = JSON.parse(res.body) as ModelsConfigPayload;
    const out: RemoteModelGroup[] = [];
    const groups = p.groups;
    if (Array.isArray(groups)) {
      for (const g of groups) {
        if (g === null || g === undefined) {
          continue;
        }
        const models: string[] = [];
        const ms = g.models;
        if (Array.isArray(ms)) {
          for (const m of ms) {
            const it = m as ModelItemLike;
            const id = strOf(it.id);
            if (id.length > 0) {
              models.push(id);
            }
          }
        }
        out.push({ provider: strOf(g.provider, '未命名'), models: models });
      }
    }
    return { default: strOf(p.default), groups: out };
  }

  /**
   * 服务端群聊消息 → 本地 GroupMessage。
   *
   * 字段来自实测（2026-06，load_messages 的 ack 是 `{messages:[...]}`）：
   *   id 是**字符串** gcmsg_<room>_<profile>_<ts>_<rand>_part_N（与单聊的 int 不同）
   *   senderId 是 agentId（形如 muct8eaayw0yt1），人发的消息是 auth:1
   *   没有 senderName 字段 → 用 roomAgent 的名字兜底
   */
  static gcMessageToLocal(m: GcMessage, agentNames: string[]): GroupMessage {
    const isHuman: boolean = m.senderId.indexOf('auth:') === 0;
    let name: string = m.senderName;
    if (name.length === 0) {
      // P2-10：agentNames 实际是 agentId 列表，indexOf 命中也只是返回同一个 id。
      //   兜底直接回 senderId 会让 UI 显示一串不可读 id（形如 muct8eaayw0yt1）。
      //   没拿到可读名字时就显示 'Agent'，保持 UI 可读。
      name = isHuman ? '我' : (agentNames.indexOf(m.senderId) >= 0 ? 'Agent' : 'Agent');
    }
    return {
      id: m.id,
      roomId: m.roomId,
      senderName: name,
      senderKind: isHuman ? 'human' : 'agent',
      agentId: isHuman ? undefined : m.senderId,
      role: StudioApi.toRole(typeof m.role === 'string' ? m.role : ''),
      content: typeof m.content === 'string' ? m.content : '',
      timestamp: typeof m.timestamp === 'number' ? m.timestamp : 0,
      streaming: false
    };
  }

  static async testServer(baseUrl: string): Promise<ServerProbe> {
    const prev = NetConfig.getBaseUrl();    NetConfig.setBaseUrl(baseUrl);
    try {
      const st = await StudioApi.authStatus();
      return {
        ok: true,
        message: st.hasPasswordLogin ? '连接成功，需要账号密码' : '连接成功（免密）'
      };
    } catch (e) {
      return { ok: false, message: errorMessage(e) };
    } finally {
      NetConfig.setBaseUrl(prev);
    }
  }
}

/** 登录请求体：显式 interface */
interface LoginBody {
  username: string;
  password: string;
}

function newLoginBody(username: string, password: string): LoginBody {
  return { username: username, password: password };
}