/**
 * 仓库层：会话 / 消息 / 群聊房间 / 群聊 Agent / 执行队列 / Provider / Agent 配置。
 * 把 relationalStore 的原始行对象映射为 model/Types.ets 里的领域模型。
 */

import relationalStore from '@ohos.data.relationalStore';
import {
  SessionSummary, ChatMessage, ContentBlock, RunUsage, ToolTraceItem,
  RoomInfo, RoomAgent, AgentRuntime, Provider, ProviderApiMode,
  AgentProfile, GroupMessage, MentionRef, ExecutionQueueItem, QueueStatus, MessageRole
} from '../model/Types';
import { Database, queryToObjects, queryOne, str, num, bool } from './Database';
import {
  encryptApiKey, decryptApiKeyWithState, API_KEY_CIPHER_PREFIX
} from './ApiKeyCrypto';
import { shortId } from '../common/Core';
import { StudioApi, GcHandlers } from '../net/StudioApi';
import { NetConfig } from '../net/Http';
import { blockLocalWrite } from '../viewmodel/ServerMode';

/**
 * 是否走服务端数据源。
 *
 * ⚠ 这里刻意**不**调 AppStore.isServerMode()：
 *   AppStore 反过来 import 了本文件的各个 Repo，直接互相引用会形成循环依赖。
 *   dataSource 本来就存在 AppStorage 全局态里，直读同样准确且没有环。
 */
