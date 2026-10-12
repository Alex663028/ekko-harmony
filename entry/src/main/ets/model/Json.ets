/**
 * JSON 值类型：ArkTS 禁止 any/unknown，所有来自 JSON.parse 的数据
 * 都要落成显式 interface。本文件集中放这些结构。
 *
 * 原则：**宁可多写一个字段，也不要用 Record<string, unknown> 或 any**——
 * 那些在ArkTS 里是编译错误，而且真机上缺字段会静默出undefined。
 */

// P2-9：MessagePayload 的扩展字段（blocks / usage / toolTrace）类型定义在 Types 里
import { ContentBlock, RunUsage, ToolTraceItem } from './Types';

/** 通用文本字段包：多数 SSE / JSON 载荷都有这几个键 */
export interface TextFields {
  id: string;
  object: string;
  model: string;
  type: string;
  role: string;
  status: string;
  name: string;
  error: string;
  message: string;
  index: number;
}

/** usage 载荷（OpenAI 兼容命名） */
export interface TokenUsagePayload {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  cache_read_tokens: number;
  prompt_cache_hit_tokens: number;
  cost_usd: number;
}

/** 错误体 */
export interface ErrorPayload {
  error: ErrorDetail;
}

export interface ErrorDetail {
  message: string;
  type: string;
  code: string;
}

/** 登录响应（与 Studio 服务端 auth 对齐） */
export interface LoginPayload {
  token: string;
  userId: number;
}

export interface AuthStatusPayload {
  hasPasswordLogin: boolean;
  hasUsers: boolean;
}

export interface UserPayload {
  id: number;
  username: string;
  role: string;
  status: string;
  created_at: number;
  updated_at: number;
  last_login_at: number;
  avatar: string;
  requiresCredentialChange: boolean;
}

export interface CurrentUserPayload {
  user: UserPayload;
}

/** 会话列表 */
export interface SessionListPayload {
  sessions: SessionPayload[];
}

/**
 * 会话对象（GET /api/studio/sessions 的 sessions[] 元素）。
 *
 * ⚠ 字段名是**实测**出来的，不是从 OpenAPI 猜的
 *   （openapi.json 里这个端点只写了 `sessions: [{}]`，没给元素 schema）。
 *   用真实响应（账号 ALEX、2026-10-06 抓）逐字段比对后修正：
 *     pinned        → 服务端实际叫 is_pinned
 *     created_at    → 没有；实际是 started_at / ended_at / last_active
 *     updated_at    → 没有；实际是 last_active（列表按它倒序）
 *     channel/active→ 服务端没有
 *   所以下面把这些「猜出来的」字段都改成**可选**，
 *   映射时用兜底值，字段名再变也只会少显示一项、不会崩。
 */
export interface SessionPayload {
  id: string;
  title: string;
  source: string;
  /** 实测：source=coding_agent 时有值（codebuddy/claude/codex） */
  agent?: string;
  /**
   * 实测：**会话归属的 profile**（如 "default"）。
   * 切agent 就是切 active profile（PUT /api/hermes/profiles/active），
   * 新建会话时按它选。
   */
  profile?: string;
  /** 实测：消息预览正文。之前没读这个字段，列表全是「暂无消息」 */
  preview?: string;
  workspace: string;
  model: string;
  provider: string;
  message_count: number;
  /** 实测：开始时间（秒级时间戳） */
  started_at: number;
  /** 实测：结束时间 */
  ended_at: number;
  /** 实测：最后活跃时间，列表默认按它倒序 */
  last_active: number;
  /** 实测：置顶标记（原来错写成 pinned） */
  is_pinned: number;
  is_archived: number;
  category_id?: number;
  channel?: string;
  active?: boolean;
  created_at?: number;
  updated_at?: number;
  pinned?: boolean;
}

export interface MessageListPayload {
  messages: MessagePayload[];
}

export interface MessagePayload {
  /**
   * ⚠ 服务端返回的是**整数**（实测 104149 / 104150），不是字符串。
   *   之前写成 `typeof m.id === 'string' ? m.id : ''` 导致 13 条消息的 id
   *   全变成空串 → ForEach 的 key 重复 → ArkUI 只渲染一个气泡
   *   （现象：会话里只有标题没有内容）。
   *   所以这里放宽成 string | number，映射时统一 String()。
   */
  id: string | number;
  session_id: string;
  role: string;
  content: string;
  timestamp: number;
  /** P2-9：富文本/工具调用块 */
  blocks?: ContentBlock[];
  /** P2-9：token 用量 */
  usage?: RunUsage;
  /** P2-9：工具调用轨迹 */
  toolTrace?: ToolTraceItem[];
  /** P2-9：助手思考过程 */
  reasoning?: string;
  /** P2-9：错误详情 */
  error?: string;
}

