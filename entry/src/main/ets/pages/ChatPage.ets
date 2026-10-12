/**
 * 单聊页：流式对话 + 工具轨迹 + 思考区 + 中止。
 * 对应原版 hermes/ChatView.vue 及其组件树。
 *
 * ArkTS 约束（都是编译器实测报错，不是建议）：
 *  - 禁止对象字面量当类型：工具轨迹项抽成具名 interface BubbleTool。
 *  - map() 回调若返回对象字面量，必须有显式返回类型 → 全部走具名工厂函数。
 *  - 禁止对象展开 {...x}：patchLive / finishRun 改成逐字段赋值。
 *  - ForEach 回调参数必须显式标注类型，否则退化成 any。
 *  - 枚举收敛用具名函数返回联合类型，不用 X['k'] 索引断言。
 */

import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SocketClientHooks, SocketClient } from '../net/SocketClient';
import { CrEventSink, CrApprovalRequest, CrClarifyRequest } from '../net/StudioApi';
import { notifyAsk, cancelAskNotify } from '../common/Notify';
import { pasteboard } from '@kit.BasicServicesKit';
import { ChatMessage, Provider, AgentProfile, ToolTraceItem, RemoteProfile } from '../model/Types';
import { SessionRepo, MessageRepo, ProviderRepo } from '../data/Repos';
import { AttachmentRepo, ShareRepo, MemoryRepo, SkillRepo, composeSystemPrompt } from '../data/ExtendRepos';
import { Attachment, SessionShare, MemoryItem } from '../model/Extend';
import { AppStore } from '../viewmodel/AppStore';
import { blockLocalWrite } from '../viewmodel/ServerMode';
import { NetConfig } from '../net/Http';
import { ChatRunBody } from '../model/Json';
import { StudioApi } from '../net/StudioApi';
import {
  LlmEngine, LlmMessage, LlmRunHandle, LlmRunRequest,
  userMsg, systemMsg, assistantMsg
} from '../net/LlmEngine';
import {
  RunEventLite, StreamState, TraceLite, emptyStream, reduceRunEvent,
  shortId, previewOf, formatNumber, relativeTime, humanSize
} from '../common/Core';
import {
  MdText, EmptyState, StreamingDots, ToolTraceRow, SectionTitle,
  Card, PrimaryButton, GhostButton, LabeledInput
} from '../view/Common';
import { Tok } from '../view/Theme';

// ───────────────────────── 渲染模型 ─────────────────────────

/** 气泡内的一条工具轨迹（渲染态，字段全部收敛为非可选） */
interface BubbleTool {
  name: string;
  status: string;
  args: string;
  result: string;
}

/** 列表项：渲染态（把流式状态挂到消息上） */
interface Bubble {
  id: string;
  role: 'user' | 'assistant' | 'system';
  /**
   * 助手气泡上显示「这条是哪个 agent 说的」。
   * 服务端 source=coding_agent 的会话带 agent（codebuddy/claude/codex），
   * source=cli 的没有（单 Agent），此时留空不显示。
   */
  agentName: string;
  text: string;
  reasoning: string;
  tools: BubbleTool[];
  streaming: boolean;
  error: string;
  timestamp: number;
  usageText: string;
}

/** 路由参数：具名 interface，避免 obj['k'] 动态键访问 */
interface ChatRouteParams {
  sessionId: string;
  /** 从系统通知点进来时带：'approval' | 'clarify' —— 用来把面板立刻亮起来 */
  ask?: string;
}

// ─────────────────────单聊 socket 事件桥 ─────────────────────

/**
 * 把 SocketClient 的「事件名 + 参数数组」翻译成具名回调。
 *
 * 为什么要有这层：socket 事件有20+ 种（run.* / subagent.* / approval.* / clarify.* …），
 * 在页面里 switch 事件名字符串既啰嗦又容易拼错静默失效。
 * 这里集中做一次映射 + 字段兜底，页面只管拿结果。
 *
 * ⚠ payload 字段名不确定：安卓版里同一个语义出现了
 *   `requestId`（收）和 `approval_id`（发）两种写法，
 *   所以下面每个字段都按多个候选名取。
 */
class ChatRunBridge implements SocketClientHooks {
  onAny: (name: string, args: Object[]) => void = (): void => {};
  onStatus: (status: string, detail: string) => void = (): void => {};
  onRunStarted: (args: Object[]) => void = (): void => {};
  onDelta: (args: Object[]) => void = (): void => {};
  onRunDone: (ok: boolean, args: Object[]) => void = (): void => {};
  /**
   * 服务端确认中止完成。
   * ⚠ 被中止的 run 不会有 run.completed，页面要靠这个事件收尾气泡（真机 21:13 实测）。
   */
  onAbortCompleted: (args: Object[]) => void = (): void => {};
  onApproval: (req: CrApprovalRequest) => void = (): void => {};
  onApprovalResolved: (args: Object[]) => void = (): void => {};
  onClarify: (req: CrClarifyRequest) => void = (): void => {};
  onClarifyResolved: (args: Object[]) => void = (): void => {};
  onSubagent: (name: string, args: Object[]) => void = (): void => {};
  onUsage: (args: Object[]) => void = (): void => {};

  /** 取第一个参数并转成 Record，失败给空对象（ArkTS 不允许 any/unknown） */
  private payload(args: Object[]): Record<string, Object> {
    if (args.length === 0) {
      return {};
    }
    const o = args[0];
    if (o === null || o === undefined) {
      return {};
    }
    return o as Record<string, Object>;
  }

  /** 按候选名取字符串，取不到给空串 */
  private str(o: Record<string, Object>, keys: string[]): string {
    for (const k of keys) {
      const v = o[k];
      if (typeof v === 'string' && v.length > 0) {
        return v;
      }
    }
    return '';
  }

  /** 按候选名取字符串数组 */
  private strList(o: Record<string, Object>, keys: string[]): string[] {
    for (const k of keys) {
      const v = o[k];
      if (Array.isArray(v)) {
        const out: string[] = [];
        for (const it of v as Object[]) {
          if (typeof it === 'string') {
            out.push(it);
          } else {
            out.push(String(it));
          }
        }
        if (out.length > 0) {
          return out;
        }
      }
    }
    return [];
  }

  onEvent(name: string, args: Object[]): void {
    this.onAny(name, args);
    const p = this.payload(args);

    if (name === StudioApi.CR_RUN_STARTED) {
      this.onRunStarted(args);
      return;
    }
    if (name === StudioApi.CR_RUN_DELTA) {
      this.onDelta(args);
      return;
    }
    if (name === StudioApi.CR_RUN_COMPLETED) {
      this.onRunDone(true, args);
      return;
    }
    if (name === StudioApi.CR_RUN_FAILED) {
      this.onRunDone(false, args);
      return;
    }
    if (name === StudioApi.CR_APPROVAL_REQ) {
      const req: CrApprovalRequest = {
        sessionId: this.str(p, ['session_id', 'sessionId']),
        approvalId: this.str(p, ['approval_id', 'requestId', 'id']),
        title: this.str(p, ['title', 'name', 'summary']),
        detail: this.str(p, ['detail', 'description', 'reason', 'message', 'prompt']),
        choices: this.strList(p, ['choices', 'options'])
      };
      this.onApproval(req);
      return;
    }
    if (name === StudioApi.CR_APPROVAL_RESOLVED) {
      this.onApprovalResolved(args);
      return;
    }
    if (name === StudioApi.CR_ABORT_COMPLETED) {
      this.onAbortCompleted(args);
      return;
    }
    if (name === StudioApi.CR_CLARIFY_REQ) {
      const req: CrClarifyRequest = {
        sessionId: this.str(p, ['session_id', 'sessionId']),
        clarifyId: this.str(p, ['clarify_id', 'requestId', 'id']),
        question: this.str(p, ['question', 'prompt', 'message', 'text']),
        choices: this.strList(p, ['choices', 'options'])
      };
      this.onClarify(req);
      return;
    }
    if (name === StudioApi.CR_CLARIFY_RESOLVED) {
      this.onClarifyResolved(args);
      return;
    }
    if (name === StudioApi.CR_USAGE_UPDATED) {
      this.onUsage(args);
      return;
    }
    if (name === StudioApi.CR_SUBAGENT_START || name === StudioApi.CR_SUBAGENT_TEXT ||
      name === StudioApi.CR_SUBAGENT_THINKING || name === StudioApi.CR_SUBAGENT_TOOL ||
      name === StudioApi.CR_SUBAGENT_COMPLETE) {
      this.onSubagent(name, args);
      return;
    }
  }
}

// ───────────────────────── 具名工厂 / 收敛函数 ─────────────────────────

/** ArkTS：返回对象字面量必须能对应到已声明类型，用具名工厂最稳 */
function newBubbleTool(name: string, status: string, args: string, result: string): BubbleTool {
  return { name: name, status: status, args: args, result: result };
}

function toBubbleTool(t: TraceLite): BubbleTool {
  return newBubbleTool(t.name, t.status, t.args, t.result);
}

/** ToolTraceItem.status 是联合类型，收敛写具名函数（不用 X['k'] 索引断言） */
function traceStatus(s: string): 'running' | 'ok' | 'failed' {
  if (s === 'ok' || s === 'failed') {
    return s;
  }
  return 'running';
}

function toTraceItem(t: TraceLite): ToolTraceItem {
  return {
    name: t.name,
    status: traceStatus(t.status),
    args: t.args,
    result: t.result
  };
}

/** ChatMessage.role 含 'tool'，渲染时并入 assistant */
function bubbleRole(r: string): 'user' | 'assistant' | 'system' {
  if (r === 'user' || r === 'system') {
    return r;
  }
  return 'assistant';
}

function newBubble(id: string, role: 'user' | 'assistant' | 'system', text: string): Bubble {
  return {
    id: id,
    role: role,
    agentName: '',
    text: text,
    reasoning: '',
    tools: [],
    streaming: false,
    error: '',
    timestamp: Date.now(),
    usageText: ''
  };
}

function newRunRequest(
  provider: Provider,
  model: string,
  messages: LlmMessage[],
  reasoningEffort: string
): LlmRunRequest {
  return {
    provider: provider,
    model: model,
    messages: messages,
    temperature: 0,
    maxTokens: 4096,
    reasoningEffort: reasoningEffort
  };
}

/** 把异常统一转成文案，避免到处 (e as Error).message */
function errText(e: Error, fallback: string): string {
  return e.message.length > 0 ? e.message : fallback;
}

function usageLine(inputTokens: number, outputTokens: number): string {
  if (inputTokens + outputTokens <= 0) {
    return '';
  }
  return `↑${formatNumber(inputTokens, 0)} ↓${formatNumber(outputTokens, 0)}`;
}

