/**
 * Agent 编排器：替代原版 Koa 侧的 group-chat 执行引擎。
 *
 * 原版流程：Socket.IO(/group-chat) → 服务端 processMentions → 落 gc_execution_queue
 *           → 各 agent 进程自行消费 → Socket.IO 广播消息
 * 鸿蒙流程：消息入队（本地 gc_execution_queue）→ 本地 orchestrator 逐个取出
 *           → 用对应 Agent 的 provider/model 调 LLM → 写回 gc_messages
 *
 * @ 提及的处理严格对齐原版：只有被 @ 的 agent 才入队；@all 展开为全体在线 agent。
 */

import relationalStore from '@ohos.data.relationalStore';
import {
  RoomAgent, RoomInfo, Provider, AgentProfile, GroupMessage,
  MentionRef, ExecutionQueueItem, RunUsage
} from '../model/Types';
import { RunEventLite, StreamState, emptyStream, reduceRunEvent, shortId } from '../common/Core';
import { LogRepo, SkillRepo, composeSystemPrompt } from '../data/ExtendRepos';
import { ProviderRepo, AgentProfileRepo, RoomAgentRepo, GroupMessageRepo, QueueRepo, RoomRepo, newId } from '../data/Repos';
import { LlmEngine, LlmMessage, LlmRunHandle, LlmRunRequest } from './LlmEngine';

export interface OrchestratorHooks {
  /** 消息产生增量（用于 UI 流式刷新） */
  onDelta?: (messageId: string, state: StreamState) => void;
  /** 一条消息完成 */
  onComplete?: (messageId: string, state: StreamState, usage: RunUsage) => void;
  /** 失败 */
  onError?: (messageId: string, error: string) => void;
  /**
   * D-R31-2：队列泵把该房间抽干、队列行全部落到终态之后触发一次。
   *
   * 为什么必须单独有它：onComplete 在 finalize 内部触发，那时 pump 还没把当前
   * 队列项置 done（pump 先置 running，runOne 返回后才 updateStatus('done')）。
   * UI 若只靠 onComplete 刷新，读到的 pending 仍是「queued+running = 1」，
   * 之后无人再刷 → 角标停在「1 个排队中」、「■ 停止」不消失，直到重进页面。
   */
  onQueueIdle?: (roomId: string) => void;
}

/**
 * ArkTS 不接受「全成员可选的 interface 用对象字面量构造」，
 * 判为 arkts-no-untyped-obj-literals。空钩子用 class 实现。
 */
class EmptyHooks implements OrchestratorHooks {
  onDelta?: (messageId: string, state: StreamState) => void;
  onComplete?: (messageId: string, state: StreamState, usage: RunUsage) => void;
  onError?: (messageId: string, error: string) => void;
  onQueueIdle?: (roomId: string) => void;
}

export function newEmptyHooks(): OrchestratorHooks {
  return new EmptyHooks();
}

/** 队列泵的占位句柄：只需要一个 no-op abort */
class AbortOnly implements LlmRunHandle {
  abort(): void {
  }
}

function newAbortOnly(): LlmRunHandle {
  return new AbortOnly();
}

export class AgentOrchestrator {
  private static running = new Map<string, LlmRunHandle>();
  /**
   * P2-SEQ11：ctxKey → 正在跑的 runId。
   *
   * 为什么不能只靠 running（句柄表）：句柄要等 `await LlmEngine.run(...)`
   * 返回才登记，而 run 内部要等 requestInStream 完成才 resolve —— 整个建连与
   * 流式窗口（最长可到 300s）里 running 是空的，用户在这段时间点「停止」
   * 会查不到句柄，abort 静默丢失，请求继续烧 token。
   */
  private static activeRunIds = new Map<string, string>();
  private static hooks: OrchestratorHooks = newEmptyHooks();
  /** 正在被某 Agent 消费的对话上下文：roomId:agentId → 消息列表 */
  private static contexts = new Map<string, LlmMessage[]>();

