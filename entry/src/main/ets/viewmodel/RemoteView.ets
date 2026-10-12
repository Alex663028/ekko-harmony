/**
 * 远程数据适配层：把服务端的 Remote* ViewModel 映射成本地领域模型。
 *
 * 为什么需要这一层（而不是让页面直接用 Remote*）：
 *   页面（JobsPage / KanbanPage / UsagePage / MemoryPage / SkillsPage）
 *   已经是按本地模型 `Job` / `KanbanCard` / `UsageSummary` / `MemoryItem` 写的，
 *   几百行UI 逻辑（排序、聚合、配色、格式化）都有价值，不该重写。
 *
 *   所以：**只换数据源，不改页面**。本文件负责
 *     本地模式：ExtendRepos → SQLite
 *     服务端模式：StudioApi → HTTP → Remote* → 本文件映射 → 本地模型
 *   页面的 reload() 调`RemoteView.xxx()` 拿到的还是它熟悉的那个类型。
 *
 * 只读页面的写操作（新建/编辑任务等）在服务端模式下要拦住——
 * 见 blockLocalWrite。
 */

import relationalStore from '@ohos.data.relationalStore';
import { StudioApi, RemoteJob, RemoteTask, RemoteUsage, RemoteMemory } from '../net/StudioApi';
import { NetConfig } from '../net/Http';
import { isServerMode } from './ServerMode';
import {
  JobRepo, KanbanRepo, MemoryRepo, SkillRepo, McpRepo, LogRepo, UsageRepo
} from '../data/ExtendRepos';
import {
  Job, KanbanCard, KanbanColumn, MemoryItem, Skill, McpServer, AppLog,
  UsageSummary, UsageBucket, LogLevel
} from '../model/Extend';
import { strOf, numOf, boolOf } from '../model/Json';

function token(): string {
  return NetConfig.getToken();
}

/** 看板状态 → 列 slug。服务端用 status 字符串，本地按 id 分列 */
const STATUS_TO_COLUMN: Record<string, string> = {
  'backlog': 'backlog', 'todo': 'todo', 'in_progress': 'in_progress',
  'doing': 'in_progress', 'review': 'review', 'done': 'done', 'completed': 'done'
};

export class RemoteView {
  // ───────── 定时任务 ─────────

  static async jobs(store: relationalStore.RdbStore): Promise<Job[]> {
    if (!isServerMode()) {
      return JobRepo.list(store);
    }
    const list = await StudioApi.listJobs(token());
    const out: Job[] = [];
    for (const r of list) {
      out.push(RemoteView.toJob(r));
    }
    return out;
  }

  private static toJob(r: RemoteJob): Job {
    // 服务端 schedule_display 是给人看的（"每天 09:00"），
    // 本地 Job.cron 存的是 5 段表达式；只读展示的话用 display 更直观，
    // 所以塞进 cron 字段（页面只显示它，不做解析）。
    return {
      id: r.id,
      name: r.name,
      cron: r.schedule.length > 0 ? r.schedule : '—',
      sessionId: '',
      roomId: '',
      agentId: '',
      prompt: r.prompt,
      enabled: r.enabled,
      lastRunAt: r.lastRunAt,
      lastStatus: r.lastStatus,
      nextRunAt: r.nextRunAt,
      createdAt: 0
    };
  }

  // ───────── 看板 ─────────

  /**
   * 看板列（只读）。
   *
   * ⚠ 本地模型 KanbanColumn **只存列本身**（id/name/position/wipLimit），
   *   卡片是另一张表（KanbanCard），页面分别拉。
   *   所以服务端模式不能把卡片塞进列里 —— 按同样形状返回列，卡片走 cards()。
   */
  static async kanban(store: relationalStore.RdbStore): Promise<KanbanColumn[]> {
    if (!isServerMode()) {
      return KanbanRepo.columns(store);
    }
    // 服务端 kanban 不存「列」这个概念，状态字段才是。
    // 用固定的一套列模板，把服务端有任务的列排前面。
    const tasks = await StudioApi.listKanban(token());
    const slugs: string[] = ['backlog', 'todo', 'in_progress', 'review', 'done'];
    const nameOf: Record<string, string> = {
      'backlog': '待规划', 'todo': '待处理', 'in_progress': '进行中',
      'review': '待验收', 'done': '已完成'
    };
    const out: KanbanColumn[] = [];
    for (let i = 0; i < slugs.length; i++) {
      const slug = slugs[i];
      // 只保留服务端实际用到的状态列，避免空列占位
      let used = false;
      for (const t of tasks) {
        if (RemoteView.toSlug(t.status) === slug) {
          used = true;
          break;
        }
      }
      if (!used && i > 0) {
        continue;
      }
      const col: KanbanColumn = {
        id: slug,
        name: nameOf[slug] ?? slug,
        position: i,
        wipLimit: 0
      };
      out.push(col);
    }
    return out;
  }

  /** 看板卡片（只读）—— 按列 id 分组，页面自己拼 */
  static async kanbanCards(store: relationalStore.RdbStore): Promise<KanbanCard[]> {
    if (!isServerMode()) {
      return KanbanRepo.allCards(store);
    }
    const tasks = await StudioApi.listKanban(token());
    const out: KanbanCard[] = [];
    for (const t of tasks) {
      out.push(RemoteView.toCard(t));
    }
    return out;
  }

  private static toSlug(status: string): string {
    const s = status.toLowerCase();
    if (STATUS_TO_COLUMN[s] !== undefined) {
      return STATUS_TO_COLUMN[s];
    }
    return 'todo';
  }