/** 复制到系统剪贴板。本 SDK 版本是 getSystemPasteboard().setData() */
async function copyToClipboard(text: string): Promise<boolean> {
  try {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await pasteboard.getSystemPasteboard().setData(data);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 生成分享 token。
 * shortId 单次约 13 位 base36，拼三次约 40 位，足够抗暴力猜解。
 */
function makeShareToken(nowMs: number): string {
  const a = shortId(nowMs, Math.random());
  const b = shortId(nowMs + 7, Math.random());
  const c = shortId(nowMs + 13, Math.random());
  return `${a}${b}${c}`;
}

/** 分享链接：服务端地址 + /share/ + token */
function shareLinkOf(token: string): string {
  return `${NetConfig.getBaseUrl()}/share/${token}`;
}

/** 到期文案。expiresAt=0 视为永不过期 */
function shareExpiryText(expiresAt: number, now: number): string {
  if (expiresAt <= 0) {
    return '永不过期';
  }
  const days = Math.floor((expiresAt - now) / 86400000);
  if (days <= 0) {
    return '今天内过期';
  }
  return `${days} 天后过期`;
}

/** 附件一行：文件名 + 体积 + 类型 */
function attachmentLine(a: Attachment): string {
  const kind = a.kind.length > 0 ? a.kind : 'file';
  return `${a.name} · ${humanSize(a.size)} · ${kind}`;
}

/** 记忆来源标签：全局记忆对所有会话生效 */
function memoryScopeLabel(m: MemoryItem): string {
  if (m.scope === 'global') {
    return '全局';
  }
  return '本会话';
}

@Entry
@Component
struct ChatPage {
  @StorageProp('themeDark') dark: boolean = false;

  @State sessionId: string = '';
  /**
   * 草稿页：服务端模式下「＋新建对话」进来时还没有会话 id。
   * 服务端没有建会话的写端点，会话由首条消息的 chat-run顺带创建。
   */
  @State draftMode: boolean = false;
  /** 当前会话用的 agent（服务端会话对象带agent 字段），气泡上显示 */
  private sessionAgent: string = '';
  /** 会话自带的模型 / provider / profile —— 顶栏副标题要用，不能拿本地默认值糊弄 */
  private sessionModel: string = '';
  private sessionProfile: string = '';
  /** 草稿页选择器：PC 上的 profile 列表（=可选 agent） */
  @State profiles: RemoteProfile[] = [];
  @State pickedProfile: string = '';
  @State profilePanelOpen: boolean = false;

  // ── socket 流式 + 交互（服务端模式的正路）──
  /** 单聊 socket 是否已连上。连不上会**自动退回**等待式 HTTP，功能不中断 */
  @State socketLive: boolean = false;
  /** Agent 反向提问：要审批 */
  @State approvalReq: CrApprovalRequest | null = null;
  /** Agent 反向提问：要澄清（Agent 反问） */
  @State clarifyReq: CrClarifyRequest | null = null;
  @State clarifyText: string = '';
  /** 正在建立 socket 连接 */
  @State connecting: boolean = false;
  /** 是从系统通知点进来的（此时不再重复发通知，直接亮面板） */
  private fromNotify: boolean = false;
  /** StudioApi 的实例方法（要持请求状态） */
  private api: StudioApi = new StudioApi();
  @State title: string = '';
  @State bubbles: Bubble[] = [];
  @State draft: string = '';
  @State streaming: boolean = false;
  @State agent: AgentProfile | null = null;
  @State provider: Provider | null = null;
  @State reasonOpen: boolean = false;
  @State sheetOpen: boolean = false;

  // ── 附件 / 记忆注入 / 分享 ──
  @State attachments: Attachment[] = [];
  @State attachPanelOpen: boolean = false;
  @State memories: MemoryItem[] = [];
  @State memoryPanelOpen: boolean = false;
  @State shares: SessionShare[] = [];
  @State freshLink: string = '';
  @State now: number = Date.now();

  // Scroller 不是可观察对象，不能用 @State
  private scroller: Scroller = new Scroller();

  /**
   * 把消息列表滚到底部。
   *
   * ⚠ 实测踩过（2026-10-07）：新气泡是 push 到 `bubbles` 末尾的，
   *   但列表**不会自动跟随** —— 视图停在原来的滚动位置，
   *   用户看到的就是「消息发出去了却什么都没变」。
   *   ⇒ 每次气泡变化后都要显式滚一次。
   *
   * @param animate true=平滑滚动（用户主动发送时用）；
   *                false=瞬时（流式 delta 高频调用时用，避免动画堆积）
   */
  private scrollToBottom(animate: boolean = true): void {
    // 布局还没完成时滚动无效，等下一帧再滚。
    setTimeout(() => {
      try {
        if (animate) {
          this.scroller.scrollTo({ xOffset: 0, yOffset: 100000 });
        } else {
          this.scroller.scrollEdge(Edge.Bottom);
        }
      } catch (e) {
        // 列表尚未就绪时忽略；后续调用会补滚
      }
    }, 60);
  }

  private handle: LlmRunHandle | null = null;
  private live: StreamState = emptyStream();
  private liveBubbleId: string = '';
  /**
   * 当前正在进行的 socket run 的 id。
   * 用来判断迟到的 run.completed 是不是「上一轮的」——
   * 真机上两个 run 交替到达时，无条件清状态会让气泡永远转圈。
   */
  private liveRunId: string = '';
  /**
   * P1-SEQ12：本地模式下正在跑的 runId（等于 liveBubbleId）。
   *
   * ⚠ 必须在 `await LlmEngine.run(...)` **之前**登记：LlmRunHandle 要等整段流
   *   结束才返回（建连最长 20s、流式最长 300s），窗口内 this.handle 恒为 null。
   *   没有这个登记位，单聊点「停止」会被静默丢弃 —— UI 假装已停止、请求继续
   *   烧 token，退出页面（aboutToDisappear）也拦不住。与群聊 Orchestrator 的
   *   activeRunIds 同源同构。
   */
  private liveLocalRunId: string = '';

  aboutToAppear() {
    // router.getParams() 的声明返回 Object，可能整个是 undefined
    // （进程被回收后从恢复栈重建页面时 params 会丢）。
    // as只骗过编译期，不会插入判空 —— 必须自己兜。
    const p = router.getParams() as ChatRouteParams | undefined;
    this.sessionId = p?.sessionId ?? '';
    // 从系统通知点进来：标记一下，等socket 收到 approval.requested
    // 时**不用再发通知**（用户已经在这个页面了，直接亮面板即可）
    this.fromNotify = (p?.ask ?? '').length > 0;

    if (this.sessionId.length === 0) {
      // 空 id有两种来路，必须分开处理：
      //   1. 服务端模式 + 点「＋新建对话」→ **草稿页**，正常往下走。
      //      服务端没有建会话的端点，会话是首条消息发出时才创建的
      //      （chat-run 的 session_id 可省略 → 自动新建）。
      //   2. 其余情况（恢复栈丢参数等）→ 无从加载，退回列表页。
      if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
        this.title = '新对话';
        this.draftMode = true;
        this.reloadAgent();
        // 草稿页要能选 agent（切PC 的 active profile）
        this.loadProfiles();
        return;
      }
      promptAction.showToast({ message: '会话不存在' });
      const opts: router.RouterOptions = { url: 'pages/SessionListPage' };
      router.replaceUrl(opts);
      return;
    }
    this.loadSession();
    this.loadSideData();
    // 服务端模式提前把单聊 socket 建起来 —— 建连要等 auth ack（最多 8 秒），
    // 放在 onAppear 里后台做，等用户输完字就能直接走流式。
    if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
      this.startChatSocket();
    }
  }

  onPageHide() {
    this.stopIfRunning();
    // ⚠ 这里**故意不断socket**。
    // 页面切到后台时 Agent 可能正好要审批/澄清 ——
    // 断了就收不到 approval.requested 事件，系统通知永远发不出来，
    // 用户只看到「Agent 一直转、5 分钟后超时」。
    //所以连接跟着 Ability 生命周期走，由 onForeground 负责重连。
  }

  onPageShow() {
    // 回到前台先探一下连接；断了自己重连
    if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server' &&
      !this.api.isChatRunConnected()) {
      this.startChatSocket();
    }
  }

  aboutToDisappear() {
    // 页面真正销毁（关掉/返回列表）才断。
    // ⚠ 必须中止正在跑的 LlmEngine handle：onPageHide 只覆盖「切后台」，
    //   系统直接销毁页面（内存回收/关页）不会走 onPageHide，
    //   若这里不 abort，run 的 sink 会继续回调已销毁页面的 @State，
    //   且 LlmEngine.inflight 里的 runId 会残留。
    this.stopIfRunning();
    if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
      this.api.disconnectChatRun();
      this.socketLive = false;
    }
  }

  /**
   * 附件与记忆是辅助信息，读取失败不该拦住对话主流程，
   * 所以单独一个方法、单独 try/catch。
   */
  private async loadSideData(): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    try {
      this.attachments = await AttachmentRepo.bySession(AppStore.db(), this.sessionId);
    } catch (e) {
      this.attachments = [];
    }
    try {
      this.memories = await MemoryRepo.effective(AppStore.db(), 'session', this.sessionId);
    } catch (e) {
      this.memories = [];
    }
  }

  private async loadShares(): Promise<void> {
    try {
      this.shares = await ShareRepo.bySession(AppStore.db(), this.sessionId);
    } catch (e) {
      this.shares = [];
    }
  }

  /** 生成分享链接，默认 7 天有效 */
  private async createShare(): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「链接已生成并复制」假成功 toast
    if (blockLocalWrite('分享')) {
      return;
    }
    const nowTs = Date.now();
    const token = makeShareToken(nowTs);
    const expiresAt = nowTs + 7 * 86400000;
    try {
      await ShareRepo.create(AppStore.db(), this.sessionId,
        this.title.length > 0 ? this.title : '对话', 'session', token, expiresAt, nowTs);
      this.freshLink = shareLinkOf(token);
      await this.loadShares();
      const ok = await copyToClipboard(this.freshLink);
      promptAction.showToast({ message: ok ? '链接已生成并复制' : '链接已生成' });
    } catch (e) {
      promptAction.showToast({ message: `生成分享链接失败: ${errText(e as Error, '未知错误')}` });
    }
  }

  private async copyFreshLink(): Promise<void> {
    if (this.freshLink.length === 0) {
      return;
    }
    const ok = await copyToClipboard(this.freshLink);
    promptAction.showToast({ message: ok ? '已复制' : '复制失败' });
  }

  private async revokeShare(token: string): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已撤销」假成功 toast
    if (blockLocalWrite('分享')) {
      return;
    }
    await ShareRepo.revoke(AppStore.db(), token);
    if (this.freshLink.endsWith(token)) {
      this.freshLink = '';
    }
    await this.loadShares();
    promptAction.showToast({ message: '已撤销' });
  }

  private async loadSession(): Promise<void> {
    if (this.sessionId.length === 0) {
      return;
    }
    try {
      const s = await SessionRepo.get(AppStore.db(), this.sessionId);
      if (s !== null) {
        this.title = s.title;
        this.sessionAgent = s.agent ?? '';
        this.sessionModel = s.model ?? '';
        this.sessionProfile = s.profile ?? '';
        AppStore.setActiveSession(s.id);
      }
      await this.reloadAgent();
      const rows = await MessageRepo.page(AppStore.db(), this.sessionId, 60);
      const list: Bubble[] = [];
      for (const m of rows) {
        list.push(this.toBubble(m));
      }

      if (list.length === 0 && this.agent !== null) {
        // 首屏给一句引导，避免空白页让人以为坏了
        list.push(newBubble('welcome', 'assistant', `我是「${this.agent.name}」。有什么可以帮你的？`));
      }
      // ArkUI 只在整体重新赋值时刷新数组
      this.bubbles = list;
      // 打开会话直接停在最新消息（长会话开头是旧消息，看不到刚发的）
      this.scrollToBottom(false);
    } catch (e) {
      promptAction.showToast({ message: `加载失败: ${errText(e as Error, '未知错误')}` });
    }
  }

  /**
   * 顶栏副标题：**这个会话**的 agent + 模型。
   *
   * ⚠ 之前用的是 `${this.agent.name} · ${this.agent.model}`，
   *   而 this.agent 是本地默认 agent（AgentRepo 第一项），
   *   所以打开任何会话顶部都一样 —— 老板报的「旧会话顶部还是显示 Hermes·模型」。
   *
   * 优先级：会话的 coding agent（codebuddy/claude/codex）
   *        → 会话的 profile 名 → 会话的模型 → 空。
   * 服务端实测：source=global_agent 的会话 agent 字段是空串，
   * 这时 profile 名才是有信息量的那个。
   */