  static setHooks(h: OrchestratorHooks): void {
    AgentOrchestrator.hooks = h;
  }

  /**
   * 处理一条群聊消息：落库 → 解析 mentions → 入队 → 触发执行。
   * 返回入队的任务数。
   */
  static async dispatch(
    store: relationalStore.RdbStore,
    room: RoomInfo,
    text: string,
    mentions: MentionRef[],
    username: string
  ): Promise<number> {
    const now = Date.now();
    const msgId = shortId(now, Math.random());

    // 1. 落库用户消息
    const userMsg: GroupMessage = {
      id: msgId,
      roomId: room.id,
      senderName: username,
      senderKind: 'human',
      role: 'user',
      content: text,
      mentions: mentions,
      timestamp: now
    };
    await GroupMessageRepo.insert(store, userMsg);
    await RoomRepo.touch(store, room.id, 0, now);

    // 2. 把 mentions 展开成具体 agent 列表
    const alive = room.agents ?? [];
    const targets: RoomAgent[] = [];
    for (const ref of mentions) {
      if (ref.type === 'all') {
        for (const a of alive) {
          if (!targets.some((t) => t.agentId === a.agentId)) {
            targets.push(a);
          }
        }
      } else {
        // 关键：按 agentId（稳定全局 id）匹配，不是房间记录 id
        const hit = alive.find((a) => a.agentId === ref.participantId);
        if (hit !== undefined && !targets.some((t) => t.agentId === hit.agentId)) {
          targets.push(hit);
        }
      }
    }

    if (targets.length === 0) {
      return 0;
    }

    // 3. 入队
    for (const a of targets) {
      const item: ExecutionQueueItem = {
        id: shortId(Date.now(), Math.random()),
        roomId: room.id,
        targetAgentId: a.agentId,
        targetAgentName: a.name,
        status: 'queued',
        createdAt: Date.now()
      };
      await QueueRepo.enqueue(store, item);
    }

    // 4. 触发执行（不 await，让消息先返回给 UI）
    AgentOrchestrator.pump(store, room.id);
    return targets.length;
  }

  /** 队列泵：把该房间里排队中的任务逐个执行完 */
  static async pump(store: relationalStore.RdbStore, roomId: string): Promise<void> {
    // 防重入：同一房间同一时刻只跑一个 pump
    const lockKey = `pump:${roomId}`;
    if (AgentOrchestrator.running.has(lockKey)) {
      return;
    }
    AgentOrchestrator.running.set(lockKey, newAbortOnly());

    try {
      let guard = 0;
      for (;;) {
        guard++;
        if (guard > 100) {
          // 死循环保护：单次泵最多处理 100 个任务
          break;
        }
        const next = await QueueRepo.takeNext(store, roomId);
        if (next === null) {
          break;
        }
        await QueueRepo.updateStatus(store, next.id, 'running', Date.now());
        try {
          const aborted = await AgentOrchestrator.runOne(store, roomId, next);
          if (aborted) {
            // P1-SEQ7-④ 接线：用户中止的队列项终态是 cancelled。
            // 不能盖成 done —— 队列账目会说「已完成」，与「用户点了停止」矛盾。
            await QueueRepo.updateStatus(store, next.id, 'cancelled', Date.now(), '用户已中止');
          } else {
            await QueueRepo.updateStatus(store, next.id, 'done', Date.now());
          }
        } catch (e) {
          const err = e as Error;
          const msg = err.message ?? 'unknown';
          await QueueRepo.updateStatus(store, next.id, 'failed', Date.now(), msg);
          // P1-2：onError 已由 runOne 内部用真实 messageId 触发，
          // 这里只负责队列状态与日志，不再把 next.id 当 messageId 外传。
          try {
            await LogRepo.error(store, 'orchestrator', `run failed room=${roomId} agent=${next.targetAgentId}: ${msg}`);
          } catch (le) {
            // 落库失败不能掩盖原始错误
          }
        }
      }
    } finally {
      AgentOrchestrator.running.delete(lockKey);
      // D-R31-2：队列已抽干（本房间所有项都落到终态）之后再通知一次 UI。
      // 放在释放锁之后：此刻重入的 pump 已可重新进入，读到的账目就是最新的，
      // 不会把刚被置 running 的新任务误报成已空闲。
      if (AgentOrchestrator.hooks.onQueueIdle !== undefined) {
        AgentOrchestrator.hooks.onQueueIdle(roomId);
      }
    }
  }

