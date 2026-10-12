/**
 * 扩展仓库层：附件 / 分享 / 归档 / Skills / 插件 / MCP / 任务 / 看板 /
 * 记忆 / 用量 / 日志 / 偏好。
 *
 * ArkTS 要点：map 里返回对象字面量会被判未类型化，一律用显式循环 + 具名工厂。
 */

import relationalStore from '@ohos.data.relationalStore';
import { str, num, bool, queryToObjects, queryOne } from './Database';
import { safeJson, newId } from './Repos';
import { StudioApi, RemoteJob } from '../net/StudioApi';
import { NetConfig } from '../net/Http';
import { blockLocalWrite } from '../viewmodel/ServerMode';
import {
  Attachment, SessionShare, SessionArchive, Skill, Plugin, McpServer,
  Job, KanbanColumn, KanbanCard, MemoryItem, UsageRecord, UsageSummary,
  UsageBucket, AppLog, LogLevel, LayoutPrefs, ThemePrefs
} from '../model/Extend';

// ───────────────────────── 通用偏好 ─────────────────────────

export class PrefsRepo {
  static async getStr(store: relationalStore.RdbStore, key: string, fallback: string): Promise<string> {
    const row = await queryOne(store, 'SELECT value FROM prefs WHERE key = ?', [key]);
    if (row === null) {
      return fallback;
    }
    return str(row, 'value', fallback);
  }

  static async setStr(store: relationalStore.RdbStore, key: string, value: string): Promise<void> {
    // R35-EXEMPT: cache-only —— 纯本地偏好缓存（布局/主题），不承载业务数据，
    // 服务端模式下被 PrefsRepo 的读路径使用也不产生用户可见的「假成功」。
    // 调用点白名单（非页面）：PrefsRepo.setNum / setBool / saveLayout / saveTheme / setCategory。
    // 页面**不得**直调本方法，必须走带守卫的包装方法（如 setCategory）。
    await store.executeSql('INSERT OR REPLACE INTO prefs (key, value) VALUES (?, ?)', [key, value]);
  }

  static async getNum(store: relationalStore.RdbStore, key: string, fallback: number): Promise<number> {
    const row = await queryOne(store, 'SELECT value FROM prefs WHERE key = ?', [key]);
    if (row === null) {
      return fallback;
    }
    const n = Number(str(row, 'value', ''));
    return isFinite(n) ? n : fallback;
  }

  static async setNum(store: relationalStore.RdbStore, key: string, value: number): Promise<void> {
    await PrefsRepo.setStr(store, key, `${value}`);
  }

  static async getBool(store: relationalStore.RdbStore, key: string, fallback: boolean): Promise<boolean> {
    const row = await queryOne(store, 'SELECT value FROM prefs WHERE key = ?', [key]);
    if (row === null) {
      return fallback;
    }
    return str(row, 'value', '') === '1';
  }

  static async setBool(store: relationalStore.RdbStore, key: string, value: boolean): Promise<void> {
    await PrefsRepo.setStr(store, key, value ? '1' : '0');
  }

  /** 布局偏好：双栏比例、折叠态等，PC 上跨启动保留 */
  static async loadLayout(store: relationalStore.RdbStore): Promise<LayoutPrefs> {
    const p: LayoutPrefs = {
      sidebarRatio: await PrefsRepo.getNum(store, 'layout.sidebarRatio', 0.28),
      lastBreakpoint: await PrefsRepo.getStr(store, 'layout.lastBreakpoint', 'compact'),
      sidebarCollapsed: await PrefsRepo.getBool(store, 'layout.sidebarCollapsed', false),
      contentMaxWidth: await PrefsRepo.getNum(store, 'layout.contentMaxWidth', 0)
    };
    // 比例必须落在合理区间，否则拖拽异常或旧数据越界会把界面挤坏
    if (p.sidebarRatio < 0.18) {
      p.sidebarRatio = 0.18;
    }
    if (p.sidebarRatio > 0.46) {
      p.sidebarRatio = 0.46;
    }
    return p;
  }

  static async saveLayout(store: relationalStore.RdbStore, p: LayoutPrefs): Promise<void> {
    // 4 条独立 INSERT OR REPLACE，中途被杀会留下半套布局（改了比例没改折叠态）。
    // 单事务提交，要么全生效要么全不动。
    store.beginTransaction();
    try {
      await PrefsRepo.setNum(store, 'layout.sidebarRatio', p.sidebarRatio);
      await PrefsRepo.setStr(store, 'layout.lastBreakpoint', p.lastBreakpoint);
      await PrefsRepo.setBool(store, 'layout.sidebarCollapsed', p.sidebarCollapsed);
      await PrefsRepo.setNum(store, 'layout.contentMaxWidth', p.contentMaxWidth);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('保存布局失败，已回滚');
    }
  }

