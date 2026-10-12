/**
 * 会话列表页：单聊 + 群聊两个 Tab。
 * 对应原版 SessionListView + GroupChatListView。
 *
 * 增强点（不动原有功能，只往上叠）：
 *  - 分类 Tab：全部 / 未分类 / 已归档，分类名存 prefs
 *  - 归档：长按菜单归档，「已归档」分类里可恢复
 *  - 分享链接：长按菜单生成 token，可复制、可撤销
 *  - 宽屏（expanded）：列表常驻左栏，点会话不跳转，改更新右栏详情
 */

import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { SessionSummary, RoomInfo, Provider } from '../model/Types';
import { SessionRepo, RoomRepo } from '../data/Repos';
import { ShareRepo, ArchiveRepo, PrefsRepo } from '../data/ExtendRepos';
import { SessionShare, SessionArchive, Breakpoint, LayoutPrefs } from '../model/Extend';
import { AppStore } from '../viewmodel/AppStore';
import { blockLocalWrite } from '../viewmodel/ServerMode';
import { NetConfig } from '../net/Http';
import { StudioApi } from '../net/StudioApi';
import {
  relativeTime, sortSessionIndexes, SessionSortItem, previewOf, shortId, clampRatio
} from '../common/Core';
import { EmptyState, SegmentedTabs, SectionTitle } from '../view/Common';
import { SplitPane } from '../view/Responsive';
import { Tok } from '../view/Theme';

/**
 * 置顶 > 活跃 > 最近更新。
 * Core 只导出 sortSessionIndexes（返回下标），这里按它重排会话数组，
 * 避免在页面层另写一套排序规则。
 */
function sortSessions(list: SessionSummary[]): SessionSummary[] {
  const items: SessionSortItem[] = [];
  for (const s of list) {
    const it: SessionSortItem = {
      id: s.id,
      pinned: s.pinned === true,
      active: s.active === true,
      updatedAt: s.updatedAt
    };
    items.push(it);
  }
  const order = sortSessionIndexes(items);
  const out: SessionSummary[] = [];
  for (const idx of order) {
    const hit = list[idx];
    if (hit !== undefined) {
      out.push(hit);
    }
  }
  return out;
}

/** 三个分类 Tab 的文案，同时作为 prefs 里持久化的键 */
const CAT_ALL: string = 'all';
const CAT_UNCATEGORIZED: string = 'uncategorized';
const CAT_ARCHIVED: string = 'archived';

/** 分类 Tab 的下标 ↔ prefs 里的分类名 */
function catNameOf(idx: number): string {
  if (idx === 1) {
    return CAT_UNCATEGORIZED;
  }
  if (idx === 2) {
    return CAT_ARCHIVED;
  }
  return CAT_ALL;
}