  /** 执行单个 agent 的一次回复。返回 true 表示这次 run 是被用户 abort 掉的 */
  private static async runOne(
    store: relationalStore.RdbStore,
    roomId: string,
    item: ExecutionQueueItem
  ): Promise<boolean> {
    // P1-2：msgId 提前生成，让「供应商未配置/禁用」等前置失败也能拿到真实消息 id，
    // 与 LlmEngine 流式路径共用同一个 msgId，避免队列 id 混用。
    const msgId = shortId(Date.now(), Math.random());
    try {
      const room = await RoomRepo.get(store, roomId);
      if (room === null) {
        throw new Error('房间不存在');
      }
      const agent = (room.agents ?? []).find((a) => a.agentId === item.targetAgentId);
      if (agent === undefined) {
        throw new Error('Agent 不在房间内');
      }
      const provider = await ProviderRepo.get(store, agent.provider);
      if (provider === null) {
        throw new Error(`未配置供应商: ${agent.provider}`);
      }
      if (!provider.enabled) {
        throw new Error(`供应商已禁用: ${provider.name}`);
      }

      const ctxKey = AgentOrchestrator.contextKey(roomId, agent.agentId);
      let ctx = AgentOrchestrator.contexts.get(ctxKey);
      if (ctx === undefined || ctx.length === 0) {
        ctx = await AgentOrchestrator.buildInitialContext(store, roomId, agent);
        AgentOrchestrator.contexts.set(ctxKey, ctx);
      }

      let state: StreamState = emptyStream();

      const sink = (ev: RunEventLite): void => {
        state = reduceRunEvent(state, ev);
        if (AgentOrchestrator.hooks.onDelta !== undefined) {
          AgentOrchestrator.hooks.onDelta(msgId, state);
        }
        // P1-SEQ7-④：abort.completed 也必须收尾。
        //   漏了它的后果（DSH 复审后补）：handle.abort() 只发 abort.completed，
        //   finalize 不跑 → waitFor 的 waiter 永不 resolve → runOne 的 await done
        //   一直卡到 600s 兜底定时器，pump 锁被占满 10 分钟，期间该房间新消息
        //   全部排队不执行。补上后 abort 立即收尾，泵随即释放。
        if (ev.event === 'run.completed' || ev.event === 'run.failed' || ev.event === 'abort.completed') {
          // P1-7：finalize 现在返回 Promise，不 await（sink 是同步的），
          // 但错误不能吞掉。
          const p = AgentOrchestrator.finalize(store, roomId, agent, msgId, state, ctx as LlmMessage[]);
          p.catch((e: Error) => {
            console.error(`finalize failed: ${e.message}`);
          });
        }
      };

      const llmReq: LlmRunRequest = {
        provider: provider,
        model: agent.model,
        messages: ctx,
        temperature: 0,
        maxTokens: 4096,
        reasoningEffort: agent.reasoningEffort
      };
      // 关键顺序：先注册 waiter，再发起 run。
      //
      // 反过来（先 run 后 wait）会死锁：LlmEngine.run() 在参数非法时
      // 会**同步**回调 sink(run.failed) → finalize() → 此时waiter 还没注册，
      // resolve 被丢弃 → waitFor 永远等不到 → 队列项卡在 running，
      // 该房间后续所有消息全部堵死，只能等10 分钟兜底。
      const done = AgentOrchestrator.waitFor(ctxKey);
      // P2-SEQ11：先登记 runId 再 await run —— 建连窗口（最长 connectTimeout=20s、
      //   流式期间到流结束）内句柄还没到手，此刻 abort() 拿不到 handle。
      //   登记后 abort() 可以按 runId 走 LlmEngine.abortRun，用户点的「停止」不再丢。
      AgentOrchestrator.activeRunIds.set(ctxKey, msgId);
      try {
        const handle = await LlmEngine.run(llmReq, msgId, sink);
        AgentOrchestrator.running.set(ctxKey, handle);
        // 等这次 run 结束（run.completed / run.failed 会 resolve）
        await done;
      } finally {
        // 无论正常结束还是抛错，句柄都必须清掉，否则 running 泄漏
        AgentOrchestrator.running.delete(ctxKey);
        AgentOrchestrator.activeRunIds.delete(ctxKey);
        AgentOrchestrator.clearWaiter(ctxKey);
      }
      // R33/D-R32-1：run.failed 必须按失败抛出 —— 旧实现只回传「是否 aborted」，
      //   run.failed 落进 else 分支 → pump 把队列项记成 done，故障被记账成「已完成」。
      //   抛错后走下方既有 catch 路径：onError 通知 UI、queue 落 failed 带原因、
      //   LogRepo 留痕，一套逻辑覆盖「抛异常」与「事件失败」两种失败形态。
      if (state.status === 'failed') {
        throw new Error(state.error.length > 0 ? state.error : '运行失败');
      }
      // 中止的 run 也走 finalize（sink 已把 abort.completed 纳入收尾），
      // 这里把状态回传给 pump，让队列项落 cancelled 而不是 done。
      return state.status === 'aborted';
    } catch (e) {
      // P1-2：runOne 内捕获失败并用真实 messageId 通知 UI，失败气泡才能收尾。
      // 队列项状态由 pump 继续置为 failed，这里不吞异常。
      const err = e as Error;
      const msg = err.message ?? 'unknown';
      if (AgentOrchestrator.hooks.onError !== undefined) {
        AgentOrchestrator.hooks.onError(msgId, msg);
      }
      // ArkTS 不允许 throw 任意类型，rethrow 一个明确类型的 Error。
      throw new Error(msg);
    }
  }