export interface RoomListPayload {
  rooms: RoomPayload[];
}

/**
 * GET /api/studio/group-chat/rooms/{roomId} 的响应（实测 2026-06）。
 *
 * ⚠ 它是**聚合包**，不是 {rooms:[...]} 也不是裸房间对象：
 *   一次把 room + messages + agents + members + handoffChains 全给回来。
 *   之前按「rooms 数组 / 裸对象」两种形状去猜，都不匹配 → 解析成 null
 *   → 页面报「群聊不存在」，而服务端其实一直返回 200。
 *   **响应形状必须实测，不能猜。**
 */
export interface RoomDetailPayload {
  room?: RoomPayload;
  messages?: GcMessageLike[];
  agents?: RoomAgentPayload[];
  members?: Object[];
  handoffChains?: Object[];
  total?: number;
  offset?: number;
  limit?: number;
  hasMore?: boolean;
  historyTruncated?: boolean;
}

/** 聚合包里的消息（与 net 层 GcMessage 同构，这里用 Json 层的形状声明） */
export interface GcMessageLike {
  id: string;
  roomId: string;
  senderId: string;
  senderName: string;
  content: string;
  timestamp: number;
  role: string;
}

export interface RoomPayload {
  id: string;
  name: string;
  inviteCode: string;
  workspace: string;
  totalTokens: number;
  createdAt: number;
  lastActiveAt: number;
}

export interface RoomAgentListPayload {
  agents: RoomAgentPayload[];
}

export interface RoomAgentPayload {
  id: string;
  roomId: string;
  agentId: string;
  agent: string;
  agentMode: string;
  profile: string;
  provider: string;
  model: string;
  apiMode: string;
  reasoningEffort: string;
  name: string;
  description: string;
  invited: number;
  connectionStatus: string;
}

export interface AgentListPayload {
  agents: AgentProfilePayload[];
}

export interface AgentProfilePayload {
  id: string;
  name: string;
  runtime: string;
  provider: string;
  model: string;
  apiMode: string;
  systemPrompt: string;
  reasoningEffort: string;
  enabled: boolean;
}

export interface ProviderListPayload {
  providers: ProviderPayload[];
}

export interface ProviderPayload {
  id: string;
  name: string;
  baseUrl: string;
  apiKey: string;
  apiMode: string;
  models: string[];
  enabled: boolean;
}

/** /v1/models 响应 */
export interface ModelListPayload {
  data: ModelItemPayload[];
}

export interface ModelItemPayload {
  id: string;
  object: string;
  owned_by: string;
}

/** 健康检查 */
export interface HealthPayload {
  ok: boolean;
  status: string;
  version: string;
}

// ───────────────────────── 工厂：造空对象 ─────────────────────────
// ArkTS 里对象字面量必须能被推断成已声明的 interface，
// 统一用工厂函数造，避免各处重复字面量。

export function emptyTokenUsage(): TokenUsagePayload {
  return {
    prompt_tokens: 0,
    completion_tokens: 0,
    total_tokens: 0,
    cache_read_tokens: 0,
    prompt_cache_hit_tokens: 0,
    cost_usd: 0
  };
}

export function emptyModelList(): ModelListPayload {
  return { data: [] };
}

export function emptySessionList(): SessionListPayload {
  return { sessions: [] };
}

export function emptyRoomList(): RoomListPayload {
  return { rooms: [] };
}

export function emptyRoomAgentList(): RoomAgentListPayload {
  return { agents: [] };
}

export function emptyAgentList(): AgentListPayload {
  return { agents: [] };
}

export function emptyProviderList(): ProviderListPayload {
  return { providers: [] };
}

export function emptyMessageList(): MessageListPayload {
  return { messages: [] };
}

/**
 * POST /api/studio/chat-run/runs 的请求体。
 *
 * 字段名严格对照服务端 openapi.json：
 * dist/server/openapi.json → paths["/api/studio/chat-run/runs"].post.requestBody
 * 摘要写的是 "Run chat and wait for completion" —— 是**等待式**接口，
 * 要打字机效果需配合 socket.io 的 message_stream_delta 事件（见 net/SocketClient）。
 */
