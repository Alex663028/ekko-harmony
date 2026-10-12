/**
 * 会话关系图（Journey）：谁（Agent）在哪个群聊里、哪些会话挂在哪条链路上。
 * 对应原版 JourneyView。
 *
 * 不引图形库，也不硬上 Canvas：ArkUI 的 Canvas 在 PC 上要处理尺寸/重绘，
 * 收益远低于成本。这里用「缩进 + 连接线」把层级画出来，
 * compact 下单列、expanded 下双列并排，关系一样能读。
 *
 * 数据来源：RoomRepo.list（群聊 + 群内 Agent）、SessionRepo.list（会话）、
 * AppStore.agents()（全局 Agent 配置）。会话与群聊之间没有外键，
 * 所以归属关系按 source / 群内 Agent 交集推导，不臆造。
 */

import { router, promptAction } from '@kit.ArkUI';
import { SessionSummary, RoomInfo, RoomAgent, AgentProfile } from '../model/Types';
import { JourneyNode, JourneyEdge } from '../model/Extend';
import { SessionRepo, RoomRepo } from '../data/Repos';
import { AppStore } from '../viewmodel/AppStore';
import { relativeTime } from '../common/Core';
import { Card, SectionTitle, EmptyState, SegmentedTabs } from '../view/Common';
import { Tok } from '../view/Theme';

/** 节点种类：'root' 汇总 / 'room' 群聊 / 'agent' Agent / 'session' 会话 */
type NodeKind = 'root' | 'room' | 'agent' | 'session';

function newNode(id: string, label: string, kind: NodeKind, refId: string, ts: number): JourneyNode {
  const n: JourneyNode = {
    id: id,
    label: label,
    kind: kind,
    refId: refId,
    timestamp: ts
  };
  return n;
}

function newEdge(from: string, to: string, label: string): JourneyEdge {
  const e: JourneyEdge = {
    from: from,
    to: to,
    label: label
  };
  return e;
}

function emptyNodes(): JourneyNode[] {
  const a: JourneyNode[] = [];
  return a;
}

function emptyEdges(): JourneyEdge[] {
  const a: JourneyEdge[] = [];
  return a;
}

/** 会话 source 字段的中文名，认不出来就原样显示 */
function sourceLabel(src: string): string {
  if (src === 'group_chat') {
    return '群聊';
  }
  if (src === 'workflow') {
    return '工作流';
  }
  if (src === 'global_agent') {
    return '全局 Agent';
  }
  if (src === 'api_server') {
    return '本地直连';
  }
  return src.length > 0 ? src : '未分类';
}