  private static waiters = new Map<string, () => void>();
  /** 兜底定时器 id：正常完成时必须清掉，否则每次回复都留一个 10 分钟的悬挂定时器 */
  private static waiterTimers = new Map<string, number>();

  private static waitFor(key: string): Promise<void> {
    // 已经结束过（run 在注册前就完成了）→ 立即返回，不能再等
    if (AgentOrchestrator.finished.has(key)) {
      AgentOrchestrator.finished.delete(key);
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      AgentOrchestrator.waiters.set(key, resolve);
      const timer = setTimeout(() => {
        if (AgentOrchestrator.waiters.has(key)) {
          AgentOrchestrator.waiters.delete(key);
          AgentOrchestrator.waiterTimers.delete(key);
          resolve();
        }
      }, 600000);
      AgentOrchestrator.waiterTimers.set(key, timer);
    });
  }

  /** 清掉某key 的兜底定时器 */
  private static clearWaiter(key: string): void {
    const t = AgentOrchestrator.waiterTimers.get(key);
    if (t !== undefined) {
      clearTimeout(t);
      AgentOrchestrator.waiterTimers.delete(key);
    }
    AgentOrchestrator.waiters.delete(key);
    AgentOrchestrator.finished.delete(key);
  }

  /** run 已结束但waiter 尚未注册的窗口标记 */
  private static finished = new Set<string>();

  private static finalize(
    store: relationalStore.RdbStore,
    roomId: string,
    agent: RoomAgent,
    msgId: string,
    state: StreamState,
    ctx: LlmMessage[]
  ): Promise<void> {
    const usage: RunUsage = {
      inputTokens: state.usage.inputTokens,
      outputTokens: state.usage.outputTokens,
      totalTokens: state.usage.inputTokens + state.usage.outputTokens,
      cacheReadTokens: state.usage.cacheReadTokens
    };
    const key = AgentOrchestrator.contextKey(roomId, agent.agentId);
    // P1-SEQ7-④：用户点「停止」但一个字都没生成时，不落库、不写上下文 ——
    //   否则留下一个空白气泡，还往 ctx 塞一条空 assistant 消息污染后续对话。
    //   收尾通知与 waiter 释放照旧：它们负责清掉流式占位，并让 pump 从
    //   await done 返回；跳过的话泵会一直卡到 600s 兜底。
    const emptyAbort = state.status === 'aborted' && state.text.length === 0;
    // R33/D-R32-1：run.failed 且一个字都没有时同理 —— 旧行为会把失败记成成功并
    //   落一条空正文 assistant 消息（用户看到空气泡，后续对话上下文也被污染）。
    const emptyFailure = state.status === 'failed' && state.text.length === 0;
    let insertPromise: Promise<void> = Promise.resolve();
    if (!emptyAbort && !emptyFailure) {
      const msg: GroupMessage = {
        id: msgId,
        roomId: roomId,
        senderName: agent.name,
        senderKind: 'agent',
        agentId: agent.agentId,
        role: 'assistant',
        content: state.text,
        usage: usage,
        timestamp: Date.now()
      };
      // P1-7：必须 await insert，否则消息可能还没落库 UI 就显示完成，
      // 退出页面重进后消息丢失。
      insertPromise = GroupMessageRepo.insert(store, msg);
      RoomRepo.touch(store, roomId, usage.totalTokens, Date.now());

      // 把这一轮写回上下文，供后续追问。
      // ⚠ 角色必须是 assistant：state.text 是 Agent 自己生成的回复。
      //   之前误写 user，模型会把「自己的回答」当成「用户的新提问」，
      //   长对话中逐渐复读/角色错乱。与落库、buildInitialContext 的
      //   assistant 角色保持一致。
      ctx.push({ role: 'assistant', content: state.text });
      // P1-8：上下文无限增长会导致 LLM 400（context length exceeded），
      // 且每次请求 token 费用线性增长。超过上限时丢弃最早的消息。
      AgentOrchestrator.trimContext(ctx);
      AgentOrchestrator.contexts.set(key, ctx);
    }

    if (AgentOrchestrator.hooks.onComplete !== undefined) {
      AgentOrchestrator.hooks.onComplete(msgId, state, usage);
    }
    AgentOrchestrator.releaseWaiter(key);
    return insertPromise;
  }

  /**
   * 释放某 key 的等待者，并清掉兜底定时器（不清理会留一个 10 分钟悬挂定时器）。
   * waiter 尚未注册（run 同步结束）时打 finished 标记，让随后到来的 waitFor
   * 立即返回而不是死等 10 分钟。
   */
  private static releaseWaiter(key: string): void {
    const w = AgentOrchestrator.waiters.get(key);
    if (w === undefined) {
      AgentOrchestrator.finished.add(key);
      return;
    }
    AgentOrchestrator.waiters.delete(key);
    const t = AgentOrchestrator.waiterTimers.get(key);
    if (t !== undefined) {
      clearTimeout(t);
      AgentOrchestrator.waiterTimers.delete(key);
    }
    w();
  }

  private static contextKey(roomId: string, agentId: string): string {
    return `${roomId}:${agentId}`;
  }

  /**
   * P1-8：上下文截断。
   *
   * 群聊上下文每次回复都会 push，无限增长会导致：
   * 1. LLM API 400（context length exceeded）
   * 2. 每次请求 token 费用线性增长
   *
   * 策略：超过 MAX_CTX_MESSAGES 条时丢弃最早的消息（保留 system 角色），
   * 同时用近似估算 token 数（中文字符 × 1.5，英文 × 0.3），
   * 超过 MAX_CTX_TOKENS 时继续丢弃直到低于阈值。
   */
  private static MAX_CTX_MESSAGES = 50;
  private static MAX_CTX_TOKENS = 24000;

  private static trimContext(ctx: LlmMessage[]): void {
    // 先按条数截断
    while (ctx.length > AgentOrchestrator.MAX_CTX_MESSAGES) {
      // 保留 system 角色消息（通常是第一条）
      const idx = ctx.findIndex((m) => m.role !== 'system');
      if (idx === -1) {
        break;
      }
      ctx.splice(idx, 1);
    }
    // 再按 token 估算截断
    let totalTokens = AgentOrchestrator.estimateTokens(ctx);
    while (totalTokens > AgentOrchestrator.MAX_CTX_TOKENS && ctx.length > 1) {
      const idx = ctx.findIndex((m) => m.role !== 'system');
      if (idx === -1) {
        break;
      }
      ctx.splice(idx, 1);
      totalTokens = AgentOrchestrator.estimateTokens(ctx);
    }
  }

  /** 近似估算 token 数：中文字符 × 1.5，英文 × 0.3 */
  private static estimateTokens(ctx: LlmMessage[]): number {
    let tokens = 0;
    for (const m of ctx) {
      const content = m.content;
      for (let i = 0; i < content.length; i++) {
        const code = content.charCodeAt(i);
        if (code > 127) {
          tokens += 1.5;
        } else {
          tokens += 0.3;
        }
      }
    }
    return Math.ceil(tokens);
  }

  /** 首次进入房间时，用最近若干条群消息构造上下文 */
  private static async buildInitialContext(
    store: relationalStore.RdbStore,
    roomId: string,
    agent: RoomAgent
  ): Promise<LlmMessage[]> {
    const history = await GroupMessageRepo.page(store, roomId, 20);
    const ctx: LlmMessage[] = [];
    if (agent.description.length > 0) {
      ctx.push({
        role: 'system',
        content: `你是群聊中的成员「${agent.name}」。${agent.description}\n请用简洁、专业的中文回答。`
      });
    }
    // P0-1：把已启用的技能指令注入群聊上下文，与单聊保持一致。
    // 本地模式才会走到这里（服务端模式走 socket），本地技能表即唯一数据源。
    const enabledSkills = await SkillRepo.enabled(store);
    if (enabledSkills.length > 0) {
      ctx.push({ role: 'system', content: composeSystemPrompt(enabledSkills) });
    }
    // 只把 user 消息与自己的历史回复带入，避免把别人的回复当成自己说的
    for (const m of history) {
      if (m.senderKind === 'human') {
        ctx.push({ role: 'user', content: m.content });
      } else if (m.agentId === agent.agentId && m.role === 'assistant') {
        ctx.push({ role: 'assistant', content: m.content });
      }
    }
    return ctx;
  }

  /**
   * 中止某房间某 agent 的当前回复，并取消该 agent 在该房间内所有排队任务。
   *
   * P1-SEQ7-④：原实现只 abort 当前正在跑的 LlmRunHandle，pump 会继续取
   * queued 任务执行 → 用户点「停止」后仍在烧 token。QueueStatus 预留了
   * 'cancelled' 状态却全项目无写入点，此处补上。
   *
   * pump 的循环每次取队首都先 takeNext 条件认领（WHERE status='queued'），
   * 这里把 queued 行置为 cancelled 后，takeNext 自然取不到，泵随即退出；
   * 不需要中断 pump 协程，也不存在竞态：takeNext 的认领 UPDATE 带
   * status='queued' 条件，与本 UPDATE 互斥，谁先执行谁是空操作。
   */
  static async abort(store: relationalStore.RdbStore, roomId: string, agentId: string): Promise<void> {
    // ⚠ 顺序不能反：必须先取消排队，再 abort 正在跑的句柄。
    //   先 abort 的话，sink 里的 abort.completed 会立刻 finalize → waiter resolve
    //   → pump 从 await done 恢复并马上 takeNext；此时 cancelQueued 还没落库，
    //   泵有机会再认领一条 queued 继续烧 token。先取消排队就堵死了这个窗口。
    await QueueRepo.cancelQueued(store, roomId, agentId);
    const key = AgentOrchestrator.contextKey(roomId, agentId);
    const handle = AgentOrchestrator.running.get(key);
    if (handle !== undefined) {
      // P2-SEQ11：句柄 abort 与 LlmEngine.abortRun 都可能命中同一个 run，
      //   两者最终都走同一个 abortFn（第二次被 finished 守卫短路），
      //   不会重复发 abort.completed、不会多弹 toast。
      handle.abort();
      return;
    }
    // P2-SEQ11：句柄还没登记（run 已发起、仍在 await LlmEngine.run 的建连/流式窗口）
    //   这时不能什么都不做 —— 用户点的「停止」会被静默丢弃，请求继续烧 token。
    //   runId 就是 queueItem 派生的 msgId，按 runId 直接中止。
    //   拿不到 runId（尚未进入 runOne）时下面 pump 的认领会被 cancelQueued 堵死，
    //   不会真跑起来，无需补偿。
    const liveRunId = AgentOrchestrator.activeRunIds.get(key);
    if (liveRunId !== undefined && liveRunId.length > 0) {
      LlmEngine.abortRun(liveRunId);
    }
  }

  /**
   * P1-SEQ7-④ 接线（ALEX 拍板方案 a）：中止整个房间。
   *
   * 群聊页「停止」按钮的唯一入口。做成房间级而不是 agent 级，是因为 UI 上
   * 用户点的是「停止这群的回复」，不是某一个 agent。逐个 agent 走 abort()：
   * 先把它所有 queued 行置 cancelled，再 abort 正在跑的句柄。泵每轮
   * takeNext 只认 status='queued'，取不到即 break 并释放 pump 锁。
   *
   * ⚠ 边界：只在**本地编排模式**有意义。服务端模式下 agent 跑在 PC 上，
   *    本地 gc_execution_queue 为空，停止需要服务端接口（当前不存在），
   *    调用方（GroupChatPage.stopAll）会明确提示用户而不是假装停掉。
   *
   * @returns 真正被 abort 掉的 run 数（running 句柄计数，供 UI 提示文案）
   */
  static async abortRoom(store: relationalStore.RdbStore, roomId: string): Promise<number> {
    const agents = await RoomAgentRepo.listByRoom(store, roomId);
    let stopped = 0;
    for (const a of agents) {
      const key = AgentOrchestrator.contextKey(roomId, a.agentId);
      // P2-SEQ11：建连窗口内句柄还没登记，但 runId 已登记；
      //   两者任一命中都算「有在跑」，计数才与实际停止数一致。
      if (AgentOrchestrator.running.has(key) || AgentOrchestrator.activeRunIds.has(key)) {
        stopped++;
      }
      await AgentOrchestrator.abort(store, roomId, a.agentId);
    }
    return stopped;
  }

  /** 清空某 agent 的对话上下文（换模型/清记忆时用） */
  static resetContext(roomId: string, agentId: string): void {
    AgentOrchestrator.contexts.delete(AgentOrchestrator.contextKey(roomId, agentId));
  }

  /**
   * 清空整个房间所有 agent 的上下文（页面退出时调用）。
   * contexts 是 static Map 只进不出：多房间×多 agent 场景内存单调增长。
   * 退出群聊页时统一清空，避免内存泄漏；下次进入会重建初始上下文。
   */
  static resetRoom(roomId: string): void {
    const prefix = `${roomId}:`;
    const keys: string[] = [];
    AgentOrchestrator.contexts.forEach((_v: LlmMessage[], k: string): void => {
      if (k.indexOf(prefix) === 0) {
        keys.push(k);
      }
    });
    for (const k of keys) {
      AgentOrchestrator.contexts.delete(k);
    }
  }
}