function isServerMode(): boolean {
  return (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
}

/** 服务端模式下的登录令牌；拿不到就抛，避免拿着空 token 去请求拿到看不懂的 401 */
function requireToken(): string {
  const t = NetConfig.getToken();
  if (t.length === 0) {
    throw new Error('服务端模式下未登录，请退出后重新登录');
  }
  return t;
}

/**
 * 从任意字符串解析 JSON，失败或形状不对返回默认值。绝不让解析异常冒泡到 UI。
 *
 * 只保证「能 parse」是不够的：库里可能存着数组、缺字段对象甚至旧版本结构，
 * 直接 `as T` 强转后字段是 undefined，UI 算术得 NaN，只在渲染时才暴露。
 * 这里在 parse 后多做一层形状校验：
 *   - 数组类型必须 Array.isArray，否则回落默认值；
 *   - 对象类型必须是非数组对象。
 * RunUsage 这类数字字段还要逐个 numOf 归一化，坏值（字符串/null）变成 0 而不是 NaN。
 */
export function safeJson<T>(s: string, fallback: T): T {
  if (s === '' || s === 'undefined' || s === 'null') {
    return fallback;
  }
  let parsed: Record<string, relationalStore.ValueType> | null = null;
  try {
    const v: Record<string, relationalStore.ValueType> = JSON.parse(s);
    if (v !== null && v !== undefined) {
      parsed = v;
    }
  } catch (e) {
    return fallback;
  }
  if (parsed === null) {
    return fallback;
  }
  // 调用方用 safeJson<T[]> 声明数组时，T 的编译期类型擦除后无法在运行时比对，
  // 所以按 fallback 自身形状判定：默认值是数组就要求解析结果也是数组。
  if (Array.isArray(fallback)) {
    return (Array.isArray(parsed) ? parsed : fallback) as T;
  }
  return parsed as T;
}

/**
 * RunUsage 专用归一化：库里存的可能是旧结构/缺字段/字符串数字，
 * 逐字段兜底成有限数字，绝不让 undefined 流到 UI 算术里变成 NaN。
 */
export function normalizeUsage(s: string): RunUsage {
  const o: Record<string, relationalStore.ValueType> = safeJson<Record<string, relationalStore.ValueType>>(
    s, {} as Record<string, relationalStore.ValueType>);
  return {
    inputTokens: num(o, 'inputTokens'),
    outputTokens: num(o, 'outputTokens'),
    totalTokens: num(o, 'totalTokens')
  };
}

/** RunUsage 的零值工厂：ArkTS 不接受内联对象字面量做默认值 */
export function emptyUsage(): RunUsage {
  return { inputTokens: 0, outputTokens: 0, totalTokens: 0 };
}

/** 队列状态收敛：禁止 ExecutionQueueItem['status'] 这种索引访问类型断言 */
export function toQueueStatus(s: string): QueueStatus {
  if (s === 'queued' || s === 'running' || s === 'done' || s === 'failed' || s === 'cancelled') {
    return s;
  }
  return 'queued';
}

/** 供应商协议收敛 */
export function toApiMode(s: string): ProviderApiMode {
  if (s === 'anthropic' || s === 'gemini' || s === 'responses' || s === 'openai_responses') {
    return s;
  }
  return 'chat_completions';
}

/** 运行时类型收敛（白名单放行，未知回落 ekko） */
export function toRuntime(s: string): AgentRuntime {
  const known: string[] = [
    'hermes', 'ekko', 'claude-code', 'codex', 'pi', 'grok', 'opencode',
    'dsh', 'cursor', 'antigravity', 'qwen', 'kimi', 'codebuddy', 'qoder', 'copilot', 'zcode'
  ];
  if (known.indexOf(s) >= 0) {
    return s as AgentRuntime;
  }
  return 'ekko';
}

/** @ 提及候选：与 common/Core 的 MentionCandidate 对齐 */
export interface MentionCandidateRow {
  agentId: string;
  recordId: string;
  name: string;
  removedAt: number;
  canMentionAll: boolean;
}

function newMentionCandidate(
  agentId: string, recordId: string, name: string, removedAt: number, canMentionAll: boolean
): MentionCandidateRow {
  return {
    agentId: agentId,
    recordId: recordId,
    name: name,
    removedAt: removedAt,
    canMentionAll: canMentionAll
  };
}

/** 行 → Provider。ArkTS 不接受 map 里直接返回对象字面量。
 *  ③ API Key 存储态脱敏：api_key 列是 AES-GCM-256 密文，读取时异步解密为内存明文。
 *  Scheme A（DSH R15）：解密结果携带三态 apiKeyState ——
 *   'empty'（真未填）/ 'ok'（可解密）/ 'undecryptable'（有密文但解密失败）。
 *  这是全部 Provider 读取路径（list / get / 惰性迁移）的统一状态源。 */
async function newProviderFromRow(r: Record<string, relationalStore.ValueType>): Promise<Provider> {
  const decrypted = await decryptApiKeyWithState(str(r, 'api_key'));
  const p: Provider = {
    id: str(r, 'id'),
    name: str(r, 'name'),
    baseUrl: str(r, 'base_url'),
    apiKey: decrypted.apiKey,
    apiKeyState: decrypted.state,
    apiMode: toApiMode(str(r, 'api_mode')),
    // safeJson 已按 fallback 形状校验：fallback 是数组时要求解析结果也是数组，
    // 列里存了 '{}' 这类非数组会回落为 []，不会强转成 string[] 让下游 .map 抛错。
    models: safeJson<string[]>(str(r, 'models'), []),
    enabled: bool(r, 'enabled'),
    builtin: bool(r, 'builtin'),
    updatedAt: num(r, 'updated_at')
  };
  return p;
}

/** 行 → AgentProfile */
function newAgentFromRow(r: Record<string, relationalStore.ValueType>): AgentProfile {
  const a: AgentProfile = {
    id: str(r, 'id'),
    name: str(r, 'name'),
    runtime: toRuntime(str(r, 'runtime')),
    provider: str(r, 'provider'),
    model: str(r, 'model'),
    apiMode: toApiMode(str(r, 'api_mode')),
    systemPrompt: str(r, 'system_prompt'),
    reasoningEffort: str(r, 'reasoning_effort'),
    toolsEnabled: bool(r, 'tools_enabled'),
    enabled: bool(r, 'enabled'),
    updatedAt: num(r, 'updated_at')
  };
  return a;
}

// ───────────────────────── 会话 ─────────────────────────

export class SessionRepo {
  /**
   * 会话列表。
   *
   * 服务端模式下直接读 PC 上的 Ekko Studio（StudioApi.listSessions），
   * 本地模式下仍走手机 SQLite —— 两条路返回的是同一个 SessionSummary 模型，
   * 所以页面层完全不用改。
   *
   * 分页：之前是无 LIMIT 的 SELECT *，会话积累到几百条时全量入内存。
   * 默认只取最近 200 条（按 pinned/active/updated_at 排序后），列表页本来
   * 也只渲染最近的；需要更多时传更大的 limit。
   */
  static async list(
    store: relationalStore.RdbStore,
    limit: number = 200
  ): Promise<SessionSummary[]> {
    if (isServerMode()) {
      return StudioApi.listSessions(requireToken());
    }
    const rows = await queryToObjects(store,
      `SELECT * FROM sessions ORDER BY pinned DESC, active DESC, updated_at DESC LIMIT ?`,
      [limit]);
    return rows.map((r) => SessionRepo.toSummary(r));
  }

  static async count(store: relationalStore.RdbStore): Promise<number> {
    if (isServerMode()) {
      // 服务端没有计数端点，列表取长度
      const all = await StudioApi.listSessions(requireToken());
      return all.length;
    }
    const row = await queryOne(store, 'SELECT COUNT(*) AS c FROM sessions');
    return num(row, 'c');
  }

  /** server 模式会话缓存：get() 不必每次进会话都全量拉一遍列表 */
  // 每条 entry 自带写入时间：此前用单一 serverCacheAt，任何一次全量重拉都会
  // 给所有 entry「续命」，导致某会话标题在别处改名后远超 TTL 仍不刷新。
  // ⚠ ArkTS 禁止对象展开（arkts-no-spread），无法用 { ...hit } 返回浅拷贝，
  //    SessionSummary 又含 categoryId/categoryName/profile 等可选字段，具名拷贝
  //    函数逐字段赋值会漏掉 undefined 的可选项。所以改为**不可变约定**：
  //    缓存里的对象只读，所有写入（重命名/置顶）都走各自的 Repo 方法并刷新缓存，
  //    调用方拿到的就是缓存引用本身，不允许就地改字段。
  private static serverCache: Map<string, SessionSummary> = new Map();
  private static serverCacheAt: Map<string, number> = new Map();
  private static readonly SERVER_CACHE_TTL: number = 20000;

  static async get(store: relationalStore.RdbStore, id: string): Promise<SessionSummary | null> {
    if (isServerMode()) {
      // 服务端没有「取单个会话」的轻量端点，只能从列表里筛。
      // 但不必每次进会话都全量拉一遍：列表 20 秒内复用，窗口外才重拉。
      const now = Date.now();
      const hit = SessionRepo.serverCache.get(id);
      const at = SessionRepo.serverCacheAt.get(id);
      if (hit !== undefined && at !== undefined && now - at < SessionRepo.SERVER_CACHE_TTL) {
        return hit;
      }
      const all = await StudioApi.listSessions(requireToken());
      for (const s of all) {
        SessionRepo.serverCache.set(s.id, s);
        SessionRepo.serverCacheAt.set(s.id, now);
      }
      const found = SessionRepo.serverCache.get(id);
      return found === undefined ? null : found;
    }
    const row = await queryOne(store, 'SELECT * FROM sessions WHERE id = ?', [id]);
    return row === null ? null : SessionRepo.toSummary(row);
  }

  /** 重命名后同步刷缓存，避免 20 秒窗口内读到旧标题 */
  static invalidateCache(id: string): void {
    SessionRepo.serverCache.delete(id);
    SessionRepo.serverCacheAt.delete(id);
  }

  private static toSummary(r: Record<string, relationalStore.ValueType>): SessionSummary {
    const categoryIdRaw = r['category_id'];
    return {
      id: str(r, 'id'),
      title: str(r, 'title'),
      source: str(r, 'source', 'api_server'),
      categoryId: typeof categoryIdRaw === 'number' ? categoryIdRaw : null,
      categoryName: str(r, 'category_name'),
      workspace: r['workspace'] === null ? null : str(r, 'workspace'),
      model: str(r, 'model'),
      provider: str(r, 'provider'),
      channel: str(r, 'channel'),
      pinned: bool(r, 'pinned'),
      active: bool(r, 'active'),
      messageCount: num(r, 'message_count'),
      lastMessagePreview: str(r, 'last_message_preview'),
      createdAt: num(r, 'created_at'),
      updatedAt: num(r, 'updated_at')
    };
  }

  static async create(
    store: relationalStore.RdbStore,
    id: string,
    title: string,
    source: string,
    now: number,
    model: string = '',
    provider: string = ''
  ): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('会话')) {
      return;
    }
    await store.executeSql(
      `INSERT INTO sessions (id, title, source, model, provider, message_count, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?)`,
      [id, title, source, model, provider, now, now]);
  }

  static async rename(store: relationalStore.RdbStore, id: string, title: string, now: number): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('会话')) {
      return;
    }
    await store.executeSql('UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?', [title, now, id]);
    SessionRepo.invalidateCache(id);
  }

  static async touch(store: relationalStore.RdbStore, id: string, now: number): Promise<void> {
    // 内部路径（Orchestrator 会话活跃度刷新）：只拦截不弹 toast，避免非用户触发的提示刷屏
    if (blockLocalWrite('会话', true)) {
      return;
    }
    await store.executeSql('UPDATE sessions SET updated_at = ? WHERE id = ?', [now, id]);
    SessionRepo.invalidateCache(id);
  }

  static async setActive(store: relationalStore.RdbStore, id: string, active: boolean): Promise<void> {
    // 内部路径（会话切换/新建后的 active 标记）：只拦截不弹 toast
    if (blockLocalWrite('会话', true)) {
      return;
    }
    await store.executeSql('UPDATE sessions SET active = ? WHERE id = ?', [active ? 1 : 0, id]);
    SessionRepo.invalidateCache(id);
  }

  /**
   * 置顶/取消置顶。
   *
   * list() 已按 pinned DESC 排序，SessionSummary.pinned 字段也一直在，
   * 但此前没有写回方法 —— 置顶按钮点了会「看起来生效但刷新就丢」。
   */
  static async setPinned(store: relationalStore.RdbStore, id: string, pinned: boolean): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('会话')) {
      return;
    }
    await store.executeSql('UPDATE sessions SET pinned = ? WHERE id = ?', [pinned ? 1 : 0, id]);
    SessionRepo.invalidateCache(id);
  }

  /** 归档标记（与 ArchiveRepo.add/remove 配合，双写保证一致） */
  static async setArchived(store: relationalStore.RdbStore, id: string, archived: boolean): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('会话')) {
      return;
    }
    await store.executeSql('UPDATE sessions SET archived = ? WHERE id = ?', [archived ? 1 : 0, id]);
    SessionRepo.invalidateCache(id);
  }

  static async setModel(
    store: relationalStore.RdbStore,
    id: string,
    model: string,
    provider: string
  ): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('会话模型')) {
      return;
    }
    await store.executeSql('UPDATE sessions SET model = ?, provider = ? WHERE id = ?', [model, provider, id]);
    SessionRepo.invalidateCache(id);
  }

  /** 增量更新消息计数与预览，比整对象覆盖安全 */
  static async recordMessage(
    store: relationalStore.RdbStore,
    sessionId: string,
    preview: string,
    now: number
  ): Promise<void> {
    // 内部路径（消息落库后的会话计数刷新）：只拦截不弹 toast
    if (blockLocalWrite('会话', true)) {
      return;
    }
    await store.executeSql(
      `UPDATE sessions
       SET message_count = message_count + 1,
           updated_at = ?,
           last_message_preview = ?
       WHERE id = ?`,
      [now, preview.slice(0, 200), sessionId]);
    SessionRepo.invalidateCache(sessionId);
  }

  static async delete(store: relationalStore.RdbStore, id: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('会话')) {
      return;
    }
    // 显式删子表：依赖外键级联在不同设备行为不一致，双保险。
    // ⚠ 必须连带清 session_archives / session_shares / attachments /
    //   usage_records —— 否则删掉一个已归档/已分享会话后，归档表残留行会让
    //   isArchived(sessionId) 恒为 true，归档页出现幽灵条目（与 deleteAll 对齐）。
    store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM messages WHERE session_id = ?', [id]);
      await store.executeSql('DELETE FROM session_archives WHERE session_id = ?', [id]);
      await store.executeSql('DELETE FROM session_shares WHERE session_id = ?', [id]);
      await store.executeSql('DELETE FROM attachments WHERE session_id = ?', [id]);
      await store.executeSql('DELETE FROM usage_records WHERE session_id = ?', [id]);
      await store.executeSql('DELETE FROM sessions WHERE id = ?', [id]);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('删除会话失败，已回滚');
    }
  }

  static async deleteAll(store: relationalStore.RdbStore): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('全部会话')) {
      return;
    }
    // 之前只清 messages/sessions，session_archives / session_shares /
    // attachments / usage_records 全留孤儿行：归档分类靠 session_archives
    // 反推 archivedIds，清空后仍显示幽灵会话。整组放一个事务，避免清一半。
    // P0-2：设置页承诺「删除所有单聊、群聊与消息记录」—— 群聊与看板表一并清空，
    // 否则客户清完数据后群聊房间/消息/看板全留存，造成虚假安全感。
    store.beginTransaction();
    try {
      // 单聊
      await store.executeSql('DELETE FROM messages');
      await store.executeSql('DELETE FROM session_archives');
      await store.executeSql('DELETE FROM session_shares');
      await store.executeSql('DELETE FROM attachments');
      await store.executeSql('DELETE FROM usage_records');
      await store.executeSql('DELETE FROM sessions');
      // 群聊
      await store.executeSql('DELETE FROM gc_messages');
      await store.executeSql('DELETE FROM gc_execution_queue');
      await store.executeSql('DELETE FROM gc_room_agents');
      await store.executeSql('DELETE FROM gc_rooms');
      // 看板
      await store.executeSql('DELETE FROM kanban_cards');
      await store.executeSql('DELETE FROM kanban_columns');
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('清空会话失败，已回滚');
    }
  }
}