  static async loadTheme(store: relationalStore.RdbStore): Promise<ThemePrefs> {
    const t: ThemePrefs = {
      accent: await PrefsRepo.getStr(store, 'theme.accent', '#1677FF'),
      radius: await PrefsRepo.getNum(store, 'theme.radius', 12),
      fontScale: await PrefsRepo.getNum(store, 'theme.fontScale', 1),
      bubbleStyle: await PrefsRepo.getStr(store, 'theme.bubbleStyle', 'plain'),
      showTimestamp: await PrefsRepo.getBool(store, 'theme.showTimestamp', true),
      showUsage: await PrefsRepo.getBool(store, 'theme.showUsage', true)
    };
    if (t.radius < 4) {
      t.radius = 4;
    }
    if (t.radius > 24) {
      t.radius = 24;
    }
    if (t.fontScale < 0.85) {
      t.fontScale = 0.85;
    }
    if (t.fontScale > 1.4) {
      t.fontScale = 1.4;
    }
    return t;
  }

  static async saveTheme(store: relationalStore.RdbStore, t: ThemePrefs): Promise<void> {
    // 同 saveLayout：6 个键必须原子生效，否则会出现「半径改了字号没改」的半套主题。
    store.beginTransaction();
    try {
      await PrefsRepo.setStr(store, 'theme.accent', t.accent);
      await PrefsRepo.setNum(store, 'theme.radius', t.radius);
      await PrefsRepo.setNum(store, 'theme.fontScale', t.fontScale);
      await PrefsRepo.setStr(store, 'theme.bubbleStyle', t.bubbleStyle);
      await PrefsRepo.setBool(store, 'theme.showTimestamp', t.showTimestamp);
      await PrefsRepo.setBool(store, 'theme.showUsage', t.showUsage);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('保存主题失败，已回滚');
    }
  }

  /**
   * 会话分类偏好（页面入口包装）。
   *
   * 为什么不直接暴露 setStr：setStr 是 R35-EXEMPT: cache-only 豁免方法，
   * 页面直调会绕过写拦截（D-R35 门禁要求「豁免码需附非页面调用点白名单」）。
   * 这里提供带守卫的包装，服务端模式下正常拦截并提示。
   */
  static async setCategory(store: relationalStore.RdbStore, name: string): Promise<void> {
    if (blockLocalWrite('会话分类')) {
      return;
    }
    await PrefsRepo.setStr(store, 'sessions.category', name);
  }
}

// ───────────────────────── 附件 ─────────────────────────

function toAttachment(r: Record<string, relationalStore.ValueType>): Attachment {
  return {
    id: str(r, 'id'),
    sessionId: str(r, 'session_id'),
    roomId: str(r, 'room_id'),
    messageId: str(r, 'message_id'),
    name: str(r, 'name'),
    path: str(r, 'path'),
    mediaType: str(r, 'media_type'),
    size: num(r, 'size'),
    kind: str(r, 'kind', 'file'),
    createdAt: num(r, 'created_at')
  };
}

export class AttachmentRepo {
  static async add(store: relationalStore.RdbStore, a: Attachment): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('附件')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO attachments
       (id, session_id, room_id, message_id, name, path, media_type, size, kind, created_at)
       VALUES (?,?,?,?,?,?,?,?,?,?)`,
      [a.id, a.sessionId, a.roomId, a.messageId, a.name, a.path,
       a.mediaType, a.size, a.kind, a.createdAt]);
  }

  static async bySession(store: relationalStore.RdbStore, sessionId: string): Promise<Attachment[]> {
    const rows = await queryToObjects(
      store, 'SELECT * FROM attachments WHERE session_id = ? ORDER BY created_at', [sessionId]);
    const out: Attachment[] = [];
    for (const r of rows) {
      out.push(toAttachment(r));
    }
    return out;
  }

  static async byRoom(store: relationalStore.RdbStore, roomId: string): Promise<Attachment[]> {
    const rows = await queryToObjects(
      store, 'SELECT * FROM attachments WHERE room_id = ? ORDER BY created_at', [roomId]);
    const out: Attachment[] = [];
    for (const r of rows) {
      out.push(toAttachment(r));
    }
    return out;
  }

  static async remove(store: relationalStore.RdbStore, id: string): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('附件')) {
      return;
    }
    await store.executeSql('DELETE FROM attachments WHERE id = ?', [id]);
  }

  static async clearSession(store: relationalStore.RdbStore, sessionId: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('附件')) {
      return;
    }
    await store.executeSql('DELETE FROM attachments WHERE session_id = ?', [sessionId]);
  }
}

// ───────────────────────── 分享与归档 ─────────────────────────

export class ShareRepo {
  static async create(
    store: relationalStore.RdbStore,
    sessionId: string, title: string, kind: string, token: string, expiresAt: number, now: number
  ): Promise<SessionShare | null> {
    // D-R35-3：服务端模式下数据在 PC 上，写本地库不会有任何效果。
    // **不得返回假对象**——否则页面会拿着它生成「链接已生成并复制」的假成功 toast。
    // 返回 null，调用方（页面已短路）不会把它当成功结果使用。
    if (blockLocalWrite('分享')) {
      return null;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO session_shares
       (token, session_id, title, kind, expires_at, view_count, created_at)
       VALUES (?,?,?,?,?,0,?)`,
      [token, sessionId, title, kind, expiresAt, now]);
    const s: SessionShare = {
      token: token,
      sessionId: sessionId,
      title: title,
      kind: kind,
      expiresAt: expiresAt,
      viewCount: 0,
      createdAt: now
    };
    return s;
  }

  static async bySession(store: relationalStore.RdbStore, sessionId: string): Promise<SessionShare[]> {
    const rows = await queryToObjects(
      store, 'SELECT * FROM session_shares WHERE session_id = ? ORDER BY created_at DESC', [sessionId]);
    const out: SessionShare[] = [];
    for (const r of rows) {
      out.push(toShare(r));
    }
    return out;
  }

  static async revoke(store: relationalStore.RdbStore, token: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('分享')) {
      return;
    }
    await store.executeSql('DELETE FROM session_shares WHERE token = ?', [token]);
  }

  static async byToken(store: relationalStore.RdbStore, token: string): Promise<SessionShare | null> {
    const row = await queryOne(store, 'SELECT * FROM session_shares WHERE token = ?', [token]);
    if (row === null) {
      return null;
    }
    return toShare(row);
  }
}