private subtitle(): string {
    const agent = this.sessionAgent.length > 0 ? this.sessionAgent : '';
    const model = this.sessionModel.length > 0 ? this.sessionModel : '';
    if (agent.length > 0 && model.length > 0) {
      return `${agent} · ${model}`;
    }
    if (agent.length > 0) {
      return agent;
    }
    // 没coding agent 就用 profile 名（PC 上 profile 就是用户认知的 agent）
    const prof = this.pickedProfile.length > 0 ? this.pickedProfile : this.sessionProfile;
    if (prof.length > 0 && model.length > 0) {
      return `${prof} · ${model}`;
    }
    if (model.length > 0) {
      return model;
    }
    if (prof.length > 0) {
      return prof;
    }
    return '';
  }

  /**
   * 拉 PC 上的 profile 列表（草稿页选择器用）。
   * 失败不阻塞 —— 选择器拿不到数据时降级成「只有当前 profile」。
   */
  private async loadProfiles(): Promise<void> {
    if ((AppStorage.get<string>('dataSource') ?? 'local') !== 'server') {
      return;
    }
    try {
      const list = await StudioApi.listProfiles(NetConfig.getToken());
      this.profiles = list;
      if (this.pickedProfile.length === 0 && list.length > 0) {
        this.pickedProfile = list[0].name;
      }
    } catch (e) {
      this.profiles = [];
    }
  }

  /** 草稿页换agent：先切服务端 active profile，再记到本地 state */
  private async pickProfile(name: string): Promise<void> {
    this.pickedProfile = name;
    this.profilePanelOpen = false;
    try {
      await StudioApi.switchProfile(NetConfig.getToken(), name);
    } catch (e) {
      promptAction.showToast({ message: `切换失败: ${errText(e as Error, '未知错误')}` });
    }
  }

  private async reloadAgent(): Promise<void> {
    const agents = AppStore.agents();
    this.agent = agents.length > 0 ? agents[0] : null;
    if (this.agent !== null) {
      this.provider = await ProviderRepo.get(AppStore.db(), this.agent.provider);
    }
  }

  private toBubble(m: ChatMessage): Bubble {
    const u = m.usage;
    const tools: BubbleTool[] = [];
    const trace = m.toolTrace ?? [];
    for (const t of trace) {
      tools.push(newBubbleTool(t.name, t.status, t.args ?? '', t.result ?? ''));
    }
    const b: Bubble = {
      id: m.id,
      role: bubbleRole(m.role),
      agentName: m.agentName ?? this.sessionAgent,
      text: m.content,
      reasoning: m.reasoning ?? '',
      tools: tools,
      streaming: false,
      error: m.error ?? '',
      timestamp: m.timestamp,
      usageText: u !== undefined ? usageLine(u.inputTokens, u.outputTokens) : ''
    };
    return b;
  }

  /** 构造发给模型的消息列表：保留最后 N 轮，控制上下文长度 */
  private async buildContext(): Promise<LlmMessage[]> {
    const ctx: LlmMessage[] = [];
    const sysPrompt = this.agent !== null ? this.agent.systemPrompt : '';
    if (sysPrompt.length > 0) {
      ctx.push(systemMsg(sysPrompt));
    }
    // P0-1：注入已启用的技能指令，兑现 SkillsPage「启用后立刻在对话中生效」的承诺。
    // 本地模式才会走到这里（服务端模式走 sendViaServer），本地技能表即唯一数据源。
    const enabledSkills = await SkillRepo.enabled(AppStore.db());
    if (enabledSkills.length > 0) {
      ctx.push(systemMsg(composeSystemPrompt(enabledSkills)));
    }
    // 只取真实的用户/助手消息（过滤 welcome 引导语）
    const real = this.bubbles.filter((b: Bubble) => b.id !== 'welcome' && b.text.length > 0);
    const tail = real.slice(-20);
    for (const b of tail) {
      ctx.push(b.role === 'user' ? userMsg(b.text) : assistantMsg(b.text));
    }
    return ctx;
  }

  /**
   * 服务端模式发消息。
   *
   * 走 `POST /api/studio/chat-run/runs`（**等待式**，实测 2026-06）：
   *   body: {input, session_id, source, mode, provider, model, workspace}
   *   resp: {ok, status, event, session_id, run_id, output}
   *
   * ⚠ 服务端这个端点是「跑完才返回」，响应里的 `events` 实测**恒为空数组**，
   *   拿不到增量 —— 所以单聊**做不了打字机**，只能先转圈再一次性出结果。
   *   （群聊才有真流式，因为它走 socket 的 /group-chat 命名空间）
   *
   * 交互上用「转圈气泡」占位，尽量降低等待的突兀感。
   */
  /**
   * 服务端模式发消息 —— **走 socket 的正路**。
   *
   * 为什么优先 socket（实测 2026-10-06，从安卓版 AppSingleChatView.vue 反编译确认）：
   *   `/chat-run` 命名空间是**真流式 + 可交互**的：
   *     · run.delta逐字推 → 有打字机
   *     · approval.requested / clarify.requested → Agent 反向提问，用户能答
   * 等待式 HTTP（chat-run）这两样都没有，且跑长任务必然 Operation timeout。
   *
   * ⚠ socket 连不上时**静默退回** HTTP —— 局域网不稳定、token 过期都可能挂，
   *   但功能不能因此彻底不可用（只是没打字机）。
   */
  private async sendViaServer(text: string): Promise<void> {
    if (await this.sendViaSocket(text)) {
      return;
    }
    await this.sendViaHttp(text);
  }

  /**
   * 尝试走 socket。返回 false 表示走不了，调用方该退回 HTTP。
   *
   *⚠ **先判断能不能走，再画气泡** —— 顺序反了会出现重复气泡：
   *   这里画完返回 false，HTTP 路径又画一遍，用户看到两条一样的消息。
   */
  private async sendViaSocket(text: string): Promise<boolean> {
    // socket 没连上 → 直接退回（连的动作异步做，本次先用 HTTP）
    if (!this.api.isChatRunConnected() && !this.startChatSocket()) {
      return false;
    }
    // 草稿页还没有 sessionId —— socket 路径需要先有会话，
    // 所以首条消息仍走 HTTP（服务端懒创建），拿到 id 后后续走 socket。
    if (this.sessionId.length === 0) {
      return false;
    }
    const prof: string = this.pickedProfile.length > 0 ? this.pickedProfile : this.sessionProfile;

    // ⚠⚠ 顺序不能反：**先建占位气泡，再 emit**（2026-10-07 真机实测发现）
    //
    // 原来先 emitChatRun 再设 liveBubbleId。而 socket 的 emit 是异步的 ——
    // 如果上一轮 run 还没结束，它的 run.completed 会在本轮设 liveBubbleId
    // 之后到达，把 liveBubbleId 清成 ''。
    // 于是本轮的 message.delta 找不到占位气泡（onSocketDelta 直接 return），
    // 症状就是「消息发出去、Agent 也在跑，但气泡一直转圈不显示回复」。
    //
    // 真实报文（真机日志）：
    //   sendViaSocket liveId=muy39ck41gue6   ← 设了
    //   ← 42/chat-run,["run.completed",...]   ← 上一轮的完成帧
    //   ← 42/chat-run,["message.delta",...]  ← 本轮的增量，此时 liveId 已被清空
    this.draft = '';
    this.streaming = true;
    this.liveBubbleId = shortId(Date.now(), Math.random());
    SocketClient.log(`[chat] sendViaSocket liveId=${this.liveBubbleId}`);

    const userBubble: Bubble = newBubble(shortId(Date.now(), Math.random()), 'user', text);
    const liveBubble: Bubble = newBubble(this.liveBubbleId, 'assistant', '');
    liveBubble.agentName = this.sessionAgent;
    liveBubble.streaming = true;
    const next: Bubble[] = this.bubbles.slice();
    next.push(userBubble);
    next.push(liveBubble);
    this.bubbles = next;

    if (!this.api.emitChatRun(this.sessionId, prof, text)) {
      // 声称连着但发不出去 → 收摊（占位气泡标错误）
      this.socketLive = false;
      const failed: Bubble[] = this.bubbles.slice();
      for (let i = 0; i < failed.length; i++) {
        if (failed[i].id === this.liveBubbleId) {
          failed[i] = {
            id: failed[i].id, role: failed[i].role, agentName: failed[i].agentName,
            text: '', reasoning: '', tools: failed[i].tools, streaming: false,
            error: '发送失败，请检查与电脑的连接',
            timestamp: failed[i].timestamp, usageText: ''
          };
          break;
        }
      }
      this.bubbles = failed;
      this.streaming = false;
      this.liveBubbleId = '';
      return false;
    }
    this.scrollToBottom(true);

    this.title = this.title === '新对话' || this.title.length === 0
      ? previewOf(text, 18) : this.title;
    return true;
  }

  /**
   * 收到审批/澄清时发系统通知。
   *
   * 前台时页面内遮罩已经能看到，但**锁屏 / 切到别的 App 时只有通知管用** ——
   * 而这恰恰是最常见的状态（Agent 跑几分钟，人不可能一直盯着）。
   */
  private pushAskNotify(sessionId: string, title: string, detail: string,
    isClarify: boolean): void {
    // 已经是从通知点进来的 → 用户就在这个页面，不用再弹系统通知
    if (this.fromNotify) {
      return;
    }
    notifyAsk(title, detail, { id: sessionId, page: 'pages/ChatPage' }, isClarify);
  }

  /**
   * 发起建连（异步）。返回 false 表示「本次不能走 socket」。
   *
   * 为什么不在这里等连接完成：connectChatRun 内部要等 auth ack（最多 8 秒），
   * await 它会让用户点发送后界面卡住 8 秒。所以：
   *   第一次发送 → 走 HTTP（顺带把草稿会话建出来）
   *   连接在后台建立 → 之后的发送就走 socket（有打字机了）
   */
  private startChatSocket(): boolean {
    if (this.connecting) {
      return false;
    }
    const bridge: ChatRunBridge = new ChatRunBridge();
    bridge.onStatus = (status: string): void => {
      this.socketLive = status === 'connected';
      if (status !== 'connected') {
        this.connecting = false;
      }
    };
    bridge.onRunStarted = (args: Object[]): void => {
      this.streaming = true;
      // 记下 run_id，用于识别迟到的 run.completed（见 onSocketDone）
      const rp: Record<string, Object> = args.length > 0 ? args[0] as Record<string, Object> : {};
      this.liveRunId = ChatPage.pickStr(rp, ['run_id', 'runId']);
      SocketClient.log(`[chat] run.started id=${this.liveRunId.slice(0,8)}`);
    };
    bridge.onDelta = (args: Object[]): void => {
      this.onSocketDelta(args);
    };
    bridge.onRunDone = (ok: boolean, args: Object[]): void => {
      this.onSocketDone(ok, args);
    };
    bridge.onAbortCompleted = (args: Object[]): void => {
      this.onAbortCompleted(args);
    };
    bridge.onApproval = (req: CrApprovalRequest): void => {
 this.approvalReq = req;
 // 页面不在前台时，遮罩面板用户看不见 → 必须发系统通知（老板 2026-10-06 要求）
 this.pushAskNotify(req.sessionId, req.title, req.detail, false);
 };
    bridge.onApprovalResolved = (): void => {
      this.approvalReq = null;
      cancelAskNotify();
      // 与澄清同理：遮罩关掉了，气泡也得收尾（见 onClarifyResolved 注释）
      this.finishStreamingBubble('（已处理）');
    };
    bridge.onClarify = (req: CrClarifyRequest): void => {
      this.clarifyReq = req;
      this.clarifyText = '';
      this.pushAskNotify(req.sessionId, 'Agent 有个问题', req.question, true);
    };
    bridge.onClarifyResolved = (): void => {
      this.clarifyReq = null;
      this.clarifyText = '';
      cancelAskNotify();
      // ⚠ 遮罩关掉了，但「正在处理」的气泡还在转 —— 真机实测（21:07）。
      //   服务端在等用户回答时不会推 run.completed，
      //   所以得由遮罩关闭这一侧把气泡收尾。
      this.finishStreamingBubble('（已处理）');
    };
    bridge.onSubagent = (name: string, args: Object[]): void => {
      this.onSocketSubagent(name, args);
    };
    bridge.onUsage = (): void => {
    // 用量在 done 时统一写，这里不单独渲染
    };
    bridge.onAny = (name: string, args: Object[]): void => {
      ChatPage.sockLog(`ev ${name}`);
    };

    this.connecting = true;
    this.api.connectChatRun(NetConfig.getBaseUrl(), NetConfig.getToken(), bridge)
      .then((ok: boolean) => {
        this.connecting = false;
        this.socketLive = ok;
      })
      .catch(() => {
        this.connecting = false;
        this.socketLive = false;
      });
    return false; // 本次不等它
  }

  /** socket 推来的文本增量 */
  private onSocketDelta(args: Object[]): void {
    if (args.length === 0) {
      return;
    }
    const p = args[0] as Record<string, Object>;
    const delta: string = ChatPage.pickStr(p, ['delta', 'text', 'content', 'chunk']);
    if (delta.length === 0) {
      return;
    }
    const idx: number = this.bubbles.findIndex((b: Bubble) => b.id === this.liveBubbleId);
    if (idx < 0) {
      // ⚠ 没有占位气泡。可能是：上一轮 run.completed 把 liveBubbleId 清了，
      //   而本轮的增量随后才到（实测真机踩过，症状是「一直转圈不显示」）。
      //   静默丢弃等于把回复整段吞掉 —— 宁可**补建一条气泡**，
      //   宁可多一条，也不要什么都不显示。
      SocketClient.log(`[chat] delta 无占位气泡，补建 liveId=${this.liveBubbleId} delta="${delta}"`);
      const fresh: Bubble = newBubble(
        this.liveBubbleId.length > 0 ? this.liveBubbleId : shortId(Date.now(), Math.random()),
        'assistant', delta
      );
      fresh.agentName = this.sessionAgent;
      fresh.streaming = true;
      this.liveBubbleId = fresh.id;
      this.bubbles = this.bubbles.concat([fresh]);
      this.scrollToBottom(false);
      return;
    }
    const arr: Bubble[] = this.bubbles.slice();
    const b: Bubble = arr[idx];
    const merged: Bubble = {
      id: b.id,
      role: b.role,
      agentName: b.agentName,
      text: b.text + delta,
      reasoning: b.reasoning,
      tools: b.tools,
      streaming: true,
      error: b.error,
      timestamp: b.timestamp,
      usageText: b.usageText
    };
    arr[idx] = merged;
    this.bubbles = arr;
    this.scrollToBottom(false);
  }

  /** socket 的 run 结束 */
  private onSocketDone(ok: boolean, args: Object[]): void {
    const p: Record<string, Object> = args.length > 0 ? args[0] as Record<string, Object> : {};
    const doneRunId: string = ChatPage.pickStr(p, ['run_id', 'runId']);

    // ⚠⚠ 必须按 run_id 判断这个 completed 是不是「当前 run」的（2026-10-07 真机实测）
    //
    // 原来是无条件清streaming / liveBubbleId。问题场景：
    //   用户在上一轮还没渲染完时又发了一条 → 两个 run 交替到达
    //   → 迟到的旧 run.completed 把当前 run 的状态清了
    //   → 气泡永远停在「正在处理」，而发送按钮已经恢复（状态不同步）
    //
    // 现在：只有 doneRunId 与当前记录的 liveRunId 一致（或拿不到 id）才收尾。
    if (this.liveRunId.length > 0 && doneRunId.length > 0 && doneRunId !== this.liveRunId) {
      SocketClient.log(`[chat] run.completed 过期 run=${doneRunId.slice(0,8)} 当前=${this.liveRunId.slice(0,8)} 忽略`);
      return;
    }

    this.streaming = false;
    this.liveRunId = '';
    // ⚠ 别在这里清 liveBubbleId —— 下面的收尾要靠它定位气泡。
    //   提前清掉会让 finishStreamingBubble 退化成「按 streaming 标记找」，
    //   页面上有多个在转的气泡时就会收错（真机 21:37 idx=576 但 liveId=空）。
    //   finishStreamingBubble 内部会在改完数组后自己清。
    // ⚠ 定位要按 liveBubbleId（delta 写进的就是它），否则页面上有多个
    //   在转的气泡时会拿错那条，导致「delta 进了A 气泡、收尾收了 B 气泡」。
    let idx: number = -1;
    if (this.liveBubbleId.length > 0) {
      for (let i = 0; i < this.bubbles.length; i++) {
        if (this.bubbles[i].id === this.liveBubbleId) {
          idx = i;
          break;
        }
      }
    }
    if (idx < 0) {
      idx = this.bubbles.findIndex((b: Bubble) => b.streaming);
    }
    if (idx < 0) {
      this.liveBubbleId = '';
      return;
    }
    const arr: Bubble[] = this.bubbles.slice();
    const b: Bubble = arr[idx];

    if (!ok) {
      //失败：把服务端给的原因写进气泡
      let msg: string = ChatPage.pickStr(p, ['error', 'message', 'reason']);
      if (msg.length === 0) {
        // ⚠ run.failed 的原因**不在顶层**，在 result 里（真机 21:27 抓包）：
        //   { run_id, output:"", result:{ final_response:"Stopped waiting for
        //     another Hermes process on this session. Your message was not processed…" } }
        //   之前这里取不到就 return，导致气泡永远停在「正在处理」——
        //   而 `this.streaming` 已经在前面被清成false，界面看起来「不忙了却在转」。
        const r: Record<string, Object> | undefined = p['result'] as Record<string, Object> | undefined;
        if (r !== undefined && r !== null) {
          msg = ChatPage.pickStr(r, ['final_response', 'error', 'message', 'reason']);
        }
      }
      if (msg.length === 0) {
        msg = '（运行失败）';
      }
      // 统一收尾：finishStreamingBubble 保证 @State 数组整体重建 → 界面一定刷新
      this.finishStreamingBubble('', msg);
      return;
    }

    // 成功：delta 可能丢过几帧（重连/后台被杀），用 complete 的权威结果兜底
    // ⚠ 实测 payload（_test/probe_events.js 抓包）：
    //   { run_id, message_id, output, result: { final_response, last_reasoning, messages[] } }
    //   output 已经是完整文本，result.final_response 是同一份。
    let finalText: string = ChatPage.pickStr(p, ['output', 'text', 'content']);
    if (finalText.length === 0) {
      const r = p['result'] as Record<string, Object> | undefined;
      if (r !== undefined && r !== null) {
        finalText = ChatPage.pickStr(r, ['final_response', 'output', 'text']);
      }
    }
    // 已有增量且长度不短于最终结果 → 说明 delta 完整，别覆盖
    if (finalText.length > 0 && b.text.length < finalText.length) {
      // 先把 finalText 写进正在转的气泡，再统一收尾
      // ⚠ 必须整体重建 @State 数组，否则界面不刷新（真机 21:24 踩过）
      this.bubbles = this.replaceAt(idx, finalText);
      this.finishStreamingBubble('');
      return;
    }

    // 只收尾（文本已由 delta 拼全）
    if (b.streaming) {
      this.finishStreamingBubble('');
    }
  }

  /** 子 Agent 事件：拼成一条「委派」说明 */
  private onSocketSubagent(name: string, args: Object[]): void {
    if (name !== StudioApi.CR_SUBAGENT_START || args.length === 0) {
      return;
    }
    const p = args[0] as Record<string, Object>;
    const who: string = ChatPage.pickStr(p, ['name', 'agent', 'profile', 'label']);
    if (who.length === 0) {
      return;
    }
    // 挂到当前气泡的 tools 里，不单独占一条消息（避免刷屏）
    const idx = this.bubbles.findIndex((b: Bubble) => b.id === this.liveBubbleId);
    if (idx < 0) {
      return;
    }
    const arr: Bubble[] = this.bubbles.slice();
    const b: Bubble = arr[idx];
    const tool: BubbleTool = newBubbleTool(who, 'running', '子 Agent', '');
    const tools: BubbleTool[] = b.tools.slice();
    tools.push(tool);
    arr[idx] = {
      id: b.id,
      role: b.role,
      agentName: b.agentName,
      text: b.text,
      reasoning: b.reasoning,
      tools: tools,
      streaming: b.streaming,
      error: b.error,
      timestamp: b.timestamp,
      usageText: b.usageText
    };
    this.bubbles = arr;
    this.scrollToBottom(false);
  }

  /** 从Record 里按候选名取字符串（ChatPage 静态工具） */
  private static pickStr(o: Record<string, Object>, keys: string[]): string {
    for (const k of keys) {
      const v = o[k];
      if (typeof v === 'string' && v.length > 0) {
        return v;
      }
    }
    return '';
  }

  private static sockLog(msg: string): void {
    // 走 NetTrace 同 tag，hdc 一次就能抓到全部链路日志
    try {
      hilog.info(0xD00, 'NetTrace', '%{public}s', `[chat] ${msg}`);
    } catch (e) {
    }
  }

  /** 回审批 */
  private respondApproval(choice: string): void {
    const req = this.approvalReq;
    if (req === null) {
      return;
    }
    const ok: boolean = this.api.emitApprovalRespond(req.sessionId, req.approvalId, choice);
    if (ok) {
      this.approvalReq = null;
      cancelAskNotify();
    } else {
      promptAction.showToast({ message: '发送失败，请检查连接' });
    }
  }

  /** 回澄清 */
  private respondClarify(): void {
    const req = this.clarifyReq;
    if (req === null) {
      return;
    }
    const answer: string = this.clarifyText.trim();
    if (answer.length === 0) {
      promptAction.showToast({ message: '请输入回答' });
      return;
    }
    const ok: boolean = this.api.emitClarifyRespond(req.sessionId, req.clarifyId, answer);
    if (ok) {
      this.clarifyReq = null;
      this.clarifyText = '';
      cancelAskNotify();
    } else {
      promptAction.showToast({ message: '发送失败，请检查连接' });
    }
  }

  /** 发送失败时的降级路径（等待式 HTTP） */
  private async sendViaHttp(text: string): Promise<void> {
    this.draft = '';
    this.streaming = true;
    this.liveBubbleId = shortId(Date.now(), Math.random());

    // 先画用户气泡 + 空的助手气泡（转圈态）
    const userBubble: Bubble = newBubble(shortId(Date.now(), Math.random()), 'user', text);
    const liveBubble: Bubble = newBubble(this.liveBubbleId, 'assistant', '');
    liveBubble.streaming = true;
    const withUser: Bubble[] = this.bubbles.concat([userBubble, liveBubble]);
    this.bubbles = withUser;
    this.scrollToBottom(true);

    // 草稿页（首条消息）**不带 session_id**，服务端会新建会话并回传新 id。
    // ArkTS 不允许对象字面量条件省略字段，所以分两个分支各写一份。
    //
    // ⚠ 服务端模式下**不传 model / provider / instructions**：
    //   这三个是手机本地 Agent 的配置（本地模式才用），
    //   传给服务端只会覆盖掉 profile 自带的模型设置。
    const isNew: boolean = this.sessionId.length === 0;
    const server: boolean = (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
    const prof: string = this.pickedProfile.length > 0 ? this.pickedProfile : this.sessionProfile;
    const base: ChatRunBody = {
      input: text,
      source: 'global_agent',
      mode: 'scoped',
      provider: server ? '' : (this.provider === null ? '' : this.provider.id),
      model: server ? '' : (this.agent === null ? '' : this.agent.model),
      instructions: server ? '' : (this.agent === null ? '' : this.agent.systemPrompt),
      workspace: '',
      reasoning_effort: ''
    };
    if (isNew) {
      // 草稿：session_id 整个键都不出现；选了 agent 就带 profile
      if (prof.length > 0) {
        const withProf: ChatRunBody = {
          input: base.input,
          source: base.source,
          mode: base.mode,
          provider: base.provider,
          model: base.model,
          instructions: base.instructions,
          workspace: base.workspace,
          reasoning_effort: base.reasoning_effort,
          profile: prof
        };
        await this.runServerBody(withProf, text);
      } else {
        await this.runServerBody(base, text);
      }
    } else {
      const withId: ChatRunBody = {
        input: base.input,
        session_id: this.sessionId,
        source: base.source,
        mode: base.mode,
        provider: base.provider,
        model: base.model,
        instructions: base.instructions,
        workspace: base.workspace,
        reasoning_effort: base.reasoning_effort
      };
      if (prof.length > 0) {
        withId.profile = prof;
      }
      await this.runServerBody(withId, text);
    }
  }

  /** chat-run 请求 + 气泡回填。新建成功后把服务端回的 session_id 绑到本页。 */
  private async runServerBody(body: ChatRunBody, firstText: string): Promise<void> {
    try {
      const res = await StudioApi.chatRun(NetConfig.getToken(), body);

      // 服务端新建了会话 → 回填 id，本页从草稿页变成正常会话页
      if (this.sessionId.length === 0 && res.session_id.length > 0) {
        this.sessionId = res.session_id;
        this.draftMode = false;
        AppStore.setActiveSession(res.session_id);
        // 标题取首条消息前18 字（服务端可能已自己命名，这里只用于顶部显示）
        if (this.title === '新对话' || this.title.length === 0) {
          this.title = previewOf(firstText, 18);
        }
        // 会话已经有 profile 了 → 顶栏副标题立刻正确，不用等重新加载
        if (body.profile !== undefined && body.profile.length > 0) {
          this.sessionProfile = body.profile;
          this.sessionModel = '';
          this.sessionAgent = '';
        }
      }

      // 写入回复正文（找不到气泡就补一条，避免用户气泡和回复错位）
      let found = false;
      const next: Bubble[] = this.bubbles.slice();
      for (let i = 0; i < next.length; i++) {
        if (next[i].id === this.liveBubbleId) {
          next[i] = {
            id: next[i].id, role: next[i].role, agentName: next[i].agentName, text: res.output,
            reasoning: res.reasoning, tools: next[i].tools, streaming: false,
            error: '', timestamp: next[i].timestamp, usageText: ''
          };
          found = true;
          break;
        }
      }
      if (!found) {
        const done: Bubble = newBubble(this.liveBubbleId, 'assistant', res.output);
        done.reasoning = res.reasoning;
        this.bubbles = this.bubbles.concat([done]);
        this.scrollToBottom(true);
      } else {
        this.bubbles = next;
        this.scrollToBottom(true);
      }
    } catch (e) {
      const msg = errText(e as Error, '发送失败');
      const next2: Bubble[] = this.bubbles.slice();
      for (let i = 0; i < next2.length; i++) {
        if (next2[i].id === this.liveBubbleId) {
          next2[i] = {
            id: next2[i].id, role: next2[i].role, agentName: next2[i].agentName, text: '',
            reasoning: '', tools: next2[i].tools, streaming: false,
            error: msg, timestamp: next2[i].timestamp, usageText: ''
          };
          break;
        }
      }
      this.bubbles = next2;
      this.scrollToBottom(true);
    } finally {
      this.streaming = false;
      this.liveBubbleId = '';
    }
  }

  private async send(): Promise<void> {
    const text = this.draft.trim();
    if (text.length === 0 || this.streaming) {
      return;
    }

    // 服务端模式：模型调用与 Agent 编排都在 PC 上，手机只发请求
    if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
      await this.sendViaServer(text);
      return;
    }

    if (this.provider === null || this.agent === null) {
      promptAction.showToast({ message: '请先在「设置 → 供应商」配置 API Key' });
      return;
    }
    // Scheme A：三态校验。undecryptable 与 empty 分开提示。
    if (this.provider.apiKeyState === 'undecryptable') {
      promptAction.showToast({ message: 'API Key 解密失败，请到「设置 → 供应商」重新填写' });
      return;
    }
    if (this.provider.apiKeyState === 'empty' || this.provider.apiKey.trim().length === 0) {
      promptAction.showToast({ message: 'API Key 为空，请到「设置 → 供应商」填写' });
      return;
    }

    this.draft = '';
    this.streaming = true;
    this.live = emptyStream();
    this.liveBubbleId = shortId(Date.now(), Math.random());
    // P1-SEQ12：本地模式的 runId 就是 liveBubbleId，必须在发起请求之前登记
    //   （建连/流式窗口内 this.handle 仍是 null，只能靠 runId 回落中止）。
    const localRunId: string = this.liveBubbleId;
    this.liveLocalRunId = localRunId;

    // 先把用户气泡和占位的助手气泡画出来（整体赋值，push 不会触发刷新）
    const userBubble: Bubble = newBubble(shortId(Date.now(), Math.random()), 'user', text);
    const liveBubble: Bubble = newBubble(this.liveBubbleId, 'assistant', '');
    liveBubble.streaming = true;
    const next: Bubble[] = this.bubbles.slice();
    next.push(userBubble);
    next.push(liveBubble);
    this.bubbles = next;

    // 落库用户消息
    await MessageRepo.insert(AppStore.db(), {
      id: userBubble.id,
      sessionId: this.sessionId,
      role: 'user',
      content: text,
      timestamp: userBubble.timestamp
    });
    await SessionRepo.recordMessage(AppStore.db(), this.sessionId, previewOf(text), Date.now());

    // 首轮自动命名
    if (this.title === '新对话' || this.title.length === 0) {
      const name = previewOf(text, 18);
      this.title = name;
      await SessionRepo.rename(AppStore.db(), this.sessionId, name, Date.now());
    }

    await SessionRepo.setActive(AppStore.db(), this.sessionId, true);

    const sink = (ev: RunEventLite): void => {
      this.live = reduceRunEvent(this.live, ev);
      this.patchLive();

      if (ev.event === 'run.completed') {
        this.finishRun(null);
      } else if (ev.event === 'run.failed') {
        this.finishRun(this.live.error.length > 0 ? this.live.error : '运行失败');
      }
    };

    const req = newRunRequest(
      this.provider, this.agent.model, await this.buildContext(), this.agent.reasoningEffort);
    // P1-SEQ12：buildContext 也是 await —— 期间用户可能已点「停止」。
    //   已停止就不要再发起请求，否则「停止」之后仍会烧一次 token。
    if (this.liveLocalRunId !== localRunId) {
      return;
    }
    try {
      const h = await LlmEngine.run(req, localRunId, sink);
      // P1-SEQ12：只有这一轮仍是当前 run 时才挂句柄。停止 / 正常收尾都会清
      //   liveLocalRunId —— 不校验会把已结束的陈旧句柄挂到 this.handle 上，
      //   下一轮「停止」就可能走错分支、漏掉 abortRun。
      if (this.liveLocalRunId === localRunId) {
        this.handle = h;
      }
    } catch (e) {
      this.finishRun(errText(e as Error, '发起失败'));
    }
  }

  /** 把 live 状态同步到对应气泡（ArkUI 需要整体赋值才刷新） */
  private patchLive(): void {
    // 收尾后 live 会被重置、liveBubbleId 也会清空。
    // 此时若还有尾部 dataReceive 帧进来（run.completed 后仍可能带usage 帧），
    // 继续patch 会用空的 live 覆盖已落库的正文 → 用户看到刚生成的回复被清空。
    if (!this.streaming || this.liveBubbleId.length === 0) {
      return;
    }
    const idx = this.bubbles.findIndex((b: Bubble) => b.id === this.liveBubbleId);
    if (idx < 0) {
      return;
    }
    const tools: BubbleTool[] = [];
    for (const t of this.live.tools) {
      tools.push(toBubbleTool(t));
    }
    const old = this.bubbles[idx];
    // 逐字段赋值，不用 {...old}
    const b: Bubble = {
      id: old.id,
      agentName: old.agentName,
      role: old.role,
      text: this.live.text,
      reasoning: this.live.reasoning,
      tools: tools,
      streaming: this.live.status === 'streaming',
      error: old.error,
      timestamp: old.timestamp,
      usageText: old.usageText
    };
    const arr = this.bubbles.slice();
    arr[idx] = b;
    this.bubbles = arr;
    this.scrollToBottom(false);
  }

  private async finishRun(err: string | null): Promise<void> {
    this.streaming = false;
    this.handle = null;
    // P1-SEQ12：收尾即摘掉 runId 登记（停止 / 正常完成都不再是「当前 run」）
    this.liveLocalRunId = '';

    const idx = this.bubbles.findIndex((b: Bubble) => b.id === this.liveBubbleId);
    if (idx < 0) {
      return;
    }
    const u = this.live.usage;
    const old = this.bubbles[idx];
    const b: Bubble = {
      id: old.id,
      agentName: old.agentName,
      role: old.role,
      text: old.text,
      reasoning: old.reasoning,
      tools: old.tools,
      streaming: false,
      error: err ?? old.error,
      timestamp: old.timestamp,
      usageText: usageLine(u.inputTokens, u.outputTokens)
    };
    const arr = this.bubbles.slice();
    arr[idx] = b;
    this.bubbles = arr;
    this.scrollToBottom(false);

    // 只有拿到正文才落库，避免把空回复写进去
    if (this.live.text.length > 0 || (err !== null && err.length > 0)) {
      const trace: ToolTraceItem[] = [];
      for (const t of this.live.tools) {
        trace.push(toTraceItem(t));
      }
      await MessageRepo.insert(AppStore.db(), {
        id: this.liveBubbleId,
        sessionId: this.sessionId,
        role: 'assistant',
        content: this.live.text,
        reasoning: this.live.reasoning,
        toolTrace: trace,
        usage: {
          inputTokens: u.inputTokens,
          outputTokens: u.outputTokens,
          totalTokens: u.inputTokens + u.outputTokens,
          cacheReadTokens: u.cacheReadTokens
        },
        error: err ?? '',
        timestamp: Date.now()
      });
      await SessionRepo.recordMessage(AppStore.db(), this.sessionId,
        previewOf(this.live.text), Date.now());
    } else if (err !== null) {
      // 空回复 + 有错：单独提示，别让用户对着空气
      promptAction.showToast({ message: err });
    }

    await SessionRepo.setActive(AppStore.db(), this.sessionId, false);
    // live 与 liveBubbleId 必须一起清：只清 live 会让迟到的 patchLive
    // 拿空状态覆盖正文（patchLive 已有streaming 守卫，这里是第二道保险）。
    this.live = emptyStream();
    this.liveBubbleId = '';
  }

  /**
 * 服务端确认中止完成 —— 收尾气泡。
 *
 * ⚠ 被中止的 run **不会有 run.completed**（真机 21:13 实测的报文）：
 *   << ["abort.started",  {"run_id":...}]
 *   << ["abort.completed",{"run_id":...}]
 * 所以气泡的 streaming 标记只能靠这个事件清，
 * 否则界面永远停在「正在处理」。
 */