export interface ChatRunBody {
  input: string;
  /**
   * 会话 id。
   *
   * ⚠ 服务端契约（openapi 2026-10 实测）：
   *   "Optional session id. Omit this to create a new session automatically."
   *   → **新建对话必须整个字段省略**，传空串会当成 id='' 去查，直接 404。
   *   所以这里是可选字段，新建时由 StudioApi.chatRunNew负责组装。
   */
  session_id?: string;
  provider: string;
  model: string;
  /** enum: cli | builtin_agent | coding_agent | global_agent | workflow | group_chat */
  source: string;
  instructions: string;
  workspace: string;
  reasoning_effort: string;
  /** enum: scoped | global */
  mode: string;
  /**
   * Ekko Studio profile 名（实测字段名就是 profile）。
   * 省略时用服务端当前 active 的 profile。
   */
  profile?: string;
}

/** POST /api/studio/chat-run/runs 的响应 */
export interface ChatRunPayload {
  ok: boolean;
  status: string;
  session_id: string;
  run_id: string;
  /** 完整正文（等待式接口，非流式） */
  output: string;
  /** 推理过程 */
  reasoning: string;
}

export function emptyChatRun(): ChatRunPayload {
  return { ok: false, status: '', session_id: '', run_id: '', output: '', reasoning: '' };
}

/**
 * GET /api/hermes/config/models 的响应（实测 2026-10-06）。
 *
 * 真实形状：{ default: "u2-flash", groups: [ { provider: "Custom", models: [{id,label}] } ] }
 * ⚠ 之前手机端请求的是 `/api/studio/providers`，实测 404。
 */
export interface ModelsConfigPayload {
  default: string;
  groups: ModelGroupPayload[];
}

export interface ModelGroupPayload {
  provider: string;
  models: ModelItemLike[];
}

/** ArkTS 不接受索引访问类型断言，用具名 interface */
export interface ModelItemLike {
  id: string;
  label: string;
}

// ─────────────────────────────────────────────────────────────
// Profile（= 用户认知里的「Agent」）
//
// 服务端**没有 per-request 选agent 的参数** ——
// chat-run 的请求体里只有 profile 字段可选，而实际生效的是
// `PUT /api/hermes/profiles/active` 切「当前激活的 profile」。
// 所以「新建对话选agent」= 先切 active profile，再发首条消息。
//
// ⚠ openapi 里 /api/hermes/profiles 的响应 schema 是空的，
//   字段名以真机实测为准（见 StudioApi.listProfiles）。
// ─────────────────────────────────────────────────────────────

/** profile 列表项。实测字段：name / display_name / description / agent / model */
export interface ProfilePayload {
  name?: string;
  display_name?: string;
  description?: string;
  agent?: string;
  model?: string;
  provider?: string;
  /** 部分响应里是嵌套对象，取它的 name */
  agent_profile?: ProfileAgentRef;
}

/** ProfilePayload.agent_profile 的嵌套类型（ArkTS 不允许内联对象字面量类型） */
export interface ProfileAgentRef {
  name?: string;
  model?: string;
}

/** profile 列表响应：可能是数组，也可能是 {profiles:[...]}，两种都兜 */
export interface ProfileListPayload {
  profiles?: ProfilePayload[];
}

/** POST /api/hermes/profiles 的 body */
export interface ProfileCreateBody {
  name: string;
  /** true = 从当前配置克隆（openapi 实测有这个字段） */
  clone: boolean;
}

/** PUT /api/hermes/config/model 的 body */
export interface DefaultModelBody {
  default: string;
  provider: string;
}

/** StudioApi.modelsConfig 的返回值 */
export interface ModelsConfig {
  default: string;
  groups: RemoteModelGroupLite[];
}

/** ModelsConfig 里的分组（避免与 StudioApi.RemoteModelGroup 循环依赖） */
export interface RemoteModelGroupLite {
  provider: string;
  models: string[];
}

// ─────────────────────────────────────────────────────────────
// 阶段二：定时 / 看板 / 用量 / 记忆（只读展示）
//
// ⚠ 这些端点在服务端 openapi.json 里**没有定义响应 schema**
//   （只定义了路径），字段名是从服务端 bundle
//   dist/server/index.js 里 grep 出来的：
//     jobs   → next_run_at / last_status / last_run_at / run_count / schedule
//     kanban → priority / assignee / created_at / updated_at
//     memory → source / content / scope / tags / pinned / importance
//   因为是 grep 推断，所有字段都可能缺失 —— 所以这里全部声明为可选，
//   映射时用 strOf/numOf/boolOf 兜底，字段名不符只会显示为空、不会崩。
//   实测后如果发现某块是空的，按真实响应改这里的字段名即可。
// ─────────────────────────────────────────────────────────────

