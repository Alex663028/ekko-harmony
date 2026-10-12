/**
 * 群聊页：多 Agent @ 协作。
 *
 * 关键行为对齐原版：
 *  - 发送前必须 @ 至少一个 Agent，否则服务端会拒绝（normalizeStructuredMentions）
 *  - @ 提及解析用 agentId（稳定全局 id），不是房间内记录 id
 *  - 被 @ 的 Agent 逐个入队执行
 */

import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { RoomInfo, RoomAgent, GroupMessage, MentionRef, RunUsage } from '../model/Types';
import { RoomRepo, RoomAgentRepo, GroupMessageRepo, ProviderRepo, QueueRepo } from '../data/Repos';
import { MemoryRepo } from '../data/ExtendRepos';
import { MemoryItem } from '../model/Extend';
import { AppStore } from '../viewmodel/AppStore';
import { blockLocalWrite } from '../viewmodel/ServerMode';
import { AgentOrchestrator, OrchestratorHooks } from '../net/Orchestrator';
import { StudioApi, GcHandlers, GcMention, GcDelta, GcMessage } from '../net/StudioApi';
import { NetConfig, errorMessage } from '../net/Http';
import { notifyAsk, cancelAskNotify } from '../common/Notify';
import {
  resolveMentions, validateGroupMessage, relativeTime,
  formatNumber, shortId, StreamState, MentionCandidate,
  MentionRef as CoreMentionRef
} from '../common/Core';
import { MdText, EmptyState, StreamingDots, SectionTitle } from '../view/Common';
import { Tok } from '../view/Theme';