function toShare(r: Record<string, relationalStore.ValueType>): SessionShare {
  return {
    token: str(r, 'token'),
    sessionId: str(r, 'session_id'),
    title: str(r, 'title'),
    kind: str(r, 'kind', 'session'),
    expiresAt: num(r, 'expires_at'),
    viewCount: num(r, 'view_count'),
    createdAt: num(r, 'created_at')
  };
}

export class ArchiveRepo {
  static async add(
    store: relationalStore.RdbStore, sessionId: string, label: string, note: string, now: number
  ): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('归档')) {
      return;
    }
    // 归档行与 sessions.archived 是双写，之前两条 executeSql 无事务：
    // 中间被杀或第二条失败 → 归档表有行但 sessions.archived 还是 0（或反之），永久不一致。
    store.beginTransaction();
    try {
      await store.executeSql(
        'INSERT OR REPLACE INTO session_archives (id, session_id, label, note, created_at) VALUES (?,?,?,?,?)',
        [newId(now), sessionId, label, note, now]);
      await store.executeSql('UPDATE sessions SET archived = 1 WHERE id = ?', [sessionId]);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('归档失败，已回滚');
    }
  }

  static async list(store: relationalStore.RdbStore): Promise<SessionArchive[]> {
    const rows = await queryToObjects(store, 'SELECT * FROM session_archives ORDER BY created_at DESC');
    const out: SessionArchive[] = [];
    for (const r of rows) {
      out.push({
        id: str(r, 'id'),
        sessionId: str(r, 'session_id'),
        label: str(r, 'label'),
        note: str(r, 'note'),
        createdAt: num(r, 'created_at')
      });
    }
    return out;
  }

  static async remove(store: relationalStore.RdbStore, id: string, sessionId: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('归档')) {
      return;
    }
    store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM session_archives WHERE id = ?', [id]);
      await store.executeSql('UPDATE sessions SET archived = 0 WHERE id = ?', [sessionId]);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('取消归档失败，已回滚');
    }
  }
}

// ───────────────────────── Skills ─────────────────────────

/**
 * 把已启用的技能拼成一段「追加到系统提示词之后的指令」（P0-1）。
 *
 * 这是「预览」与「实际发送」共用的唯一事实源：SkillsPage 的预览、
 * ChatPage 的单聊上下文、Orchestrator 的群聊上下文都调用它，
 * 保证页面上承诺的注入内容与真正发给模型的内容一致。
 *
 * 返回的是**追加段**，不含 Agent 自身的 systemPrompt / 固定前缀：
 * 聊天侧把它作为独立 system 消息拼在 agent 提示词之后；
 * 预览侧由页面自行拼上固定前缀展示完整效果。
 */
export function composeSystemPrompt(skills: Skill[]): string {
  const lines: string[] = [];
  lines.push('以下是本次会话启用的技能指令：');
  for (const s of skills) {
    if (!s.enabled || s.instructions.trim().length === 0) {
      continue;
    }
    lines.push('');
    lines.push(`## ${s.name}`);
    if (s.description.length > 0) {
      lines.push(`（${s.description}）`);
    }
    lines.push(s.instructions.trim());
  }
  return lines.join('\n');
}

function toSkill(r: Record<string, relationalStore.ValueType>): Skill {
  return {
    id: str(r, 'id'),
    name: str(r, 'name'),
    description: str(r, 'description'),
    instructions: str(r, 'instructions'),
    source: str(r, 'source', 'local'),
    enabled: bool(r, 'enabled'),
    usageCount: num(r, 'usage_count'),
    lastUsedAt: num(r, 'last_used_at'),
    builtin: bool(r, 'builtin'),
    updatedAt: num(r, 'updated_at')
  };
}

export class SkillRepo {
  static async list(store: relationalStore.RdbStore): Promise<Skill[]> {
    const rows = await queryToObjects(store, 'SELECT * FROM skills ORDER BY builtin DESC, name');
    const out: Skill[] = [];
    for (const r of rows) {
      out.push(toSkill(r));
    }
    return out;
  }

