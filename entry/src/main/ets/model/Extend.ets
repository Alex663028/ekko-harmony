/**
 * 扩展领域模型：附件 / 分享 / 归档 / Skills / 插件 / MCP / 定时任务 /
 * 看板 / 记忆 / 用量 / 日志 / 布局。
 *
 * ArkTS 约束：所有枚举收敛用具名联合类型，不用 X['k']。
 */

// ───────────────────────── 附件 ─────────────────────────

export interface Attachment {
  id: string;
  sessionId: string;
  roomId: string;
  messageId: string;
  name: string;
  /** 沙箱内绝对路径 */
  path: string;
  mediaType: string;
  size: number;
  /** 'image' | 'file' | 'video_frame' */
  kind: string;
  createdAt: number;
}

// ───────────────────────── 分享与归档 ─────────────────────────

export interface SessionShare {
  token: string;
  sessionId: string;
  title: string;
  /** 'session' | 'room' */
  kind: string;
  /** 0 = 永不过期 */
  expiresAt: number;
  viewCount: number;
  createdAt: number;
}

export interface SessionArchive {
  id: string;
  sessionId: string;
  label: string;
  note: string;
  createdAt: number;
}

// ───────────────────────── Skills / 插件 / MCP ─────────────────────────

export interface Skill {
  id: string;
  name: string;
  description: string;
  /** 注入到 system prompt 的指令正文 */
  instructions: string;
  /** 'local' | 'bundled' | 'server' */
  source: string;
  enabled: boolean;
  usageCount: number;
  lastUsedAt: number;
  builtin: boolean;
  updatedAt: number;
}

export interface Plugin {
  id: string;
  name: string;
  version: string;
  description: string;
  enabled: boolean;
  config: string;
  installedAt: number;
}

export interface McpServer {
  id: string;
  name: string;
  /** 'stdio' | 'sse' | 'http' */
  transport: string;
  command: string;
  /** JSON 数组字符串 */
  args: string;
  url: string;
  /** JSON 对象字符串 */
  env: string;
  enabled: boolean;
  builtin: boolean;
  updatedAt: number;
}

// ───────────────────────── 定时任务 ─────────────────────────

export interface Job {
  id: string;
  name: string;
  /** 5 段 cron：分 时 日 月 周 */
  cron: string;
  sessionId: string;
  roomId: string;
  agentId: string;
  prompt: string;
  enabled: boolean;
  lastRunAt: number;
  /** '' | 'ok' | 'failed' | 'skipped' */
  lastStatus: string;
  nextRunAt: number;
  createdAt: number;
}

// ───────────────────────── 看板 ─────────────────────────

export interface KanbanColumn {
  id: string;
  name: string;
  position: number;
  /** 0 = 不限制 */
  wipLimit: number;
}

export interface KanbanCard {
  id: string;
  columnId: string;
  title: string;
  body: string;
  tag: string;
  /** 0 高 / 1 中 / 2 低 */
  priority: number;
  position: number;
  sessionId: string;
  createdAt: number;
  updatedAt: number;
}

// ───────────────────────── 记忆 ─────────────────────────

export interface MemoryItem {
  id: string;
  /** 'global' | 'session' | 'room' | 'agent' */
  scope: string;
  scopeId: string;
  /** 'note' | 'fact' | 'preference' */
  kind: string;
  content: string;
  pinned: boolean;
  hitCount: number;
  createdAt: number;
  updatedAt: number;
}

// ───────────────────────── 用量与日志 ─────────────────────────

export interface UsageRecord {
  id: string;
  sessionId: string;
  roomId: string;
  agentId: string;
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  createdAt: number;
}

export interface UsageSummary {
  totalInput: number;
  totalOutput: number;
  totalCost: number;
  sessionCount: number;
  /** 按模型聚合：model → tokens */
  byModel: UsageBucket[];
  /** 近 N 天趋势，索引 0 = 最早 */
  daily: UsageBucket[];
}

export interface UsageBucket {
  key: string;
  tokens: number;
  cost: number;
}

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface AppLog {
  id: string;
  level: LogLevel;
  scope: string;
  message: string;
  createdAt: number;
}

// ───────────────────────── 布局与主题 ─────────────────────────

/**
 * 响应式断点。
 * compact=手机竖屏；medium=折叠屏展开/小平板；expanded=平板/PC 宽屏。
 */
export type Breakpoint = 'compact' | 'medium' | 'expanded';

export interface LayoutPrefs {
  /** 展开态下左栏占比（0.2~0.45） */
  sidebarRatio: number;
  /** 上次使用的断点，启动时用于避免闪烁 */
  lastBreakpoint: string;
  /** 侧栏是否折叠 */
  sidebarCollapsed: boolean;
  /** 聊天区最大内容宽度（vp），0 = 铺满 */
  contentMaxWidth: number;
}

export interface ThemePrefs {
  accent: string;
  radius: number;
  fontScale: number;
  /** 气泡样式：'plain' | 'bordered' */
  bubbleStyle: string;
  /** 是否显示消息时间戳 */
  showTimestamp: boolean;
  /** 是否显示 token 用量 */
  showUsage: boolean;
}

export interface JourneyNode {
  id: string;
  label: string;
  kind: string;
  /** 关联的会话/群聊 */
  refId: string;
  timestamp: number;
}

export interface JourneyEdge {
  from: string;
  to: string;
  label: string;
}