/** 收敛 mention 的 type 字面量，避免 ArkTS 把它退化成 string */
function toMentionType(t: string): 'agent' | 'all' {
  return t === 'all' ? 'all' : 'agent';
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
 * 邀请码：6 位大写字母数字，去掉易混字符（0/O/1/I）。
 * RoomRepo 目前没有写回 invite_code 的方法，这里只负责生成与展示。
 */
const INVITE_ALPHABET: string = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function makeInviteCode(): string {
  let out = '';
  for (let i = 0; i < 6; i++) {
    const idx = Math.floor(Math.random() * INVITE_ALPHABET.length);
    out += INVITE_ALPHABET.charAt(idx);
  }
  return out;
}

/** 交接深度文案：0/null 视为跟随编排器默认 */
function handoffDepthText(depth: number | null): string {
  if (depth === null || depth === undefined || depth <= 0) {
    return '默认';
  }
  return `${depth} 层`;
}

/** 记忆条目的来源标签：全局记忆对所有房间生效 */
function memoryScopeLabel(m: MemoryItem): string {
  if (m.scope === 'global') {
    return '全局';
  }
  if (m.scope === 'room') {
    return '本群';
  }
  if (m.scope === 'session') {
    return '会话';
  }
  return m.scope;
}

/** 路由参数：具名 interface，避免 ArkTS 的动态键访问限制 */
interface GcRouteParams {
  roomId: string;
  /** 通知 URI 里用的键名（群聊页也认这个，见 aboutToAppear） */
  sessionId?: string;
  /** 从系统通知点进来时带的标记（`approval` / `clarify`），普通进入不带 */
  ask?: string;
}

interface GBubble {
  id: string;
  senderName: string;
  senderKind: 'human' | 'agent';
  agentId: string;
  role: string;
  content: string;
  timestamp: number;
  usageText: string;
  streaming: boolean;
}

/**
 * 流式中的消息。用数组而不是 Record<string, StreamState>：
 * ArkTS禁止 obj['k'] 动态键访问、对象展开与 delete（arkts-no-props-by-index /
 * arkts-no-spread / arkts-no-delete），且 @State 必须整体重新赋值才刷新。
 */
interface LiveEntry {
  messageId: string;
  state: StreamState;
}

/**
 * 服务端流式缓冲的一条记录。
 * id 是服务端的 message id（形如gcmsg_<room>_<profile>_<ts>_<rand>_part_0），
 * 同一 id 的多个 delta 拼起来就是一条完整回复。
 */
interface StreamBuf {
  id: string;
  text: string;
}

/**
 * 群聊里的审批请求（对应服务端 `group.approval.requested`）。
 *
 * ⚠ 字段名不能自己猜：服务端 payload 里可能有 approvalId / approval_id 两种，
 *   解析时都要试；选项也要原样回传，不能自己编。
 */
interface GcApprovalReq {
  approvalId: string;
  title: string;
  detail: string;
  tool: string;
  choices: string[];
}

/** 群聊里的澄清提问（对应服务端 `group.clarification.requested`） */
interface GcClarifyReq {
  clarifyId: string;
  question: string;
  detail: string;
  choices: string[];
}

/** 从payload 取第一个非空字符串字段（服务端字段名不统一） */
function pickAny(p: Record<string, Object>, keys: string[]): string {
  for (const k of keys) {
    const v = p[k];
    if (typeof v === 'string' && (v as string).length > 0) {
      return v as string;
    }
  }
  return '';
}

/** 从 payload 取字符串数组（choices / options） */
function pickStrList(p: Record<string, Object>, keys: string[]): string[] {
  const out: string[] = [];
  for (const k of keys) {
    const v = p[k];
    if (Array.isArray(v)) {
      for (const item of v as Object[]) {
        if (typeof item === 'string') {
          out.push(item as string);
        } else {
          const o = item as Record<string, Object>;
          const label = pickAny(o, ['label', 'name', 'title', 'value', 'choice']);
          if (label.length > 0) {
            out.push(label);
          }
        }
      }
      if (out.length > 0) {
        return out;
      }
    }
  }
  return out;
}

/**
 * 编排器回调容器。
 * ArkTS 不接受「对应 interface 的对象字面量」来构造可选成员全为可选的
 * 结构（arkts-no-untyped-obj-literals），必须用具名 class逐字段赋值。
 */
class GroupChatHooks implements OrchestratorHooks {
  onDelta: (messageId: string, state: StreamState) => void = (): void => {};
  onComplete: (messageId: string, state: StreamState, usage: RunUsage) => void = (): void => {};
  onError: (messageId: string, error: string) => void = (): void => {};
  /** D-R31-2：pump 抽干队列后补一次刷新，消除残留角标 */
  onQueueIdle: (roomId: string) => void = (): void => {};
}

/**
 * 把 socket 的「事件名 + 参数数组」翻译成具名回调。
 *
 * 事件名与载荷形状全部来自实测（2026-10-06，账号 ALEX + 房间「工具」）：
 *   message                GcMessage        一条完整消息（自己发的也会广播回来）
 *   message_stream_delta   GcDelta          正文增量，打字机靠它
 *   message_reasoning_delta GcDelta         推理过程增量（不显示，噪音大）
 *   execution_queue_updated {roomId,items} 队列变化
 *
 * 为什么要有这一层：GcHandlers 只能拿到 (name, args)，
 * 而页面逻辑想要 onMessage(m) / onDelta(d) 这种强类型回调。
 * ArkTS 不允许在对象字面量里写内联函数，所以用具名 class 逐字段转。
 */
class GcEventBridge implements GcHandlers {
  onMessage: (m: GcMessage) => void = (): void => {};
  onDelta: (d: GcDelta) => void = (): void => {};
  onStatus: (status: string) => void = (): void => {};
  /** 流式开始：可以先把「正在输入」占位气泡画出来 */
  onStreamStart: (id: string) => void = (): void => {};
  /** 流式结束：把占位气泡转正（去掉转圈、落最终内容） */
  onStreamEnd: (id: string) => void = (): void => {};
  /** 服务端要求审批（对应 group.approval.requested） */
  onApproval: (req: GcApprovalReq) => void = (): void => {};
  /** 审批已被处理（对应 group.approval.resolved） */
  onApprovalResolved: () => void = (): void => {};
  /** Agent 反问（对应 group.clarification.requested） */
  onClarify: (req: GcClarifyReq) => void = (): void => {};
  /** 澄清已回答（对应 group.clarification.resolved） */
  onClarifyResolved: () => void = (): void => {};

  /** 从payload 里取消息 id（各种事件字段名不统一） */
  private idOf(first: Object): string {
    const o = first as Record<string, Object>;
    for (const k of ['id', 'messageId', 'message_id']) {
      const v = o[k];
      if (typeof v === 'string' && v.length > 0) {
        return v;
      }
    }
    return '';
  }

  onEvent(name: string, args: Object[]): void {
    if (args.length === 0) {
      return;
    }
    const first: Object = args[0];
    if (name === StudioApi.GC_STREAM_DELTA) {
      this.onDelta(first as GcDelta);
      return;
    }
    if (name === StudioApi.GC_MESSAGE) {
      // ⚠ 用量消息（id 以 gcusage_ 开头）**不能当正文显示**。
      //   服务端每次 run 结束都会推一条，内容是 JSON：
      //     {"runId":...,"inputTokens":35061,"outputTokens":185,...}
      //   之前没过滤，用户在聊天流里直接看到一坨 JSON
      //   （实测截图：hermes 回复完「回归」，下面跟着一坨用量数据）。
      //   ⇒ 拦在这里，页面侧就不用各自处理了。
      const msgId = this.idOf(first);
      if (msgId.indexOf('gcusage') === 0) {
        return;
      }
      this.onMessage(first as GcMessage);
      return;
    }
    if (name === StudioApi.GC_STREAM_START) {
      // ⚠ 之前只处理 delta，缺 start/end —— 表现为流式气泡一直转圈不收尾
      const id: string = this.idOf(first);
      if (id.length > 0) {
        this.onStreamStart(id);
      }
      return;
    }
    if (name === StudioApi.GC_STREAM_END) {
      const id: string = this.idOf(first);
      if (id.length > 0) {
        this.onStreamEnd(id);
      }
      return;
    }
    // ── 审批 / 澄清（群聊侧走group.* 前缀，不是 chat-run 那套）──
    if (name === StudioApi.GC_GROUP_APPROVAL_REQ) {
      const o = first as Record<string, Object>;
      const req: GcApprovalReq = {
        approvalId: pickAny(o, ['approvalId', 'approval_id', 'id']),
        title: pickAny(o, ['title', 'tool', 'toolName', 'tool_name', 'summary']),
        detail: pickAny(o, ['detail', 'description', 'message', 'prompt']),
        tool: pickAny(o, ['tool', 'toolName', 'tool_name']),
        choices: pickStrList(o, ['choices', 'options'])
      };
      // 没有明确选项时给「同意 / 拒绝」两个最常见的值，
      // 否则用户点不动（服务端给什么就回什么，别自作聪明改成别的）
      if (req.choices.length === 0) {
        req.choices = ['approve', 'reject'];
      }
      this.onApproval(req);
      return;
    }
    if (name === StudioApi.GC_GROUP_APPROVAL_RESOLVED) {
      this.onApprovalResolved();
      return;
    }
    if (name === StudioApi.GC_GROUP_CLARIFY_REQ) {
      const o = first as Record<string, Object>;
      const req: GcClarifyReq = {
        clarifyId: pickAny(o, ['clarifyId', 'clarify_id', 'requestId', 'request_id', 'id']),
        question: pickAny(o, ['question', 'title', 'message', 'prompt']),
        detail: pickAny(o, ['detail', 'description', 'context']),
        choices: pickStrList(o, ['choices', 'options'])
      };
      this.onClarify(req);
      return;
    }
    if (name === StudioApi.GC_GROUP_CLARIFY_RESOLVED) {
      this.onClarifyResolved();
      return;
    }
  }

  onStatusChanged(status: string): void {
    this.onStatus(status);
  }

  onStatusReport(status: string, detail: string): void {
    this.onStatusChanged(status);
  }
}

@Entry
@Component
struct GroupChatPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('userName') userName: string = '';

  @State roomId: string = '';
  @State roomName: string = '';
  @State agents: RoomAgent[] = [];
  @State messages: GBubble[] = [];
  @State draft: string = '';
  @State pending: number = 0;
  @State agentSheet: boolean = false;
  @State now: number = Date.now();
  /** 房间是否允许 @all（RoomInfo.canMentionAll） */
  @State canMentionAll: boolean = false;

  // ── 群信息面板：邀请码 / Agent 交接链 / 本群记忆 ──
  @State infoSheet: boolean = false;
  @State inviteCode: string = '';
  @State handoffEnabled: boolean = false;
  @State handoffMaxDepth: number = 0;
  @State handoffUnlimited: boolean = false;
  @State memories: MemoryItem[] = [];
  @State memoryDraft: string = '';

  // 流式中的消息列表：messageId → 状态（整体重新赋值才会触发刷新）
  @State liveList: LiveEntry[] = [];
  /**
   * P2-SEQ11：「停止」按钮幂等位。
   *
   * 连点 5 次原先会发起 5 次 abortRoom（幂等所以无副作用），但会弹 5 次 toast、
   * 触发 5 轮 refreshPending。加上这道门：正在停时后续点击直接忽略。
   */
  @State stopping: boolean = false;
  /**
   * P2-SEQ12：发送幂等位（与 stopping 对称）。
   *
   * send() 里有多处 await（查 provider / RoomRepo / dispatch）；期间用户再点一次
   * 「↑」会并行走第二遍 send → 队列出现 2 条重复任务、agent 对同一条消息回两遍。
   * ChatPage 侧靠 `if (this.streaming) return;` 守住，群聊侧原先没有对称保护。
   */
  @State sending: boolean = false;

  // ── 服务端模式（远端操作 PC 上的 Ekko Studio）──
  /** 是否走服务端；false 走本地 orchestrator */
  private serverMode: boolean = false;
  /** 服务端 socket 是否已连上并 join */
  private gcReady: boolean = false;
  /** 群聊 socket 相关方法在 StudioApi 上是实例方法（要持有 socket 状态） */
  private api: StudioApi = new StudioApi();
  /**
   * 服务端流式缓冲：消息 id → 已收到的正文。
   * 用数组而不是 Record：ArkTS 禁止 obj['k'] 动态键访问（arkts-no-props-by-index）。
   */
  private gcStreams: StreamBuf[] = [];

  aboutToAppear() {
    // ⚠ 必须用具名 interface + **点号**访问，不能用 Record + obj['key']。
    //   ArkTS 禁止动态键访问（arkts-no-props-by-index），
    //   `p?.['roomId']` 编译能过但运行时拿不到值 → roomId 空 → 提示「群聊不存在」。
    //   ChatPage 就是因为用了具名 interface 才能正常进入。
    const p = router.getParams() as GcRouteParams | undefined;
    // ⚠ 两个键都要认：正常路由传 roomId，
    //   而**系统通知的 URI 统一用 sessionId**（见 Notify.ets的 AskTarget），
    //   只读 roomId 会导致「点通知进来 → roomId 空 → 提示群聊不存在」。
    this.roomId = p?.roomId ?? p?.sessionId ?? '';
    // 从通知点进来：已经在本页了，socket 再收到审批请求时**不用重复发通知**
    this.fromNotify = (p?.ask ?? '').length > 0;
    if (this.roomId.length === 0) {
      promptAction.showToast({ message: '群聊不存在' });
      const back: router.RouterOptions = { url: 'pages/SessionListPage' };
      router.replaceUrl(back);
      return;
    }
    // 置位后再loadRoom，让 onPageShow 知道首屏已初始化过
    this.appeared = true;

    // 服务端模式：数据与执行都在 PC 上
    this.serverMode = (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
    if (this.serverMode) {
      // 预连 socket 并 join 房间：连不上也要让用户进得来（能看到历史）
      this.ensureGroupSocket();
    }

    this.loadRoom();

    const hooks: GroupChatHooks = new GroupChatHooks();
    hooks.onDelta = (messageId: string, state: StreamState): void => {
      this.upsertLive(messageId, state);
    };
    hooks.onComplete = (messageId: string, _s: StreamState, usage: RunUsage): void => {
      this.removeLive(messageId);
      this.refreshMessages();
      this.refreshPending();
    };
    hooks.onError = (messageId: string, error: string): void => {
      this.removeLive(messageId);
      promptAction.showToast({ message: error });
      this.refreshMessages();
    };
    // D-R31-2：onComplete 早于 pump 置 done（见 Orchestrator.pump），单靠它会
    // 把「正在跑的队列项」读成仍排在队里，角标与「■」不消失。泵抽干后再刷一次。
    hooks.onQueueIdle = (roomId: string): void => {
      if (roomId !== this.roomId) {
        return;
      }
      this.refreshMessages();
      this.refreshPending();
    };
    AgentOrchestrator.setHooks(hooks);
  }

  aboutToDisappear() {
    AgentOrchestrator.setHooks(new GroupChatHooks());
    // 服务端 socket 必须显式断开：daemon 侧的连接会一直留着，
    // 不关的话重新进页面会复用旧连接、且 PC 上会积累僵尸连接。
    if (this.gcReady) {
      this.gcReady = false;
      this.api.disconnectGroupChat();
    }
    // 审批/澄清状态别带出页面：下次进来是新的会话状态，
    // 残留的遮罩会挡住整个界面（实测过一次，退出再进群聊全被遮住点不动）。
    this.approvalReq = null;
    this.clarifyReq = null;
    this.clarifyText = '';
    this.gcConnecting = null;
    cancelAskNotify();
    // 页面退出时清空本房间所有 agent 的对话上下文，避免 static contexts 内存泄漏
    AgentOrchestrator.resetRoom(this.roomId);
  }

  /** 写入/更新一条流式状态（整体重建数组，避开动态键与 delete） */
  private upsertLive(messageId: string, state: StreamState): void {
    const next: LiveEntry[] = [];
    let found = false;
    for (const e of this.liveList) {
      if (e.messageId === messageId) {
        const hit: LiveEntry = { messageId: messageId, state: state };
        next.push(hit);
        found = true;
      } else {
        next.push(e);
      }
    }
    if (!found) {
      const added: LiveEntry = { messageId: messageId, state: state };
      next.push(added);
    }
    this.liveList = next;
  }

  private removeLive(messageId: string): void {
    const next: LiveEntry[] = [];
    for (const e of this.liveList) {
      if (e.messageId !== messageId) {
        next.push(e);
      }
    }
    this.liveList = next;
  }

  onPageShow() {
    // aboutToAppear 里已经 loadRoom（内部含 refreshMessages + refreshPending），
    // 首屏再刷就是三倍查询。首次跳过，返回时才刷新。
    if (this.appeared) {
      this.refreshMessages();
      this.refreshPending();
    }
  }

  /** 临时排查探针 */
  private static probe(msg: string): void {
    try {
      hilog.info(0xD03, 'GcProbe', '%{public}s', msg);
    } catch (e) {
      // 忽略
    }
  }

  /** 等gcReady=true 的等待者队列 */
  private gcConnecting: Promise<boolean> | null = null;
  private scroller: Scroller = new Scroller();

  // ── 审批 / 澄清（群聊走group.* 事件，见 GcEventBridge.onEvent）──
  @State approvalReq: GcApprovalReq | null = null;
  @State clarifyReq: GcClarifyReq | null = null;
  @State clarifyText: string = '';
  /** 是否从系统通知点进来的 —— 已经在这个页面了，别再弹通知 */
  private fromNotify: boolean = false;

  /**
   * 回群聊审批。
   *
   * @param choice 服务端给的选项值，**原样回传**（不要自己编）
   */
  private respondApproval(choice: string): void {
    const req = this.approvalReq;
    if (req === null) {
      return;
    }
    const ok: boolean = this.api.respondGroupApproval(this.roomId, req.approvalId, choice);
    if (ok) {
      this.approvalReq = null;
      cancelAskNotify();
    } else {
      promptAction.showToast({ message: '发送失败，请检查连接' });
    }
  }

  /** 回群聊澄清（有选项就点选项，没选项就填空） */
  private respondClarify(choice: string): void {
    const req = this.clarifyReq;
    if (req === null) {
      return;
    }
    const answer: string = choice.length > 0 ? choice : this.clarifyText.trim();
    if (answer.length === 0) {
      promptAction.showToast({ message: '请输入回答' });
      return;
    }
    const ok: boolean = this.api.respondGroupClarify(this.roomId, req.clarifyId, answer);
    if (ok) {
      this.clarifyReq = null;
      this.clarifyText = '';
      cancelAskNotify();
    } else {
      promptAction.showToast({ message: '发送失败，请检查连接' });
    }
  }

  /**
   * 把消息列表滚到底部。
   *
   * ⚠ ArkUI 的 List **不会**跟随新消息自动滚动（实测 2026-10-07）：
   *   Agent 回复已经在`messages` 里，但视图停在原处，
   *   用户看到的是「消息发了但什么都没变」。
   *
   * @param animate false=瞬时（流式 delta 高频调用，避免动画堆积）
   */
  private scrollToBottom(animate: boolean = false): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 列表尚未就绪时忽略
      }
    }, 60);
  }

  /** socket 层日志，与 SockTrace 同tag（hdc 一次抓全） */
  private static sockLog(msg: string): void {
    try {
      hilog.info(0xD00, 'SockTrace', '%{public}s', `[gc] ${msg}`);
    } catch (e) {
    }
  }

  private appeared: boolean = false;

  private async loadRoom(): Promise<void> {
    if (this.roomId.length === 0) {
      return;
    }
    try {
      GroupChatPage.probe('loadRoom 开始 roomId=' + this.roomId + ' serverMode=' + this.serverMode);
      const room = await RoomRepo.get(AppStore.db(), this.roomId);
      GroupChatPage.probe('get 返回 ' + (room === null ? 'null'
        : ('ok 名称=' + room.name + ' agents=' + (room.agents === undefined ? 0 : room.agents.length))));
      if (room === null) {
        // 只有服务端明确说「没有这个房间」才提示不存在。
        // 之前的写法把 get 返回 null 一律当成不存在，
        // 于是「本地库查不到（因为数据在 PC 上）」也被说成房间不存在 ——
        // 提示语与真实原因不符，排查时极易被带偏。
        promptAction.showToast({ message: '群聊不存在或已被删除' });
        router.back();
        return;
      }
      this.roomName = room.name;
this.canMentionAll = room.canMentionAll === true;
this.agents = room.agents ?? [];
      this.readHandoff(room);
      AppStore.setActiveRoom(this.roomId);
      // 消息加载单独 try：socket 失败不该把整个 loadRoom 拖掉。
      // 之前没有 catch，socket 一卡（无 ack）整条链路就停在这里，
      // 表现是「房间信息出来了但消息区一直空着，也不报错」。
      try {
        await this.refreshMessages();
        GroupChatPage.probe('消息刷新完成 条数=' + this.messages.length);
      } catch (me) {
        GroupChatPage.probe('消息加载失败: ' + (me as Error).message);
        promptAction.showToast({ message: '消息加载失败：' + (me as Error).message });
      }
      await this.refreshPending();
      await this.pumpIfIdle();
    } catch (e) {
      promptAction.showToast({ message: `加载失败: ${(e as Error).message}` });
    }
  }

  /** 交接链配置从 RoomInfo 读，落到 @State 供面板展示与开关 */
  private readHandoff(room: RoomInfo): void {
    this.handoffEnabled = room.agentHandoffEnabled === true;
    this.handoffUnlimited = room.agentHandoffUnlimited === true;
    const d = room.agentHandoffMaxDepth;
    this.handoffMaxDepth = d === null || d === undefined ? 0 : d;
    this.inviteCode = room.inviteCode ?? '';
  }

  private async refreshMessages(): Promise<void> {
    GroupChatPage.probe('refreshMessages 取消息 serverMode=' + (AppStorage.get<string>('dataSource') ?? 'local'));
    const rows = await GroupMessageRepo.page(AppStore.db(), this.roomId, 100);
    this.messages = rows.map((m: GroupMessage) => this.toBubble(m));
    this.scrollToBottom(false);
  }


  private async refreshPending(): Promise<void> {
    this.pending = await QueueRepo.pending(AppStore.db(), this.roomId);
  }

  /** 有排队任务就启动编排（页面重进时补跑） */
  private async pumpIfIdle(): Promise<void> {
    if (this.pending > 0) {
      await AgentOrchestrator.pump(AppStore.db(), this.roomId);
      await this.refreshMessages();
      await this.refreshPending();
    }
  }

  private toBubble(m: GroupMessage): GBubble {
    return {
      id: m.id,
      senderName: m.senderName,
      senderKind: m.senderKind,
      agentId: m.agentId ?? '',
      role: m.role,
      content: m.content,
      timestamp: m.timestamp,
      usageText: m.usage !== undefined && m.usage.totalTokens > 0
        ? `↑${formatNumber(m.usage.inputTokens, 0)} ↓${formatNumber(m.usage.outputTokens, 0)}` : '',
      streaming: false
    };
  }

  /** 输入框里插入 @xxx */
  private insertMention(name: string): void {
    const withSpace = this.draft.length > 0 && !this.draft.endsWith(' ') ? `${this.draft} ` : this.draft;
    this.draft = `${withSpace}@${name} `;
    this.agentSheet = false;
  }

  // ─────────────────────────────────────────────────────
  // 服务端模式：连 /group-chat、join 房间、收发消息
  //
  // 协议全部实测（2026-10-06）：
  //   命名空间必须是 /group-chat（默认 / 收不到任何事件）
  //   join 之后服务端才按房间分发
  //   delta 用 message id 归并（分片共用同一个 id）
  // ─────────────────────────────────────────────────────

  /** 连上服务端并 join 当前房间。返回是否就绪。 */
  private async ensureGroupSocket(): Promise<boolean> {
    if (this.gcReady) {
      return true;
    }
    // ⚠ 已经在建连就直接复用那个 Promise，**不能并发跑第二遍**（实测 2026-10-07）。
    //   两遍会各自connectGroupChat → 第二遍 disconnectGroupChat 把刚建好的连接关掉，
    //   表现为「connected 后 2ms 就 disconnected」，之后每条消息都发不出去。
    if (this.gcConnecting !== null) {
      GroupChatPage.sockLog('ensureGroupSocket: 复用进行中的建连');
      return this.gcConnecting;
    }
    const task: Promise<boolean> = this.doEnsureGroupSocket();
    this.gcConnecting = task;
    const ok: boolean = await task;
    this.gcConnecting = null;
    return ok;
  }

  /** 真正建连+ join 的那段（由 ensureGroupSocket 加锁串行化） */
  private async doEnsureGroupSocket(): Promise<boolean> {
    GroupChatPage.sockLog('ensureGroupSocket: 开始建连');
    const bridge: GcEventBridge = new GcEventBridge();
    bridge.onMessage = (m: GcMessage): void => {
      this.onServerMessage(m);
    };
    bridge.onDelta = (d: GcDelta): void => {
      this.onServerDelta(d);
    };
    bridge.onStatus = (status: string): void => {
      // ⚠ connected 也要把 gcReady 置回 true（实测 2026-10-07）：
      //   只要有过一次 disconnected/error，之后每次发送都会重新建连，
      //   而 connectGroupChat → ensureGroupSocket 是异步链，
      //   期间 gcReady 还是 false，下一次发送又触发一轮 → 卡住发不出去。
      if (status === 'connected') {
        this.gcReady = true;
        GroupChatPage.sockLog('gcReady=true（connected）');
        return;
      }
      if (status === 'disconnected' || status === 'error') {
        this.gcReady = false;
        GroupChatPage.sockLog(`gcReady=false（${status}）`);
      }
    };
    // ⚠ start / end 之前没接 —— 表现为流式气泡一直转圈不收尾，
    //   finishStream() 写了但从来没被调用过。
    bridge.onStreamStart = (id: string): void => {
      GroupChatPage.sockLog(`stream start ${id}`);
    };
    bridge.onStreamEnd = (id: string): void => {
      GroupChatPage.sockLog(`stream end ${id}`);
      this.finishStream(id);
    };
    //审批/澄清：页面不在前台时遮罩看不见 → 必须同时发系统通知
    // ⚠ 通知必须指向**本页**（GroupChatPage），不能是 ChatPage ——
    //   之前路径写死跳单聊，用户点完落到一个空会话，不知道自己在批什么。
    bridge.onApproval = (req: GcApprovalReq): void => {
      GroupChatPage.sockLog(`群聊审批 ${req.approvalId}：${req.title}`);
      this.approvalReq = req;
      // 已经从通知点进来的就别再弹一条（否则点完通知进来、遮罩+通知双重提示）
      if (this.fromNotify) {
        return;
      }
      notifyAsk(req.title.length > 0 ? req.title : '需要审批',
        req.detail.length > 0 ? req.detail : req.tool,
        { id: this.roomId, page: 'pages/GroupChatPage' }, false);
    };
    bridge.onApprovalResolved = (): void => {
      GroupChatPage.sockLog('群聊审批已处理');
      this.approvalReq = null;
      cancelAskNotify();
      // ⚠ 遮罩关掉了但流式气泡还在转（与单聊同问题，真机 21:07 实测）。
      //   服务端在等用户操作时不推 message_stream_end，得自己收尾。
      this.closeAllStreams();
    };
    bridge.onClarify = (req: GcClarifyReq): void => {
      GroupChatPage.sockLog(`群聊澄清 ${req.clarifyId}：${req.question}`);
      this.clarifyReq = req;
      if (this.fromNotify) {
        return;
      }
      notifyAsk('Agent 有问题要问你', req.question,
        { id: this.roomId, page: 'pages/GroupChatPage' }, true);
    };
    bridge.onClarifyResolved = (): void => {
      GroupChatPage.sockLog('群聊澄清已回答');
      this.clarifyReq = null;
      cancelAskNotify();
      this.closeAllStreams();
    };
    const ok = await this.api.connectGroupChat(
      NetConfig.getBaseUrl(), NetConfig.getToken(), this.roomId, bridge);
    GroupChatPage.sockLog(`ensureGroupSocket: connectGroupChat=${ok}`);
    // 以connectGroupChat 的最终结果为准覆盖一次：
    // onStatus('connected') 在 join 完成前就会把 gcReady 置 true，
    // 万一 join 失败，这里必须纠正回来，否则后续发送会误判"已连接"。
    this.gcReady = ok;
    return ok;
  }

  /** 服务端推来一条完整消息（可能是自己发的，也可能是别人的） */
  private onServerMessage(m: GcMessage): void {
    // 自己的消息：send() 里已经乐观插入了，别重复
    for (const b of this.messages) {
      if (b.id === m.id) {
        return;
      }
    }
    // 正在流式中的 id 走 delta 拼装，不用这里插入
    for (const s of this.gcStreams) {
      if (s.id === m.id) {
        return;
      }
    }
    this.messages = this.messages.concat([this.toServerBubble(m)]);
    this.scrollToBottom(true);
  }

  /**
   * 服务端推来一段增量。
   *
   * 同一个 message id 会有多条 delta，拼起来才是完整回复。
   * 用数组而不是 Record：ArkTS 禁止 obj['k'] 动态键访问。
   */
  private onServerDelta(d: GcDelta): void {
    for (let i = 0; i < this.gcStreams.length; i++) {
      if (this.gcStreams[i].id === d.id) {
        const next: StreamBuf[] = this.gcStreams.slice();
        next[i] = { id: d.id, text: next[i].text + d.delta };
        this.gcStreams = next;
        this.showStream(d.id, next[i].text);
        return;
      }
    }
    this.gcStreams = this.gcStreams.concat([{ id: d.id, text: d.delta }]);
    this.showStream(d.id, d.delta);
  }

  /** 把流式缓冲显示成一条「正在输入」的气泡 */
  /**
 * 关掉所有还在流式的气泡。
 *
 * ⚠ 服务端在等用户批准 / 回答澄清时**不推** `message_stream_end`，
 *   所以遮罩一关，若不手动收尾，界面就一直转圈（真机 21:07 实测）。
 */
