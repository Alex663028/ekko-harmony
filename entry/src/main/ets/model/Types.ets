/**
 * Ekko Studio 鸿蒙版 —— 领域模型层
 *
 * 对应原仓库 packages/client/src/api 下的 TypeScript 类型定义
 * （chat.ts / group-chat.ts / sessions.ts / coding-agents.ts）。
 * 字段命名刻意保持与原版一致，便于后续与 Ekko Studio 服务端对接时逐字段核对。
 */

/**
 * ArkTS 不支持 `X['key']` 这种索引访问类型做返回值注解
 * （arkts-no-aliases-by-index），所以凡是"从宽泛类型收窄到枚举"的地方
 * 都用具名联合类型，而不是索引访问。
 */
export type MessageRole = 'user' | 'assistant' | 'system' | 'tool';
export type QueueStatus = 'queued' | 'running' | 'done' | 'failed' | 'cancelled';
export type UserRole = 'super_admin' | 'admin' | 'user';
export type AgentMode = 'scoped' | 'global';
export type ConnectionStatus = 'online' | 'offline';
export type ExecutorType = 'server' | 'remote';

/** 内容块：文本 / 图片 / 文件。对应原版 ContentBlock。 */
export interface ContentBlock {
  type: 'text' | 'image' | 'file';
  /** type=text 时为正文 */
  text?: string;
  /** type=image|file 时的显示名 */
  name?: string;
  /** 本地或远端路径 */
  path?: string;
  media_type?: string;
  context?: string;
  /** 图片是否由视频抽帧得到 */
  video_frame?: boolean;
}

/** 会话消息。对应原版 ChatMessage。 */
export interface ChatMessage {
  id: string;
  runId?: string;
  sessionId: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  /** 统一存文本；富媒体放在 blocks 中 */
  content: string;
  blocks?: ContentBlock[];
  timestamp: number;
  /** 该条消息所属的 agent（群聊场景） */
  agentName?: string;
  model?: string;
  provider?: string;
  usage?: RunUsage;
  /** 工具调用轨迹 */
  toolTrace?: ToolTraceItem[];
  /** 助手思考过程 */
  reasoning?: string;
  /** 是否仍在流式接收中 */
  streaming?: boolean;
  error?: string;
}

/** 工具调用轨迹项 */
export interface ToolTraceItem {
  name: string;
  status: 'running' | 'ok' | 'failed';
  args?: string;
  result?: string;
  preview?: string;
  timestamp?: number;
}

/** Token 用量汇总。对应原版 RunUsageSummary 的核心字段。 */
export interface RunUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  totalTokens: number;
  costUsd?: number;
  contextTokens?: number;
}

/** 会话摘要。对应原版会话列表项。 */
export interface SessionSummary {
  id: string;
  title: string;
  /** 会话来源：api_server / group_chat / workflow / global_agent */
  source: string;
  /** 归档分类，空=未分类 */
  categoryId?: number | null;
  categoryName?: string;
  workspace?: string | null;
  model?: string;
  provider?: string;
  createdAt: number;
  updatedAt: number;
  lastMessagePreview?: string;
  messageCount: number;
  /** 是否有正在运行的 run */
  active?: boolean;
  /** 来源平台：telegram / discord / slack / 本地 */
  channel?: string;
  pinned?: boolean;
  /**
   * 会话使用的 agent。
   * 服务端实测（2026-06）：source=coding_agent 的会话带这个字段，
   * 值形如 codebuddy / claude / codex —— 单聊气泡上要显示「这条是谁说的」就靠它。
   * source=cli 的会话没有（单 Agent 对话）。
   */
  agent?: string;
  /**
   * 会话归属的 profile（服务端实测2026-10：默认 "default"）。
   * 「新建对话选agent」就是选 profile ——
   * 服务端只有 `PUT /api/hermes/profiles/active` 能切，没有 per-request 参数。
   */
  profile?: string;
}

/** 群聊房间。对应原版 RoomInfo。 */
export interface RoomInfo {
  id: string;
  name: string;
  inviteCode: string | null;
  canManage?: boolean;
  canMentionAll?: boolean;
  ownerMemberId?: string;
  /** 群摘要用的模型配置 */
  summaryProfile: string;
  summaryProvider: string;
  summaryModel: string;
  summaryApiMode: string;
  summaryEveryTurns: number;
  totalTokens?: number;
  workspace: string;
  agentHandoffEnabled?: boolean;
  agentHandoffMaxDepth?: number | null;
  agentHandoffUnlimited?: boolean;
  createdAt?: number;
  lastActiveAt?: number;
  agents?: RoomAgent[];
}

/** 群聊内的 Agent。对应原版 RoomAgent。 */
export interface RoomAgent {
  /** 房间内记录 id（不稳定，重加会刷新） */
  id: string;
  /**
   * 所属房间 id。
   *
   * 必须是必填且由调用方显式传入：此前 upsert 误把 agent.id 写进 room_id，
   * 导致所有行room_id ==自身 id，而查询是 WHERE room_id = ?，
   * 结果群聊里的 Agent 存进去就永远查不出来（群聊功能整体失效且无报错）。
   */
  roomId: string;
  /** 全局 agent id（稳定，@ 提及必须用这个） */
  agentId: string;
  /** 运行时类型 */
  agent: AgentRuntime;
  agentMode: 'scoped' | 'global';
  profile: string;
  provider: string;
  model: string;
  apiMode: string;
  agentPreset?: string;
  reasoningEffort: string;
  /** 显示名，@ 时用它 */
  name: string;
  description: string;
  avatar: string;
  invited: number;
  executorType?: 'server' | 'remote';
  remoteOrigin?: string;
  connectionStatus?: 'online' | 'offline';
  ownerMemberId?: string;
  connectorId?: string;
  removedAt?: number;
}