// ───────────────────────── 消息 ─────────────────────────

export class MessageRepo {
  /** 倒序取一页（向上翻历史用），返回时翻正为时间正序 */
  static async page(
    store: relationalStore.RdbStore,
    sessionId: string,
    limit: number,
    beforeTs: number = 0,
    beforeId: string = ''
  ): Promise<ChatMessage[]> {
    if (isServerMode()) {
      // 服务端一次性返回整页，没有 beforeTs 游标语义
      // （它另有 /messages/paginated，但结构不同，等需要时再接）。
      return StudioApi.sessionMessages(requireToken(), sessionId, limit);
    }
    // 复合游标 (timestamp, id)：同毫秒多条消息（流式批量落库常见）在翻页边界
    // 会被重复返回或整批跳过，光用 timestamp < ? 挡不住。
    // beforeId 空串时必须退化为纯 timestamp < ? 查询：TEXT 与 '' 比较恒为 false，
    // (timestamp = ? AND id < '') 会整批漏掉同一毫秒的消息。
    //
    // D-R31-1：beforeTs 也必须是三态，不能与 beforeId 合并成一个 else。
    // 首页调用者一律吃默认值 beforeTs = 0（ChatPage.loadSession / GroupChatPage
    // .refreshMessages / Orchestrator.buildInitialContext），若 else 分支仍带
    // `AND timestamp < ?`，首页 SQL 就退化成 `timestamp < 0` → 恒 0 行：
    // 重进会话历史全空，群聊上下文整体丢失。
    let rows: Record<string, relationalStore.ValueType>[] = [];
    if (beforeTs > 0 && beforeId.length > 0) {
      rows = await queryToObjects(store,
        `SELECT * FROM messages WHERE session_id = ?
           AND (timestamp < ? OR (timestamp = ? AND id < ?))
         ORDER BY timestamp DESC, id DESC LIMIT ?`,
        [sessionId, beforeTs, beforeTs, beforeId, limit]);
    } else if (beforeTs > 0) {
      rows = await queryToObjects(store,
        `SELECT * FROM messages WHERE session_id = ?
           AND timestamp < ?
         ORDER BY timestamp DESC, id DESC LIMIT ?`,
        [sessionId, beforeTs, limit]);
    } else {
      // 首页：无游标谓词
      rows = await queryToObjects(store,
        `SELECT * FROM messages WHERE session_id = ?
         ORDER BY timestamp DESC, id DESC LIMIT ?`,
        [sessionId, limit]);
    }
    return rows.map((r) => MessageRepo.toMessage(r)).reverse();
  }