private onAbortCompleted(args: Object[]): void {
    SocketClient.log('[chat] abort.completed → 收尾气泡');
    this.streaming = false;
    this.liveRunId = '';
    this.liveBubbleId = '';
    this.finishStreamingBubble('（已中止）');
  }

  /**
 * 把当前「正在处理」的气泡收尾。
 *
 * ⚠ 为什么需要它（2026-10-07 真机实测）
 *
 * 服务端在「等用户批准 / 等用户回答澄清」期间**不会**推 run.completed，
 * 所以气泡的 streaming 标记没人清。结果：遮罩关掉了、气泡还在转圈。
 * 三个触发点都要走这里：
 *   ① 遮罩关闭（approval.resolved / clarify.resolved）
 *   ② 手动点「中止」
 *   ③ run.completed 正常收尾（那条路径自己处理）
 *
 * @param fallbackText 气泡没有正文时填的兜底文案
 */
/**
   * 整体重建数组并替换第 idx 个气泡的文本（元素也换新引用）。
   *
   * ⚠ ArkUI 的 @State 数组必须**整体重新赋值**才刷新，
   *   数组里的元素也要换新引用，否则所在行不重绘（真机 21:24 踩过）。
   */
  private replaceAt(idx: number, text: string): Bubble[] {
    const next: Bubble[] = [];
    for (let i = 0; i < this.bubbles.length; i++) {
      const x: Bubble = this.bubbles[i];
      if (i !== idx) {
        next.push(x);
        continue;
      }
      const nb: Bubble = newBubble(x.id, x.role, text);
      nb.agentName = x.agentName;
      nb.reasoning = x.reasoning;
      nb.tools = x.tools;
      nb.streaming = x.streaming;
      nb.error = x.error;
      nb.timestamp = x.timestamp;
      nb.usageText = x.usageText;
      next.push(nb);
    }
    return next;
  }

  private finishStreamingBubble(fallbackText: string, errMsg: string = ''): void {
    // ⚠ 先按 liveBubbleId 定位，兜底再按 streaming 标记找。
    //   只按 streaming 找会错位：页面上可能同时存在多个「看起来在转」的气泡
    //   （比如上一轮没收尾干净），findIndex只会命中第一个（真机 21:34 idx=574
    //   但真正那条是另一个）。
    let idx: number = -1;
    if (this.liveBubbleId.length > 0) {
      for (let i = 0; i < this.bubbles.length; i++) {
        if (this.bubbles[i].id === this.liveBubbleId) {
          idx = i;
          break;
        }
      }
    }
    if (idx < 0) {
      idx = this.bubbles.findIndex((b: Bubble) => b.streaming);
    }
    SocketClient.log(`[chat] finishStreamingBubble idx=${idx} total=${this.bubbles.length} liveId=${this.liveBubbleId} err="${errMsg}"`);
    if (idx < 0) {
      return;
    }
    // ⚠ ArkUI 的 @State 数组：**必须换成全新的数组和全新的元素对象**才刷新。
    //   之前用 bubbles.slice() + 替换某个下标，界面就是不更新（日志显示
    //   idx=569 收尾成功，气泡却还在转 —— 真机 21:24）。
    //   ⚠ ArkTS 不允许 map 回调返回对象字面量（arkts-no-untyped-obj-literals），
    //   所以必须用显式 for 循环 + newBubble 工厂。
    const next: Bubble[] = [];
    for (let i = 0; i < this.bubbles.length; i++) {
      const x: Bubble = this.bubbles[i];
      const nb: Bubble = newBubble(x.id, x.role,
        x.streaming && x.text.length === 0 ? fallbackText : x.text);
      nb.agentName = x.agentName;
      nb.reasoning = x.reasoning;
      nb.tools = x.tools;
      nb.streaming = false;
      // 有新错误就用新的，否则保留原有（成功路径的 error 恒为空）
      nb.error = errMsg.length > 0 ? errMsg : x.error;
      nb.timestamp = x.timestamp;
      nb.usageText = x.usageText;
      next.push(nb);
    }
    this.bubbles = next;
    // ⚠ 必须在这之后清：下次收尾若再按 liveBubbleId 找，会打到已完成的旧气泡
    this.liveBubbleId = '';
    this.scrollToBottom(false);
  }

  private stopIfRunning(): void {
    if (this.handle !== null) {
      this.handle.abort();
      this.handle = null;
    }
    // P1-SEQ12：建连/流式窗口内 this.handle 恒为 null（句柄要等整段流结束才返回）
    //   → 必须按 runId 回落，否则「停止」被静默丢弃：UI 假装已停止、请求继续
    //   烧 token、退出页面（aboutToDisappear）也拦不住。
    //   与上面的句柄分支**不互斥**：句柄可能属于上一轮（陈旧句柄），
    //   abortRun 才是建连窗口的权威路径。
    if (this.liveLocalRunId.length > 0) {
      LlmEngine.abortRun(this.liveLocalRunId);
      this.liveLocalRunId = '';
    }
    this.streaming = false;
    this.liveRunId = '';
    this.liveBubbleId = '';
    // 也要把「正在处理」的气泡收尾（真机实测：只清页面级 streaming 时，
    //   气泡上的 streaming 标记还在，界面就一直转圈，按钮也恢复不了）
    this.finishStreamingBubble('（已中止）');
    // socket 模式下还要通知服务端停掉这个 run
    if (this.api !== undefined && this.api !== null) {
      this.api.emitChatAbort(this.sessionId);
    }
  }