private closeAllStreams(): void {
    if (this.gcStreams.length === 0) {
      return;
    }
    const next: GBubble[] = this.messages.map((b: GBubble) => {
      if (!b.streaming) {
        return b;
      }
      const fixed: GBubble = {
        id: b.id,
        senderName: b.senderName,
        senderKind: b.senderKind,
        agentId: b.agentId,
        role: b.role,
        content: b.content.length > 0 ? b.content : '（已处理）',
        timestamp: b.timestamp,
        usageText: b.usageText,
        streaming: false
      };
      return fixed;
    });
    this.messages = next;
    this.gcStreams = [];
}

private showStream(id: string, text: string): void {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === id) {
        // ⚠⚠ 占位气泡已存在时**不能直接 return** —— onServerDelta 传进来的
        //   text 是拼好的全文，return 等于把「打字机」冻结在第一段增量，
        //   finishStream 前用户看到的一直是一句残文（真机 2026-10-07 实测）。
        //   必须把最新缓冲整体写回该气泡（@State 数组要整体重建）。
        const old: GBubble = this.messages[i];
        if (old.content === text) {
          return;
        }
        const grown: GBubble = {
          id: old.id,
          senderName: old.senderName,
          senderKind: old.senderKind,
          agentId: old.agentId,
          role: old.role,
          content: text,
          timestamp: old.timestamp,
          usageText: old.usageText,
          streaming: true
        };
        const next: GBubble[] = this.messages.slice();
        next[i] = grown;
        this.messages = next;
        this.scrollToBottom(true);
        return;
      }
    }
    const bubble: GBubble = {
      id: id,
      senderName: '…',
      senderKind: 'agent',
      agentId: '',
      role: 'assistant',
      content: text,
      timestamp: Date.now(),
      usageText: '',
      streaming: true
    };
    this.messages = this.messages.concat([bubble]);
    this.scrollToBottom(true);
  }

  /** 增量结束：固化内容并清缓冲（服务端没有明确的 end 事件，靠 message 补齐） */
  private finishStream(id: string): void {
    const next: StreamBuf[] = [];
    let found = '';
    for (const s of this.gcStreams) {
      if (s.id === id) {
        found = s.text;
      } else {
        next.push(s);
      }
    }
    this.gcStreams = next;
    if (found.length === 0) {
      return;
    }
    for (const b of this.messages) {
      if (b.id === id) {
        const arr = this.messages.slice();
        for (let i = 0; i < arr.length; i++) {
          if (arr[i].id === id) {
            arr[i] = { id: id, senderName: b.senderName, senderKind: b.senderKind,
              agentId: b.agentId, role: b.role, content: found,
              timestamp: b.timestamp, usageText: b.usageText, streaming: false };
          }
        }
        this.messages = arr;
        this.scrollToBottom(false);
        return;
      }
    }
  }

  /** 服务端 GcMessage → 本地气泡 */
  private toServerBubble(m: GcMessage): GBubble {
    const isAgent: boolean = m.senderId.indexOf('auth:') !== 0;
    return {
      id: m.id,
      senderName: m.senderName,
      senderKind: isAgent ? 'agent' : 'human',
      agentId: '',
      role: m.role,
      content: m.content,
      timestamp: m.timestamp,
      usageText: '',
      streaming: false
    };
  }

  /** 服务端模式：发消息 */
  private async sendViaServer(text: string, mentions: MentionRef[]): Promise<boolean> {
    const ready: boolean = await this.ensureGroupSocket();
    GroupChatPage.sockLog(`sendViaServer: ensureGroupSocket=${ready} room=${this.roomId}`);
    if (!ready) {
      promptAction.showToast({ message: '未连接到服务端' });
      return false;
    }
    const gms: GcMention[] = [];
    for (const m of mentions) {
      // 本地 MentionRef.displayName 是可选的，服务端 GcMention 要求必填 —— 用 participantId 兜底
      gms.push({
        type: m.type,
        participantId: m.participantId,
        displayName: m.displayName ?? m.participantId
      });
    }
    const id = 'gc_' + Date.now().toString();
    // ⚠ 这段 catch 不是死代码：ready 检查（ensureGroupSocket）之后、
    //   sendGroupMessage 执行之前，连接仍可能在瞬间断开（服务端踢人/网络抖动），
    //   此时 emitNoAck 返回 false → sendGroupMessage throw。保留 catch 兜底，
    //   避免未处理异常冒泡到 send()（send() 的 serverMode 分支没有 try/catch）。
    try {
      await this.api.sendGroupMessage(this.roomId, id, text, gms);
      GroupChatPage.sockLog(`sendViaServer: 已发出 id=${id}`);
      // 自己那条也会被服务端广播回来，onServerMessage 会插入
      return true;
    } catch (e) {
      GroupChatPage.sockLog(`sendViaServer 失败：${errorMessage(e as Error)}`);
      promptAction.showToast({ message: '发送失败：' + errorMessage(e) });
      return false;
    }
  }

  /**
   * P1-SEQ7-④（ALEX 拍板方案 a）：群聊「停止」入口，接 Orchestrator.abortRoom。
   *
   * 之前 abort() 全项目零调用 —— 队列里排着的任务在用户点「停止」后照跑，
   * 症状「停止后还在烧 token」。这里补上真实调用点。
   *
   * 本地模式：中止本房间所有正在跑的 run + 取消所有 queued 任务。
   * 服务端模式：agent 跑在 PC 上，本地队列为空，没有可停的东西 ——
   *   明确提示而不是假装停掉（服务端停止接口当前不存在）。
   */
  private async stopAll(): Promise<void> {
    if (this.stopping) {
      return;
    }
    if (this.serverMode) {
      promptAction.showToast({ message: '回复由 PC 端执行，请到服务端停止' });
      return;
    }
    this.stopping = true;
    try {
      const stopped = await AgentOrchestrator.abortRoom(AppStore.db(), this.roomId);
      // 立刻清掉流式占位：abort 的 onComplete 收尾是异步的，先给用户即时反馈。
      // 随后 onComplete/onError 会 refreshMessages，把已落库的半截回复显示出来。
      this.liveList = [];
      await this.refreshPending();
      promptAction.showToast({ message: stopped > 0 ? '已停止正在生成的回复' : '已取消排队任务' });
    } finally {
      this.stopping = false;
    }
  }

  private async send(): Promise<void> {
    const text = this.draft.trim();
    if (text.length === 0) {
      GroupChatPage.sockLog(`send: 空内容，直接返回`);
      return;
    }
    // P2-SEQ12：发送幂等位。连点两次否则会在两次 await 之间各跑一遍
    //   → 队列 2 条重复任务、agent 回两遍。与 stopAll 的 stopping 同款修法。
    if (this.sending) {
      GroupChatPage.sockLog(`send: 正在发送中，忽略重复点击`);
      return;
    }
    this.sending = true;
    try {
      await this.sendInner(text);
    } finally {
      // 异常路径也复位，避免一次失败后发送按钮永久禁用
      this.sending = false;
    }
  }

  /** send 的实体；入口守卫与幂等位在 send() 里，见上。 */
  private async sendInner(text: string): Promise<void> {
    GroupChatPage.sockLog(`send: 收到文本「${text.substring(0, 20)}」serverMode=${this.serverMode}`);

    // 解析 @ 提及：用 agentId，不是房间记录 id
    //
    // ⚠ 服务端模式必须用 `this.agents`（来自服务端 room.agents），
    //   **不能查本地库** —— 服务端模式下所有本地库写入都被 blockLocalWrite 拦掉，
    //   `RoomAgentRepo.mentionCandidates()` 走本地 SQL 必然返回空，
    //   于是 resolveMentions 拿不到任何候选 → 校验永远判定「没@ Agent」→ 发不出去。
    //   （实测 2026-10-07：工具 Copy 群有 8 个 Agent，candidates 却是 0）
    let candidates: MentionCandidate[] = [];
    if (this.serverMode) {
      for (const a of this.agents) {
        const c: MentionCandidate = {
          agentId: a.agentId,
          recordId: a.id,
          name: a.name,
          removedAt: a.removedAt ?? 0,
          canMentionAll: this.canMentionAll
        };
        candidates.push(c);
      }
    } else {
      const rows = await RoomAgentRepo.mentionCandidates(AppStore.db(), this.roomId);
      for (const row of rows) {
        const c: MentionCandidate = {
          agentId: row.agentId,
          recordId: row.recordId,
          name: row.name,
          removedAt: row.removedAt,
          canMentionAll: this.canMentionAll
        };
        candidates.push(c);
      }
    }
    GroupChatPage.sockLog(`send: 候选 ${candidates.length} 个（serverMode=${this.serverMode}）`);
    const refs: CoreMentionRef[] = resolveMentions(text, candidates);
    GroupChatPage.sockLog(`send: mentions解析出 ${refs.length} 个`);

    const errMsg = validateGroupMessage(text, refs);
    if (errMsg.length > 0) {
      GroupChatPage.sockLog(`send: 校验不通过「${errMsg}」`);
      promptAction.showToast({ message: errMsg });
      return;
    }

    // 校验用 Core 的 MentionRef，交给 orchestrator 前转成 model/Types 的 MentionRef
    const mentions: MentionRef[] = [];
    for (const r of refs) {
      const m: MentionRef = {
        type: toMentionType(r.type),
        participantId: r.participantId,
        displayName: r.displayName
      };
      mentions.push(m);
    }

    // 服务端模式：API Key 在 PC 上，手机不用校验本地 provider，直接走 socket
    if (this.serverMode) {
      GroupChatPage.sockLog(`send: 服务端模式，清空 draft 并发往 socket`);
      this.draft = '';
      const ok = await this.sendViaServer(text, mentions);
      // ⚠ 发送失败要把草稿还回去，否则用户辛苦打的字凭空消失
      //   （实测踩过：draft 被清空 + Toast一闪而过，用户以为没发出去也没内容可重打）
      if (!ok) {
        this.draft = text;
      }
      GroupChatPage.sockLog(`send: sendViaServer=${ok}`);
      return;
    }

    // 本地模式：检查这些 agent 是否配置了可用的 provider
    const bad = this.agents.filter((a: RoomAgent) =>
      mentions.some((m: MentionRef) => m.participantId === a.agentId));
    for (const a of bad) {
      const p = await ProviderRepo.get(AppStore.db(), a.provider);
      // 服务端模式下 PC 侧才有 key，手机端拿不到是正常的
      if (p !== null && p.apiKey === '__server_side__') {
        continue;
      }
      // Scheme A：三态校验。undecryptable 单独提示，区别于「未填」。
      if (p !== null && p.apiKeyState === 'undecryptable') {
        promptAction.showToast({ message: `「${a.name}」API Key 解密失败，请到「Agent 管理」重新填写` });
        return;
      }
      if (p === null || p.apiKeyState === 'empty' || p.apiKey.trim().length === 0) {
        promptAction.showToast({ message: `「${a.name}」尚未配置 API Key，请到「Agent 管理」设置` });
        return;
      }
    }

    this.draft = '';
    const room = await RoomRepo.get(AppStore.db(), this.roomId);
    if (room === null) {
      return;
    }

    const count = await AgentOrchestrator.dispatch(
      AppStore.db(), room, text, mentions, this.userName.length > 0 ? this.userName : '我');
    await this.refreshMessages();
    await this.refreshPending();

    if (count === 0) {
      promptAction.showToast({ message: '没有匹配到 Agent，请检查 @ 的名字' });
    }
  }

  private async addAgent(): Promise<void> {
    // 快捷添加：从全局 Agent 配置里挑一个
    const globals = AppStore.agents();
    if (globals.length === 0) {
      promptAction.showToast({ message: '请先在「Agent 管理」里创建 Agent' });
      return;
    }
    const existing = this.agents.map((a) => a.agentId);
    const candidates = globals.filter((g) => !existing.some((id) => id.endsWith(g.id)));
    if (candidates.length === 0) {
      promptAction.showToast({ message: '全局 Agent 都已在本群' });
      return;
    }
    const g = candidates[0];
    const now = Date.now();
    const ra: RoomAgent = {
      id: shortId(now, Math.random()),
      // roomId 必填：upsert 靠它把Agent 归到本房间，
      // 漏了会导致「加进群 → 刷新就消失」。
      roomId: this.roomId,
      agentId: `room-${this.roomId}-${g.id}`,
      agent: g.runtime,
      agentMode: 'scoped',
      profile: '',
      provider: g.provider,
      model: g.model,
      apiMode: g.apiMode,
      reasoningEffort: g.reasoningEffort,
      name: g.name,
      description: g.systemPrompt,
      avatar: '',
      invited: 1,
      executorType: 'server',
      connectionStatus: 'online'
    };
    await RoomAgentRepo.upsert(AppStore.db(), ra, now);
    await this.loadRoom();
    promptAction.showToast({ message: `已添加「${g.name}」` });
  }

  private async removeAgent(a: RoomAgent): Promise<void> {
    const res = await promptAction.showDialog({
      title: '移出群聊',
      message: `确定把「${a.name}」移出本群？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '移出', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await RoomAgentRepo.remove(AppStore.db(), a.id, Date.now());
    await this.loadRoom();
  }

  // ───────────────── 群信息面板 ─────────────────

  private async openInfo(): Promise<void> {
    await this.loadMemories();
    this.infoSheet = true;
  }

  /**
   * 生成邀请码。
   * 生成后立刻用 RoomRepo.setInviteCode 落库 —— 之前只写 @State，
   * 页面一退出邀请码就没了。
   */
  private async generateInviteCode(): Promise<void> {
    const code = makeInviteCode();
    try {
      await RoomRepo.setInviteCode(AppStore.db(), this.roomId, code);
      this.inviteCode = code;
    } catch (e) {
      // 落库失败就不改 @State，避免展示一个其实没存下来的码
      promptAction.showToast({ message: `生成邀请码失败: ${(e as Error).message}` });
      return;
    }
    const ok = await copyToClipboard(this.inviteCode);
    promptAction.showToast({ message: ok ? `邀请码 ${this.inviteCode} 已复制` : `邀请码 ${this.inviteCode}` });
  }

  private async copyInviteCode(): Promise<void> {
    if (this.inviteCode.length === 0) {
      promptAction.showToast({ message: '还没有邀请码' });
      return;
    }
    const ok = await copyToClipboard(this.inviteCode);
    promptAction.showToast({ message: ok ? '邀请码已复制' : '复制失败' });
  }

  /**
   * 交接链配置落库。
   * maxDepth 语义：0 表示「跟随默认」，库里存 NULL；1~10 存实际值。
   * 三个入口（开关 / 无限 / 深度）都走这里，保证任何一次变更都写回。
   */
  private async persistHandoff(): Promise<void> {
    if (this.roomId.length === 0) {
      return;
    }
    const depth: number | null = this.handoffMaxDepth > 0 ? this.handoffMaxDepth : null;
    try {
      await RoomRepo.setAgentHandoff(
        AppStore.db(), this.roomId, this.handoffEnabled, depth, this.handoffUnlimited, Date.now());
    } catch (e) {
      promptAction.showToast({ message: `保存交接配置失败: ${(e as Error).message}` });
    }
  }

  /**
   * 交接链开关。
   * 先切本地状态再落库，UI 立即响应；写回走 RoomRepo.setAgentHandoff，
   * 之前只存 @State，重启即丢。
   */
  private async toggleHandoff(): Promise<void> {
    this.handoffEnabled = !this.handoffEnabled;
    await this.persistHandoff();
    promptAction.showToast({
      message: this.handoffEnabled ? '已开启 Agent 交接' : '已关闭 Agent 交接'
    });
  }

  private async toggleUnlimited(): Promise<void> {
    this.handoffUnlimited = !this.handoffUnlimited;
    await this.persistHandoff();
  }

  private async setMaxDepth(delta: number): Promise<void> {
    let d = this.handoffMaxDepth + delta;
    if (d < 0) {
      d = 0;
    }
    if (d > 10) {
      d = 10;
    }
    this.handoffMaxDepth = d;
    await this.persistHandoff();
  }

  /** 本群记忆：effective 会把全局记忆一起带出来（全局对所有房间生效） */
  private async loadMemories(): Promise<void> {
    if (this.roomId.length === 0) {
      return;
    }
    try {
      this.memories = await MemoryRepo.effective(AppStore.db(), 'room', this.roomId);
    } catch (e) {
      this.memories = [];
    }
  }

  private async addMemory(): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已加入本群记忆」假成功 toast
    if (blockLocalWrite('记忆')) {
      return;
    }
    const text = this.memoryDraft.trim();
    if (text.length === 0) {
      promptAction.showToast({ message: '先写点内容' });
      return;
    }
    await MemoryRepo.add(AppStore.db(), 'room', this.roomId, 'note', text, Date.now());
    this.memoryDraft = '';
    await this.loadMemories();
    promptAction.showToast({ message: '已加入本群记忆' });
  }

  private async removeMemory(m: MemoryItem): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已删除」假成功 toast
    if (blockLocalWrite('记忆')) {
      return;
    }
    await MemoryRepo.remove(AppStore.db(), m.id);
    await this.loadMemories();
    promptAction.showToast({ message: '已删除' });
  }

  private async togglePinMemory(m: MemoryItem): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路
    if (blockLocalWrite('记忆')) {
      return;
    }
    await MemoryRepo.setPinned(AppStore.db(), m.id, !m.pinned);
    await this.loadMemories();
  }

  build() {
    // 外层 Stack 只为承载覆盖层面板。
    // 不用 bindSheet：实测同一节点只能挂一个 bindSheet，挂第二个会覆盖第一个
    //（症状：点成员没反应、点群信息却弹出成员、关掉后又弹出群信息）。
    Stack() {
      Column() {
        // ── 顶栏 ──
        Row({ space: 12 }) {
          Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
            .width(24)
            .onClick(() => router.back())
          Column({ space: 2 }) {
            Text(this.roomName.length > 0 ? this.roomName : '群聊')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
              .maxLines(1)
            Text(`${this.agents.length} 个 Agent${this.pending > 0 ? ` · ${this.pending} 个排队中` : ''}`)
              .fontSize(11)
              .fontColor(this.pending > 0 ? Tok.warn : Tok.text3(this.dark))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('成员').fontSize(13).fontColor(Tok.brand)
            .padding({ left: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.agentSheet = true;
            })

          Text('群信息').fontSize(13).fontColor(Tok.brand)
            .padding({ left: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.openInfo();
            })
        }
        .width('100%')
        .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })
        .backgroundColor(Tok.pageBg(this.dark))

        // ── 消息列表 ──
        if (this.messages.length === 0) {
          EmptyState({
            icon: '👥',
            text: '群里还很安静',
            hint: this.agents.length === 0 ? '先点右上角「成员」加几个 Agent' : '输入 @名字 提问'
          })
          Blank()
        } else {
          List({ space: 12, scroller: this.scroller }) {
            ForEach(this.messages, (b: GBubble) => {
              ListItem() {
                this.bubbleView(b)
              }
              // ⚠ 同 ChatPage：key 只用 b.id 会让同 id 新对象（流式增长/
              //   收尾/改名）全部不重建，气泡冻结在首帧（真机实测同款）。
              //   key 带上会变的字段，变了才重建该项。
            }, (b: GBubble) => `${b.id}:${b.streaming ? 1 : 0}:${b.content.length}:${b.senderName.length}:${b.usageText.length}`)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: Tok.pagePad, right: Tok.pagePad })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }

        // ── 输入区 ──
        Row({ space: 8 }) {
          Text('@').fontSize(20).fontColor(Tok.brand)
            .width(24)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.agentSheet = true;
            })
          TextArea({ placeholder: '@Agent 说点什么…', text: this.draft })
            .layoutWeight(1)
            .height(40)
            .fontSize(15)
            .backgroundColor(Tok.cardBg(this.dark))
            .borderRadius(Tok.radius)
            .maxLength(4000)
            .onChange((v: string) => {
              this.draft = v;
            })
          // P1-SEQ7-④：有待执行任务（queued/running）时显示「停止」。
          // 本地编排模式下点了它 → Orchestrator.abortRoom → 中止在跑的 run
          // 并取消所有排队任务，泵随即退出，不再烧 token。
          if (this.pending > 0) {
            Button('■', { type: ButtonType.Circle })
              .width(44)
              .height(44)
              .fontSize(18)
              .fontColor('#FFFFFF')
              .backgroundColor(this.stopping ? Tok.text3(this.dark) : Tok.danger)
              // P2-SEQ11：连点只生效一次，停止中置灰防重复触发。
              .enabled(!this.stopping)
              .onClick(() => {
                this.stopAll();
              })
          }
          Button('↑', { type: ButtonType.Circle })
            .width(44)
            .height(44)
            .fontSize(20)
            .fontColor('#FFFFFF')
            .backgroundColor(this.draft.trim().length > 0 ? Tok.brand : Tok.text3(this.dark))
            // P2-SEQ12：发送中置灰 + 禁用，防连点重复入队
            .enabled(this.draft.trim().length > 0 && !this.sending)
            .onClick(() => {
              this.send();
            })
        }
        .width('100%')
        .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 8, bottom: 10 })
        .backgroundColor(Tok.pageBg(this.dark))
      }
      .width('100%')
      .height('100%')

      // ── 面板覆盖层：成员 / 群信息 二选一 ──
      this.panelOverlay()

      // ── 审批 / 澄清遮罩（优先级最高，压在面板之上）──
      this.askOverlay()
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 审批 / 澄清遮罩。
   *
   * 为什么要遮罩：Agent 在 PC 上跑，审批请求是**反向提问** ——
   * 用户必须能就地回答，否则 run 永远卡在那儿。
   * 页面在后台时用户看不到遮罩，所以同时发系统通知（见 build 里的 bridge 回调）。
   *
   * ⚠ 不能用 bindSheet：同一节点只能挂一个，
   *   而本页面已经有 panelOverlay（成员/群信息）占用了（实测会互相覆盖）。
   */
  @Builder
  askOverlay() {
    if (this.approvalReq !== null || this.clarifyReq !== null) {
      Stack({ alignContent: Alignment.Center }) {
        // 半透明遮罩：**不能**绑 onClick 关闭 ——
        // 审批必须明确表态（同意/拒绝），点外面关掉等于让 run 永久卡住。
        Column() {}
          .width('100%')
          .height('100%')
          .backgroundColor(this.dark ? '#B3000000' : '#88000000')

        Column({ space: 12 }) {
          if (this.approvalReq !== null) {
            Text('需要你确认')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
            if (this.approvalReq.title.length > 0) {
              Text(this.approvalReq.title)
                .fontSize(15)
                .fontColor(Tok.text1(this.dark))
                .maxLines(3)
            }
            if (this.approvalReq.detail.length > 0) {
              Text(this.approvalReq.detail)
                .fontSize(13)
                .fontColor(Tok.text3(this.dark))
                .maxLines(5)
            }
            Row({ space: 10 }) {
              ForEach(this.approvalReq.choices, (c: string) => {
                Button(c)
                  .fontSize(14)
                  .layoutWeight(1)
                  .backgroundColor(Tok.brand)
                  .fontColor('#FFFFFF')
                  .onClick(() => this.respondApproval(c))
              }, (c: string) => c)
            }
            .width('100%')
          } else if (this.clarifyReq !== null) {
            Text('Agent 有问题要问你')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
            if (this.clarifyReq.question.length > 0) {
              Text(this.clarifyReq.question)
                .fontSize(15)
                .fontColor(Tok.text1(this.dark))
                .maxLines(4)
            }
            if (this.clarifyReq.detail.length > 0) {
              Text(this.clarifyReq.detail)
                .fontSize(13)
                .fontColor(Tok.text3(this.dark))
                .maxLines(5)
            }
            if (this.clarifyReq.choices.length > 0) {
              Column({ space: 8 }) {
                ForEach(this.clarifyReq.choices, (c: string) => {
                  Button(c)
                    .fontSize(14)
                    .width('100%')
                    .backgroundColor(Tok.cardBg(this.dark))
                    .fontColor(Tok.text1(this.dark))
                    .onClick(() => this.respondClarify(c))
                }, (c: string) => c)
              }
              .width('100%')
            } else {
              // 没给选项 → 必须能自由输入
              TextArea({ placeholder: '输入你的回答…', text: this.clarifyText })
                .width('100%')
                .height(72)
                .fontSize(14)
                .backgroundColor(Tok.cardBg(this.dark))
                .borderRadius(Tok.radius)
                .onChange((v: string) => {
                  this.clarifyText = v;
                })
              Button('发送回答')
                .fontSize(14)
                .width('100%')
                .backgroundColor(Tok.brand)
                .fontColor('#FFFFFF')
                .onClick(() => this.respondClarify(''))
            }
          }
        }
        .padding(20)
        .width('86%')
        .backgroundColor(this.dark ? '#1E1E1E' : '#FFFFFF')
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
    }
  }

  /**
   * 面板覆盖层（不用 bindSheet）。
   *
   * 成员面板和群信息面板共用这一个挂载点，靠 agentSheet / infoSheet
   * 两个状态互斥切换 —— 避开了「一个节点只能挂一个 bindSheet」的坑。
   */
  @Builder
  panelOverlay() {
    if (this.agentSheet || this.infoSheet) {
      Stack({ alignContent: Alignment.Bottom }) {
        // 半透明遮罩，点它关闭
        Column() {}
          .width('100%')
          .height('100%')
          .backgroundColor(this.dark ? '#99000000' : '#66000000')
          .onClick(() => {
            this.closePanels();
          })

        // 面板本体
        Column() {
          Row() {
            Text(this.agentSheet ? '群成员' : '群信息')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
              .layoutWeight(1)
            Text('✕')
              .fontSize(18)
              .fontColor(Tok.text3(this.dark))
              .width(28)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.closePanels();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 8 })

          // ⚠ 内容必须放 Scroll 里：agent 数量不可控（PC 上可能十几个），
          //   固定 68% 高度下不滚动 → 底部的 agent 看不到，
          //   表现得像「面板里只列了几个就到底了」。
          Scroll() {
            Column() {
              if (this.agentSheet) {
                this.agentSheetContent()
              } else {
                this.infoSheetContent()
              }
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        // 用 constraintSize 而不是固定 height('68%')：
        // 内容少时面板贴着内容高度（不浪费屏幕），
        // 内容多时封顶并滚动。
        .constraintSize({ maxHeight: '68%' })
        .backgroundColor(Tok.cardBg(this.dark))
        .borderRadius({ topLeft: 16, topRight: 16 })
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  bubbleView(b: GBubble) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Circle({ width: 18, height: 18 })
          .fill(b.senderKind === 'human' ? Tok.brand : Tok.success)
        Text(b.senderName)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(b.senderKind === 'human' ? Tok.brand : Tok.success)
        Text(relativeTime(b.timestamp, this.now))
          .fontSize(10)
          .fontColor(Tok.text3(this.dark))
      }
      .width('100%')

      // Card 组件没有 @BuilderParam，不能用尾随 lambda 传内容，
      // 所以这里用同样配色的Column 本地承载气泡卡片。
      Column({ space: 4 }) {
        if (b.content.length > 0) {
          // dark 是 @StorageProp，由AppStorage 自动注入，不能在调用处传
          MdText({ source: b.content, fontSize: 15 })
        } else {
          StreamingDots({})
        }
        if (b.usageText.length > 0) {
          Text(b.usageText)
            .fontSize(10)
            .fontColor(Tok.text3(this.dark))
            .fontFeature(Tok.TNUM)
            .width('100%')
            .textAlign(TextAlign.End)
        }
      }
      .width('100%')
      .padding(12)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(Tok.cardBg(this.dark))
      .borderRadius(Tok.radius)
      .border({ width: 1, color: Tok.line(this.dark) })
    }
  }
  @Builder
  agentSheetContent() {
    Scroll() {
      Column({ space: 10 }) {
        Text('群成员')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .width('100%')

        if (this.agents.length === 0) {
          Text('还没有 Agent。点下面「添加 Agent」把全局配置搬进来。')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .margin({ top: 10, bottom: 10 })
        }

        ForEach(this.agents, (a: RoomAgent) => {
          Row({ space: 12 }) {
            Circle({ width: 32, height: 32 }).fill(Tok.success)
            Column({ space: 2 }) {
              Text(a.name)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tok.text1(this.dark))
              Text(`${a.model.length > 0 ? a.model : '未选模型'} · ${a.agent}`)
                .fontSize(11)
                .fontColor(Tok.text3(this.dark))
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('提及').fontSize(12).fontColor(Tok.brand)
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => this.insertMention(a.name))
            Text('移出').fontSize(12).fontColor(Tok.danger)
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick(() => this.removeAgent(a))
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
          .borderRadius(Tok.radiusSmall)
        }, (a: RoomAgent) => a.id)

        Button('＋ 添加 Agent')
          .width('100%')
          .height(42)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor(Tok.brand)
          .borderRadius(Tok.radiusSmall)
          .onClick(() => this.addAgent())

        Button('关闭')
          .width('100%')
          .height(38)
          .fontSize(14)
          .fontColor(Tok.text2(this.dark))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.agentSheet = false;
          })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }

  /** 关闭任一面板 */
  private closePanels(): void {
    this.agentSheet = false;
    this.infoSheet = false;
  }

  /** 群信息面板：邀请码 + Agent 交接链 + 本群记忆 */
  @Builder
  infoSheetContent() {
    Scroll() {
      Column({ space: 10 }) {
        // ── 邀请码 ──
        SectionTitle({ text: '邀请码' })

        Row({ space: 10 }) {
          Text(this.inviteCode.length > 0 ? this.inviteCode : '尚未生成')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.inviteCode.length > 0 ? Tok.brand : Tok.text3(this.dark))
            .fontFeature(Tok.TNUM)
            .layoutWeight(1)
          Text('复制')
            .fontSize(12)
            .fontColor(Tok.brand)
            .padding({ left: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.copyInviteCode();
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
        .borderRadius(Tok.radiusSmall)

        Button(this.inviteCode.length > 0 ? '重新生成邀请码' : '生成邀请码')
          .width('100%')
          .height(40)
          .fontSize(14)
          .fontColor(Tok.brand)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: Tok.brand })
          .borderRadius(Tok.radiusSmall)
          .onClick(() => {
            this.generateInviteCode();
          })

        // ── Agent 交接链 ──
        SectionTitle({ text: 'Agent 交接链' })

        Row() {
          Column({ space: 2 }) {
            Text('启用交接')
              .fontSize(14)
              .fontColor(Tok.text1(this.dark))
            Text('被 @ 的 Agent 可以把任务接力给下一个 Agent')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.handoffEnabled })
            .selectedColor(Tok.brand)
            .onChange((on: boolean) => {
              this.handoffEnabled = on;
              this.persistHandoff();
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
        .borderRadius(Tok.radiusSmall)

        Row() {
          Text('最大交接深度')
            .fontSize(14)
            .fontColor(Tok.text1(this.dark))
            .layoutWeight(1)
          Text('−')
            .fontSize(18)
            .fontColor(this.handoffMaxDepth > 0 ? Tok.brand : Tok.text3(this.dark))
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.setMaxDepth(-1);
            })
          Text(handoffDepthText(this.handoffMaxDepth === 0 ? null : this.handoffMaxDepth))
            .fontSize(14)
            .fontColor(Tok.text1(this.dark))
            .fontFeature(Tok.TNUM)
            .width(52)
            .textAlign(TextAlign.Center)
          Text('＋')
            .fontSize(18)
            .fontColor(Tok.brand)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.setMaxDepth(1);
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
        .borderRadius(Tok.radiusSmall)

        Row() {
          Column({ space: 2 }) {
            Text('不限交接层数')
              .fontSize(14)
              .fontColor(Tok.text1(this.dark))
            Text('打开后忽略上面的深度限制')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.handoffUnlimited })
            .selectedColor(Tok.brand)
            .onChange((on: boolean) => {
              this.handoffUnlimited = on;
              this.persistHandoff();
            })
        }
        .width('100%')
        .padding(12)
        .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
        .borderRadius(Tok.radiusSmall)

        // ── 本群记忆 ──
        SectionTitle({ text: '本群记忆', trailing: `${this.memories.length} 条` })

        Text('这里的记忆会在本群提问时注入给Agent。')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')

        if (this.memories.length === 0) {
          Text('还没有记忆。')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .padding({ top: 8, bottom: 8 })
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
                Text(this.memoryDate(m))
                  .fontSize(10)
                  .fontColor(Tok.text3(this.dark))
              }
              .width('100%')

              Text(m.content)
                .fontSize(13)
                .fontColor(Tok.text1(this.dark))
                .width('100%')
                .maxLines(6)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Row({ space: 14 }) {
                Text(m.pinned ? '取消置顶' : '置顶')
                  .fontSize(11)
                  .fontColor(Tok.brand)
                  .onClick(() => {
                    this.togglePinMemory(m);
                  })
                Text('删除')
                  .fontSize(11)
                  .fontColor(Tok.danger)
                  .onClick(() => {
                    this.removeMemory(m);
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
            .borderRadius(Tok.radiusSmall)
            .alignItems(HorizontalAlign.Start)
          }, (m: MemoryItem) => m.id)
        }

        TextArea({ placeholder: '记一条本群约定或结论…', text: this.memoryDraft })
          .width('100%')
          .height(64)
          .fontSize(14)
          .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
          .borderRadius(Tok.radiusSmall)
          .maxLength(500)
          .onChange((v: string) => {
            this.memoryDraft = v;
          })

        Button('加入本群记忆')
          .width('100%')
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor(Tok.brand)
          .borderRadius(Tok.radiusSmall)
          .onClick(() => {
            this.addMemory();
          })

        Button('关闭')
          .width('100%')
          .height(38)
          .fontSize(14)
          .fontColor(Tok.text2(this.dark))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.infoSheet = false;
          })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }

  private memoryDate(m: MemoryItem): string {
    return relativeTime(m.updatedAt, this.now);
  }
}