  private static toCard(t: RemoteTask): KanbanCard {
    // 本地 priority 是 0高1中2低，服务端是字符串
    const p = t.priority.toLowerCase();
    const lvl: number = (p === 'high' || p === 'urgent') ? 0 : ((p === 'low') ? 2 : 1);
    return {
      id: t.id,
      columnId: RemoteView.toSlug(t.status),
      title: t.title,
      body: t.description,
      // 本地 tag 是自由文本，服务端的 priority/assignee 放这里能显示出来
      tag: RemoteView.cardTag(t),
      priority: lvl,
      position: 0,
      sessionId: t.assignee,
      createdAt: 0,
      updatedAt: t.updatedAt
    };
  }

  /** 卡片的角标：优先 assignee，其次 priority，都没有就空 */
  private static cardTag(t: RemoteTask): string {
    if (t.assignee.length > 0) {
      return '@' + t.assignee;
    }
    return t.priority;
  }

  // ───────── 用量 ─────────

  static async usage(store: relationalStore.RdbStore): Promise<UsageSummary> {
    if (!isServerMode()) {
      return UsageRepo.summary(store, Date.now());
    }
    const u = await StudioApi.sessionUsage(token());
    const buckets: UsageBucket[] = [];
    for (const row of u.byModel) {
      buckets.push({ key: row.model, tokens: row.totalTokens, cost: row.cost });
    }
    return {
      totalInput: u.totalInputTokens,
      totalOutput: u.totalOutputTokens,
      totalCost: u.totalCost,
      sessionCount: u.sessions,
      byModel: buckets,
      // 服务端这个端点不返回按天趋势，页面要能处理空数组
      daily: []
    };
  }

  // ───────── 记忆 ─────────

  static async memory(store: relationalStore.RdbStore, scope: string, scopeId: string): Promise<MemoryItem[]> {
    if (!isServerMode()) {
      return MemoryRepo.effective(store, scope, scopeId);
    }
    const list = await StudioApi.listMemory(token());
    const out: MemoryItem[] = [];
    for (const r of list) {
      out.push(RemoteView.toMemory(r));
    }
    return out;
  }

  /** 全部记忆（记忆页列表用，不做 scope 过滤） */
  static async memoryAll(store: relationalStore.RdbStore): Promise<MemoryItem[]> {
    return RemoteView.memory(store, 'global', '');
  }

  private static toMemory(r: RemoteMemory): MemoryItem {
    return {
      id: r.id,
      scope: r.scope.length > 0 ? r.scope : 'global',
      scopeId: '',
      // 服务端没有 kind 字段，用 source 顶替（note/fact/preference）
      kind: r.source.length > 0 ? r.source : 'note',
      content: r.content,
      pinned: r.pinned,
      hitCount: 0,
      createdAt: 0,
      updatedAt: r.updatedAt
    };
  }

  // ───────── 技能 ─────────

  static async skills(store: relationalStore.RdbStore): Promise<Skill[]> {
    if (!isServerMode()) {
      return SkillRepo.list(store);
    }
    const list = await StudioApi.listSkills(token());
    const out: Skill[] = [];
    for (const s of list) {
      out.push({
        id: s.id,
        name: s.name,
        description: s.description,
        // 服务端没有 instructions 字段（那是本地的正文），留空
        instructions: '',
        source: s.source.length > 0 ? s.source : 'server',
        enabled: s.enabled,
        usageCount: 0,
        lastUsedAt: 0,
        builtin: false,
        updatedAt: s.updatedAt
      });
    }
    return out;
  }

  // ───────── MCP ─────────

  static async mcpServers(store: relationalStore.RdbStore): Promise<McpServer[]> {
    if (!isServerMode()) {
      return McpRepo.list(store);
    }
    const list = await StudioApi.listMcpServers(token());
    const out: McpServer[] = [];
    for (const s of list) {
      out.push({
        id: s.name,
        name: s.name,
        transport: s.transport.length > 0 ? s.transport : 'stdio',
        command: s.command,
        // 本地字段是「JSON 数组字符串」，服务端给的是纯文本，拼成 JSON 才能被页面解析
        args: JSON.stringify(s.args),
        // http 类传输用 url 而非 command
        url: s.transport === 'http' || s.transport === 'sse' ? s.command : '',
        // 本地 env 是 JSON 对象字符串，这里只保数量
        env: s.envCount > 0 ? JSON.stringify({ count: s.envCount }) : '{}',
        enabled: s.enabled,
        builtin: false,
        updatedAt: 0
      });
    }
    return out;
  }

  // ───────── 日志 ─────────

  static async logs(store: relationalStore.RdbStore, limit: number): Promise<AppLog[]> {
    if (!isServerMode()) {
      return LogRepo.list(store, limit);
    }
    const list = await StudioApi.listLogs(token(), limit);
    const out: AppLog[] = [];
    for (const l of list) {
      out.push({
        id: l.id.length > 0 ? l.id : `${l.ts}-${l.scope}`,
        // 服务端 level 是字符串，本地是 LogLevel 联合类型 → 白名单收敛
        level: RemoteView.toLogLevel(l.level),
        scope: l.scope,
        message: l.message,
        createdAt: l.ts
      });
    }
    return out;
  }

  private static toLogLevel(s: string): LogLevel {
    const v = s.toLowerCase();
    if (v === 'debug') {
      return 'debug';
    }
    if (v === 'warn' || v === 'warning') {
      return 'warn';
    }
    if (v === 'error' || v === 'err' || v === 'fatal') {
      return 'error';
    }
    return 'info';
  }
}