@Entry
@Component
struct JourneyPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';
  @StorageLink('userName') userName: string = '';

  @State sessions: SessionSummary[] = [];
  @State rooms: RoomInfo[] = [];
  @State agents: AgentProfile[] = [];
  @State nodes: JourneyNode[] = emptyNodes();
  @State edges: JourneyEdge[] = emptyEdges();
  @State view: number = 0;
  @State now: number = Date.now();

  aboutToAppear() {
    this.reload();
    this.timer = setInterval((): void => {
      this.now = Date.now();
    }, 30000);
  }

  aboutToDisappear() {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private timer: number = -1;

  private wide(): boolean {
    return this.bp === 'expanded';
  }

  private async reload(): Promise<void> {
    try {
      this.sessions = await SessionRepo.list(AppStore.db());
      this.rooms = await RoomRepo.list(AppStore.db());
      this.agents = AppStore.agents();
      this.now = Date.now();
      this.rebuild();
    } catch (e) {
      promptAction.showToast({ message: `加载失败: ${(e as Error).message}` });
    }
  }

  /**
   * 推导节点与边。
   *
   * 结构：
   *   根 ─┬─ 群聊 ─┬─ Agent（群内成员）
   *       │        └─ 该群聊最近会话
   *       └─ 会话来源 ── 会话
   */
  private rebuild(): void {
    const nodes: JourneyNode[] = [];
    const edges: JourneyEdge[] = [];
    const now = this.now;

    nodes.push(newNode('root', 'Journey', 'root', '', now));

    // 群聊 → 群内 Agent
    for (const r of this.rooms) {
      const roomNodeId = `room:${r.id}`;
      nodes.push(newNode(roomNodeId, r.name, 'room', r.id,
        r.lastActiveAt !== undefined ? r.lastActiveAt : now));
      edges.push(newEdge('root', roomNodeId, '群聊'));
      const members: RoomAgent[] = r.agents !== undefined ? r.agents : [];
      for (const a of members) {
        const agentNodeId = `agent:${r.id}:${a.agentId}`;
        nodes.push(newNode(agentNodeId, a.name, 'agent', a.agentId, now));
        edges.push(newEdge(roomNodeId, agentNodeId, a.model.length > 0 ? a.model : '成员'));
      }
    }

    // 会话 → 来源分组
    // source 分组做去重，保持首次出现顺序
    const groupIds: string[] = [];
    for (const s of this.sessions) {
      const g = sourceLabel(s.source);
      if (groupIds.indexOf(g) === -1) {
        groupIds.push(g);
      }
    }
    for (const g of groupIds) {
      const groupNodeId = `group:${g}`;
      nodes.push(newNode(groupNodeId, g, 'root', g, now));
      edges.push(newEdge('root', groupNodeId, '来源'));
      for (const s of this.sessions) {
        if (sourceLabel(s.source) !== g) {
          continue;
        }
        const sid = `session:${s.id}`;
        nodes.push(newNode(sid, s.title, 'session', s.id, s.updatedAt));
        edges.push(newEdge(groupNodeId, sid, `${s.messageCount} 条`));
      }
    }

    this.nodes = nodes;
    this.edges = edges;
  }

  // ───────── 查询辅助 ─────────

  private childrenOf(parentId: string): JourneyNode[] {
    const out: JourneyNode[] = [];
    for (const e of this.edges) {
      if (e.from === parentId) {
        for (const n of this.nodes) {
          if (n.id === e.to) {
            out.push(n);
          }
        }
      }
    }
    return out;
  }

  private edgeLabel(fromId: string, toId: string): string {
    for (const e of this.edges) {
      if (e.from === fromId && e.to === toId) {
        return e.label;
      }
    }
    return '';
  }

  private childRooms(): JourneyNode[] {
    return this.childrenOf('root').filter((n: JourneyNode) => n.kind === 'room');
  }

  private childGroups(): JourneyNode[] {
    return this.childrenOf('root').filter((n: JourneyNode) => n.kind === 'root' && n.id !== 'root');
  }

  private isEmpty(): boolean {
    return this.sessions.length === 0 && this.rooms.length === 0;
  }

  private kindColor(kind: string): string {
    if (kind === 'room') {
      return Tok.brand;
    }
    if (kind === 'agent') {
      return Tok.success;
    }
    if (kind === 'session') {
      return Tok.warn;
    }
    return Tok.text3(this.dark);
  }

  private kindIcon(kind: string): string {
    if (kind === 'room') {
      return '▣';
    }
    if (kind === 'agent') {
      return '◆';
    }
    if (kind === 'session') {
      return '·';
    }
    return '▦';
  }

  private openSession(id: string): void {
    AppStore.setActiveSession(id);
    AppStore.setChatView('single');
    const opts: router.RouterOptions = { url: 'pages/ChatPage', params: { sessionId: id } };
    router.pushUrl(opts);
  }

  private openRoom(id: string): void {
    AppStore.setActiveRoom(id);
    AppStore.setChatView('group');
    const opts: router.RouterOptions = { url: 'pages/GroupChatPage', params: { roomId: id } };
    router.pushUrl(opts);
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(24)
          .onClick((): void => {
            router.back();
          })
        Text('会话关系')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('刷新').fontSize(14).fontColor(Tok.brand)
          .padding({ left: 8, right: 4 })
          .onClick((): void => {
            this.reload();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      SegmentedTabs({
        items: ['群聊关系', '会话归属'],
        active: this.view,
        onChange: (idx: number): void => {
          this.view = idx;
        }
      })
      .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.isEmpty()) {
            EmptyState({
              icon: '✦',
              text: '还没有可展示的关系',
              hint: '先建几个会话与群聊，这里会显示它们挂在哪个 Agent 下'
            })
          } else {
            this.stats()
            if (this.view === 0) {
              this.roomGraph()
            } else {
              this.sessionGraph()
            }
          }
          Blank()
        }
        .width('100%')
        .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 30 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
  }

  @Builder
  stats() {
    Row({ space: 10 }) {
      this.statBox('群聊', `${this.rooms.length}`)
      this.statBox('会话', `${this.sessions.length}`)
      this.statBox('Agent', `${this.agents.length}`)
    }
    .width('100%')
  }

  @Builder
  statBox(label: string, value: string) {
    Card({ pad: 10 }) {
      Column({ space: 2 }) {
        Text(value)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
        Text(label)
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 群聊 → Agent 的树。expanded 下多列并排 */
  @Builder
  roomGraph() {
    Column({ space: 12 }) {
      SectionTitle({ text: '群聊与成员', trailing: this.bp })
      if (this.childRooms().length === 0) {
        Card({ pad: 12 }) {
          Text('还没有群聊')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }
      } else if (this.wide()) {
        // PC：两列网格铺开，一眼看完所有群聊的成员构成
        Grid() {
          ForEach(this.childRooms(), (room: JourneyNode) => {
            GridItem() {
              this.roomCard(room)
            }
          }, (room: JourneyNode) => room.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .width('100%')
      } else {
        ForEach(this.childRooms(), (room: JourneyNode) => {
          this.roomCard(room)
        }, (room: JourneyNode) => room.id)
      }

      SectionTitle({ text: '全局 Agent', trailing: `${this.agents.length} 个` })
      if (this.agents.length === 0) {
        Card({ pad: 12 }) {
          Text('还没有配置 Agent')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }
      } else {
        Card({ pad: 12 }) {
          Column({ space: 10 }) {
            ForEach(this.agents, (a: AgentProfile) => {
              Row({ space: 8 }) {
                Text('◆')
                  .fontSize(11)
                  .fontColor(Tok.success)
                Text(a.name)
                  .fontSize(13)
                  .fontColor(Tok.text1(this.dark))
                Blank()
                Text(a.model.length > 0 ? a.model : '未选模型')
                  .fontSize(11)
                  .fontColor(Tok.text3(this.dark))
                  .maxLines(1)
              }
              .width('100%')
            }, (a: AgentProfile) => a.id)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
  }

  @Builder
  roomCard(room: JourneyNode) {
    Card({ pad: 12 }) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('▣')
            .fontSize(12)
            .fontColor(Tok.brand)
          Text(room.label)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tok.text1(this.dark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick((): void => {
              this.openRoom(room.refId);
            })
          Blank()
          Text(relativeTime(room.timestamp, this.now))
            .fontSize(10)
            .fontColor(Tok.text3(this.dark))
        }
        .width('100%')

        if (this.childrenOf(room.id).length === 0) {
          Text('群内暂无 Agent')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        } else {
          ForEach(this.childrenOf(room.id), (member: JourneyNode) => {
            this.branchLine(member, room.id)
          }, (member: JourneyNode) => member.id)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 一条从父节点垂下来的连线 + 子节点，缩进体现层级 */
  @Builder
  branchLine(node: JourneyNode, parentId: string) {
    Row({ space: 6 }) {
      Text('│')
        .fontSize(12)
        .fontColor(Tok.line(this.dark))
        .width(10)
      Text('└')
        .fontSize(12)
        .fontColor(Tok.line(this.dark))
        .width(10)
      Text(this.kindIcon(node.kind))
        .fontSize(11)
        .fontColor(this.kindColor(node.kind))
      Text(node.label)
        .fontSize(13)
        .fontColor(Tok.text2(this.dark))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.edgeLabel(parentId, node.id))
        .fontSize(10)
        .fontColor(Tok.text3(this.dark))
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }

  /** 会话 → 来源分组 */
  @Builder
  sessionGraph() {
    Column({ space: 12 }) {
      SectionTitle({ text: '会话按来源分组', trailing: `${this.sessions.length} 个会话` })
      if (this.childGroups().length === 0) {
        Card({ pad: 12 }) {
          Text('还没有会话')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }
      } else {
        ForEach(this.childGroups(), (group: JourneyNode) => {
          Card({ pad: 12 }) {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Text('▦')
                  .fontSize(12)
                  .fontColor(Tok.brand)
                Text(group.label)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tok.text1(this.dark))
                Blank()
                Text(`${this.childrenOf(group.id).length} 个会话`)
                  .fontSize(11)
                  .fontColor(Tok.text3(this.dark))
              }
              .width('100%')

              ForEach(this.childrenOf(group.id), (sn: JourneyNode) => {
                this.sessionLine(sn, group.id)
              }, (sn: JourneyNode) => sn.id)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }, (group: JourneyNode) => group.id)
      }
    }
    .width('100%')
  }

  @Builder
  sessionLine(node: JourneyNode, parentId: string) {
    Row({ space: 6 }) {
      Text('└')
        .fontSize(12)
        .fontColor(Tok.line(this.dark))
        .width(10)
      Column({ space: 2 }) {
        Text(node.label)
          .fontSize(13)
          .fontColor(Tok.text2(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick((): void => {
            this.openSession(node.refId);
          })
        Text(`${this.edgeLabel(parentId, node.id)} · ${relativeTime(node.timestamp, this.now)}`)
          .fontSize(10)
          .fontColor(Tok.text3(this.dark))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }
}