  private static toMessage(r: Record<string, relationalStore.ValueType>): ChatMessage {
    // timestamp 是必填字段：漏了会让消息落库后全部变成 0，
    // 之后按时间排序/分页会全乱（编译器已经替我们抓到过一次）。
    return MessageRepo.newMessage(
      str(r, 'id'),
      str(r, 'run_id'),
      str(r, 'session_id'),
      MessageRepo.toRole(str(r, 'role')),
      str(r, 'content'),
      safeJson<ContentBlock[]>(str(r, 'blocks'), []),
      str(r, 'agent_name'),
      str(r, 'model'),
      str(r, 'provider'),
      normalizeUsage(str(r, 'usage')),
      safeJson<ToolTraceItem[]>(str(r, 'tool_trace'), []),
      str(r, 'reasoning'),
      str(r, 'error'),
      num(r, 'timestamp')
    );
  }

  /** ArkTS 要求返回的对象字面量对应已声明的 interface；用具名工厂最稳。 */
  private static newMessage(
    id: string, runId: string, sessionId: string, role: MessageRole,
    content: string, blocks: ContentBlock[], agentName: string,
    model: string, provider: string, usage: RunUsage,
    traces: ToolTraceItem[], reasoning: string, error: string, timestamp: number
  ): ChatMessage {
    const msg: ChatMessage = {
      id: id,
      runId: runId,
      sessionId: sessionId,
      role: role,
      content: content,
      blocks: blocks,
      agentName: agentName,
      model: model,
      provider: provider,
      usage: usage,
      toolTrace: traces,
      reasoning: reasoning,
      error: error,
      timestamp: timestamp
    };
    return msg;
  }

  private static toRole(s: string): 'user' | 'assistant' | 'system' | 'tool' {
    if (s === 'user' || s === 'assistant' || s === 'system' || s === 'tool') {
      return s;
    }
    return 'assistant';
  }

