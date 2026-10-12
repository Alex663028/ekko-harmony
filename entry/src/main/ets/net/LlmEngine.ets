/**
 * LLM 推理引擎：替代原版 Koa 服务端 spawn CLI Agent 的那层。
 *
 * 原版：浏览器 → Socket.IO(/chat-run) → Koa → spawn claude-code/codex → 事件流
 * 鸿蒙：页面 → LlmEngine → HTTPS/SSE 直连模型 API → 归约为 RunEventLite
 *
 * 对外事件名与原版一致（run.started / message.delta / run.completed …），
 * UI 层因此不需要为两种架构写两套渲染逻辑。
 *
 * ArkTS 要点：请求/响应体一律显式 interface；JSON.parse 后必须 as 成具体类型。
 */

import http from '@ohos.net.http';
import { Provider } from '../model/Types';
import {
  emptyRunEvent, RunEventLite, UsageLite
} from '../common/Core';
import {
  parseSseChunk, isSseDone, extractDelta, extractUsage, extractSseError,
  hasUsage, arrayBufferToString
} from '../common/Core';
import {
  emptyModelList, ModelListPayload, TokenUsagePayload, emptyTokenUsage
} from '../model/Json';

/** 事件回调：与原版 run 事件同名同义 */
export type RunEventSink = (ev: RunEventLite) => void;

export interface LlmMessage {
  role: string;
  content: string;
}

export interface LlmRunRequest {
  provider: Provider;
  model: string;
  messages: LlmMessage[];
  temperature: number;
  maxTokens: number;
  reasoningEffort: string;
}

export interface LlmRunHandle {
  abort(): void;
}

/**
 * ArkTS：返回对象字面量时，编译器要求它对应一个 **class**，
 * 光有 interface 不行。所以这里用具名工厂函数返回。
 */
class NoopHandle implements LlmRunHandle {
  abort(): void {
  }
}

function newHandle(abortFn: () => void): LlmRunHandle {
  return new AbortableHandle(abortFn);
}

class AbortableHandle implements LlmRunHandle {
  private fn: () => void;

  constructor(fn: () => void) {
    this.fn = fn;
  }

  abort(): void {
    this.fn();
  }
}

export interface ProbeResult {
  ok: boolean;
  message: string;
  modelCount: number;
}

/** OpenAI 兼容请求体：无顶层 system（OpenAI 只认 messages[0] 的 system 角色） */
interface OpenAIRequestBody {
  model: string;
  messages: LlmMessage[];
  stream: boolean;
  max_tokens: number;
  temperature: number;
  reasoning_effort: string;
}

/** Anthropic 请求体：顶层 system 字段（Anthropic 协议形态） */
interface AnthropicRequestBody {
  model: string;
  messages: LlmMessage[];
  stream: boolean;
  max_tokens: number;
  system: string;
  temperature: number;
  reasoning_effort: string;
}

function newOpenAIRequestBody(model: string, messages: LlmMessage[]): OpenAIRequestBody {
  return {
    model: model,
    messages: messages,
    stream: true,
    max_tokens: 4096,
    temperature: 0,
    reasoning_effort: ''
  };
}

function newAnthropicRequestBody(model: string, messages: LlmMessage[]): AnthropicRequestBody {
  return {
    model: model,
    messages: messages,
    stream: true,
    max_tokens: 4096,
    system: '',
    temperature: 0,
    reasoning_effort: ''
  };
}

export function userMsg(content: string): LlmMessage {
  return { role: 'user', content: content };
}

export function systemMsg(content: string): LlmMessage {
  return { role: 'system', content: content };
}

export function assistantMsg(content: string): LlmMessage {
  return { role: 'assistant', content: content };
}

export class LlmEngine {
  /** 运行中请求表：runId → 请求对象，用于中止 */
  private static inflight = new Map<string, http.HttpRequest>();