/**
 * Agent 运行时类型。
 *
 * 注意：原版里绝大多数是本机 CLI 进程（claude-code / codex / dsh…），
 * 手机端无法拉起这些进程，因此鸿蒙版把它们降级为「直连 LLM API」，
 * 保留类型名以便与原库数据互通。
 */
export type AgentRuntime =
  | 'hermes'
  | 'ekko'
  | 'claude-code'
  | 'codex'
  | 'pi'
  | 'grok'
  | 'opencode'
  | 'dsh'
  | 'cursor'
  | 'antigravity'
  | 'qwen'
  | 'kimi'
  | 'codebuddy'
  | 'qoder'
  | 'copilot'
  | 'zcode';

/** 用户账号。对应原版 CurrentUser。 */
export interface CurrentUser {
  id: number;
  username: string;
  role: 'super_admin' | 'admin' | 'user';
  status: string;
  createdAt: number;
  lastLoginAt: number | null;
  avatar?: string;
}

/**
 * API Key 三态（Scheme A，DSH R15 裁定）。
 *   - 'empty'：真未填（DB 空串，或解密后为空）。
 *   - 'ok'：已填且可解密（内存明文可用于请求头/表单）。
 *   - 'undecryptable'：DB 有密文但解密失败（主密钥丢失/密文损坏/形状非法）。
 *     该态必须与 'empty' 区分渲染，且绝不允许把「解密失败」当空串静默吞掉。
 */
export type ProviderApiKeyState = 'empty' | 'ok' | 'undecryptable';

/** 模型供应商配置 */
export interface Provider {
  id: string;
  name: string;
  baseUrl: string;
  /** API Key。数据库列 api_key 存加密密文（AES-GCM-256，见 data/ApiKeyCrypto.ets），
   *  此字段为内存解密后的明文，供请求头/表单使用。
   *  解密失败时为 ''（与未填同值），真实状态由 apiKeyState 区分。 */
  apiKey: string;
  /** API Key 三态：'empty' | 'ok' | 'undecryptable'（见 ProviderApiKeyState） */
  apiKeyState: ProviderApiKeyState;
  apiMode: ProviderApiMode;
  /** 该供应商下可选模型 */
  models: string[];
  enabled: boolean;
  /** 内置供应商不可删除 */
  builtin: boolean;
  /** 最后更新时间（epoch ms），列表排序用 */
  updatedAt: number;
}

export type ProviderApiMode = 'chat_completions' | 'responses' | 'anthropic' | 'gemini' | 'openai_responses';

/**
 * 服务端 Profile —— 用户认知里的「Agent」。
 *
 * ⚠ 与本地 `AgentProfile` 是两回事：
 *   - AgentProfile：手机本地配置，直连模型 API（本地模式用）
 *   - RemoteProfile：PC 上的 Ekko profile，切换靠 PUT /api/hermes/profiles/active
 */
export interface RemoteProfile {
  /** profile 唯一名，切 active 时传这个 */
  name: string;
  /** 展示名（display_name 缺失时退回 name） */
  displayName: string;
  description: string;
  /** 绑定的模型 id */
  model: string;
  provider: string;
  /** 服务端是否标记为当前激活 */
  active: boolean;
  /** 头像字符/emoji，没有就取名字首字母 */
  initial: string;
}

/** 全局 Agent 配置（单聊里选择的助手） */
export interface AgentProfile {
  id: string;
  name: string;
  runtime: AgentRuntime;
  provider: string;
  model: string;
  apiMode: ProviderApiMode;
  systemPrompt: string;
  reasoningEffort: string;
  enabled: boolean;
  /** 工具调用开关 */
  toolsEnabled: boolean;
  /** 最后更新时间（epoch ms），列表排序用 */
  updatedAt: number;
}

/** 群聊消息。对应原版 gc_messages 表的渲染视图。 */
export interface GroupMessage {
  id: string;
  roomId: string;
  /** 发送者显示名；用户消息为用户名，Agent 消息为 agent 名 */
  senderName: string;
  senderKind: 'human' | 'agent';
  /** agentId，仅 agent 消息有 */
  agentId?: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  mentions?: MentionRef[];
  timestamp: number;
  usage?: RunUsage;
  toolTrace?: ToolTraceItem[];
  streaming?: boolean;
}

/** @ 提及结构化引用。
 *
 * 关键（原版踩过的坑）：participantId 必须是 gc_room_agents.agentId，
 * 不是房间内记录 id，取错会被服务端以 Invalid structured mentions 拒绝。
 */
export interface MentionRef {
  type: 'agent' | 'all';
  participantId: string;
  displayName?: string;
}

/** 执行队列项（原版 gc_execution_queue） */
export interface ExecutionQueueItem {
  id: string;
  roomId: string;
  targetAgentId: string;
  targetAgentName: string;
  status: 'queued' | 'running' | 'done' | 'failed' | 'cancelled';
  createdAt: number;
  startedAt?: number;
  finishedAt?: number;
  error?: string;
}