  static async insert(store: relationalStore.RdbStore, msg: ChatMessage): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('聊天消息')) {
      return;
    }
    // timestamp 是 INTEGER NOT NULL：NaN/undefined 落库直接触发约束异常冒泡到 UI。
    // 上层传非有限时间戳时补 Date.now()，保证一定写得进去。
    const ts: number = typeof msg.timestamp === 'number' && isFinite(msg.timestamp)
      ? msg.timestamp
      : Date.now();
    await store.executeSql(
      `INSERT OR REPLACE INTO messages
       (id, session_id, run_id, role, content, blocks, agent_name, model, provider,
        usage, tool_trace, reasoning, error, timestamp)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [
        msg.id, msg.sessionId, msg.runId ?? '', msg.role, msg.content,
        msg.blocks !== undefined ? JSON.stringify(msg.blocks) : '',
        msg.agentName ?? '', msg.model ?? '', msg.provider ?? '',
        msg.usage !== undefined ? JSON.stringify(msg.usage) : '',
        msg.toolTrace !== undefined ? JSON.stringify(msg.toolTrace) : '',
        msg.reasoning ?? '', msg.error ?? '', ts
      ]);
  }

  static async updateContent(store: relationalStore.RdbStore, id: string, content: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('聊天消息')) {
      return;
    }
    await store.executeSql('UPDATE messages SET content = ? WHERE id = ?', [content, id]);
  }

  static async updateUsage(store: relationalStore.RdbStore, id: string, usage: RunUsage): Promise<void> {
    // 内部路径（流式消息的用量回填）：只拦截不弹 toast
    if (blockLocalWrite('聊天消息', true)) {
      return;
    }
    await store.executeSql('UPDATE messages SET usage = ? WHERE id = ?', [JSON.stringify(usage), id]);
  }

  static async deleteBySession(store: relationalStore.RdbStore, sessionId: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('聊天消息')) {
      return;
    }
    await store.executeSql('DELETE FROM messages WHERE session_id = ?', [sessionId]);
  }
}

// ───────────────────────── 群聊 ─────────────────────────

export class RoomRepo {
  static async list(store: relationalStore.RdbStore): Promise<RoomInfo[]> {
    if (isServerMode()) {
      const rooms = await StudioApi.listRooms(requireToken());
      // 逐个补上房间成员。服务端没有「房间+成员」的聚合端点，
      // 只能 N 次请求 —— 房间数通常个位数，可接受。
      for (const r of rooms) {
        r.agents = await StudioApi.roomAgents(requireToken(), r.id);
      }
      return rooms;
    }
    // 一次查出所有房间的 Agent，在内存里按 room_id 分组装配，
    // 不再每个房间单独 await（原写法是房间数 × 1 次查询的 N+1）。
    const rows = await queryToObjects(store, 'SELECT * FROM gc_rooms ORDER BY last_active_at DESC');
    // 无参查询：不必传 bind 数组，传了会让读代码的人误以为这里有占位参数。
    const agentRows = await queryToObjects(store, 'SELECT * FROM gc_room_agents ORDER BY name');
    const roomIds: Set<string> = new Set();
    for (const r of rows) {
      roomIds.add(str(r, 'id'));
    }
    const byRoom: Map<string, RoomAgent[]> = new Map();
    for (const ar of agentRows) {
      if (num(ar, 'removed_at') !== 0) {
        continue;
      }
      const rid = str(ar, 'room_id');
      // 防孤儿行：房间已删除但 gc_room_agents 残留（跨房间脏数据/中断的软删除）
      // 时，这些 Agent 不应再出现在任何房间的成员列表里。
      if (!roomIds.has(rid)) {
        continue;
      }
      const one = RoomAgentRepo.fromRow(ar);
      const list = byRoom.get(rid);
      if (list === undefined) {
        byRoom.set(rid, [one]);
      } else {
        list.push(one);
      }
    }
    const out: RoomInfo[] = [];
    for (const r of rows) {
      const room = RoomRepo.toRoom(r);
      const got = byRoom.get(room.id);
      room.agents = got === undefined ? [] : got;
      out.push(room);
    }
    return out;
  }

  /**
   * 单个群聊详情。
   *
   * ⚠ 必须和服务端模式对齐：list() 有远程分支而 get() 原来没有，
   *   导致「列表能看见房间、点进去提示群聊不存在」
   *   （get 查的是手机本地库，服务端的房间当然查不到 → 返回 null）。
   */
  static async get(store: relationalStore.RdbStore, id: string): Promise<RoomInfo | null> {
    if (isServerMode()) {
      // 服务端有 rooms/{roomId} 精确端点（实测 200），比从列表里筛更省
      const token = requireToken();
      // withDetail=true：聚合包里已经带了 agents，不用再单独拉一次
      // （实测该端点一次返回 room + messages + agents + members）
      const room = await StudioApi.getRoom(token, id, true);
      if (room === null) {
        return null;
      }
      if (room.agents === undefined || room.agents.length === 0) {
        room.agents = await StudioApi.roomAgents(token, id);
      }
      return room;
    }
    const row = await queryOne(store, 'SELECT * FROM gc_rooms WHERE id = ?', [id]);
    if (row === null) {
      return null;
    }
    const room2 = RoomRepo.toRoom(row);
    room2.agents = await RoomAgentRepo.listByRoom(store, id);
    return room2;
  }

  private static toRoom(r: Record<string, relationalStore.ValueType>): RoomInfo {
    const maxDepth = r['agent_handoff_max_depth'];
    return {
      id: str(r, 'id'),
      name: str(r, 'name'),
      inviteCode: r['invite_code'] === null ? null : str(r, 'invite_code'),
      ownerMemberId: str(r, 'owner_member_id'),
      summaryProfile: str(r, 'summary_profile'),
      summaryProvider: str(r, 'summary_provider'),
      summaryModel: str(r, 'summary_model'),
      summaryApiMode: toApiMode(str(r, 'summary_api_mode')),
      summaryEveryTurns: num(r, 'summary_every_turns'),
      totalTokens: num(r, 'total_tokens'),
      workspace: str(r, 'workspace'),
      agentHandoffEnabled: bool(r, 'agent_handoff_enabled'),
      agentHandoffMaxDepth: typeof maxDepth === 'number' ? maxDepth : null,
      agentHandoffUnlimited: bool(r, 'agent_handoff_unlimited'),
      // 缺列时（老库）默认允许 @all，与建表 DEFAULT 1 保持一致。
      // 注意不能直接用 bool()：它在列缺失时返回 false，会把 @all 又关掉。
      canMentionAll: num(r, 'can_mention_all', 1) !== 0,
      createdAt: num(r, 'created_at'),
      lastActiveAt: num(r, 'last_active_at')
    };
  }

  static async create(
    store: relationalStore.RdbStore,
    id: string,
    name: string,
    now: number,
    workspace: string = ''
  ): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('群聊房间')) {
      return;
    }
    await store.executeSql(
      `INSERT INTO gc_rooms (id, name, workspace, created_at, last_active_at)
       VALUES (?, ?, ?, ?, ?)`, [id, name, workspace, now, now]);
  }

  static async rename(store: relationalStore.RdbStore, id: string, name: string, now: number): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('群聊房间')) {
      return;
    }
    await store.executeSql('UPDATE gc_rooms SET name = ?, last_active_at = ? WHERE id = ?', [name, now, id]);
  }

  /**
   * 写回邀请码。
   * gc_rooms.invite_code 列与 RoomInfo.inviteCode 字段本来就有，
   * 但缺写回方法 —— 生成后只显示不落库，刷新即丢。
   */
  static async setInviteCode(store: relationalStore.RdbStore, id: string, code: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('邀请码')) {
      return;
    }
    await store.executeSql('UPDATE gc_rooms SET invite_code = ? WHERE id = ?', [code, id]);
  }

  /** Agent 交接链配置持久化（此前只存 @State，重启丢失） */
  static async setAgentHandoff(
    store: relationalStore.RdbStore,
    id: string,
    enabled: boolean,
    maxDepth: number | null,
    unlimited: boolean,
    now: number
  ): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('Agent 交接链')) {
      return;
    }
    await store.executeSql(
      `UPDATE gc_rooms
       SET agent_handoff_enabled = ?, agent_handoff_max_depth = ?,
           agent_handoff_unlimited = ?, last_active_at = ?
       WHERE id = ?`,
      [enabled ? 1 : 0, maxDepth, unlimited ? 1 : 0, now, id]);
  }

  static async touch(store: relationalStore.RdbStore, id: string, tokens: number, now: number): Promise<void> {
    // 内部路径（群聊消息落库后的房间活跃度/Token 累计）：只拦截不弹 toast
    if (blockLocalWrite('群聊房间', true)) {
      return;
    }
    await store.executeSql(
      'UPDATE gc_rooms SET last_active_at = ?, total_tokens = total_tokens + ? WHERE id = ?',
      [now, tokens, id]);
  }

  static async delete(store: relationalStore.RdbStore, id: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('群聊房间')) {
      return;
    }
    // ⚠ 连带清 attachments(room_id)：AttachmentRepo.byRoom 按 room_id 查，
    //   只删群消息/成员/队列/房间会让附件变孤儿行。
    store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM gc_messages WHERE room_id = ?', [id]);
      await store.executeSql('DELETE FROM gc_room_agents WHERE room_id = ?', [id]);
      await store.executeSql('DELETE FROM gc_execution_queue WHERE room_id = ?', [id]);
      await store.executeSql('DELETE FROM attachments WHERE room_id = ?', [id]);
      await store.executeSql('DELETE FROM gc_rooms WHERE id = ?', [id]);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('删除群聊失败，已回滚');
    }
  }
}

export class RoomAgentRepo {
  static async listByRoom(store: relationalStore.RdbStore, roomId: string): Promise<RoomAgent[]> {
    const rows = await queryToObjects(
      store, 'SELECT * FROM gc_room_agents WHERE room_id = ? ORDER BY name', [roomId]);
    return rows.filter((r) => num(r, 'removed_at') === 0).map((r) => RoomAgentRepo.fromRow(r));
  }

  /**
   * 供 @ 提及解析用。
   * 关键：返回的 agentId 是稳定全局 id，participantId 必须用它，
   * 不能用房间内记录 id（原版踩过 Invalid structured mentions）。
   */
  static async mentionCandidates(store: relationalStore.RdbStore, roomId: string): Promise<MentionCandidateRow[]> {
    // canMentionAll 必须取 gc_rooms.can_mention_all（v7 加的开关列）。
    // 之前用 gc_room_agents.owner_member_id===0 冒充，语义完全不同：
    // owner_member_id 是字符串房主 id，恒非 0 → @all 对每个非房主 Agent 恒为 true。
    const rows = await queryToObjects(
      store,
      `SELECT a.*, r.can_mention_all AS room_can_mention_all
         FROM gc_room_agents a
         LEFT JOIN gc_rooms r ON a.room_id = r.id
        WHERE a.room_id = ?`, [roomId]);
    const out: MentionCandidateRow[] = [];
    for (const r of rows) {
      out.push(newMentionCandidate(
        str(r, 'agent_id'),
        str(r, 'id'),
        str(r, 'name'),
        num(r, 'removed_at'),
        bool(r, 'room_can_mention_all')
      ));
    }
    return out;
  }

  /** 行 → RoomAgent。公开供 RoomRepo.list 批量装配，避免 N+1 */
  static fromRow(r: Record<string, relationalStore.ValueType>): RoomAgent {
    return {
      id: str(r, 'id'),
      roomId: str(r, 'room_id'),
      agentId: str(r, 'agent_id'),
      agent: toRuntime(str(r, 'agent', 'ekko')),
      agentMode: str(r, 'agent_mode', 'scoped') === 'global' ? 'global' : 'scoped',
      profile: str(r, 'profile'),
      provider: str(r, 'provider'),
      model: str(r, 'model'),
      apiMode: toApiMode(str(r, 'api_mode')),
      agentPreset: str(r, 'agent_preset'),
      reasoningEffort: str(r, 'reasoning_effort'),
      name: str(r, 'name'),
      description: str(r, 'description'),
      avatar: str(r, 'avatar'),
      invited: num(r, 'invited'),
      executorType: str(r, 'executor_type', 'server') === 'remote' ? 'remote' : 'server',
      remoteOrigin: str(r, 'remote_origin'),
      connectionStatus: str(r, 'connection_status', 'online') === 'offline' ? 'offline' : 'online',
      ownerMemberId: str(r, 'owner_member_id'),
      connectorId: str(r, 'connector_id')
    };
  }

  static async upsert(store: relationalStore.RdbStore, agent: RoomAgent, now: number): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('群聊 Agent')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO gc_room_agents
       (id, room_id, agent_id, agent, agent_mode, profile, provider, model, api_mode,
        agent_preset, reasoning_effort, name, description, avatar, invited,
        executor_type, remote_origin, connection_status, owner_member_id, connector_id, removed_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [
        // room_id 必须用 agent.roomId。
        // 此前误传 agent.id，导致 room_id 恒等于自身 id，
        // 而 listByRoom / mentionCandidates 都按 room_id 查 → Agent 永远读不出来。
        agent.id, agent.roomId, agent.agentId, agent.agent, agent.agentMode,
        agent.profile, agent.provider, agent.model, agent.apiMode,
        agent.agentPreset ?? '', agent.reasoningEffort, agent.name,
        agent.description, agent.avatar, agent.invited,
        agent.executorType ?? 'server', agent.remoteOrigin ?? '',
        agent.connectionStatus ?? 'online', agent.ownerMemberId ?? '', agent.connectorId ?? '', 0
      ]);
  }

  /** 软删除：保留行以便审计（原版用 removed_at） */
  static async remove(store: relationalStore.RdbStore, recordId: string, now: number): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('群聊 Agent')) {
      return;
    }
    await store.executeSql('UPDATE gc_room_agents SET removed_at = ? WHERE id = ?', [now, recordId]);
  }
}

/** 服务端模式下加载历史时不需要事件回调（占位实现） */
class GcNoopHandlers implements GcHandlers {
  onEvent(name: string, args: Object[]): void {
  }

  onStatus(status: string, detail: string): void {
  }
}

export class GroupMessageRepo {
  /** 房间成员名单缓存：server 模式翻页时不必每次都重拉一遍成员 */
  private static agentNames: Map<string, string[]> = new Map();
  private static agentNamesAt: Map<string, number> = new Map();
  private static readonly NAMES_TTL: number = 60000;

  static async page(
    store: relationalStore.RdbStore,
    roomId: string,
    limit: number,
    beforeTs: number = 0,
    beforeId: string = ''
  ): Promise<GroupMessage[]> {
    if (isServerMode()) {
      // 走 HTTP 聚合端点，不用 socket。
      //   实测（2026-06）：鸿蒙原生 `@ohos.net.webSocket` 对
      //   `/socket.io/?transport=websocket` 的请求，服务端返回 **code=200**
      //   （当成普通 HTTP 处理），根本没进 WebSocket 升级流程；
      //   而 socket.io 客户端能连是因为它先走 `transport=polling` 拿 sid 再升级。
      //   完整实现两阶段握手工作量大，先用 HTTP 端点保证功能可用
      //   （实测一次返回 150 条消息 + 8 个成员，id 全唯一）。
      const token = requireToken();
      const raw = await StudioApi.listRoomMessages(token, roomId, limit);
      // 服务端消息里 senderName 常为空，用房间成员的 agentId 补名字。
      // 成员名单按 roomId 缓存 60 秒：翻页时同一房间的成员不会变，
      // 之前每翻一页都重拉一次是纯浪费。
      const now = Date.now();
      let names: string[] = [];
      const cachedAt = GroupMessageRepo.agentNamesAt.get(roomId);
      if (cachedAt !== undefined && now - cachedAt < GroupMessageRepo.NAMES_TTL) {
        const got = GroupMessageRepo.agentNames.get(roomId);
        names = got === undefined ? [] : got;
      } else {
        const agents = await StudioApi.roomAgents(token, roomId);
        for (const a of agents) {
          names.push(a.agentId);
        }
        GroupMessageRepo.agentNames.set(roomId, names);
        GroupMessageRepo.agentNamesAt.set(roomId, now);
      }
      const out: GroupMessage[] = [];
      for (const m of raw) {
        out.push(StudioApi.gcMessageToLocal(m, names));
      }
      return out;
    }
    // 复合游标 (timestamp, id)：同 P2-8，同毫秒批量消息在边界不丢不重。
    // beforeId 空串时退化为纯 timestamp < ?：TEXT 与 '' 比较恒为 false（同 P2-8 修法）。
    //
    // D-R31-1：与 MessageRepo.page 同修 —— beforeTs <= 0 是「首页」，不得带
    // timestamp 谓词。否则 `timestamp < 0` 恒 0 行：群聊消息区恒空态，
    // 且 buildInitialContext 拿不到历史（模型收不到用户本轮提问）。
    let rows: Record<string, relationalStore.ValueType>[] = [];
    if (beforeTs > 0 && beforeId.length > 0) {
      rows = await queryToObjects(store,
        `SELECT * FROM gc_messages WHERE room_id = ?
           AND (timestamp < ? OR (timestamp = ? AND id < ?))
         ORDER BY timestamp DESC, id DESC LIMIT ?`,
        [roomId, beforeTs, beforeTs, beforeId, limit]);
    } else if (beforeTs > 0) {
      rows = await queryToObjects(store,
        `SELECT * FROM gc_messages WHERE room_id = ?
           AND timestamp < ?
         ORDER BY timestamp DESC, id DESC LIMIT ?`,
        [roomId, beforeTs, limit]);
    } else {
      // 首页：无游标谓词
      rows = await queryToObjects(store,
        `SELECT * FROM gc_messages WHERE room_id = ?
         ORDER BY timestamp DESC, id DESC LIMIT ?`,
        [roomId, limit]);
    }
    return rows.map((r) => GroupMessageRepo.toMessage(r)).reverse();
  }

  private static toMessage(r: Record<string, relationalStore.ValueType>): GroupMessage {
    const agentIdRaw = r['agent_id'];
    return {
      id: str(r, 'id'),
      roomId: str(r, 'room_id'),
      senderName: str(r, 'sender_name'),
      senderKind: str(r, 'sender_kind') === 'human' ? 'human' : 'agent',
      agentId: typeof agentIdRaw === 'string' ? agentIdRaw : undefined,
      role: MessageRepoRole(str(r, 'role')),
      content: str(r, 'content'),
      mentions: safeJson<MentionRef[]>(str(r, 'mentions'), []),
      usage: normalizeUsage(str(r, 'usage')),
      toolTrace: safeJson<ToolTraceItem[]>(str(r, 'tool_trace'), []),
      timestamp: num(r, 'timestamp')
    };
  }

  static async insert(store: relationalStore.RdbStore, msg: GroupMessage): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('群聊消息')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO gc_messages
       (id, room_id, sender_name, sender_kind, agent_id, role, content, mentions, usage, tool_trace, timestamp)
       VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
      [
        msg.id, msg.roomId, msg.senderName, msg.senderKind, msg.agentId ?? '',
        msg.role, msg.content,
        msg.mentions !== undefined ? JSON.stringify(msg.mentions) : '',
        msg.usage !== undefined ? JSON.stringify(msg.usage) : '',
        msg.toolTrace !== undefined ? JSON.stringify(msg.toolTrace) : '',
        msg.timestamp
      ]);
  }

  static async updateContent(store: relationalStore.RdbStore, id: string, content: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('群聊消息')) {
      return;
    }
    await store.executeSql('UPDATE gc_messages SET content = ? WHERE id = ?', [content, id]);
  }
}

function MessageRepoRole(s: string): 'user' | 'assistant' | 'system' | 'tool' {
  if (s === 'user' || s === 'assistant' || s === 'system' || s === 'tool') {
    return s;
  }
  return 'assistant';
}

export class QueueRepo {
  static async enqueue(store: relationalStore.RdbStore, item: ExecutionQueueItem): Promise<void> {
    // 内部编排路径：只拦截不弹 toast（非用户触发，避免刷屏）
    if (blockLocalWrite('执行队列', true)) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO gc_execution_queue
       (id, room_id, target_agent_id, target_agent_name, status, error, created_at, started_at, finished_at)
       VALUES (?,?,?,?,?,?,?,?,?)`,
      [
        item.id, item.roomId, item.targetAgentId, item.targetAgentName,
        item.status, item.error ?? '', item.createdAt, item.startedAt ?? null, item.finishedAt ?? null
      ]);
  }

  static async updateStatus(
    store: relationalStore.RdbStore,
    id: string,
    status: string,
    now: number,
    error: string = ''
  ): Promise<void> {
    // 内部编排路径：只拦截不弹 toast（非用户触发，避免刷屏）
    if (blockLocalWrite('执行队列', true)) {
      return;
    }
    if (status === 'running') {
      await store.executeSql(
        'UPDATE gc_execution_queue SET status = ?, started_at = ? WHERE id = ?', [status, now, id]);
    } else {
      await store.executeSql(
        'UPDATE gc_execution_queue SET status = ?, finished_at = ?, error = ? WHERE id = ?',
        [status, now, error, id]);
    }
  }

  /**
   * P1-SEQ7-④：取消某 agent 在某房间内所有排队任务（status='queued' → 'cancelled'）。
   *
   * 与 takeNext 的认领 UPDATE（WHERE status='queued'）天然互斥，无需额外锁。
   * 只改 queued：running 行由 abort() 的 handle.abort() 收尾，done/failed/cancelled
   * 是终态不该动。
   *
   * ⚠ HarmonyOS executeSql 返回 Promise<void>（非 ResultSet），拿不到影响行数，
   *    所以不返回行数；调用方需要统计时可先 SELECT count。
   */
  static async cancelQueued(
    store: relationalStore.RdbStore,
    roomId: string,
    agentId: string
  ): Promise<void> {
    // 内部/用户中止编排路径：只拦截不弹 toast
    if (blockLocalWrite('执行队列', true)) {
      return;
    }
    await store.executeSql(
      `UPDATE gc_execution_queue
          SET status = 'cancelled', finished_at = ?, error = ?
        WHERE room_id = ? AND target_agent_id = ? AND status = 'queued'`,
      [Date.now(), '用户已中止', roomId, agentId]);
  }

  /**
   * 取房间里排队中的任务，按创建时间 FIFO。
   *
   * 取的同时直接条件认领（UPDATE ... SET status='running' WHERE status='queued'），
   * 保证只被认领一次。之前只 SELECT 不认领，状态翻转完全依赖调用方随后调
   * updateStatus('running')，任一路径漏调 → 同一任务被反复取出重复执行。
   */
  static async takeNext(store: relationalStore.RdbStore, roomId: string): Promise<ExecutionQueueItem | null> {
    // 内部编排路径：只拦截不弹 toast（非用户触发，避免刷屏）
    if (blockLocalWrite('执行队列', true)) {
      return null;
    }
    // 先 SELECT 出目标 id，再按 id 认领、按 id 取回。
    // 之前 UPDATE 后用「本房间 status='running' 且 started_at 最大的一行」反查，
    // 房间里若已有别的 running 行（并发 pump，或上一任务失败后残留 running）
    // 就会取回错误的那一行。
    const target = await queryOne(
      store,
      `SELECT id FROM gc_execution_queue
        WHERE room_id = ? AND status = 'queued'
        ORDER BY created_at ASC LIMIT 1`, [roomId]);
    if (target === null) {
      return null;
    }
    const claimId = str(target, 'id');
    // 按 id 认领：WHERE 里再带一次 status='queued'，
    // 即使 SELECT 与 UPDATE 之间被别处抢先认领，这条 UPDATE 也是空操作而非误抢。
    await store.executeSql(
      `UPDATE gc_execution_queue
          SET status = 'running', started_at = ?
        WHERE id = ? AND status = 'queued'`, [Date.now(), claimId]);
    const row = await queryOne(
      store, 'SELECT * FROM gc_execution_queue WHERE id = ?', [claimId]);
    if (row === null) {
      return null;
    }
    return {
      id: str(row, 'id'),
      roomId: str(row, 'room_id'),
      targetAgentId: str(row, 'target_agent_id'),
      targetAgentName: str(row, 'target_agent_name'),
      status: toQueueStatus(str(row, 'status')),
      createdAt: num(row, 'created_at'),
      error: str(row, 'error')
    };
  }

  static async pending(store: relationalStore.RdbStore, roomId: string): Promise<number> {
    const row = await queryOne(
      store,
      `SELECT COUNT(*) AS c FROM gc_execution_queue WHERE room_id = ? AND status IN ('queued','running')`,
      [roomId]);
    return num(row, 'c');
  }
}