/**
 * GET /api/hermes/jobs 的响应（实测 2026-10-06，账号 ALEX 下有 2 条）。
 *
 * ⚠ 与最初 grep bundle 猜的差异很大，**已按真实响应重写**：
 *   · schedule 不是字符串，是对象 `{kind, expr, display}` → 另有平铺的 schedule_display
 *   · next_run_at / last_run_at / created_at 是 **ISO 字符串**，不是数字时间戳
 *   · 多了 state / last_error / last_delivery_error / failure_streak / workdir 等
 *   · 没有 run_count；次数在 `repeat.completed`
 */
export interface JobListPayload {
  jobs: JobPayload[];
}

export interface JobPayload {
  id: string;
  name: string;
  prompt: string;
  /** 真实是对象；为了容错，这里同时允许 string */
  schedule?: JobScheduleLike;
  /** 平铺的 cron 表达式，最省事，直接用它 */
  schedule_display?: string;
  /** 运行次数在 repeat.completed（实测 21） */
  repeat?: JobRepeatLike;
  enabled?: boolean;
  /** scheduled / running / paused ... */
  state?: string;
  /** ISO 8601 字符串，如 2026-10-05T10:00:00+08:00 */
  next_run_at?: string;
  last_run_at?: string;
  last_status?: string;
  last_error?: string;
  last_delivery_error?: string;
  failure_streak?: number;
  workdir?: string;
  model?: string;
  provider?: string;
  script?: string;
  no_agent?: boolean;
  created_at?: string;
  paused_reason?: string;
}

export interface JobScheduleLike {
  kind?: string;
  expr?: string;
  display?: string;
}

export interface JobRepeatLike {
  times?: number;
  completed?: number;
}

export function emptyJobList(): JobListPayload {
  return { jobs: [] };
}

/**
 * GET /api/hermes/kanban
 * ⚠ 实测该账号下返回 `{"tasks": []}`（还没建过卡片），所以元素结构未经验证，
 *   字段全是可选 + 兜底，建了卡片后按真实响应再校正。
 */
export interface KanbanListPayload {
  tasks?: KanbanPayload[];
}

export interface KanbanPayload {
  id?: string;
  title?: string;
  status?: string;
  priority?: string;
  assignee?: string;
  board_slug?: string;
  description?: string;
  blocked_reason?: string;
  created_at?: string;
  updated_at?: string;
}

export function emptyKanbanList(): KanbanListPayload {
  return { tasks: [] };
}

/** GET /api/studio/sessions/usage（会话用量） */
export interface UsagePayload {
  total_input_tokens?: number;
  total_output_tokens?: number;
  total_tokens?: number;
  total_cost?: number;
  sessions?: number;
  by_model?: UsageModelPayload[];
}

export interface UsageModelPayload {
  model?: string;
  provider?: string;
  input_tokens?: number;
  output_tokens?: number;
  total_tokens?: number;
  cost?: number;
  requests?: number;
}

export function emptyUsage(): UsagePayload {
  return { sessions: 0, by_model: [] };
}

/**
 * GET /api/ekko/memory
 * ⚠ 字段名来自 bundle grep，未实测（该端点需要特定作用域才有数据）。
 *   全可选 + 兜底，取不到就显示空列表。
 */
export interface MemoryListPayload {
  memories?: MemoryPayload[];
}

export interface MemoryPayload {
  id?: string;
  content?: string;
  scope?: string;
  source?: string;
  tags?: string;
  pinned?: boolean;
  importance?: number;
  created_at?: string;
  updated_at?: string;
}

export function emptyMemoryList(): MemoryListPayload {
  return { memories: [] };
}

export function emptyError(): ErrorDetail {
  return { message: '', type: '', code: '' };
}

/** 从任意 JSON 里安全取字符串字段：类型不符/缺失时给默认 */
export function strOf(v: string | undefined | null, fallback: string = ''): string {
  return typeof v === 'string' ? v : fallback;
}

/** 安全取数字 */
export function numOf(v: number | undefined | null, fallback: number = 0): number {
  return typeof v === 'number' && isFinite(v) ? v : fallback;
}

/** 安全取布尔 */
export function boolOf(v: boolean | undefined | null, fallback: boolean = false): boolean {
  return typeof v === 'boolean' ? v : fallback;
}

/**
 * 服务端供应商写入体（实测 2026-06：POST 空 body 返回
 * "Missing name, base_url, or model" → 这三个必填；api_key 可选）。
 * ⚠ 字段是**下划线**风格（base_url / api_key），与本地 Provider 的驼峰不同。
 */
export interface RemoteProviderBody {
  name: string;
  base_url: string;
  model: string;
  api_key?: string;
}

export interface RemoteProviderResult {
  success: boolean;
  error?: string;
}