  static async enabled(store: relationalStore.RdbStore): Promise<Skill[]> {
    const rows = await queryToObjects(
      store, 'SELECT * FROM skills WHERE enabled = 1 ORDER BY name');
    const out: Skill[] = [];
    for (const r of rows) {
      out.push(toSkill(r));
    }
    return out;
  }

  static async upsert(store: relationalStore.RdbStore, s: Skill): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('技能')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO skills
       (id, name, description, instructions, source, enabled, usage_count, last_used_at, builtin, updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?)`,
      [s.id, s.name, s.description, s.instructions, s.source,
       s.enabled ? 1 : 0, s.usageCount, s.lastUsedAt, s.builtin ? 1 : 0, s.updatedAt]);
  }

  static async setEnabled(store: relationalStore.RdbStore, id: string, enabled: boolean): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('技能')) {
      return;
    }
    await store.executeSql('UPDATE skills SET enabled = ? WHERE id = ?', [enabled ? 1 : 0, id]);
  }

  static async markUsed(store: relationalStore.RdbStore, id: string, now: number): Promise<void> {
    // 内部路径（编排器/对话侧自动计数）：只拦截不弹 toast
    if (blockLocalWrite('技能', true)) {
      return;
    }
    await store.executeSql(
      'UPDATE skills SET usage_count = usage_count + 1, last_used_at = ? WHERE id = ?', [now, id]);
  }

  static async remove(store: relationalStore.RdbStore, id: string): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('技能')) {
      return;
    }
    await store.executeSql('DELETE FROM skills WHERE id = ? AND builtin = 0', [id]);
  }
}

// ───────────────────────── 插件与 MCP ─────────────────────────

export class PluginRepo {
  static async list(store: relationalStore.RdbStore): Promise<Plugin[]> {
    const rows = await queryToObjects(store, 'SELECT * FROM plugins ORDER BY name');
    const out: Plugin[] = [];
    for (const r of rows) {
      out.push({
        id: str(r, 'id'),
        name: str(r, 'name'),
        version: str(r, 'version'),
        description: str(r, 'description'),
        enabled: bool(r, 'enabled'),
        config: str(r, 'config', '{}'),
        installedAt: num(r, 'installed_at')
      });
    }
    return out;
  }

  static async upsert(store: relationalStore.RdbStore, p: Plugin): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('插件')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO plugins (id, name, version, description, enabled, config, installed_at)
       VALUES (?,?,?,?,?,?,?)`,
      [p.id, p.name, p.version, p.description, p.enabled ? 1 : 0, p.config, p.installedAt]);
  }

  static async setEnabled(store: relationalStore.RdbStore, id: string, enabled: boolean): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('插件')) {
      return;
    }
    await store.executeSql('UPDATE plugins SET enabled = ? WHERE id = ?', [enabled ? 1 : 0, id]);
  }

  static async remove(store: relationalStore.RdbStore, id: string): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('插件')) {
      return;
    }
    await store.executeSql('DELETE FROM plugins WHERE id = ?', [id]);
  }
}

function toMcp(r: Record<string, relationalStore.ValueType>): McpServer {
  return {
    id: str(r, 'id'),
    name: str(r, 'name'),
    transport: str(r, 'transport', 'stdio'),
    command: str(r, 'command'),
    args: str(r, 'args', '[]'),
    url: str(r, 'url'),
    env: str(r, 'env', '{}'),
    enabled: bool(r, 'enabled'),
    builtin: bool(r, 'builtin'),
    updatedAt: num(r, 'updated_at')
  };
}

export class McpRepo {
  static async list(store: relationalStore.RdbStore): Promise<McpServer[]> {
    const rows = await queryToObjects(store, 'SELECT * FROM mcp_servers ORDER BY builtin DESC, name');
    const out: McpServer[] = [];
    for (const r of rows) {
      out.push(toMcp(r));
    }
    return out;
  }