// ───────────────────────── Provider / Agent 配置 ─────────────────────────

/** 已加密字段的占位标记：服务端模式 list 拿不到本地 api_key 明细 */
const API_KEY_SERVER_SIDE = '__server_side__';

export class ProviderRepo {
  static async list(store: relationalStore.RdbStore): Promise<Provider[]> {
    if (isServerMode()) {
      return StudioApi.listProviders(requireToken());
    }
    const rows = await queryToObjects(store, 'SELECT * FROM providers ORDER BY builtin DESC, name');
    const out: Provider[] = [];
    for (const r of rows) {
      const p = await newProviderFromRow(r);
      // ③ 存量迁移：列表路径也会读到无前缀明文 → 惰性加密回写（与 get() 同一逻辑），
      // 避免升级后只走列表路径的存量明文继续躺库。
      // Scheme A：迁移后必须刷新三态（与 newProviderFromRow 同源）。
      const rawKey = str(r, 'api_key');
      const migrated = await ProviderRepo.migrateLegacyKey(store, p.id, rawKey);
      if (migrated !== rawKey) {
        const refreshed = await decryptApiKeyWithState(migrated);
        p.apiKey = refreshed.apiKey;
        p.apiKeyState = refreshed.state;
      }
      out.push(p);
    }
    return out;
  }