build() {
    // ⚠ 必须用 Stack 套Column，不能直接用 Column。
    //   agent 选择面板是「浮在内容之上」的覆盖层，
    //   如果直接挂在 Column 末尾，它会作为**布局子节点**参与分配
    //   （height('100%') 直接把输入区顶出屏幕），
    //   表现就是「打开面板后整页错位 / 输入框消失」。
    //   Stack 让面板脱离布局流，才是真正的覆盖。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(28)
          .onClick(() => router.back())
        Column({ space: 2 }) {
          Text(this.title.length > 0 ? this.title : '对话')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tok.text1(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 副标题 = 这个会话自己的 agent + 模型。
          // ⚠ 不能用 `${this.agent.name} · ${this.agent.model}`——
          //   this.agent 是**本地默认 agent**，任何会话都显示同一个。
          // 只有草稿页能换 agent：已有会话的 agent 是历史事实。
          Row({ space: 3 }) {
            Text(this.subtitle().length > 0 ? this.subtitle() : ' ')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.subtitle().length > 0) {
              Text(this.draftMode ? '▾' : '')
                .fontSize(9)
                .fontColor(Tok.text3(this.dark))
                .width(10)
            }
          }
          .width('100%')
          .height(16)
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        // 整块都可点（草稿页才响应），点击区比只点小三角大得多
        .onClick(() => {
          if (this.draftMode && this.profiles.length > 0) {
            this.profilePanelOpen = true;
          }
        })

        Blank()

        Text('⋯').fontSize(20).fontColor(Tok.text2(this.dark))
          .width(28)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.freshLink = '';
            this.loadShares();
            this.sheetOpen = true;
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })
      .backgroundColor(Tok.pageBg(this.dark))
      .bindSheet($$this.sheetOpen, this.sheet(), {
        height: SheetSize.MEDIUM,
        dragBar: true
      })

      // 消息列表
      if (this.bubbles.length === 0) {
        EmptyState({ icon: '✦', text: '开始一段对话', hint: '下方输入框发送' })
        Blank()
      } else {
        List({ space: 12, scroller: this.scroller }) {
          ForEach(this.bubbles, (b: Bubble) => {
            ListItem() {
              this.bubbleView(b)
            }
            // ⚠⚠ key 不能只用 b.id —— 本页所有更新（delta 合并 / finish /
            //   错误写入）都是「同 id 新对象」，ForEach 对 key 不变的项
            //   不重建，而 bubbleView 是 @Builder（按值传参、无观察），
            //   结果就是气泡永远停在首次渲染的样子：占位符冻结、正文/
            //   错误/收尾全都看不见（真机 2026-10-07 22:12 实测：
            //   finishStreamingBubble idx=2 收尾成功，界面纹丝不动）。
            //   key 必须带上全部会变的字段，变了才触发该项重建。
          }, (b: Bubble) => `${b.id}:${b.streaming ? 1 : 0}:${b.text.length}:${b.reasoning.length}:${b.tools.length}:${b.error.length}:${b.usageText.length}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Tok.pagePad, right: Tok.pagePad })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      // 附件条 + 记忆注入提示，压在输入区上方
      if (this.attachments.length > 0) {
        this.attachmentBar()
      }
      if (this.memories.length > 0) {
        this.memoryBar()
      }
      // 草稿页的 agent 选择条 —— 显式入口，不能只靠「猜顶栏副标题可点」
      if (this.draftMode && this.profiles.length > 0) {
        this.agentBar()
      }

      // 输入区
      this.composer()
      }
      .width('100%')
      .height('100%')
      // P1-17 同形修复：一个组件节点只能挂一个 bindSheet。原本 attachPanelOpen 与
      // memoryPanelOpen 两个 sheet 都挂在根 Stack 上，后者覆盖前者 —— 附件条
      // 「查看」点了没反应（同形限制，见 ad7d68c / 5bafac6 模板）。
      // 本 sheet 移到内层 Column（Stack 的第一个子节点，无条件渲染的稳定宿主），
      // memory sheet 留根 Stack。纯属性迁移，零逻辑改动。
      .bindSheet($$this.attachPanelOpen, this.attachmentSheet(), {
        height: SheetSize.LARGE,
        dragBar: true
      })

      // 覆盖层（Stack 的第二个子节点→ 不参与 Column 布局，浮在上面）
      this.profileOverlay()

      // Agent 反向提问：审批 / 澄清
      // ⚠ 必须放在最上（后画的就是在上），否则会被 profileOverlay盖住。
      this.askOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.memoryPanelOpen, this.memorySheet(), {
      height: SheetSize.LARGE,
      dragBar: true
    })
  }

  /**
   * 草稿页的 agent 选择条（输入框上方常驻）。
   *
   * 为什么要有这个：光靠「顶栏副标题可点」太隐蔽，
   * 老板不知道那里能点。草稿页本来就是选 agent 的场景，
   * 给一条常驻的、明确写着「Agent」的可点条。
   */
  @Builder
  agentBar() {
    Row({ space: 6 }) {
      Text('Agent')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
      Text(this.pickedLabel())
        .fontSize(12)
        .fontColor(Tok.text1(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('切换 ▾')
        .fontSize(11)
        .fontColor(Tok.brand)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 4 })
    .backgroundColor(Tok.brandSoft)
    .borderRadius(Tok.radius)
    .onClick(() => {
      this.profilePanelOpen = true;
    })
  }

  /** 当前选中的 agent 展示名 */
  private pickedLabel(): string {
    for (const p of this.profiles) {
      if (p.name === this.pickedProfile) {
        return p.displayName;
      }
    }
    return this.pickedProfile.length > 0 ? this.pickedProfile : '未选择';
  }

  /**
 * Agent 反向提问面板（审批 / 澄清）。
 *
 * ## 为什么必须有这个（安卓版有、鸿蒙版原本没有）
 *
 * Agent 干活时会遇到需要人拿主意的场合：写文件前问一句、要钱前问一句、
 * 拿不准该用哪个方案时反问。这些请求到达后 **PC 端的 run 会挂起等 5 分钟**，
 * 手机端不显示、不回答 —— 表现为「Agent 一直转、最后超时失败」。
 *
 * 事件链路（安卓版反编译确认）：
 *   收 approval.requested → {session_id, requestId, ...}
 *   发 approval.respond  → {session_id, approval_id, choice}
 *   收 clarify.requested  → {session_id, requestId, question, choices?}
 *   发 clarify.respond   → {session_id, clarify_id, response}
 */
  @Builder
  askOverlay() {
    if (this.approvalReq !== null) {
      this.approvalOverlay()
    } else if (this.clarifyReq !== null) {
      this.clarifyOverlay()
    }
  }

  @Builder
  approvalOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：不允许点外面关掉 —— 审批没答复，Agent 会一直等
      Column() {}
        .width('100%')
        .height('100%')
        .backgroundColor(this.dark ? '#CC000000' : '#88000000')

      // ⚠ Card() 本身是 @Builder（编译期展开），**后面不能链式调用通用属性**。
          // 要限宽就套一层Column。
          Column() {
            Card() {
              Column({ space: 12 }) {
                Row({ space: 6 }) {
                  Text('⏸')
                    .fontSize(15)
                  Text('Agent 需要你确认')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tok.text1(this.dark))
                }
                .width('100%')

                if (this.approvalReq !== null && this.approvalReq.title.length > 0) {
                  Text(this.approvalReq.title)
                    .fontSize(14)
                    .fontColor(Tok.text1(this.dark))
                    .width('100%')
                }
                if (this.approvalReq !== null && this.approvalReq.detail.length > 0) {
                  Text(this.approvalReq.detail)
                    .fontSize(13)
                    .fontColor(Tok.text2(this.dark))
                    .width('100%')
                    .maxLines(10)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }

                // 服务端给了备选项就用按钮，否则给「同意 / 拒绝」两个兜底
                if (this.approvalReq !== null && this.approvalReq.choices.length > 0) {
                  ForEach(this.approvalReq.choices, (c: string) => {
                    PrimaryButton({
                      label: c,
                      onTap: (): void => {
                        this.respondApproval(c);
                      }
                    })
                  }, (c: string) => 'ap' + c)
                } else {
                  Row({ space: 8 }) {
                    GhostButton({
                      label: '拒绝',
                      danger: true,
                      onTap: (): void => {
                        this.respondApproval('deny');
                      }
                    })
                    PrimaryButton({
                      label: '同意',
                      onTap: (): void => {
                        this.respondApproval('approve');
                      }
                    })
                  }
                  .width('100%')
                }

                Text('不处理的话，电脑上的 Agent 会在 5 分钟后超时')
                  .fontSize(10)
                  .fontColor(Tok.text3(this.dark))
                  .width('100%')
              }
            }
          }
          .width('88%')
        }
      .width('100%')
      .height('100%')
    }

  @Builder
  clarifyOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}
        .width('100%')
        .height('100%')
        .backgroundColor(this.dark ? '#CC000000' : '#88000000')

      Column() {
      Card() {
        Column({ space: 12 }) {
          Row({ space: 6 }) {
            Text('❓')
              .fontSize(15)
            Text('Agent 有个问题')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
          }
          .width('100%')

          if (this.clarifyReq !== null) {
            Text(this.clarifyReq.question)
              .fontSize(14)
              .fontColor(Tok.text1(this.dark))
              .width('100%')
              .maxLines(8)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          // 有候选项先给按钮（点一下填进输入框，可再改），没有就自由输入
          if (this.clarifyReq !== null && this.clarifyReq.choices.length > 0) {
            ForEach(this.clarifyReq.choices, (c: string) => {
              GhostButton({
                label: c,
                onTap: (): void => {
                  this.clarifyText = c;
                }
              })
            }, (c: string) => 'cl' + c)
          }

          LabeledInput({
            label: '你的回答',
            value: this.clarifyText,
            placeholder: '输入回答…',
            onChange: (v: string): void => {
              this.clarifyText = v;
            }
          })

          PrimaryButton({
            label: '发送回答',
            enabledState: this.clarifyText.trim().length > 0,
            onTap: (): void => {
              this.respondClarify();
            }
          })
        }
      }
      }
      .width('88%')
    }
    .width('100%')
    .height('100%')
  }

  /**
   * agent（PC profile）选择面板 —— 覆盖层实现。
   *
   * 为什么不用 bindSheet：本页三个 sheet 各挂一个独立宿主节点
   * （`:1687` 顶栏 Row / `:1740` 内层 Column / `:1755` 根 Stack），
   * 再复用任一宿主挂第四个会让先前的失效（ArkUI 的已知限制）。
   */
  @Builder
  profileOverlay() {
    if (this.profilePanelOpen) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 遮罩
        Column() {}
          .width('100%')
          .height('100%')
          .backgroundColor(this.dark ? '#99000000' : '#66000000')
          .onClick(() => {
            this.profilePanelOpen = false;
          })

        // 面板本体
        Column({ space: 10 }) {
          Row() {
            Text('选择 Agent')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
            Blank()
            Text('✕')
              .fontSize(16)
              .fontColor(Tok.text2(this.dark))
              .width(28)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.profilePanelOpen = false;
              })
          }
          .width('100%')

          Text('切换后，新消息会交给这个 Agent 处理')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .width('100%')

          if (this.profiles.length === 0) {
            Text('PC 上没有可用的 Agent')
              .fontSize(13)
              .fontColor(Tok.text3(this.dark))
              .padding({ top: 24, bottom: 24 })
              .width('100%')
              .textAlign(TextAlign.Center)
          } else {
            // ⚠ 必须放Scroll 里：PC 上 agent 可能十几个，
            //   直接 ForEach 会把面板顶高到超出屏幕，列表看不全。
            Scroll() {
              Column({ space: 4 }) {
                ForEach(this.profiles, (p: RemoteProfile) => {
                  this.profileRow(p)
                }, (p: RemoteProfile) => p.name)
              }
              .width('100%')
            }
            .width('100%')
            // 最多占屏幕一半多一点，剩下的滚动
            .constraintSize({ maxHeight: '52%' })
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width('100%')
        // 面板不超过 70% 屏高，永远给内容区留位置
        .constraintSize({ maxHeight: '70%' })
        .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 16, bottom: 24 })
        .backgroundColor(this.dark ? '#1C1D22' : '#FFFFFF')
        .borderRadius({ topLeft: 16, topRight: 16 })
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 选择面板里的单个 agent 行 */
  @Builder
  profileRow(p: RemoteProfile) {
    Row({ space: 10 }) {
      Text(p.initial)
        .fontSize(14)
        .fontColor(Color.White)
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .borderRadius(17)
        .backgroundColor(p.name === this.pickedProfile ? Tok.brand : Tok.text3(this.dark))

      Column({ space: 2 }) {
        Text(p.displayName)
          .fontSize(14)
          .fontColor(Tok.text1(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (p.model.length > 0) {
          Text(p.model)
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (p.name === this.pickedProfile) {
        Text('✓')
          .fontSize(16)
          .fontColor(Tok.brand)
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 4, right: 4 })
    .backgroundColor(p.name === this.pickedProfile ? Tok.brandSoft : Color.Transparent)
    .borderRadius(Tok.radius)
    .onClick(() => {
      this.pickProfile(p.name);
    })
  }

  /** 附件条：点开看全部附件 */
  @Builder
  attachmentBar() {
    Row({ space: 8 }) {
      Text('📎')
        .fontSize(13)
      Text(`${this.attachments.length} 个附件`)
        .fontSize(12)
        .fontColor(Tok.text2(this.dark))
        .layoutWeight(1)
      Text(this.attachPanelOpen ? '收起' : '查看')
        .fontSize(12)
        .fontColor(Tok.brand)
        .onClick(() => {
          this.attachPanelOpen = !this.attachPanelOpen;
        })
    }
    .width('100%')
    .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 6 })
    .backgroundColor(Tok.cardBg(this.dark))
  }

  /** 附件条展开后直接内联在气泡下方，省一次跳转 */
  @Builder
  attachmentStrip() {
    Column({ space: 6 }) {
      SectionTitle({ text: '本会话附件', trailing: `${this.attachments.length}` })
      ForEach(this.attachments, (a: Attachment) => {
        Row({ space: 10 }) {
          Text('📄')
            .fontSize(14)
          Column({ space: 2 }) {
            Text(a.name.length > 0 ? a.name : '未命名文件')
              .fontSize(13)
              .fontColor(Tok.text1(this.dark))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(attachmentLine(a))
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Blank()
          Text('详情')
            .fontSize(11)
            .fontColor(Tok.brand)
            .padding({ left: 8, top: 4, bottom: 4 })
            .onClick(() => {
              promptAction.showToast({ message: attachmentLine(a) });
            })
        }
        .width('100%')
        .padding(10)
        .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
        .borderRadius(Tok.radiusSmall)
      }, (a: Attachment) => a.id)
    }
    .width('100%')
    .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 记忆注入提示：告诉用户有 N 条记忆会被注入，可展开看内容 */
  @Builder
  memoryBar() {
    Row({ space: 8 }) {
      Text('🧠')
        .fontSize(13)
      Text(`本会话有 ${this.memories.length} 条记忆会被注入`)
        .fontSize(12)
        .fontColor(Tok.text2(this.dark))
        .layoutWeight(1)
      Text(this.memoryPanelOpen ? '收起' : '查看')
        .fontSize(12)
        .fontColor(Tok.brand)
        .onClick(() => {
          this.memoryPanelOpen = !this.memoryPanelOpen;
        })
    }
    .width('100%')
    .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 6 })
    .backgroundColor(Tok.cardBg(this.dark))
  }

  @Builder
  attachmentSheet() {
    Scroll() {
      Column({ space: 10 }) {
        Text('本会话附件')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .width('100%')
        if (this.attachments.length === 0) {
          Text('这个会话还没有附件')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .padding({ top: 20, bottom: 20 })
        } else {
          ForEach(this.attachments, (a: Attachment) => {
            Column({ space: 4 }) {
              Text(a.name.length > 0 ? a.name : '未命名文件')
                .fontSize(14)
                .fontColor(Tok.text1(this.dark))
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`大小 ${humanSize(a.size)} · 类型 ${a.kind.length > 0 ? a.kind : 'file'}`)
                .fontSize(11)
                .fontColor(Tok.text3(this.dark))
                .width('100%')
              Text(a.path.length > 0 ? a.path : '（无本地路径）')
                .fontSize(10)
                .fontFamily('monospace')
                .fontColor(Tok.text3(this.dark))
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(relativeTime(a.createdAt, this.now))
                .fontSize(10)
                .fontColor(Tok.text3(this.dark))
                .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
            .borderRadius(Tok.radiusSmall)
            .alignItems(HorizontalAlign.Start)
          }, (a: Attachment) => a.id)
        }
        Button('关闭')
          .width('100%')
          .height(38)
          .fontSize(14)
          .fontColor(Tok.text2(this.dark))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.attachPanelOpen = false;
          })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }

  @Builder
  memorySheet() {
    Scroll() {
      Column({ space: 10 }) {
        Text('会被注入的记忆')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .width('100%')
        Text('全局记忆对所有会话生效，本会话的记忆只影响这里。')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
        if (this.memories.length === 0) {
          Text('还没有记忆')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .padding({ top: 20, bottom: 20 })
        } else {
          ForEach(this.memories, (m: MemoryItem) => {
            Column({ space: 4 }) {
              Row({ space: 6 }) {
                Text(memoryScopeLabel(m))
                  .fontSize(10)
                  .fontColor(m.scope === 'global' ? Tok.warn : Tok.brand)
                Text(m.pinned ? '已置顶' : m.kind)
                  .fontSize(10)
                  .fontColor(Tok.text3(this.dark))
                Blank()
                Text(relativeTime(m.updatedAt, this.now))
                  .fontSize(10)
                  .fontColor(Tok.text3(this.dark))
              }
              .width('100%')
              Text(m.content)
                .fontSize(13)
                .fontColor(Tok.text1(this.dark))
                .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
            .borderRadius(Tok.radiusSmall)
            .alignItems(HorizontalAlign.Start)
          }, (m: MemoryItem) => m.id)
        }
        Button('关闭')
          .width('100%')
          .height(38)
          .fontSize(14)
          .fontColor(Tok.text2(this.dark))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.memoryPanelOpen = false;
          })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }

  @Builder
  bubbleView(b: Bubble) {
    if (b.role === 'user') {
      Row() {
        Blank()
        Column({ space: 4 }) {
          Text(b.text)
            .fontSize(15)
            .fontColor('#FFFFFF')
            .lineHeight(22)
        }
        .constraintSize({ maxWidth: '78%' })
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .backgroundColor(Tok.userBubble(this.dark))
        .borderRadius(Tok.radius)
      }
      .width('100%')
    } else {
      Column({ space: 6 }) {
        // 思考区（折叠）
        if (b.reasoning.length > 0) {
          Column({ space: 4 }) {
            Row({ space: 6 }) {
              Text('思考过程').fontSize(11).fontColor(Tok.text3(this.dark))
              Blank()
              Text(this.reasonOpen ? '收起' : '展开')
                .fontSize(11)
                .fontColor(Tok.brand)
                .onClick(() => {
                  this.reasonOpen = !this.reasonOpen;
                })
            }
            .width('100%')
            if (this.reasonOpen) {
              Text(b.reasoning)
                .width('100%')
                .fontSize(12)
                .fontColor(Tok.text2(this.dark))
                .lineHeight(18)
                .maxLines(40)
            }
          }
          .width('100%')
          .padding(10)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })
        }

        // agent 标签：服务端 source=coding_agent 的会话有值（codebuddy/claude/codex），
        // source=cli 的没有（单 Agent 对话），此时不显示。
        if (b.agentName.length > 0) {
          Text(b.agentName)
            .fontSize(11)
            .fontColor(Tok.brand)
            .padding({ left: 2, right: 6, top: 1, bottom: 1 })
            .backgroundColor(Tok.brandSoft)
            .borderRadius(4)
        }

        // 工具轨迹
        if (b.tools.length > 0) {
          Column({ space: 2 }) {
            ForEach(b.tools, (t: BubbleTool, i: number) => {
              ToolTraceRow({
                name: t.name,
                status: t.status,
                detail: toolDetail(t)
              })
            }, (t: BubbleTool, i: number) => `${b.id}-t${i}`)
          }
          .width('100%')
          .padding(8)
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })
        }

        // 正文
        Column({ space: 4 }) {
          if (b.text.length > 0) {
            // dark 是 @StorageProp，由 AppStorage 传播，不能在这里显式传
            MdText({ source: b.text, fontSize: 15 })
          } else if (b.streaming) {
            StreamingDots({})
            // 服务端模式是等待式接口（跑完才返回，可能好几分钟），
            // 光三个点太像卡死了，补一句说明。
            if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
              Text('PC 上的 Agent 正在处理，完成后自动显示…')
                .fontSize(11)
                .fontColor(Tok.text3(this.dark))
                .margin({ top: 4 })
            }
          } else {
            Text('（无输出）')
              .fontSize(13)
              .fontColor(Tok.text3(this.dark))
          }

          if (b.error.length > 0) {
            Text(b.error)
              .fontSize(12)
              .fontColor(Tok.danger)
              .width('100%')
              .margin({ top: 4 })
          }

          if (b.usageText.length > 0) {
            Text(b.usageText)
              .fontSize(10)
              .fontColor(Tok.text3(this.dark))
              .fontFeature(Tok.TNUM)
              .width('100%')
              .textAlign(TextAlign.End)
              .margin({ top: 2 })
          }
        }
        .width('100%')
        .padding(12)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Tok.cardBg(this.dark))
        .borderRadius(Tok.radius)
        .border({ width: 1, color: Tok.line(this.dark) })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  composer() {
    Column({ space: 0 }) {
      if (this.attachPanelOpen && this.attachments.length > 0) {
        this.attachmentStrip()
      }
      Row({ space: 8 }) {
        TextArea({ placeholder: '说点什么…', text: this.draft })
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .maxLength(4000)
          .onChange((v: string) => {
            this.draft = v;
          })

        if (this.streaming) {
          Button('■', { type: ButtonType.Circle })
            .width(44)
            .height(44)
            .fontSize(16)
            .fontColor('#FFFFFF')
            .backgroundColor(Tok.danger)
            .onClick(() => this.stopIfRunning())
        } else {
          Button('↑', { type: ButtonType.Circle })
            .width(44)
            .height(44)
            .fontSize(20)
            .fontColor('#FFFFFF')
            .backgroundColor(this.draft.trim().length > 0 ? Tok.brand : Tok.text3(this.dark))
            .enabled(this.draft.trim().length > 0)
            .onClick(() => {
              this.send();
            })
        }
      }
      .width('100%')
      }
    .width('100%')
    .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 8, bottom: 10 })
    .backgroundColor(Tok.pageBg(this.dark))
  }

  /** 顶部"⋯"拉出的操作面板 */
  @Builder
  sheet() {
    Column({ space: 12 }) {
      Text('会话操作')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tok.text1(this.dark))
        .width('100%')

      Row({ space: 8 }) {
        Text('标题')
          .fontSize(14)
          .fontColor(Tok.text2(this.dark))
          .width(56)
        TextInput({ placeholder: '给会话起个名', text: this.title })
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .backgroundColor(Tok.fieldBg(this.dark))
          .borderRadius(Tok.radiusSmall)
          .onChange((v: string) => {
            this.title = v;
          })
      }
      .width('100%')

      Button('保存标题')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(Tok.brand)
        .borderRadius(Tok.radiusSmall)
        .onClick(async () => {
          await SessionRepo.rename(AppStore.db(), this.sessionId, this.title, Date.now());
          this.sheetOpen = false;
          promptAction.showToast({ message: '已保存' });
        })

      Button('清空消息')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor(Tok.danger)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: Tok.danger })
        .borderRadius(Tok.radiusSmall)
        .onClick(async () => {
          await MessageRepo.deleteBySession(AppStore.db(), this.sessionId);
          this.bubbles = [];
          this.sheetOpen = false;
          promptAction.showToast({ message: '已清空' });
        })

      // 分享链接
      SectionTitle({ text: '分享链接', trailing: `${this.shares.length}` })

      if (this.freshLink.length > 0) {
        Text(this.freshLink)
          .width('100%')
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(Tok.text1(this.dark))
          .backgroundColor(Tok.fieldBg(this.dark))
          .padding(8)
          .borderRadius(Tok.radiusSmall)
        Text('点下面「复制链接」再次复制')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
      }

      Button('生成新的分享链接（7 天有效）')
        .width('100%')
        .height(40)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(Tok.brand)
        .borderRadius(Tok.radiusSmall)
        .onClick(() => {
          this.createShare();
        })

      if (this.freshLink.length > 0) {
        Button('复制链接')
          .width('100%')
          .height(40)
          .fontSize(14)
          .fontColor(Tok.brand)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: Tok.brand })
          .borderRadius(Tok.radiusSmall)
          .onClick(() => {
            this.copyFreshLink();
          })
      }

      if (this.shares.length > 0) {
        ForEach(this.shares, (sh: SessionShare) => {
          Row() {
            Column({ space: 2 }) {
              Text(shareLinkOf(sh.token))
                .fontSize(10)
                .fontFamily('monospace')
                .fontColor(Tok.text2(this.dark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`${shareExpiryText(sh.expiresAt, this.now)} · ${relativeTime(sh.createdAt, this.now)}`)
                .fontSize(10)
                .fontColor(Tok.text3(this.dark))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('复制')
              .fontSize(11)
              .fontColor(Tok.brand)
              .padding({ left: 6, top: 4, bottom: 4 })
              .onClick(() => {
                copyToClipboard(shareLinkOf(sh.token));
              })
            Text('撤销')
              .fontSize(11)
              .fontColor(Tok.danger)
              .padding({ left: 6, top: 4, bottom: 4 })
              .onClick(() => {
                this.revokeShare(sh.token);
              })
          }
          .width('100%')
          .padding(10)
          .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
          .borderRadius(Tok.radiusSmall)
        }, (sh: SessionShare) => sh.token)
      }

      Button('关闭')
        .width('100%')
        .height(38)
        .fontSize(14)
        .fontColor(Tok.text2(this.dark))
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.sheetOpen = false;
        })
    }
    .width('100%')
    .padding(20)
  }
}

/** 工具详情：优先结果，其次参数 */
function toolDetail(t: BubbleTool): string {
  const raw = t.result.length > 0 ? t.result : t.args;
  return raw.slice(0, 400);
}