  static async upsert(store: relationalStore.RdbStore, m: McpServer): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('MCP 服务器')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO mcp_servers
       (id, name, transport, command, args, url, env, enabled, builtin, updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?)`,
      [m.id, m.name, m.transport, m.command, m.args, m.url, m.env,
       m.enabled ? 1 : 0, m.builtin ? 1 : 0, m.updatedAt]);
  }

  static async remove(store: relationalStore.RdbStore, id: string): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('MCP 服务器')) {
      return;
    }
    await store.executeSql('DELETE FROM mcp_servers WHERE id = ? AND builtin = 0', [id]);
  }
}

// ───────────────────────── 定时任务 ─────────────────────────

function toJob(r: Record<string, relationalStore.ValueType>): Job {
  return {
    id: str(r, 'id'),
    name: str(r, 'name'),
    cron: str(r, 'cron'),
    sessionId: str(r, 'session_id'),
    roomId: str(r, 'room_id'),
    agentId: str(r, 'agent_id'),
    prompt: str(r, 'prompt'),
    enabled: bool(r, 'enabled'),
    lastRunAt: num(r, 'last_run_at'),
    lastStatus: str(r, 'last_status'),
    nextRunAt: num(r, 'next_run_at'),
    createdAt: num(r, 'created_at')
  };
}

export class JobRepo {
  /**
   * 定时任务列表。
   *
   * 服务端模式：读 PC 上的 /api/hermes/jobs。
   * ⚠ RemoteJob（服务端形状：schedule_display 平铺、时间是 ISO 串、次数在 repeat.completed）
   *   与本地 Job（cron 表达式、毫秒时间戳、runCount 平铺）字段名不同，
   *   所以在 toJobFromRemote 里显式转换，不能直接 as 成 Job。
   * 阶段二是只读的：这里只读不写，PC 端才是唯一数据源。
   */
  static async list(store: relationalStore.RdbStore): Promise<Job[]> {
    if (JobRepo.inServerMode()) {
      const remote = await StudioApi.listJobs(JobRepo.token());
      const out: Job[] = [];
      for (const r of remote) {
        out.push(JobRepo.toJobFromRemote(r));
      }
      return out;
    }
    const rows = await queryToObjects(store, 'SELECT * FROM jobs ORDER BY enabled DESC, name');
    const out: Job[] = [];
    for (const r of rows) {
      out.push(toJob(r));
    }
    return out;
  }

  private static inServerMode(): boolean {
    return (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
  }

  private static token(): string {
    const t = NetConfig.getToken();
    if (t.length === 0) {
      throw new Error('服务端模式下未登录，请退出后重新登录');
    }
    return t;
  }

  /** 服务端 RemoteJob → 本地 Job（字段名逐个对齐，不做隐式转换） */
  static toJobFromRemote(r: RemoteJob): Job {
    return {
      id: r.id,
      name: r.name,
      // 本地字段叫 cron，服务端是 schedule_display
      cron: r.schedule,
      prompt: r.prompt,
      enabled: r.enabled,
      lastRunAt: r.lastRunAt,
      lastStatus: r.lastStatus,
      nextRunAt: r.nextRunAt,
      // 服务端 RemoteJob 不暴露创建时间；之前拿 nextRunAt 兜底会把「下次运行时间」
      // 当成创建时间（未来时间排最前）。统一置 0，页面按「—」展示。
      createdAt: 0,
      // 服务端的任务不绑定会话/房间/Agent（那是手机端本地调度器的概念）
      sessionId: '',
      roomId: '',
      agentId: ''
    };
  }

  static async due(store: relationalStore.RdbStore, now: number): Promise<Job[]> {
    const rows = await queryToObjects(
      store, 'SELECT * FROM jobs WHERE enabled = 1 AND next_run_at > 0 AND next_run_at <= ?', [now]);
    const out: Job[] = [];
    for (const r of rows) {
      out.push(toJob(r));
    }
    return out;
  }

  static async upsert(store: relationalStore.RdbStore, j: Job): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('定时任务')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO jobs
       (id, name, cron, session_id, room_id, agent_id, prompt, enabled,
        last_run_at, last_status, next_run_at, created_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
      [j.id, j.name, j.cron, j.sessionId, j.roomId, j.agentId, j.prompt,
       j.enabled ? 1 : 0, j.lastRunAt, j.lastStatus, j.nextRunAt, j.createdAt]);
  }

  static async markRun(store: relationalStore.RdbStore, id: string, status: string, now: number): Promise<void> {
    // 内部调度路径：只拦截不弹 toast（非用户触发，避免刷屏）
    if (blockLocalWrite('定时任务', true)) {
      return;
    }
    await store.executeSql(
      'UPDATE jobs SET last_run_at = ?, last_status = ? WHERE id = ?', [now, status, id]);
  }

  static async setNextRun(store: relationalStore.RdbStore, id: string, next: number): Promise<void> {
    // 内部调度路径：只拦截不弹 toast（非用户触发，避免刷屏）
    if (blockLocalWrite('定时任务', true)) {
      return;
    }
    await store.executeSql('UPDATE jobs SET next_run_at = ? WHERE id = ?', [next, id]);
  }

  static async remove(store: relationalStore.RdbStore, id: string): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('定时任务')) {
      return;
    }
    await store.executeSql('DELETE FROM jobs WHERE id = ?', [id]);
  }
}

// ───────────────────────── 看板 ─────────────────────────

export class KanbanRepo {
  static async columns(store: relationalStore.RdbStore): Promise<KanbanColumn[]> {
    const rows = await queryToObjects(store, 'SELECT * FROM kanban_columns ORDER BY position');
    const out: KanbanColumn[] = [];
    for (const r of rows) {
      out.push({
        id: str(r, 'id'),
        name: str(r, 'name'),
        position: num(r, 'position'),
        wipLimit: num(r, 'wip_limit')
      });
    }
    return out;
  }

  static async addColumn(
    store: relationalStore.RdbStore, id: string, name: string, position: number, wipLimit: number,
    silent?: boolean
  ): Promise<void> {
    // D-R35-2：此方法同时被用户入口（KanbanPage 「＋列」）和内部默认列铺建（ensureDefaults）调用，
    // 不能再豁免 schema-ddl —— 用户入口必须走正常拦截，否则服务端模式下本地影子写入、
    // 用户点了「＋列」却看不到新列（真机 T4 复现）。
    if (blockLocalWrite('看板列', silent)) {
      return;
    }
    await store.executeSql(
      'INSERT OR REPLACE INTO kanban_columns (id, name, position, wip_limit) VALUES (?,?,?,?)',
      [id, name, position, wipLimit]);
  }

  static async removeColumn(store: relationalStore.RdbStore, id: string): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('看板列')) {
      return;
    }
    // 删卡片+删列必须原子完成：中间失败会留半套（列没了但卡片成孤儿，反之亦然）
    await store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM kanban_cards WHERE column_id = ?', [id]);
      await store.executeSql('DELETE FROM kanban_columns WHERE id = ?', [id]);
      await store.commit();
    } catch (e) {
      await store.rollBack();
      throw new Error('删除看板列失败，已回滚');
    }
  }

  static async cards(store: relationalStore.RdbStore, columnId: string): Promise<KanbanCard[]> {
    const rows = await queryToObjects(
      store, 'SELECT * FROM kanban_cards WHERE column_id = ? ORDER BY position', [columnId]);
    return KanbanRepo.toCards(rows);
  }

  static async allCards(store: relationalStore.RdbStore): Promise<KanbanCard[]> {
    const rows = await queryToObjects(store, 'SELECT * FROM kanban_cards ORDER BY position');
    return KanbanRepo.toCards(rows);
  }

  private static toCards(rows: Record<string, relationalStore.ValueType>[]): KanbanCard[] {
    const out: KanbanCard[] = [];
    for (const r of rows) {
      out.push({
        id: str(r, 'id'),
        columnId: str(r, 'column_id'),
        title: str(r, 'title'),
        body: str(r, 'body'),
        tag: str(r, 'tag'),
        priority: num(r, 'priority', 1),
        position: num(r, 'position'),
        sessionId: str(r, 'session_id'),
        createdAt: num(r, 'created_at'),
        updatedAt: num(r, 'updated_at')
      });
    }
    return out;
  }

  static async upsertCard(store: relationalStore.RdbStore, c: KanbanCard): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('看板卡片')) {
      return;
    }
    await store.executeSql(
      `INSERT OR REPLACE INTO kanban_cards
       (id, column_id, title, body, tag, priority, position, session_id, created_at, updated_at)
       VALUES (?,?,?,?,?,?,?,?,?,?)`,
      [c.id, c.columnId, c.title, c.body, c.tag, c.priority, c.position,
       c.sessionId, c.createdAt, c.updatedAt]);
  }

  static async moveCard(store: relationalStore.RdbStore, id: string, columnId: string, position: number): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('看板卡片')) {
      return;
    }
    await store.executeSql(
      'UPDATE kanban_cards SET column_id = ?, position = ? WHERE id = ?', [columnId, position, id]);
  }

  static async removeCard(store: relationalStore.RdbStore, id: string): Promise<void> {

    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('看板卡片')) {
      return;
    }
    await store.executeSql('DELETE FROM kanban_cards WHERE id = ?', [id]);
  }

  /** 首次启动铺默认列（内部路径：静默拦截，不弹 toast） */
  static async ensureDefaults(store: relationalStore.RdbStore): Promise<void> {
    const row = await queryOne(store, 'SELECT COUNT(*) AS c FROM kanban_columns');
    if (num(row, 'c', 0) > 0) {
      return;
    }
    // 内部铺建必须传 silent=true：服务端模式下 ensureDefaults 本就被页面跳过，
    // 这里只是双保险，静默拦截避免非用户触发的 toast 刷屏。
    await KanbanRepo.addColumn(store, 'col-backlog', '待办', 0, 0, true);
    await KanbanRepo.addColumn(store, 'col-doing', '进行中', 1, 3, true);
    await KanbanRepo.addColumn(store, 'col-done', '已完成', 2, 0, true);
  }
}

// ───────────────────────── 记忆 ─────────────────────────

function toMemory(r: Record<string, relationalStore.ValueType>): MemoryItem {
  return {
    id: str(r, 'id'),
    scope: str(r, 'scope', 'global'),
    scopeId: str(r, 'scope_id'),
    kind: str(r, 'kind', 'note'),
    content: str(r, 'content'),
    pinned: bool(r, 'pinned'),
    hitCount: num(r, 'hit_count'),
    createdAt: num(r, 'created_at'),
    updatedAt: num(r, 'updated_at')
  };
}

export class MemoryRepo {
  static async list(store: relationalStore.RdbStore, scope: string, scopeId: string): Promise<MemoryItem[]> {
    const rows = await queryToObjects(
      store,
      'SELECT * FROM memories WHERE scope = ? AND scope_id = ? ORDER BY pinned DESC, updated_at DESC',
      [scope, scopeId]);
    const out: MemoryItem[] = [];
    for (const r of rows) {
      out.push(toMemory(r));
    }
    return out;
  }

  /** 当前作用域 + 全局，一起返回（全局记忆对所有会话生效） */
  static async effective(store: relationalStore.RdbStore, scope: string, scopeId: string): Promise<MemoryItem[]> {
    const rows = await queryToObjects(
      store,
      `SELECT * FROM memories
       WHERE (scope = 'global') OR (scope = ? AND scope_id = ?)
       ORDER BY pinned DESC, updated_at DESC`,
      [scope, scopeId]);
    const out: MemoryItem[] = [];
    for (const r of rows) {
      out.push(toMemory(r));
    }
    return out;
  }

  static async add(
    store: relationalStore.RdbStore,
    scope: string, scopeId: string, kind: string, content: string, now: number
  ): Promise<string> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('记忆')) {
      return '';
    }
    // P2-12：返回新记录 id，调用方不必再用「同内容+同时间」反查，
    //   避免并发下 pin 错记录。
    //   memories 的 id 是应用生成的字符串（newId），不是自增整型，
    //   所以直接返回这里生成的 id 即可，不依赖 last_insert_rowid。
    const id = newId(now);
    await store.executeSql(
      `INSERT OR REPLACE INTO memories
       (id, scope, scope_id, kind, content, pinned, hit_count, created_at, updated_at)
       VALUES (?,?,?,?,?,0,0,?,?)`,
      [id, scope, scopeId, kind, content, now, now]);
    return id;
  }

  static async setPinned(store: relationalStore.RdbStore, id: string, pinned: boolean): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('记忆')) {
      return;
    }
    await store.executeSql('UPDATE memories SET pinned = ? WHERE id = ?', [pinned ? 1 : 0, id]);
  }

  /**
   * 编辑记忆。
   *
   * 之前没有这个方法，页面只能「删旧建新」—— 代价是 id 变了、hit_count 清零，
   * 记忆的使用统计全部丢失。加这个方法是为了保住 id 与命中次数。
   */
  static async update(
    store: relationalStore.RdbStore, id: string, kind: string, content: string, now: number
  ): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('记忆')) {
      return;
    }
    await store.executeSql(
      'UPDATE memories SET kind = ?, content = ?, updated_at = ? WHERE id = ?',
      [kind, content, now, id]);
  }

  /** 新增记忆时指定 id（导入/迁移场景） */
  static async insertWithId(
    store: relationalStore.RdbStore,
    id: string, scope: string, scopeId: string, kind: string,
    content: string, pinned: boolean, now: number
  ): Promise<void> {
    // R35-EXEMPT: migration —— 记忆导入/迁移场景（指定 id 直插），
    // 非页面常规写入口，服务端模式下不会触发用户可见的「假成功」。
    // 调用点白名单（非页面）：当前无调用点（预留导入/迁移工具）。
    // 页面**不得**直调本方法。
    await store.executeSql(
      `INSERT OR REPLACE INTO memories
       (id, scope, scope_id, kind, content, pinned, hit_count, created_at, updated_at)
       VALUES (?,?,?,?,?,?,0,?,?)`,
      [id, scope, scopeId, kind, content, pinned ? 1 : 0, now, now]);
  }

  static async markHit(store: relationalStore.RdbStore, id: string): Promise<void> {
    // 内部路径（记忆检索自动计数）：只拦截不弹 toast
    if (blockLocalWrite('记忆', true)) {
      return;
    }
    await store.executeSql('UPDATE memories SET hit_count = hit_count + 1 WHERE id = ?', [id]);
  }

  static async remove(store: relationalStore.RdbStore, id: string): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('记忆')) {
      return;
    }
    await store.executeSql('DELETE FROM memories WHERE id = ?', [id]);
  }
}

// ───────────────────────── 用量 ─────────────────────────

export class UsageRepo {
  static async add(store: relationalStore.RdbStore, r: UsageRecord): Promise<void> {
    // 内部路径（对话/编排自动记用量）：只拦截不弹 toast
    if (blockLocalWrite('用量', true)) {
      return;
    }
    await store.executeSql(
      `INSERT INTO usage_records
       (id, session_id, room_id, agent_id, provider, model,
        input_tokens, output_tokens, cost_usd, created_at)
       VALUES (?,?,?,?,?,?,?,?,?,?)`,
      [r.id, r.sessionId, r.roomId, r.agentId, r.provider, r.model,
       r.inputTokens, r.outputTokens, r.costUsd, r.createdAt]);
  }

  static async summary(store: relationalStore.RdbStore, now: number): Promise<UsageSummary> {
    // 之前把近 30 天 usage_records 全量 SELECT * 拉进内存再用 4 个 Map 聚合；
    // 现在聚合下推到 SQL，只拿聚合结果。
    const since = now - 30 * 86400000;

    // 总量 + 会话数
    const totalRow = await queryOne(
      store,
      `SELECT
         COALESCE(SUM(input_tokens), 0)  AS sum_in,
         COALESCE(SUM(output_tokens), 0) AS sum_out,
         COALESCE(SUM(cost_usd), 0)      AS sum_cost,
         COUNT(DISTINCT session_id)      AS c_session
       FROM usage_records WHERE created_at >= ? AND session_id <> ''`,
      [since]);
    const totalRowAll = await queryOne(
      store,
      `SELECT
         COALESCE(SUM(input_tokens), 0)  AS sum_in,
         COALESCE(SUM(output_tokens), 0) AS sum_out,
         COALESCE(SUM(cost_usd), 0)      AS sum_cost
       FROM usage_records WHERE created_at >= ?`,
      [since]);
    const s: UsageSummary = {
      totalInput: totalRowAll === null ? 0 : num(totalRowAll, 'sum_in'),
      totalOutput: totalRowAll === null ? 0 : num(totalRowAll, 'sum_out'),
      totalCost: totalRowAll === null ? 0 : num(totalRowAll, 'sum_cost'),
      sessionCount: totalRow === null ? 0 : num(totalRow, 'c_session'),
      byModel: [],
      daily: []
    };

    // 按模型聚合
    const modelRows = await queryToObjects(
      store,
      `SELECT
         CASE WHEN model = '' THEN 'unknown' ELSE model END AS m,
         SUM(input_tokens + output_tokens) AS t,
         SUM(cost_usd) AS cost
       FROM usage_records WHERE created_at >= ?
       GROUP BY m ORDER BY t DESC`,
      [since]);
    const byModel: UsageBucket[] = [];
    for (const r of modelRows) {
      byModel.push({ key: str(r, 'm'), tokens: num(r, 't'), cost: num(r, 'cost') });
    }
    s.byModel = byModel;

    // 按天聚合（本地时区，不能用 toISOString 那套 UTC）
    const dayRows = await queryToObjects(
      store,
      `SELECT
         strftime('%Y-%m-%d', created_at / 1000, 'unixepoch', 'localtime') AS d,
         SUM(input_tokens + output_tokens) AS t,
         SUM(cost_usd) AS cost
       FROM usage_records WHERE created_at >= ?
       GROUP BY d ORDER BY d ASC`,
      [since]);
    const daily: UsageBucket[] = [];
    for (const r of dayRows) {
      daily.push({ key: str(r, 'd'), tokens: num(r, 't'), cost: num(r, 'cost') });
    }
    s.daily = daily;
    return s;
  }

  static async clear(store: relationalStore.RdbStore): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('用量')) {
      return;
    }
    await store.executeSql('DELETE FROM usage_records');
  }
}

/** 本地日期键 YYYY-MM-DD（不能用 toISOString，那是 UTC，会串日期） */
export function dayKey(ts: number): string {
  const d = new Date(ts);
  const y = `${d.getFullYear()}`;
  const m = `${d.getMonth() + 1}`.padStart(2, '0');
  const day = `${d.getDate()}`.padStart(2, '0');
  return `${y}-${m}-${day}`;
}

// ───────────────────────── 日志 ─────────────────────────

export class LogRepo {
  static async write(
    store: relationalStore.RdbStore, level: LogLevel, scope: string, message: string, now: number
  ): Promise<void> {
    // R35-EXEMPT: cache-only —— 应用日志本地缓存，非业务数据，
    // 服务端模式下日志本就落在 PC 侧，本地写入无用户可见影响。
    // 调用点白名单（非页面）：LogRepo.info / warn / error（data 层内部）。
    // 页面**不得**直调本方法。
    await store.executeSql(
      'INSERT INTO app_logs (id, level, scope, message, created_at) VALUES (?,?,?,?,?)',
      [newId(now), level, scope, message.slice(0, 2000), now]);
  }

  static async info(store: relationalStore.RdbStore, scope: string, message: string): Promise<void> {
    await LogRepo.write(store, 'info', scope, message, Date.now());
  }

  static async warn(store: relationalStore.RdbStore, scope: string, message: string): Promise<void> {
    await LogRepo.write(store, 'warn', scope, message, Date.now());
  }

  static async error(store: relationalStore.RdbStore, scope: string, message: string): Promise<void> {
    await LogRepo.write(store, 'error', scope, message, Date.now());
  }

  static async list(store: relationalStore.RdbStore, limit: number): Promise<AppLog[]> {
    const rows = await queryToObjects(store, 'SELECT * FROM app_logs ORDER BY created_at DESC LIMIT ?', [limit]);
    const out: AppLog[] = [];
    for (const r of rows) {
      out.push({
        id: str(r, 'id'),
        level: toLogLevel(str(r, 'level', 'info')),
        scope: str(r, 'scope'),
        message: str(r, 'message'),
        createdAt: num(r, 'created_at')
      });
    }
    return out;
  }

  static async clear(store: relationalStore.RdbStore): Promise<void> {
    // 服务端模式下数据在 PC 上，写本地库不会有任何效果 —— 明确拦截，别静默失败
    if (blockLocalWrite('日志')) {
      return;
    }
    await store.executeSql('DELETE FROM app_logs');
  }

  /** 只保留最近 N 条，防止日志表无限膨胀 */
  static async trim(store: relationalStore.RdbStore, keep: number): Promise<void> {
    // 内部维护路径（定时/后台清理）：只拦截不弹 toast
    if (blockLocalWrite('日志', true)) {
      return;
    }
    await store.executeSql(
      `DELETE FROM app_logs WHERE id NOT IN
       (SELECT id FROM app_logs ORDER BY created_at DESC LIMIT ?)`, [keep]);
  }
}

export function toLogLevel(s: string): LogLevel {
  if (s === 'debug' || s === 'warn' || s === 'error') {
    return s;
  }
  return 'info';
}