  /**
   * 迁移存量明文到密文。返回迁移后的落库值。
   *  - 已是密文（ekko:v1: 前缀）：原样返回，不重复加密。
   *  - 空串：不迁移。
   *  - 存量明文：尝试加密回写；keystore 不可用/加密失败时保留明文（下轮再试）。
   * 服务端模式下数据在 PC 上，不读本地库，直接返回明文原值（调用方只在本地模式用）。
   */
  static async migrateLegacyKey(store: relationalStore.RdbStore, id: string, rawKey: string): Promise<string> {
    // R35-EXEMPT: migration —— 一次性本地旧明文密钥惰性迁移（读路径触发），
    // 服务端模式下数据在 PC 上本就提前返回，无需走写拦截。
    // 调用点白名单（非页面）：ProviderRepo.get / ProviderRepo.list（data 层内部读路径）。
    // 页面**不得**直调本方法。
    if (rawKey.length === 0 || rawKey.startsWith(API_KEY_CIPHER_PREFIX)) {
      return rawKey;
    }
    if (isServerMode()) {
      return rawKey;
    }
    try {
      const enc = await encryptApiKey(rawKey);
      if (enc !== rawKey && enc.startsWith(API_KEY_CIPHER_PREFIX)) {
        await store.executeSql('UPDATE providers SET api_key = ? WHERE id = ?', [enc, id]);
        return enc;
      }
      // 降级明文（keystore 不可用）：保留原值，下轮再试
      return rawKey;
    } catch (e) {
      const detail = e instanceof Error ? e.message : String(e);
      console.warn(`ApiKey 存量迁移失败: ${detail}`);
      return rawKey;
    }
  }