  /**
   * P2-SEQ11：建连窗口中止表：runId → 收尾回调。
   *
   * 为什么需要这张表（Pi 复核发现，ALEX 定夺修）：
   *   LlmRunHandle 是 `await requestInStream(...)` **返回之后**才交给调用方的，
   *   而建连最长 connectTimeout=20s、流式期间更是直到整段流结束才 resolve。
   *   这段窗口里调用方手里没有句柄 → `running.get()` 返回 undefined →
   *   abort 被静默丢弃 → 用户点了「停止」，请求还在跑，token 继续烧。
   *
   * 修法：在**发起请求之前**就把收尾回调登记进来（与 inflight 同时点），
   *   abortRun 直接命中，走与句柄 abort **完全相同**的收尾路径
   *   （发 abort.completed → Orchestrator finalize → 队列项置 cancelled）。
   *
   * ⚠ 清理必须覆盖所有终态（正常完成 / 失败 / abort），否则 static Map 只进不出。
   *   统一走 releaseSlot，不要单独 delete inflight。
   */
  private static aborts = new Map<string, () => void>();

  /** 释放 runId 的两张表登记。所有终态都必须调用。 */
  private static releaseSlot(runId: string): void {
    LlmEngine.inflight.delete(runId);
    LlmEngine.aborts.delete(runId);
  }

  /**
   * 按 runId 中止。可在句柄返回之前调用（建连/流式窗口）。
   * 优先走 aborts 登记的收尾回调 —— 它会发 abort.completed，
   * 只 destroy 会让 catch 把它当成「连接模型服务失败」上报 run.failed。
   */
  static abortRun(runId: string): void {
    const fn = LlmEngine.aborts.get(runId);
    // 先摘登记再回调：回调里会再 releaseSlot 一次（此时已是空操作）。
    LlmEngine.releaseSlot(runId);
    if (fn !== undefined) {
      fn();
      return;
    }
    const req = LlmEngine.inflight.get(runId);
    if (req !== undefined) {
      req.destroy();
    }
  }

  static isRunning(runId: string): boolean {
    // 两张表任一命中都算在跑：inflight 已登记但 aborts 还没登记的极短窗口内，
    // 问 isRunning 应当答 true（否则 UI 会错误地以为可以再发一次）。
    return LlmEngine.inflight.has(runId) || LlmEngine.aborts.has(runId);
  }

  /**
   * 发起流式补全。runId 用于中止；sink 逐条收到原版形态的 run 事件。
   */
  static async run(req: LlmRunRequest, runId: string, sink: RunEventSink): Promise<LlmRunHandle> {
    const started = emptyRunEvent('run.started');
    started.run_id = runId;
    sink(started);

    // P1-1：明确拦截尚未实现的接口模式，给出可操作的错误提示。
    // 历史配置里可能还存有 responses / openai_responses / gemini，
    // 直接放行会拼成 /chat/completions 得到 404/400，客户无从排查。
    if (req.provider.apiMode !== 'anthropic' && req.provider.apiMode !== 'chat_completions') {
      const failed = emptyRunEvent('run.failed');
      failed.run_id = runId;
      failed.error = `接口模式 ${req.provider.apiMode} 尚未实现，请到「模型与 Agent → 供应商」改用 OpenAI 兼容或 Anthropic`;
      sink(failed);
      return LlmEngine.doneHandle();
    }

    // Scheme A 天条：undecryptable 态绝不允许进入 HTTP header。
    // 必须在入口就拦截，给出可操作的提示（区别于「未填」）。
    const keyIssue = LlmEngine.apiKeyIssue(req.provider);
    if (keyIssue.length > 0) {
      const failed = emptyRunEvent('run.failed');
      failed.run_id = runId;
      failed.error = keyIssue;
      sink(failed);
      return LlmEngine.doneHandle();
    }

    if (req.provider.apiMode === 'anthropic') {
      return LlmEngine.runAnthropic(req, runId, sink);
    }
    return LlmEngine.runOpenAI(req, runId, sink);
  }

  private static doneHandle(): LlmRunHandle {
    return new NoopHandle();
  }

  private static buildUrl(p: Provider): string {
    const base = p.baseUrl.replace(/\/+$/, '');
    if (p.apiMode === 'anthropic') {
      return base.endsWith('/v1/messages') ? base : `${base}/v1/messages`;
    }
    return base.endsWith('/chat/completions') ? base : `${base}/chat/completions`;
  }