function catIndexOf(name: string): number {
  if (name === CAT_UNCATEGORIZED) {
    return 1;
  }
  if (name === CAT_ARCHIVED) {
    return 2;
  }
  return 0;
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
  const base = NetConfig.getBaseUrl();
  return `${base}/share/${token}`;
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

/** 断点字符串收敛成 Breakpoint 联合类型（不用 X['k'] 索引断言） */
function toBreakpoint(s: string): Breakpoint {
  if (s === 'expanded' || s === 'medium') {
    return s;
  }
  return 'compact';
}

@Entry
@Component
struct SessionListPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('userName') userName: string = '';
  @StorageLink('breakpoint') bp: string = 'compact';
  @StorageLink('sidebarRatio') sideRatio: number = 0.28;

  @State tab: number = 0;
  @State sessions: SessionSummary[] = [];
  @State rooms: RoomInfo[] = [];
  @State query: string = '';
  /** 搜索请求在飞（用于搜索框右侧的转圈） */
  @State searching: boolean = false;
  @State now: number = Date.now();

  // ── 分类 / 归档 ──
  @State catTab: number = 0;
  /** 已归档的 sessionId，来自 ArchiveRepo.list */
  @State archivedIds: string[] = [];
  @State archives: SessionArchive[] = [];

  // ── 长按菜单 ──
  @State menuOpen: boolean = false;
  @State menuId: string = '';
  @State menuTitle: string = '';

  // ── 分享面板 ──
  @State shareOpen: boolean = false;
  @State shareSessionId: string = '';
  @State shareSessionTitle: string = '';
  @State shares: SessionShare[] = [];
  /** 刚生成的链接，非空时高亮展示 */
  @State freshLink: string = '';
  @State copied: boolean = false;

  // ── 宽屏右栏 ──
  @State selectedId: string = '';

  /**
   * 宽屏左栏是否折叠。
   *
   * 折叠态下 SplitPane 整个左栏不渲染，页面顶栏要靠它显示「展开左栏」按钮，
   * 否则用户折叠一次就再也点不回来了。
   */
  @State sideCollapsed: boolean = false;

  aboutToAppear() {
    this.refresh();
    this.loadCategory();
    this.loadLayout();
    this.appeared = true;
    this.timer = setInterval(() => {
      this.now = Date.now();
    }, 30000);
  }

  aboutToDisappear() {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    // ⚠ 搜索防抖定时器也要清：否则输入搜索词后 300ms 内退出页面，
    //   setTimeout 仍会触发 searchOnServer()，改已销毁页面的 @State。
    this.clearSearchTimer();
    // 页面退出时把待写的布局落盘，避免防抖窗口内的改动丢失
    this.flushLayout();
  }

  onPageShow() {
    // ArkUI 首次进入会走 aboutToAppear → onPageShow，
    // 无条件 refresh 会让首屏查两遍库（RoomRepo.listByRoom 还是串行的）。
    // 用这个标志把首屏那次跳过，只在真正从后台/其他页返回时刷新。
    if (this.appeared) {
      this.refresh();
    }
  }

  private timer: number = -1;
  /** 首屏标记：aboutToAppear 已初始化过，onPageShow 无需重复 */
  private appeared: boolean = false;
  /** 布局落库防抖定时器，-1 表示当前没有待落盘的改动 */
  private layoutTimer: number = -1;
  /** 已读回的 contentMaxWidth，回写时不能被我们抹成 0 */
  private contentMaxWidth: number = 0;

  /**
   * 把当前布局拼成 LayoutPrefs。
   *
   * 用具名工厂而不是对象字面量直接返回（ArkTS 禁隐式对象字面量类型），
   * 只取本页面真正拥有的字段：比例用 sideRatio（@StorageLink 与 AppStorage 同源），
   * 断点用当前 bp，宽度沿用启动时读回的值。
   */
  private buildLayoutPrefs(): LayoutPrefs {
    const p: LayoutPrefs = {
      sidebarRatio: clampRatio(this.sideRatio),
      lastBreakpoint: this.bp,
      sidebarCollapsed: this.sideCollapsed,
      contentMaxWidth: this.contentMaxWidth
    };
    return p;
  }

  /** 真正写库。失败只提示不阻断，布局偏好丢了不该影响主流程 */
  private async writeLayout(): Promise<void> {
    try {
      await PrefsRepo.saveLayout(AppStore.db(), this.buildLayoutPrefs());
    } catch (e) {
      promptAction.showToast({ message: `布局保存失败: ${(e as Error).message}` });
    }
  }

  /**
   * 防抖落库：拖拽会连续触发 onRatioChange，
   * 每次都写库既频繁又可能撞上正在执行的 SQL，延迟 600ms 只写最后一次。
   */
  private scheduleLayoutSave(): void {
    if (this.layoutTimer !== -1) {
      clearTimeout(this.layoutTimer);
    }
    this.layoutTimer = setTimeout(() => {
      this.layoutTimer = -1;
      this.writeLayout();
    }, 600);
  }

  /** 立即落盘并清掉待写的定时器（页面退出时调用） */
  private flushLayout(): void {
    if (this.layoutTimer === -1) {
      return;
    }
    clearTimeout(this.layoutTimer);
    this.layoutTimer = -1;
    this.writeLayout();
  }

  /**
   * 读回上次保存的布局。
   *
   * 比例写进 AppStorage（不是直接赋 this.sideRatio）：
   * @StorageLink 双向绑定，写 AppStorage 才会让本页与其它订阅者一起刷新，
   * 直接赋字段在别处已 setOrCreate 过时会不同步。
   */
  private async loadLayout(): Promise<void> {
    try {
      const p = await PrefsRepo.loadLayout(AppStore.db());
      AppStorage.setOrCreate<number>('sidebarRatio', clampRatio(p.sidebarRatio));
      this.sideCollapsed = p.sidebarCollapsed;
      this.contentMaxWidth = p.contentMaxWidth;
    } catch (e) {
      // 读不到就用默认值，不打扰用户
    }
  }

  /** SplitPane 拖拽结束：更新比例 + 防抖落库 */
  private onRatioChange(r: number): void {
    const next = clampRatio(r);
    AppStorage.setOrCreate<number>('sidebarRatio', next);
    this.scheduleLayoutSave();
  }

  /** SplitPane 折叠按钮：切折叠态 + 立即落库（单次点击，不需要防抖） */
  private onCollapseToggle(): void {
    this.sideCollapsed = !this.sideCollapsed;
    this.flushLayout();
  }

  /** 顶栏「展开左栏」按钮：折叠后左栏不渲染，只能从这里点回来 */
  private expandSidebar(): void {
    if (!this.sideCollapsed) {
      return;
    }
    this.sideCollapsed = false;
    this.flushLayout();
  }

  /** 读回上次选的分类 */
  private async loadCategory(): Promise<void> {
    try {
      const name = await PrefsRepo.getStr(AppStore.db(), 'sessions.category', CAT_ALL);
      this.catTab = catIndexOf(name);
    } catch (e) {
      this.catTab = 0;
    }
  }


  private async refresh(): Promise<void> {
    try {
      const s = await SessionRepo.list(AppStore.db());
      this.sessions = sortSessions(s);
      this.rooms = await RoomRepo.list(AppStore.db());
      await this.loadArchives();
    } catch (e) {
      promptAction.showToast({ message: `加载失败: ${(e as Error).message}` });
    }
  }

  /** 搜索防抖计时器。-1 = 无 */
  private searchTimer: number = -1;

  /**
   * 输入防抖：停止输入 300ms 才真发请求。
   *
   * 不防抖的话每敲一个字就打一次服务端 —— 中文输入法一次能出4~6 个字，
   * 会被打成十几次请求，PC 白跑、手机卡顿。
   */
  private scheduleSearch(): void {
    if ((AppStorage.get<string>('dataSource') ?? 'local') !== 'server') {
      // 本地模式数据就在内存里，filteredSessions() 已经过滤了，不用请求
      return;
    }
    this.clearSearchTimer();
    this.searching = true;
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.searchOnServer();
    }, 300);
  }

  private clearSearchTimer(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  /**
   * 服务端搜索（仅服务端模式 + 有关键词时生效）。
   *
   * 为什么要单独一条路：部署形态是「PC 当服务端 + 手机远程控制」，
   * 台式机上会攒几百个会话，`GET /api/studio/sessions` 一次拉不全，
   * 在手机端过滤 = 只能搜到已加载的那部分，越用越搜不到。
   * 走 `GET /api/studio/search/sessions?q=` 是**服务端侧**搜索，
   * 覆盖全量，且不受手机端内存/传输限制。
   *
   * 本地模式没这个端点，仍走内存过滤（数据本来就在本地）。
   */
  private async searchOnServer(): Promise<void> {
    if ((AppStorage.get<string>('dataSource') ?? 'local') !== 'server') {
      return;
    }
    const q = this.query.trim();
    if (q.length === 0) {
      // 清空搜索词 → 恢复完整列表。
      // ⚠ 这里也必须清 searching：scheduleSearch 已把它置 true，
      //   若不清空，清空搜索框后 loading 态会一直卡住。
      this.searching = false;
      await this.refresh();
      return;
    }
    try {
      const list = await StudioApi.searchSessions(NetConfig.getToken(), q, 100);
      this.sessions = sortSessions(list);
      this.searching = false;
    } catch (e) {
      // 搜索失败**保留原列表**，不要清空 —— 否则用户看到「无结果」，
      // 实际是网络问题
      promptAction.showToast({ message: `搜索失败: ${(e as Error).message}` });
      this.searching = false;
    }
  }

  /**
   * 归档信息单独读：SessionSummary 里没有 archived 字段，
   * ArchiveRepo.add 写的是 sessions.archived，页面侧只能靠归档表反推。
   */
  private async loadArchives(): Promise<void> {
    const rows = await ArchiveRepo.list(AppStore.db());
    const ids: string[] = [];
    for (const a of rows) {
      if (ids.indexOf(a.sessionId) < 0) {
        ids.push(a.sessionId);
      }
    }
    this.archives = rows;
    this.archivedIds = ids;
  }

  private async newSession(): Promise<void> {
    // 服务端模式：**不能预建本地会话**。
    //
    // 实测（2026-10）：服务端没有「创建会话」的写端点，会话是由
    // `POST /api/studio/chat-run/runs` 在**首条消息**发出时顺带创建的
    // （openapi 原文：session_id "Omit this to create a new session automatically"）。
    //
    // 如果这里在手机本地库 INSERT 一个 id，再拿这个 id 去服务端查 → 必然 404，
    // 这就是之前「新建对话显示加载失败 HTTP404」的根因。
    //
    // 所以服务端模式直接进「草稿页」（sessionId 空），发第一条消息时
    // 不带 session_id，服务端建完把新 id 回传回来。
    if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
      AppStore.setChatView('single');
      this.openChatPage('');
      return;
    }

    try {
      const agent = await AppStore.ensureDefaultAgent();
      const providers = AppStore.providers();
      const p = providers.find((x: Provider) => x.id === agent.provider);
      const id = shortId(Date.now(), Math.random());
      await SessionRepo.create(AppStore.db(), id, '新对话', 'api_server', Date.now(),
        agent.model, p !== undefined ? p.name : '');
      AppStore.setActiveSession(id);
      AppStore.setChatView('single');
      this.openChatPage(id);
    } catch (e) {
      promptAction.showToast({ message: `新建失败: ${(e as Error).message}` });
    }
  }

  private async newRoom(): Promise<void> {
    try {
      const id = shortId(Date.now(), Math.random());
      await RoomRepo.create(AppStore.db(), id, '新群聊', Date.now());
      AppStore.setActiveRoom(id);
      AppStore.setChatView('group');
      this.openGroupPage(id);
    } catch (e) {
      promptAction.showToast({ message: `新建群聊失败: ${(e as Error).message}` });
    }
  }

  private openSession(s: SessionSummary): void {
    AppStore.setActiveSession(s.id);
    AppStore.setChatView('single');
    this.openChatPage(s.id);
  }

  private openRoom(r: RoomInfo): void {
    AppStore.setActiveRoom(r.id);
    AppStore.setChatView('group');
    this.openGroupPage(r.id);
  }

  /**
   * 会话点击。
   * 宽屏：只更新右栏，不跳页（双栏常驻）。
   * 窄屏：保持原行为跳聊天页。
   */
  private onSessionTap(s: SessionSummary): void {
    if (this.bp === 'expanded') {
      this.selectedId = s.id;
      // 存 AppStorage 供主容器做双栏时读取，键名与 activeSessionId 分开
      AppStorage.setOrCreate<string>('selectedSessionId', s.id);
      return;
    }
    this.openSession(s);
  }

  /** router.pushUrl 只接受 RouterOptions 对象，不能直接传 url 字符串 */
  private openChatPage(sessionId: string): void {
    const opts: router.RouterOptions = { url: 'pages/ChatPage', params: { sessionId: sessionId } };
    router.pushUrl(opts);
  }

  private openGroupPage(roomId: string): void {
    const opts: router.RouterOptions = { url: 'pages/GroupChatPage', params: { roomId: roomId } };
    router.pushUrl(opts);
  }

  // ───────────────── 长按菜单 ─────────────────

  private openMenu(s: SessionSummary): void {
    this.menuId = s.id;
    this.menuTitle = s.title;
    this.menuOpen = true;
  }

  private async confirmDeleteSession(id: string, title: string): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路
    if (blockLocalWrite('会话')) {
      return;
    }
    const res = await promptAction.showDialog({
      title: '删除会话',
      message: `确定删除「${title}」及其全部消息？此操作不可恢复。`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await SessionRepo.delete(AppStore.db(), id);
    this.refresh();
  }

  private async confirmDeleteRoom(id: string, name: string): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路
    if (blockLocalWrite('群聊房间')) {
      return;
    }
    const res = await promptAction.showDialog({
      title: '删除群聊',
      message: `确定删除群聊「${name}」及其全部消息？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await RoomRepo.delete(AppStore.db(), id);
    this.refresh();
  }

  /**
   * 归档：ArchiveRepo.add 顺带把 sessions.archived 置 1，
   * 这里再用 SessionRepo.setArchived 显式写回，双写保证两边一致。
   */
  private async archiveCurrent(): Promise<void> {
    if (this.menuId.length === 0) {
      return;
    }
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已归档」假成功 toast
    if (blockLocalWrite('归档')) {
      return;
    }
    if (this.archivedIds.indexOf(this.menuId) >= 0) {
      promptAction.showToast({ message: '已经在归档区了' });
      return;
    }
    try {
      await ArchiveRepo.add(AppStore.db(), this.menuId, this.menuTitle, '', Date.now());
      await SessionRepo.setArchived(AppStore.db(), this.menuId, true);
      this.menuOpen = false;
      await this.refresh();
      promptAction.showToast({ message: '已归档，可在「已归档」里恢复' });
    } catch (e) {
      promptAction.showToast({ message: `归档失败: ${(e as Error).message}` });
    }
  }

  /** 恢复：ArchiveRepo.remove 需要归档记录 id，按 sessionId 反查；同时清掉 sessions.archived */
  private async restoreSession(sessionId: string): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已恢复」假成功 toast
    if (blockLocalWrite('归档')) {
      return;
    }
    let archiveId = '';
    for (const a of this.archives) {
      if (a.sessionId === sessionId) {
        archiveId = a.id;
        break;
      }
    }
    if (archiveId.length === 0) {
      promptAction.showToast({ message: '找不到归档记录' });
      return;
    }
    try {
      await ArchiveRepo.remove(AppStore.db(), archiveId, sessionId);
      await SessionRepo.setArchived(AppStore.db(), sessionId, false);
      await this.refresh();
      promptAction.showToast({ message: '已恢复到全部会话' });
    } catch (e) {
      promptAction.showToast({ message: `恢复失败: ${(e as Error).message}` });
    }
  }

  /** 置顶状态：菜单里要显示「置顶 / 取消置顶」，所以先查当前值 */
  private isPinned(sessionId: string): boolean {
    for (const s of this.sessions) {
      if (s.id === sessionId) {
        return s.pinned === true;
      }
    }
    return false;
  }

  /**
   * 置顶 / 取消置顶。
   * 写回 SessionRepo.setPinned —— 之前只有 @State 层面的排序效果，
   * 落库缺失导致「看着生效、刷新就丢」。
   */
  private async togglePinned(): Promise<void> {
    const id = this.menuId;
    if (id.length === 0) {
      return;
    }
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已置顶」假成功 toast
    if (blockLocalWrite('会话')) {
      return;
    }
    const next = !this.isPinned(id);
    try {
      await SessionRepo.setPinned(AppStore.db(), id, next);
      this.menuOpen = false;
      await this.refresh();
      promptAction.showToast({ message: next ? '已置顶' : '已取消置顶' });
    } catch (e) {
      promptAction.showToast({ message: `操作失败: ${(e as Error).message}` });
    }
  }

  private isArchived(sessionId: string): boolean {
    return this.archivedIds.indexOf(sessionId) >= 0;
  }

  // ───────────────── 分享 ─────────────────

  private async openShare(): Promise<void> {
    this.shareSessionId = this.menuId;
    this.shareSessionTitle = this.menuTitle;
    this.freshLink = '';
    this.copied = false;
    this.menuOpen = false;
    await this.loadShares();
    this.shareOpen = true;
  }

  private async loadShares(): Promise<void> {
    try {
      this.shares = await ShareRepo.bySession(AppStore.db(), this.shareSessionId);
    } catch (e) {
      this.shares = [];
    }
  }

  /** 生成一个新的分享链接，默认 7 天有效 */
  private async createShare(): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「链接已生成并复制」假成功 toast
    if (blockLocalWrite('分享')) {
      return;
    }
    const now = Date.now();
    const token = makeShareToken(now);
    const expiresAt = now + 7 * 86400000;
    try {
      await ShareRepo.create(AppStore.db(), this.shareSessionId,
        this.shareSessionTitle, 'session', token, expiresAt, now);
      this.freshLink = shareLinkOf(token);
      await this.loadShares();
      const ok = await copyToClipboard(this.freshLink);
      this.copied = ok;
      promptAction.showToast({ message: ok ? '链接已生成并复制' : '链接已生成' });
    } catch (e) {
      promptAction.showToast({ message: `生成分享链接失败: ${(e as Error).message}` });
    }
  }

  private async copyFreshLink(): Promise<void> {
    if (this.freshLink.length === 0) {
      return;
    }
    const ok = await copyToClipboard(this.freshLink);
    this.copied = ok;
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
      this.copied = false;
    }
    await this.loadShares();
    promptAction.showToast({ message: '已撤销' });
  }

  // ───────────────── 过滤 ─────────────────

  /** 是否属于当前分类 Tab。未分类=没有分类名且未归档 */
  private inCategory(s: SessionSummary): boolean {
    if (this.catTab === 2) {
      return this.isArchived(s.id);
    }
    if (this.isArchived(s.id)) {
      return false;
    }
    if (this.catTab === 1) {
      const name = s.categoryName ?? '';
      return name.length === 0;
    }
    return true;
  }

  private filteredSessions(): SessionSummary[] {
    const base = this.sessions.filter((s: SessionSummary) => this.inCategory(s));
    const q = this.query.trim();
    if (q.length === 0) {
      return base;
    }
    // ⚠ 服务端模式下 sessions **已经是服务端搜出来的结果**，
    //   再按标题/预览过滤一次会漏（比如服务端命中在正文里的会话）。
    //   所以服务端模式直接返回，只保留分类过滤。
    if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
      return base;
    }
    // 本地模式：数据就在内存里，内存过滤就够（也没服务端搜索端点）
    const lower = q.toLowerCase();
    return base.filter((s: SessionSummary) =>
      s.title.toLowerCase().indexOf(lower) >= 0 ||
      this.previewOf(s).toLowerCase().indexOf(lower) >= 0);
  }

  /** lastMessagePreview 是可选字段，统一兜底成空串 */
  private previewOf(s: SessionSummary): string {
    return s.lastMessagePreview ?? '';
  }

  /** 列表里第二行：截断后的最后一条消息，没消息时给占位文案 */
  private lastLine(s: SessionSummary): string {
    const raw = this.previewOf(s);
    if (raw.length === 0) {
      return '（暂无消息）';
    }
    return previewOf(raw, 44);
  }

  private isWide(): boolean {
    return this.bp === 'expanded';
  }

  private selectedSession(): SessionSummary | null {
    for (const s of this.sessions) {
      if (s.id === this.selectedId) {
        return s;
      }
    }
    return null;
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('Ekko Studio')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tok.text1(this.dark))
          Text(this.userName.length > 0 ? `你好，${this.userName}` : '鸿蒙版')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        // 折叠态下 SplitPane 的左栏整个不渲染，展开入口只能放顶栏。
        // 仅宽屏显示：窄屏本来就是单栏，没有左栏可展开。
        if (this.isWide() && this.sideCollapsed) {
          Button('☰ 列表', { type: ButtonType.Normal })
            .height(32)
            .fontSize(12)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.cardBg(this.dark))
            .borderRadius(Tok.radiusSmall)
            .onClick(() => {
              this.expandSidebar();
            })
        }

        Button('＋', { type: ButtonType.Circle })
          .width(36)
          .height(36)
          .fontSize(22)
          .fontColor('#FFFFFF')
          .backgroundColor(Tok.brand)
          .onClick(() => {
            if (this.tab === 0) {
              this.newSession();
            } else {
              this.newRoom();
            }
          })

        Button('⚙', { type: ButtonType.Circle })
          .width(36)
          .height(36)
          .fontSize(16)
          .fontColor(Tok.text2(this.dark))
          .backgroundColor(Tok.cardBg(this.dark))
          .onClick(() => {
            const opts: router.RouterOptions = { url: 'pages/SettingsPage' };
            router.pushUrl(opts);
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 8, bottom: 10 })
      .backgroundColor(Tok.pageBg(this.dark))
      // P1-17 同形修复：一个组件节点只能挂一个 bindSheet。原本两个 sheet 都挂在
      // 根 Column 上，后者覆盖前者 —— 前者对应的入口点了没反应。根 Column 体内是
      // 条件分支（无 Scroll 可挂），故本 sheet 移到顶栏链末节点，另一个 sheet 留根 Column。
      .bindSheet($$this.menuOpen, this.menuSheet(), {
        height: SheetSize.MEDIUM,
        dragBar: true
      })

      SegmentedTabs({
        items: ['单聊', '群聊'],
        active: this.tab,
        onChange: (idx: number) => {
          this.tab = idx;
        }
      })
      .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 10 })

      if (this.tab === 0) {
        if (this.isWide()) {
          // 宽屏：左栏常驻列表 + 右栏详情，点击会话不跳页。
          // collapsed 必须传，否则 SplitPane 不知道折叠态、顶栏展开按钮点了也没反应。
          SplitPane({
            bp: toBreakpoint(this.bp),
            ratio: this.sideRatio,
            collapsed: this.sideCollapsed,
            side: this.singleList,
            main: this.detailPane,
            onRatioChange: (r: number) => {
              this.onRatioChange(r);
            },
            onCollapseToggle: () => {
              this.onCollapseToggle();
            }
          })
        } else {
          Column() {
            this.singleList()
          }
          .width('100%')
          .layoutWeight(1)
        }
      } else {
        this.groupList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.shareOpen, this.shareSheet(), {
      height: SheetSize.LARGE,
      dragBar: true
    })
  }

  @Builder
  singleList() {
    Column() {
      Search({ value: this.query, placeholder: this.searching ? '搜索中…' : '搜索会话' })
        .height(38)
        .backgroundColor(Tok.cardBg(this.dark))
        .borderRadius(Tok.radiusSmall)
        .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 8 })
        .onChange((v: string) => {
          this.query = v;
          this.scheduleSearch();
        })
        .onSubmit(() => {
          // 回车立即搜，不等防抖
          this.clearSearchTimer();
          this.searchOnServer();
        })

      // 分类 Tab：全部 / 未分类 / 已归档，选择写回 prefs
      SegmentedTabs({
        items: ['全部', '未分类', '已归档'],
        active: this.catTab,
        onChange: (idx: number) => {
          this.catTab = idx;
          const name = catNameOf(idx);
          PrefsRepo.setCategory(AppStore.db(), name);
        }
      })
      .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 8 })

      if (this.filteredSessions().length === 0) {
        EmptyState({
          icon: '✦',
          text: this.emptyText(),
          hint: this.emptyHint()
        })
        Blank()
      } else {
        List({ space: 8 }) {
          ForEach(this.filteredSessions(), (s: SessionSummary) => {
            ListItem() {
              Row({ space: 12 }) {
                // 会话图标
                Stack() {
                  Text(s.title.length > 0 ? s.title.charAt(0) : '✦')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                }
                .width(40)
                .height(40)
                .borderRadius(20)
                .backgroundColor(this.isArchived(s.id) ? Tok.text3(this.dark) : Tok.brand)

                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(s.title.length > 0 ? s.title : '未命名')
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Tok.text1(this.dark))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (s.active) {
                      Text('运行中')
                        .fontSize(10)
                        .fontColor(Tok.success)
                    } else if (s.pinned) {
                      Text('置顶')
                        .fontSize(10)
                        .fontColor(Tok.brand)
                    }
                    if (this.isArchived(s.id)) {
                      Text('已归档')
                        .fontSize(10)
                        .fontColor(Tok.warn)
                    }
                  }
                  .width('100%')

                  Text(this.lastLine(s))
                    .fontSize(12)
                    .fontColor(Tok.text3(this.dark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')

                  Text(relativeTime(s.updatedAt, this.now))
                    .fontSize(10)
                    .fontColor(Tok.text3(this.dark))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(Tok.cardPad)
              .backgroundColor(Tok.cardBg(this.dark))
              .borderRadius(Tok.radius)
              .onClick(() => this.onSessionTap(s))
              .gesture(LongPressGesture().onAction(() => {
                this.openMenu(s);
              }))
            }
          }, (s: SessionSummary) => s.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Tok.pagePad, right: Tok.pagePad })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  private emptyText(): string {
    if (this.query.trim().length > 0) {
      return '没有匹配的会话';
    }
    if (this.catTab === 2) {
      return '归档区是空的';
    }
    if (this.catTab === 1) {
      return '没有未分类的会话';
    }
    return '还没有会话';
  }

  private emptyHint(): string {
    if (this.query.trim().length > 0) {
      return '换个关键词试试';
    }
    if (this.catTab === 2) {
      return '长按会话可以归档到这里';
    }
    return '点右上角 ＋ 开一场新对话';
  }

  /** 宽屏右栏：选中会话的详情 + 进入对话的入口 */
  @Builder
  detailPane() {
    Column() {
      if (this.selectedSession() === null) {
        EmptyState({
          icon: '☰',
          text: '选一个会话',
          hint: '左侧列表常驻，点击后这里显示详情，不会跳页'
        })
      } else {
        this.detailBody()
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  detailBody() {
    Scroll() {
      Column({ space: 12 }) {
        SectionTitle({ text: '会话详情' })

        Text(this.titleOfSelected())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tok.text1(this.dark))
          .width('100%')

        Text(this.lastLineOfSelected())
          .fontSize(13)
          .fontColor(Tok.text2(this.dark))
          .width('100%')

        Column({ space: 2 }) {
          this.detailLine('模型', this.modelOfSelected())
          this.detailLine('消息数', `${this.countOfSelected()}`)
          this.detailLine('创建于', relativeTime(this.createdOfSelected(), this.now))
          this.detailLine('最近更新', relativeTime(this.updatedOfSelected(), this.now))
          this.detailLine('归档状态', this.isArchived(this.selectedId) ? '已归档' : '未归档')
        }
        .width('100%')
        .padding(Tok.cardPad)
        .backgroundColor(Tok.cardBg(this.dark))
        .borderRadius(Tok.radius)
        .alignItems(HorizontalAlign.Start)

        Button('进入对话')
          .width('100%')
          .height(42)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor(Tok.brand)
          .borderRadius(Tok.radiusSmall)
          .onClick(() => {
            const s = this.selectedSession();
            if (s !== null) {
              this.openSession(s);
            }
          })

        if (this.isArchived(this.selectedId)) {
          Button('从归档恢复')
            .width('100%')
            .height(42)
            .fontSize(15)
            .fontColor(Tok.brand)
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: Tok.brand })
            .borderRadius(Tok.radiusSmall)
            .onClick(() => {
              this.restoreSession(this.selectedId);
            })
        }
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: Tok.pagePad, bottom: Tok.pagePad })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  detailLine(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(Tok.text3(this.dark))
        .width(72)
      Text(value.length > 0 ? value : '—')
        .fontSize(12)
        .fontColor(Tok.text2(this.dark))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  private titleOfSelected(): string {
    const s = this.selectedSession();
    return s === null ? '' : s.title;
  }

  private lastLineOfSelected(): string {
    const s = this.selectedSession();
    return s === null ? '' : this.lastLine(s);
  }

  private modelOfSelected(): string {
    const s = this.selectedSession();
    if (s === null) {
      return '';
    }
    return s.model ?? '';
  }

  private countOfSelected(): number {
    const s = this.selectedSession();
    return s === null ? 0 : s.messageCount;
  }

  private createdOfSelected(): number {
    const s = this.selectedSession();
    return s === null ? Date.now() : s.createdAt;
  }

  private updatedOfSelected(): number {
    const s = this.selectedSession();
    return s === null ? Date.now() : s.updatedAt;
  }

  @Builder
  groupList() {
    Column() {
      if (this.rooms.length === 0) {
        EmptyState({
          icon: '👥',
          text: '还没有群聊',
          hint: '群聊可以让多个 Agent 一起讨论同一个问题'
        })
        Blank()
      } else {
        List({ space: 8 }) {
          ForEach(this.rooms, (r: RoomInfo) => {
            ListItem() {
              Row({ space: 12 }) {
                Stack() {
                  Text('群')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                }
                .width(40)
                .height(40)
                .borderRadius(20)
                .backgroundColor(Tok.success)

                Column({ space: 3 }) {
                  Text(r.name.length > 0 ? r.name : '未命名群聊')
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tok.text1(this.dark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  Text(`${(r.agents ?? []).length} 个 Agent`)
                    .fontSize(12)
                    .fontColor(Tok.text3(this.dark))

                  Text(relativeTime(r.lastActiveAt ?? r.createdAt ?? Date.now(), this.now))
                    .fontSize(10)
                    .fontColor(Tok.text3(this.dark))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(Tok.cardPad)
              .backgroundColor(Tok.cardBg(this.dark))
              .borderRadius(Tok.radius)
              .onClick(() => this.openRoom(r))
              .gesture(LongPressGesture().onAction(() => {
                this.confirmDeleteRoom(r.id, r.name);
              }))
            }
          }, (r: RoomInfo) => r.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Tok.pagePad, right: Tok.pagePad })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 长按会话弹出的操作菜单 */
  @Builder
  menuSheet() {
    Column({ space: 10 }) {
      Text(this.menuTitle.length > 0 ? this.menuTitle : '会话')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tok.text1(this.dark))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Button(this.isPinned(this.menuId) ? '取消置顶' : '置顶')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(this.isPinned(this.menuId) ? Tok.text2(this.dark) : Tok.brand)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: this.isPinned(this.menuId) ? Tok.line(this.dark) : Tok.brand })
        .borderRadius(Tok.radiusSmall)
        .onClick(() => {
          this.togglePinned();
        })

      Button(this.isArchived(this.menuId) ? '已在归档区' : '归档')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(this.isArchived(this.menuId) ? Tok.text3(this.dark) : Tok.brand)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: this.isArchived(this.menuId) ? Tok.line(this.dark) : Tok.brand })
        .borderRadius(Tok.radiusSmall)
        .enabled(!this.isArchived(this.menuId))
        .onClick(() => {
          this.archiveCurrent();
        })

      if (this.isArchived(this.menuId)) {
        Button('恢复到全部会话')
          .width('100%')
          .height(42)
          .fontSize(14)
          .fontColor(Tok.brand)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: Tok.brand })
          .borderRadius(Tok.radiusSmall)
          .onClick(() => {
            const id = this.menuId;
            this.menuOpen = false;
            this.restoreSession(id);
          })
      }

      Button('分享链接')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(Tok.brand)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: Tok.brand })
        .borderRadius(Tok.radiusSmall)
        .onClick(() => {
          this.openShare();
        })

      Button('删除会话')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(Tok.danger)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: Tok.danger })
        .borderRadius(Tok.radiusSmall)
        .onClick(() => {
          const id = this.menuId;
          const title = this.menuTitle;
          this.menuOpen = false;
          this.confirmDeleteSession(id, title);
        })

      Button('取消')
        .width('100%')
        .height(38)
        .fontSize(14)
        .fontColor(Tok.text2(this.dark))
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.menuOpen = false;
        })
    }
    .width('100%')
    .padding(20)
  }

  /** 分享面板：生成链接 + 已分享列表可撤销 */
  @Builder
  shareSheet() {
    Scroll() {
      Column({ space: 10 }) {
        Text('分享链接')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .width('100%')

        Text(this.shareSessionTitle.length > 0 ? this.shareSessionTitle : '会话')
          .fontSize(12)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.freshLink.length > 0) {
          Text(this.freshLink)
            .width('100%')
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor(Tok.text1(this.dark))
            .backgroundColor(Tok.fieldBg(this.dark))
            .padding(10)
            .borderRadius(Tok.radiusSmall)
          Button(this.copied ? '已复制，点此再复制' : '复制链接')
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
        } else {
          Text('还没有生成分享链接')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .padding({ top: 8, bottom: 8 })
        }

        Button('生成新的分享链接（7 天有效）')
          .width('100%')
          .height(42)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor(Tok.brand)
          .borderRadius(Tok.radiusSmall)
          .onClick(() => {
            this.createShare();
          })

        SectionTitle({ text: '已分享', trailing: `${this.shares.length}` })

        if (this.shares.length === 0) {
          Text('这个会话还没有分享过')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .padding({ top: 6, bottom: 6 })
        } else {
          ForEach(this.shares, (sh: SessionShare) => {
            Column({ space: 4 }) {
              Text(shareLinkOf(sh.token))
                .width('100%')
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor(Tok.text2(this.dark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Row() {
                Text(`${shareExpiryText(sh.expiresAt, this.now)} · ${relativeTime(sh.createdAt, this.now)}`)
                  .fontSize(10)
                  .fontColor(Tok.text3(this.dark))
                  .layoutWeight(1)
                Text('复制')
                  .fontSize(11)
                  .fontColor(Tok.brand)
                  .padding({ left: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    copyToClipboard(shareLinkOf(sh.token));
                  })
                Text('撤销')
                  .fontSize(11)
                  .fontColor(Tok.danger)
                  .padding({ left: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.revokeShare(sh.token);
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.dark ? '#11141A' : '#F6F7F9')
            .borderRadius(Tok.radiusSmall)
            .alignItems(HorizontalAlign.Start)
          }, (sh: SessionShare) => sh.token)
        }

        Button('关闭')
          .width('100%')
          .height(38)
          .fontSize(14)
          .fontColor(Tok.text2(this.dark))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.shareOpen = false;
          })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }
}