  static async upsert(store: relationalStore.RdbStore, p: Provider, now: number): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('供应商')) {
      return;
    }
    // ③ API Key 存储态脱敏：落库前加密。
    // keystore 不可用时 encryptApiKey 降级返回明文并告警（可用性优先，对齐 AppStore.setToken），
    // 只有 keystore 正常但加密过程失败时才抛错（fail-closed），防止数据损坏。
    const encKey = await encryptApiKey(p.apiKey);
    await store.executeSql(
      `INSERT OR REPLACE INTO providers (id, name, base_url, api_key, api_mode, models, enabled, builtin, updated_at)
       VALUES (?,?,?,?,?,?,?,?,?)`,
      [p.id, p.name, p.baseUrl, encKey, p.apiMode, JSON.stringify(p.models),
       p.enabled ? 1 : 0, p.builtin ? 1 : 0, now]);
  }

  static async delete(store: relationalStore.RdbStore, id: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('供应商')) {
      return;
    }
    await store.executeSql('DELETE FROM providers WHERE id = ? AND builtin = 0', [id]);
  }

  /**
   * ⚠ 服务端模式下**不能因为找不到就返回 null**。
   *
   * list() 在服务端模式返回的 id 是本地拼的（srv-0-Custom），
   * 而 agent.provider 存的是服务端的 poolKey（custom:maas-api.unisound.com），
   * 两者对不上 → find 返回 undefined → null
   * → ChatPage 提示「请先配置 API Key」，但其实 PC 侧配置得好好的。
   *
   * 根本原因：服务端模式下模型调用走 POST /chat-run/runs（由 PC 执行），
   * 手机端根本不需要 baseUrl / apiKey，所以拿不到明细也不影响。
   * 所以这里返回占位 Provider，标记 apiKey 特殊值让调用方跳过本地校验。
   */
  static async get(store: relationalStore.RdbStore, id: string): Promise<Provider | null> {
    // 本地模式直接取一行，不用 list() 搬整张 providers 表（解析 AgentProfile 的热路径）
    if (!isServerMode()) {
      const row = await queryOne(store, 'SELECT * FROM providers WHERE id = ? LIMIT 1', [id]);
      if (row !== null) {
        const p = await newProviderFromRow(row);
        // ③ 存量迁移：读到无前缀的明文 → 立即加密回写（惰性迁移，不用专门跑迁移脚本）。
        const rawKey = str(row, 'api_key');
        const migrated = await ProviderRepo.migrateLegacyKey(store, p.id, rawKey);
        if (migrated !== rawKey) {
          // 仅当确实发生了明文→密文迁移才刷新内存对象（迁移函数内部已负责回写数据库）。
          // 与 newProviderFromRow 同源：同样用 decryptApiKeyWithState 刷新三态。
          const refreshed = await decryptApiKeyWithState(migrated);
          p.apiKey = refreshed.apiKey;
          p.apiKeyState = refreshed.state;
        }
        return p;
      }
      return null;
    }
    // 服务端模式：list() 返回的 id 是本地拼的（srv-0-Custom），
    // 而 agent.provider 存的是服务端的 poolKey（custom:maas-api.unisound.com），
    // 两者对不上 → find 返回 undefined → null
    // → ChatPage 提示「请先配置 API Key」，但其实 PC 侧配置得好好的。
    //
    // 根本原因：服务端模式下模型调用走 POST /chat-run/runs（由 PC 执行），
    // 手机端根本不需要 baseUrl / apiKey，所以拿不到明细也不影响。
    // 所以这里返回占位 Provider，标记 apiKey 特殊值让调用方跳过本地校验。
    const all = await ProviderRepo.list(store);
    const hit = all.find((p) => p.id === id);
    if (hit !== undefined) {
      return hit;
    }
    return {
      id: id,
      name: id,
      baseUrl: '',
      // 特殊标记：调用方看到它就该跳过「必须配 API Key」的本地校验
      apiKey: API_KEY_SERVER_SIDE,
      // 服务端占位：本地校验应跳过（见上注释），state 置 'ok' 表示「不需要本地 key」
      apiKeyState: 'ok',
      apiMode: 'chat_completions',
      models: [],
      enabled: true,
      builtin: true,
      updatedAt: 0
    };
  }
}

export class AgentProfileRepo {
  static async list(store: relationalStore.RdbStore): Promise<AgentProfile[]> {
    if (isServerMode()) {
      return StudioApi.listAgents(requireToken());
    }
    const rows = await queryToObjects(store, 'SELECT * FROM agent_profiles ORDER BY name');
    const out: AgentProfile[] = [];
    for (const r of rows) {
      out.push(newAgentFromRow(r));
    }
    return out;
  }

  static async upsert(store: relationalStore.RdbStore, a: AgentProfile, now: number): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('Agent 配置')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO agent_profiles
       (id, name, runtime, provider, model, api_mode, system_prompt, reasoning_effort, tools_enabled, enabled, updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
      [a.id, a.name, a.runtime, a.provider, a.model, a.apiMode, a.systemPrompt,
       a.reasoningEffort, a.toolsEnabled === false ? 0 : 1, a.enabled ? 1 : 0, now]);
  }

  static async delete(store: relationalStore.RdbStore, id: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('Agent 配置')) {
      return;
    }
    await store.executeSql('DELETE FROM agent_profiles WHERE id = ?', [id]);
  }
}

/** 生成新 id：与原版一致（base36 时间 + 随机后缀） */
export function newId(nowMs: number): string {
  return shortId(nowMs, Math.random());
}

export { Database };