  /**
   * Scheme A：统一 API Key 可用性检查。返回错误消息（空串 = 可用）。
   *   - 'undecryptable'：有密文但解密失败 → 提示重新填写（区别于「未填」）。
   *   - 'empty'：真未填。
   *   - 'ok' 但 trim 后为空：防御性兜底（理论上 state 与明文应一致）。
   * 天条：任何返回非空的 provider 都不允许进入 buildHeaders/authHeaders。
   */
  private static apiKeyIssue(p: Provider): string {
    if (p.apiKeyState === 'undecryptable') {
      return 'API Key 解密失败，请到「模型与 Agent → 供应商」重新填写';
    }
    if (p.apiKeyState === 'empty' || p.apiKey.trim().length === 0) {
      return 'API Key 未配置，请到「模型与 Agent → 供应商」填写';
    }
    return '';
  }

  /**
   * 构建请求头。⚠ Scheme A 天条：调用方必须在入口已经做过 apiKeyIssue 校验，
   * 确保 state !== 'undecryptable' 且 apiKey 非空。这里再做一次防御：若 state
   * 仍是 'undecryptable'（理论上不可达），抛错阻断，绝不把该态泄漏进 header。
   */
  private static buildHeaders(p: Provider): Record<string, string> {
    if (p.apiKeyState === 'undecryptable') {
      throw new Error('API Key 解密失败，禁止携带请求头发送请求');
    }
    const h: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream'
    };
    if (p.apiMode === 'anthropic') {
      h['x-api-key'] = p.apiKey;
      h['anthropic-version'] = '2023-06-01';
    } else {
      h['Authorization'] = `Bearer ${p.apiKey}`;
    }
    return h;
  }

  /**
   * P1-SEQ7-①：OpenAI 兼容接口（/chat/completions）的 system 必须作为
   * messages 的首条（{role:'system', content:sys}）。之前的实现把 system 拼成
   * 请求体顶层字段 body.system——那是 Anthropic 的请求体形态，严格实现的
   * OpenAI 兼容服务会直接忽略顶层 system → 人设/技能指令静默失效。
   *
   * 修法：不再剥离 system，而是把所有 system 消息合并成一条置于 messages 首位。
   * Anthropic 路径（buildAnthropicBody）保持顶层 system 不变，那边是正确的。
   *
   * ⚠ ArkTS 约束：不能写 untyped 对象字面量，必须先构造 LlmMessage。
   *    不能复用 joinSystem 返回的空串作为占位（空 system 首条会被某些服务
   *    当作无效输入），只在有内容时插入。
   */
  private static buildChatBody(req: LlmRunRequest, stream: boolean = true): string {
    const body = newOpenAIRequestBody(req.model, LlmEngine.withSystemFirst(req.messages));
    body.max_tokens = req.maxTokens > 0 ? req.maxTokens : 4096;
    if (req.temperature > 0) {
      body.temperature = req.temperature;
    }
    body.reasoning_effort = req.reasoningEffort;
    // P2-8：通过参数控制 stream，不再用字符串替换（脆弱实现）
    body.stream = stream;
    return JSON.stringify(body);
  }

  private static buildAnthropicBody(req: LlmRunRequest): string {
    const sys = LlmEngine.joinSystem(req.messages);
    const body = newAnthropicRequestBody(
      req.model, LlmEngine.withoutSystem(req.messages));
    body.max_tokens = req.maxTokens > 0 ? req.maxTokens : 4096;
    body.system = sys;
    return JSON.stringify(body);
  }

  private static joinSystem(messages: LlmMessage[]): string {
    let out = '';
    for (const m of messages) {
      if (m.role === 'system') {
        out += out.length > 0 ? `\n\n${m.content}` : m.content;
      }
    }
    return out;
  }

  private static withoutSystem(messages: LlmMessage[]): LlmMessage[] {
    const out: LlmMessage[] = [];
    for (const m of messages) {
      if (m.role !== 'system') {
        out.push({ role: m.role, content: m.content });
      }
    }
    return out;
  }

  /**
   * 合并所有 system 消息并置于 messages 首位，其余消息保持原序。
   *
   * OpenAI 兼容接口只认 messages[0] 的 system 角色；多条 system 不会被
   * 自动拼接，因此这里先 join 成一条。没有 system 消息时原样返回（深拷贝），
   * 不插入空内容的首条——空 system 首条会被部分服务当无效输入。
   */
  private static withSystemFirst(messages: LlmMessage[]): LlmMessage[] {
    const sys = LlmEngine.joinSystem(messages);
    const out: LlmMessage[] = [];
    if (sys.length > 0) {
      out.push({ role: 'system', content: sys });
    }
    for (const m of messages) {
      if (m.role !== 'system') {
        out.push({ role: m.role, content: m.content });
      }
    }
    return out;
  }

  /** OpenAI 兼容（覆盖国内外绝大多数服务） */
  private static async runOpenAI(
    req: LlmRunRequest, runId: string, sink: RunEventSink
  ): Promise<LlmRunHandle> {
    const client = http.createHttp();
    let buffer = '';
    let finished = false;
    const usage = LlmEngine.emptyUsage();
    // R33/D-R32-1：流内是否真的产生过正文增量。用于「响应码 2xx 但既无终止帧、
    //   也无任何内容」的收尾判定（例如代理返回非 SSE 的 200 HTML/JSON）。
    let sawContent = false;
    // R33/D-R32-1：流式收尾判定所需的两项事实，到达顺序不确定，用 settle() 合流。
    //   streamEnded —— dataEnd 事件置位（响应体收完，晚于所有 dataReceive）。
    //   responseCode —— requestInStream 的 Promise 返回值（响应码）。
    let streamEnded = false;
    let responseCode = 0;
    let settled = false;
    // 超时保护定时器 id：readTimeout 300s 与 Orchestrator 600s 兜底不对齐，
    // 若 http 层超时静默失败（sink 收不到 run.failed），队列项会卡 600s。
    // 这里主动在 300s 发 run.failed，保证队列项及时释放。
    let timeoutId: number = 0;

    const clearGuard = (): void => {
      if (timeoutId > 0) {
        clearTimeout(timeoutId);
        timeoutId = 0;
      }
    };

    const finishOk = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      clearGuard();
      LlmEngine.releaseSlot(runId);
      sink(LlmEngine.completedEvent(runId, usage));
      client.destroy();
    };

    const failWith = (msg: string): void => {
      if (finished) {
        return;
      }
      finished = true;
      clearGuard();
      LlmEngine.releaseSlot(runId);
      const e = emptyRunEvent('run.failed');
      e.run_id = runId;
      e.error = msg;
      sink(e);
      client.destroy();
    };

    // P2-SEQ11：收尾抽成具名闭包，句柄 abort 与「句柄返回前的 abort」共用同一份。
    //   否则两条路径会发不同事件（一个 abort.completed、一个被 catch 当失败），
    //   队列项可能落 failed 而不是 cancelled。
    const abortFn = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      // P1-9：abort 后必须清除 300s 超时定时器，否则定时器悬挂 300 秒，
      // 连续 abort 多次会积累多个悬挂定时器。
      clearGuard();
      LlmEngine.releaseSlot(runId);
      const e = emptyRunEvent('abort.completed');
      e.run_id = runId;
      sink(e);
      try {
        client.destroy();
      } catch (x) {
        // 已销毁则忽略
      }
    };

    // R33/D-R32-1：非 SSE 应答（4xx/5xx 的 JSON、200 的 HTML 等）不会产生任何
    //   终止帧，旧实现只能烧到 300s 守卫并把房间泵锁占满。settle() 在「响应体收完」
    //   与「拿到响应码」两件事都具备后立即判定一次，二者先后顺序无关。
    const settle = (): void => {
      if (finished || settled || !streamEnded || responseCode === 0) {
        return;
      }
      settled = true;
      if (responseCode >= 400) {
        failWith(`模型服务返回 HTTP ${responseCode}，请检查接口地址与密钥`);
        return;
      }
      if (!sawContent) {
        failWith(`模型服务无有效响应（HTTP ${responseCode}）`);
        return;
      }
      // 2xx、有内容、但没有终止帧（服务端不发 [DONE]）：按已收到内容正常收尾。
      finishOk();
    };

    client.on('dataReceive', (data: ArrayBuffer) => {
      buffer += arrayBufferToString(data);
      const parsed = parseSseChunk(buffer);
      buffer = parsed.rest;
      for (const ev of parsed.events) {
        if (isSseDone(ev)) {
          finishOk();
          return;
        }
        const errText = extractSseError(ev);
        if (errText.length > 0) {
          failWith(errText);
          return;
        }
        if (hasUsage(ev)) {
          const u = extractUsage(ev);
          usage.inputTokens = u.inputTokens;
          usage.outputTokens = u.outputTokens;
        }
        const d = extractDelta(ev);
        if (d.length > 0) {
          sawContent = true;
          const e = emptyRunEvent('message.delta');
          e.run_id = runId;
          e.delta = d;
          sink(e);
        }
      }
    });

    // 响应体收完（晚于所有 dataReceive）才允许做「无终止帧」判定。
    client.on('dataEnd', (): void => {
      streamEnded = true;
      settle();
    });

    // ⚠ 必须先注册再发起请求：连接建立期间点「中止」也能 destroy。
    //   之前 requestInStream 完成后才注册，连接超时/建连中 abort 无效。
    LlmEngine.inflight.set(runId, client);
    // P2-SEQ11：句柄还没到手时的中止入口（建连最长 20s、流式期间到流结束）。
    //   键是 runId（全局唯一），与 inflight 同点登记、同点清理。
    LlmEngine.aborts.set(runId, abortFn);
    // 300s 超时保护：readTimeout 与 Orchestrator 600s 兜底对齐，
    // 超时后主动 emit run.failed，避免队列项卡死 600s。
    timeoutId = setTimeout((): void => {
      failWith('模型请求超时（300s），已中止');
    }, 300000);
    try {
      // R33/D-R32-1：requestInStream 的 Promise 以响应码 resolve，旧代码丢弃了它，
      //   于是 4xx/5xx（正文不是 SSE）永远等不到终止帧，只能烧到 300s 守卫。
      //   这里取回响应码交给 settle()，与 dataEnd 合流后立即收尾。
      responseCode = await client.requestInStream(LlmEngine.buildUrl(req.provider), {
        method: http.RequestMethod.POST,
        header: LlmEngine.buildHeaders(req.provider),
        extraData: LlmEngine.buildChatBody(req),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 300000
      });
      settle();
    } catch (e) {
      const err = e as Error;
      failWith(`连接模型服务失败: ${err.message}`);
    }

    return newHandle(abortFn);
  }

  /** Anthropic Messages API（Claude 系） */
  private static async runAnthropic(
    req: LlmRunRequest, runId: string, sink: RunEventSink
  ): Promise<LlmRunHandle> {
    const client = http.createHttp();
    let buffer = '';
    let finished = false;
    const usage = LlmEngine.emptyUsage();
    // R33/D-R32-1：同 runOpenAI —— 记录是否收到过内容，并合流 dataEnd 与响应码。
    let sawContent = false;
    let streamEnded = false;
    let responseCode = 0;
    let settled = false;
    // 超时保护定时器 id：readTimeout 300s 与 Orchestrator 600s 兜底不对齐，
    // 若 http 层超时静默失败（sink 收不到 run.failed），队列项会卡 600s。
    // 这里主动在 300s 发 run.failed，保证队列项及时释放。
    let timeoutId: number = 0;

    const clearGuard = (): void => {
      if (timeoutId > 0) {
        clearTimeout(timeoutId);
        timeoutId = 0;
      }
    };

    const finishOk = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      clearGuard();
      LlmEngine.releaseSlot(runId);
      sink(LlmEngine.completedEvent(runId, usage));
      client.destroy();
    };

    const failWith = (msg: string): void => {
      if (finished) {
        return;
      }
      finished = true;
      clearGuard();
      LlmEngine.releaseSlot(runId);
      const e = emptyRunEvent('run.failed');
      e.run_id = runId;
      e.error = msg;
      sink(e);
      client.destroy();
    };

    // P2-SEQ11：收尾抽成具名闭包，句柄 abort 与「句柄返回前的 abort」共用同一份
    //   （理由同 runOpenAI）。
    const abortFn = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      // P1-9：abort 后必须清除 300s 超时定时器，否则定时器悬挂 300 秒，
      // 连续 abort 多次会积累多个悬挂定时器。
      clearGuard();
      LlmEngine.releaseSlot(runId);
      const e = emptyRunEvent('abort.completed');
      e.run_id = runId;
      sink(e);
      try {
        client.destroy();
      } catch (x) {
        // 已销毁则忽略
      }
    };

    // R33/D-R32-1：同 runOpenAI —— 404/500 的 Anthropic JSON 错误体不是 SSE，
    //   永不产生 message_stop 帧；合流 dataEnd + 响应码后立即收尾（否则 300s）。
    const settle = (): void => {
      if (finished || settled || !streamEnded || responseCode === 0) {
        return;
      }
      settled = true;
      if (responseCode >= 400) {
        failWith(`模型服务返回 HTTP ${responseCode}，请检查接口地址与密钥`);
        return;
      }
      if (!sawContent) {
        failWith(`模型服务无有效响应（HTTP ${responseCode}）`);
        return;
      }
      finishOk();
    };

    client.on('dataReceive', (data: ArrayBuffer) => {
      buffer += arrayBufferToString(data);
      const parsed = parseSseChunk(buffer);
      buffer = parsed.rest;
      for (const raw of parsed.events) {
        if (isSseDone(raw)) {
          finishOk();
          return;
        }
        const frame = LlmEngine.parseAnthropicFrame(raw);
        if (frame.length === 0) {
          continue;
        }
        if (frame === '|STOP|') {
          // Anthropic 的流终止信号是 event: message_stop（其 data 通常为 {}），
          // 不是 OpenAI 的 data: [DONE]。收到即收尾，否则 run.completed 永远不发，
          // Orchestrator 只能等 600s 兜底、inflight 里的 HttpRequest 也不 destroy。
          finishOk();
          return;
        }
        if (frame.indexOf('|ERR|') === 0) {
          failWith(frame.slice(5));
          return;
        }
        if (frame === '|THINK|' || frame.indexOf('|THINK|') === 0) {
          sawContent = true;
          const e = emptyRunEvent('reasoning.delta');
          e.run_id = runId;
          e.text = frame.slice(7);
          sink(e);
          continue;
        }
        if (frame.indexOf('|TEXT|') === 0) {
          sawContent = true;
          const e = emptyRunEvent('message.delta');
          e.run_id = runId;
          e.delta = frame.slice(6);
          sink(e);
          continue;
        }
        if (frame.indexOf('|IN|') === 0) {
          usage.inputTokens = Number(frame.slice(4));
          continue;
        }
        if (frame.indexOf('|OUT|') === 0) {
          usage.outputTokens = Number(frame.slice(5));
        }
      }
    });

    // 响应体收完（晚于所有 dataReceive）才允许做「无终止帧」判定。
    client.on('dataEnd', (): void => {
      streamEnded = true;
      settle();
    });

    // ⚠ 必须先注册再发起请求：连接建立期间点「中止」也能 destroy。
    //   之前 requestInStream 完成后才注册，连接超时/建连中 abort 无效。
    LlmEngine.inflight.set(runId, client);
    // P2-SEQ11：句柄还没到手时的中止入口（见 runOpenAI 同处注释）。
    LlmEngine.aborts.set(runId, abortFn);
    // 300s 超时保护：readTimeout 与 Orchestrator 600s 兜底对齐，
    // 超时后主动 emit run.failed，避免队列项卡死 600s。
    timeoutId = setTimeout((): void => {
      failWith('模型请求超时（300s），已中止');
    }, 300000);
    try {
      // R33/D-R32-1：同 runOpenAI —— 取回响应码交给 settle()。
      responseCode = await client.requestInStream(LlmEngine.buildUrl(req.provider), {
        method: http.RequestMethod.POST,
        header: LlmEngine.buildHeaders(req.provider),
        extraData: LlmEngine.buildAnthropicBody(req),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 300000
      });
      settle();
    } catch (e) {
      const err = e as Error;
      failWith(`连接模型服务失败: ${err.message}`);
    }

    return newHandle(abortFn);
  }

  /**
   * Anthropic 流事件 → 紧凑字符串。
   * 用前缀标签而不是对象，是为了让ArkTS 侧只处理 string。
   *   |TEXT|<正文> |THINK|<思考> |ERR|<错误> |IN|<n> |OUT|<n>
   */
  private static parseAnthropicFrame(raw: string): string {
    try {
      const obj = JSON.parse(raw) as AnthropicFrame;
      const type = typeof obj.type === 'string' ? obj.type : '';
      if (type === 'content_block_delta') {
        const d = obj.delta;
        if (d !== undefined && d !== null) {
          if (typeof d.thinking === 'string' && d.thinking.length > 0) {
            return `|THINK|${d.thinking}`;
          }
          if (typeof d.text === 'string' && d.text.length > 0) {
            return `|TEXT|${d.text}`;
          }
        }
        return '';
      }
      if (type === 'message_start') {
        const m = obj.message;
        if (m !== undefined && m !== null && m.usage !== undefined && m.usage !== null) {
          return `|IN|${m.usage.input_tokens}`;
        }
        return '';
      }
      if (type === 'message_delta') {
        const u = obj.usage;
        if (u !== undefined && u !== null) {
          return `|OUT|${u.output_tokens}`;
        }
        return '';
      }
      if (type === 'message_stop') {
        // Anthropic Messages API 的流终止事件。data 一般是 {}，
        // 但某些代理/网关会带 {"type":"message_stop"}，都按终止处理。
        return '|STOP|';
      }
      if (type === 'error') {
        const e = obj.error;
        if (e !== undefined && e !== null && typeof e.message === 'string') {
          return `|ERR|${e.message}`;
        }
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  private static emptyUsage(): UsageLite {
    return {
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      contextTokens: 0,
      costUsd: 0
    };
  }

  private static completedEvent(runId: string, u: UsageLite): RunEventLite {
    const e = emptyRunEvent('run.completed');
    e.run_id = runId;
    e.usage.input_tokens = u.inputTokens;
    e.usage.output_tokens = u.outputTokens;
    e.usage.total_tokens = u.inputTokens + u.outputTokens;
    e.usage.cache_read_tokens = u.cacheReadTokens;
    return e;
  }

  /** 非流式补全（群聊摘要、标题生成等短文本）。失败返回 null，调用方需处理。 */
  static async complete(req: LlmRunRequest): Promise<string | null> {
    // Scheme A：与 run() 同源校验（undecryptable / empty 均拦截）
    if (LlmEngine.apiKeyIssue(req.provider).length > 0) {
      return null;
    }
    try {
      const client = http.createHttp();
      const isAnthropic = req.provider.apiMode === 'anthropic';
      // P2-8：通过参数控制 stream，不再用字符串替换
      const body = isAnthropic
        ? LlmEngine.buildAnthropicBody(req)
        : LlmEngine.buildChatBody(req, false);
      const res = await client.request(LlmEngine.buildUrl(req.provider), {
        method: http.RequestMethod.POST,
        header: LlmEngine.buildHeaders(req.provider),
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 20000,
        readTimeout: 60000
      });
      if (res.responseCode < 200 || res.responseCode >= 300) {
        client.destroy();
        // P2-8：失败返回 null，写日志让调用方知道
        console.error(`LlmEngine.complete HTTP ${res.responseCode}`);
        return null;
      }
      const text = typeof res.result === 'string' ? res.result : '';
      client.destroy();
      return isAnthropic
        ? LlmEngine.textFromAnthropic(text)
        : LlmEngine.textFromChat(text);
    } catch (e) {
      // P2-8：失败返回 null，写日志让调用方知道
      console.error(`LlmEngine.complete failed: ${(e as Error).message}`);
      return null;
    }
  }

  private static textFromChat(json: string): string {
    try {
      const obj = JSON.parse(json) as ChatResponse;
      const choices = obj.choices;
      if (choices === undefined || choices === null || choices.length === 0) {
        return '';
      }
      const msg = choices[0].message;
      if (msg === undefined || msg === null) {
        return '';
      }
      return typeof msg.content === 'string' ? msg.content : '';
    } catch (e) {
      return '';
    }
  }

  private static textFromAnthropic(json: string): string {
    try {
      const obj = JSON.parse(json) as AnthropicResponse;
      const blocks = obj.content;
      if (blocks === undefined || blocks === null) {
        return '';
      }
      let out = '';
      for (const b of blocks) {
        if (typeof b.text === 'string') {
          out += b.text;
        }
      }
      return out;
    } catch (e) {
      return '';
    }
  }

  /** 拉取模型列表 */
  static async listModels(p: Provider): Promise<string[]> {
    const base = p.baseUrl.replace(/\/+$/, '');
    const url = base.endsWith('/models') ? base : `${base}/models`;
    try {
      const client = http.createHttp();
      const res = await client.request(url, {
        method: http.RequestMethod.GET,
        header: LlmEngine.authHeaders(p),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 20000
      });
      if (res.responseCode < 200 || res.responseCode >= 300) {
        client.destroy();
        return [];
      }
      const text = typeof res.result === 'string' ? res.result : '';
      client.destroy();
      const parsed = LlmEngine.parseModels(text);
      return parsed;
    } catch (e) {
      return [];
    }
  }

  private static authHeaders(p: Provider): Record<string, string> {
    // Scheme A 天条（纵深防御）：undecryptable 态绝不允许进入请求头。
    // listModels 的调用方（probe）已先做 apiKeyIssue 校验，这里再兜底一次。
    if (p.apiKeyState === 'undecryptable') {
      throw new Error('API Key 解密失败，禁止携带请求头发送请求');
    }
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (p.apiMode === 'anthropic') {
      h['x-api-key'] = p.apiKey;
      h['anthropic-version'] = '2023-06-01';
    } else {
      h['Authorization'] = `Bearer ${p.apiKey}`;
    }
    return h;
  }

  private static parseModels(json: string): string[] {
    const out: string[] = [];
    if (json.length === 0) {
      return out;
    }
    try {
      const obj = JSON.parse(json) as ModelListPayload;
      const data = obj.data;
      if (data === undefined || data === null) {
        return out;
      }
      for (const item of data) {
        if (typeof item.id === 'string' && item.id.length > 0) {
          out.push(item.id);
        }
      }
      out.sort();
      return out;
    } catch (e) {
      return out;
    }
  }

  /** 探测连通性与 key 有效性 */
  static async probe(p: Provider): Promise<ProbeResult> {
    // P1-1：未实现的接口模式直接给出可操作提示，不发起必然失败的请求。
    if (p.apiMode !== 'anthropic' && p.apiMode !== 'chat_completions') {
      return { ok: false, message: `接口模式 ${p.apiMode} 尚未实现，请改用 OpenAI 兼容或 Anthropic`, modelCount: 0 };
    }
    // Scheme A：与 run()/complete() 同源校验。undecryptable 给出明确提示。
    const issue = LlmEngine.apiKeyIssue(p);
    if (issue.length > 0) {
      return { ok: false, message: issue, modelCount: 0 };
    }
    const models = await LlmEngine.listModels(p);
    if (models.length > 0) {
      return {
        ok: true,
        message: `连接正常，发现 ${models.length} 个模型`,
        modelCount: models.length
      };
    }
    // /models 不可用不代表 key 无效，用一次最小补全探测
    const model = p.models.length > 0 ? p.models[0] : 'gpt-4o-mini';
    const out = await LlmEngine.complete({
      provider: p,
      model: model,
      messages: [userMsg('hi')],
      temperature: 0,
      maxTokens: 8,
      reasoningEffort: ''
    });
    if (out !== null && out.length > 0) {
      return { ok: true, message: '连接正常（该服务不提供 /models）', modelCount: 0 };
    }
    return { ok: false, message: '连接失败：请检查地址与 Key', modelCount: 0 };
  }
}

// ───────────────────────── 线上的JSON 结构 ─────────────────────────

interface AnthropicDelta {
  text: string;
  thinking: string;
}

interface AnthropicUsage {
  input_tokens: number;
  output_tokens: number;
}

interface AnthropicMessage {
  usage: AnthropicUsage;
}

interface AnthropicFrame {
  type: string;
  delta: AnthropicDelta;
  message: AnthropicMessage;
  usage: AnthropicUsage;
  error: AnthropicErrBody;
}

interface AnthropicErrBody {
  message: string;
}

interface AnthropicBlock {
  text: string;
}

interface AnthropicResponse {
  content: AnthropicBlock[];
}

interface ChatMsg {
  content: string;
  role: string;
}

interface ChatChoice {
  message: ChatMsg;
  text: string;
}

interface ChatResponse {
  choices: ChatChoice[];
  usage: TokenUsagePayload;
}