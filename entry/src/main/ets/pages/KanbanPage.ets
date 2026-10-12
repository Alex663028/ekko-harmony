/**
 * 看板页：任务在列之间流转。
 * 对应原版 KanbanView。
 *
 * 两条硬约束：
 *  1. WIP 限制必须在移动**之前**用 insertPosition 检查，超限直接拒绝并提示，
 *     不能先挪再补提示——那样列已经超了。
 *  2. 同列内排序用 Core 的 reorderIds 算新顺序，再逐张回写 position，
 *     避免页面自己写一套插入算法。
 */

import { router, promptAction } from '@kit.ArkUI';
import { KanbanColumn, KanbanCard } from '../model/Extend';
import { KanbanRepo } from '../data/ExtendRepos';
import { newId } from '../data/Repos';
import { AppStore } from '../viewmodel/AppStore';
import { RemoteView } from '../viewmodel/RemoteView';
import {
  insertPosition, reorderIds, priorityLabel, kanbanDefaultColumns,
  previewOf, relativeTime
} from '../common/Core';
import {
  Card, SectionTitle, EmptyState, LabeledInput, PrimaryButton, SegmentedTabs
} from '../view/Common';
import { Tok } from '../view/Theme';

/** 优先级 0高 1中 2低 → 展示与配色 */
function priorityColor(p: number, dark: boolean): string {
  if (p === 0) {
    return Tok.danger;
  }
  if (p === 1) {
    return Tok.warn;
  }
  return dark ? Tok.text3(dark) : Tok.text2(dark);
}

@Entry
@Component
struct KanbanPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';

  @State columns: KanbanColumn[] = [];
  @State cards: KanbanCard[] = [];
  @State now: number = Date.now();

  @State cardSheet: boolean = false;
  @State cardColumnId: string = '';
  @State editingCardId: string = '';
  @State cTitle: string = '';
  @State cBody: string = '';
  @State cTag: string = '';
  @State cPriority: number = 1;

  @State colSheet: boolean = false;
  @State newColName: string = '';
  @State newColWip: string = '';

  aboutToAppear() {
    this.reload();
  }

  /** 宽屏（PC）看板横排，手机单栏纵排 */
  private wide(): boolean {
    return this.bp === 'expanded';
  }

  private async reload(): Promise<void> {
    try {
      // ensureDefaults / allCards 都是本地写，服务端模式下必须跳过，
      // 否则会往手机空库里塞一堆默认列，页面看起来有数据其实全是假的。
      if ((AppStorage.get<string>('dataSource') ?? 'local') !== 'server') {
        await KanbanRepo.ensureDefaults(AppStore.db());
      }
      this.columns = await RemoteView.kanban(AppStore.db());
      this.cards = await RemoteView.kanbanCards(AppStore.db());
      this.now = Date.now();
    } catch (e) {
      promptAction.showToast({ message: `加载失败: ${(e as Error).message}` });
    }
  }

  // ───────── 数据视图 ─────────

  private cardsOf(columnId: string): KanbanCard[] {
    const out: KanbanCard[] = [];
    for (const c of this.cards) {
      if (c.columnId === columnId) {
        out.push(c);
      }
    }
    return out;
  }

  private columnName(columnId: string): string {
    for (const c of this.columns) {
      if (c.id === columnId) {
        return c.name;
      }
    }
    return '未知列';
  }

  private columnIndex(columnId: string): number {
    for (let i = 0; i < this.columns.length; i++) {
      if (this.columns[i].id === columnId) {
        return i;
      }
    }
    return -1;
  }

  private wipText(col: KanbanColumn): string {
    const n = this.cardsOf(col.id).length;
    if (col.wipLimit > 0) {
      return `${n}/${col.wipLimit}`;
    }
    return `${n}`;
  }

  /** 目标列已满时给出可读提示 */
  private wipDenied(col: KanbanColumn): string {
    return `「${col.name}」已达 WIP 上限（${col.wipLimit}），先移走一张再过来`;
  }

  // ───────── 移动 ─────────

  /**
   * 跨列移动。desired 传目标列当前数量即表示「放到末尾」。
   * 返回 false 表示被 WIP 拒绝，调用方负责提示。
   */
  private async moveTo(cardId: string, targetColId: string, desired: number): Promise<boolean> {
    const target = this.columns.find((c: KanbanColumn) => c.id === targetColId);
    if (target === undefined) {
      return false;
    }
    const pos = insertPosition(this.cardsOf(targetColId).length, target.wipLimit, desired);
    if (pos < 0) {
      promptAction.showToast({ message: this.wipDenied(target) });
      return false;
    }
    await KanbanRepo.moveCard(AppStore.db(), cardId, targetColId, pos);
    // 同列内移动要把后面的卡顺推，否则 position 会撞车
    if (pos < this.cardsOf(targetColId).length) {
      await this.shiftAfter(targetColId, pos, cardId);
    }
    await this.reload();
    return true;
  }

  private async moveLeft(card: KanbanCard): Promise<void> {
    const idx = this.columnIndex(card.columnId);
    if (idx <= 0) {
      promptAction.showToast({ message: '已经在最左列' });
      return;
    }
    const target = this.columns[idx - 1];
    await this.moveTo(card.id, target.id, this.cardsOf(target.id).length);
  }

  private async moveRight(card: KanbanCard): Promise<void> {
    const idx = this.columnIndex(card.columnId);
    if (idx < 0 || idx >= this.columns.length - 1) {
      promptAction.showToast({ message: '已经在最右列' });
      return;
    }
    const target = this.columns[idx + 1];
    await this.moveTo(card.id, target.id, this.cardsOf(target.id).length);
  }

  /** compact 下只有一个前进按钮：移到下一列末尾 */
  private async moveNext(card: KanbanCard): Promise<void> {
    const idx = this.columnIndex(card.columnId);
    if (idx < 0 || idx >= this.columns.length - 1) {
      promptAction.showToast({ message: '已经是最后一列' });
      return;
    }
    const target = this.columns[idx + 1];
    await this.moveTo(card.id, target.id, this.cardsOf(target.id).length);
  }

  /** 同列内上移/下移：用 reorderIds 算新序，再逐张回写 */
  private async reorder(card: KanbanCard, delta: number): Promise<void> {
    const list = this.cardsOf(card.columnId);
    const ids: string[] = [];
    for (const c of list) {
      ids.push(c.id);
    }
    const fromIdx = ids.indexOf(card.id);
    if (fromIdx < 0) {
      return;
    }
    const toIdx = fromIdx + delta;
    if (toIdx < 0 || toIdx >= ids.length) {
      return;
    }
    const nextIds = reorderIds(ids, fromIdx, toIdx);
    for (let i = 0; i < nextIds.length; i++) {
      await KanbanRepo.moveCard(AppStore.db(), nextIds[i], card.columnId, i);
    }
    await this.reload();
  }

  /**
   * 插入到 pos 后，把同列里位于 pos 之后的卡整体后移一位。
   *
   * ⚠ 这里**必须用移动前（不含新卡）的 list**：moveCard 只是把新卡
   *   position 写成 pos，目标列原 pos.. 的卡在 DB 里还没动，
   *   旧 list 的索引 i 正好对应「原 position i 的卡」，顺推到 i+1 才正确。
   *   若改成移动后含新卡的 list，索引会整体偏移 1，原 pos 卡会被推到 pos+2。
   *   skipId 是为将来「同列内移动」预留的；当前 moveTo 仅跨列且总是
   *   追加到末尾（desired=目标列数量 → pos=数量），故 shiftAfter 不触发。
   */
  private async shiftAfter(columnId: string, pos: number, skipId: string): Promise<void> {
    const list = this.cardsOf(columnId);
    for (let i = pos; i < list.length; i++) {
      const c = list[i];
      if (c.id === skipId) {
        continue;
      }
      await KanbanRepo.moveCard(AppStore.db(), c.id, columnId, i + 1);
    }
  }

  // ───────── 卡片增删改 ─────────

  private openNewCard(columnId: string): void {
    this.editingCardId = '';
    this.cardColumnId = columnId;
    this.cTitle = '';
    this.cBody = '';
    this.cTag = '';
    this.cPriority = 1;
    this.cardSheet = true;
  }

  private openEditCard(c: KanbanCard): void {
    this.editingCardId = c.id;
    this.cardColumnId = c.columnId;
    this.cTitle = c.title;
    this.cBody = c.body;
    this.cTag = c.tag;
    this.cPriority = c.priority;
    this.cardSheet = true;
  }

  private async saveCard(): Promise<void> {
    if (this.cTitle.trim().length === 0) {
      promptAction.showToast({ message: '标题不能为空' });
      return;
    }
    const nowTs = Date.now();
    const isNew = this.editingCardId.length === 0;
    const id = isNew ? newId(nowTs) : this.editingCardId;
    let position = 0;
    let createdAt = nowTs;
    if (!isNew) {
      const old = this.cards.find((c: KanbanCard) => c.id === this.editingCardId);
      if (old !== undefined) {
        position = old.position;
        createdAt = old.createdAt;
      }
    } else {
      position = this.cardsOf(this.cardColumnId).length;
      // 新建也要守 WIP，否则限制形同虚设
      const col = this.columns.find((c: KanbanColumn) => c.id === this.cardColumnId);
      if (col !== undefined) {
        const p = insertPosition(this.cardsOf(col.id).length, col.wipLimit, position);
        if (p < 0) {
          promptAction.showToast({ message: this.wipDenied(col) });
          return;
        }
        position = p;
      }
    }
    const card: KanbanCard = {
      id: id,
      columnId: this.cardColumnId,
      title: this.cTitle.trim(),
      body: this.cBody,
      tag: this.cTag.trim(),
      priority: this.cPriority,
      position: position,
      sessionId: '',
      createdAt: createdAt,
      updatedAt: nowTs
    };
    await KanbanRepo.upsertCard(AppStore.db(), card);
    this.cardSheet = false;
    await this.reload();
  }

  private async removeCard(c: KanbanCard): Promise<void> {
    const res = await promptAction.showDialog({
      title: '删除卡片',
      message: `确定删除「${c.title}」？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await KanbanRepo.removeCard(AppStore.db(), c.id);
    await this.reload();
  }

  // ───────── 列增删 ─────────

  private openNewColumn(): void {
    this.newColName = '';
    this.newColWip = '0';
    this.colSheet = true;
  }

  private async saveColumn(): Promise<void> {
    const name = this.newColName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '列名不能为空' });
      return;
    }
    const wip = Number(this.newColWip);
    const wipLimit = isFinite(wip) && wip > 0 ? Math.floor(wip) : 0;
    await KanbanRepo.addColumn(
      AppStore.db(), newId(Date.now()), name, this.columns.length, wipLimit);
    this.colSheet = false;
    await this.reload();
  }

  private async removeColumn(col: KanbanColumn): Promise<void> {
    const n = this.cardsOf(col.id).length;
    const extra = n > 0 ? `\n列内 ${n} 张卡片也会一并删除。` : '';
    const res = await promptAction.showDialog({
      title: '删除列',
      message: `确定删除「${col.name}」？${extra}`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await KanbanRepo.removeColumn(AppStore.db(), col.id);
    await this.reload();
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
        Text('看板')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('＋列').fontSize(14).fontColor(Tok.brand)
          .padding({ left: 8, right: 4 })
          .onClick((): void => {
            this.openNewColumn();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })
      // P1-17 同形修复：一个组件节点只能挂一个 bindSheet。原本两个 sheet 都挂在
      // 根 Column 上，后者覆盖前者 —— 前者对应的入口点了没反应。根 Column 体内是
      // 条件分支（无 Scroll 可挂），故本 sheet 移到顶栏链末节点，另一个 sheet 留根 Column。
      .bindSheet($$this.cardSheet, this.cardEditor(), {
        height: SheetSize.LARGE,
        dragBar: true
      })

      if (this.columns.length === 0) {
        EmptyState({
          icon: '▦',
          text: '看板还没有列',
          hint: '默认列：' + kanbanDefaultColumns().join(' / ')
        })
      } else if (this.wide()) {
        this.kanbanRow()
      } else {
        this.kanbanColumnStack()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.colSheet, this.columnEditor(), {
      height: SheetSize.MEDIUM,
      dragBar: true
    })
  }

  /** expanded（PC）：横向多列并排，整体可左右滚 */
  @Builder
  kanbanRow() {
    Scroll() {
      Row({ space: 10 }) {
        ForEach(this.columns, (col: KanbanColumn) => {
          Column() {
            this.columnHead(col)
            Scroll() {
              Column({ space: 8 }) {
                ForEach(this.cardsOf(col.id), (card: KanbanCard) => {
                  Card({ pad: 10 }) {
                    Column({ space: 6 }) {
                      this.cardBody(card)
                      this.cardActions(card, true)
                    }
                    .width('100%')
                    .alignItems(HorizontalAlign.Start)
                  }
                }, (card: KanbanCard) => card.id)
                this.addCardHint(col)
              }
              .width('100%')
              .padding({ bottom: 10 })
            }
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
          }
          .width(280)
          .height('100%')
          .padding(10)
          .backgroundColor(this.dark ? '#12151A' : '#EDEFF2')
          .borderRadius(Tok.radius)
        }, (col: KanbanColumn) => col.id)
      }
      .height('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 20 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  /** compact / medium：单栏纵向排，一列一屏内可独立滚动 */
  @Builder
  kanbanColumnStack() {
    Scroll() {
      Column({ space: 12 }) {
        ForEach(this.columns, (col: KanbanColumn) => {
          Column({ space: 8 }) {
            this.columnHead(col)
            ForEach(this.cardsOf(col.id), (card: KanbanCard) => {
              Card({ pad: 10 }) {
                Column({ space: 6 }) {
                  this.cardBody(card)
                  this.cardActions(card, false)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
            }, (card: KanbanCard) => card.id)
            this.addCardHint(col)
          }
          .width('100%')
          .padding(10)
          .backgroundColor(this.dark ? '#12151A' : '#EDEFF2')
          .borderRadius(Tok.radius)
        }, (col: KanbanColumn) => col.id)
        Blank()
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 30 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  columnHead(col: KanbanColumn) {
    Row({ space: 8 }) {
      Text(col.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tok.text1(this.dark))
      Text(this.wipText(col))
        .fontSize(11)
        .fontColor(col.wipLimit > 0 && this.cardsOf(col.id).length >= col.wipLimit
          ? Tok.danger : Tok.text3(this.dark))
        .backgroundColor(Tok.fieldBg(this.dark))
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
      Blank()
      Text('✕')
        .fontSize(13)
        .fontColor(Tok.text3(this.dark))
        .padding({ left: 6, right: 2 })
        .onClick((): void => {
          this.removeColumn(col);
        })
    }
    .width('100%')
  }

  @Builder
  cardBody(card: KanbanCard) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(priorityLabel(card.priority))
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor(priorityColor(card.priority, this.dark))
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .borderRadius(4)
        Text(card.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick((): void => {
            this.openEditCard(card);
          })
      }
      .width('100%')

      if (card.body.length > 0) {
        Text(previewOf(card.body, 70))
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .maxLines(2)
          .width('100%')
      }

      Row({ space: 6 }) {
        if (card.tag.length > 0) {
          Text(card.tag)
            .fontSize(10)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(4)
        }
        Blank()
        Text(this.columnName(card.columnId))
          .fontSize(10)
          .fontColor(Tok.text3(this.dark))
        Text(relativeTime(card.updatedAt, this.now))
          .fontSize(10)
          .fontColor(Tok.text3(this.dark))
      }
      .width('100%')
    }
    .width('100%')
  }

  /**
   * 卡片操作区。
   * 宽屏给「← →」精确移动，窄屏只给「移到下一列」，
   * 两者最终都走 moveTo，WIP 检查逻辑只有一处。
   */
  @Builder
  cardActions(card: KanbanCard, wideLayout: boolean) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        if (wideLayout) {
          Text('‹')
            .fontSize(15)
            .fontColor(Tok.brand)
            .width(26)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.moveLeft(card);
            })
        }
        if (!wideLayout) {
          Text('移到下一列 ›')
            .fontSize(12)
            .fontColor(Tok.brand)
        }
        Blank()
        Text('删除')
          .fontSize(12)
          .fontColor(Tok.danger)
          .padding({ right: 4 })
          .onClick((): void => {
            this.removeCard(card);
          })
      }
      .width('100%')

      Row({ space: 6 }) {
        Text('上移')
          .fontSize(11)
          .fontColor(Tok.text2(this.dark))
          .onClick((): void => {
            this.reorder(card, -1);
          })
        Text('下移')
          .fontSize(11)
          .fontColor(Tok.text2(this.dark))
          .onClick((): void => {
            this.reorder(card, 1);
          })
        Blank()
        if (wideLayout) {
          Text('›')
            .fontSize(15)
            .fontColor(Tok.brand)
            .width(26)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.moveRight(card);
            })
        }
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  addCardHint(col: KanbanColumn) {
    Text('＋ 添加卡片')
      .fontSize(12)
      .fontColor(Tok.brand)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 10, bottom: 10 })
      .borderRadius(Tok.radiusSmall)
      .border({ width: 1, color: Tok.line(this.dark) })
      .onClick((): void => {
        this.openNewCard(col.id);
      })
  }

  @Builder
  cardEditor() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: this.editingCardId.length > 0 ? '编辑卡片' : '新建卡片' })

        LabeledInput({
          label: '标题',
          placeholder: '要做什么',
          value: this.cTitle,
          onChange: (v: string): void => {
            this.cTitle = v;
          }
        })

        LabeledInput({
          label: '描述',
          placeholder: '补充说明（可空）',
          value: this.cBody,
          onChange: (v: string): void => {
            this.cBody = v;
          }
        })

        LabeledInput({
          label: '标签',
          placeholder: '如 后端 / 文档',
          value: this.cTag,
          onChange: (v: string): void => {
            this.cTag = v;
          }
        })

        Column({ space: 6 }) {
          Text('优先级')
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
          SegmentedTabs({
            items: ['高', '中', '低'],
            active: this.cPriority,
            onChange: (idx: number): void => {
              this.cPriority = idx;
            }
          })
        }
        .width('100%')

        if (this.editingCardId.length === 0) {
          Column({ space: 6 }) {
            Text('所属列')
              .fontSize(12)
              .fontColor(Tok.text2(this.dark))
              .width('100%')
            SegmentedTabs({
              items: this.columnNames(),
              active: this.columnNames().indexOf(this.cardColumnId),
              onChange: (idx: number): void => {
                const names = this.columnNames();
                const col = this.columns.find((c: KanbanColumn) => c.name === names[idx]);
                if (col !== undefined) {
                  this.cardColumnId = col.id;
                }
              }
            })
          }
          .width('100%')
        }

        PrimaryButton({
          label: '保存',
          busy: false,
          onTap: (): void => {
            this.saveCard();
          }
        })
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }

  /** SegmentedTabs 只吃 string[]，列多了这里会很长，故只在新建时用 */
  private columnNames(): string[] {
    const out: string[] = [];
    for (const c of this.columns) {
      out.push(c.name);
    }
    return out;
  }

  @Builder
  columnEditor() {
    Column({ space: 14 }) {
      SectionTitle({ text: '新建列' })

      LabeledInput({
        label: '列名',
        placeholder: '如 待评审',
        value: this.newColName,
        onChange: (v: string): void => {
          this.newColName = v;
        }
      })

      LabeledInput({
        label: 'WIP 上限（0 = 不限）',
        placeholder: '0',
        value: this.newColWip,
        onChange: (v: string): void => {
          this.newColWip = v;
        }
      })

      Text('WIP 限制用于防止「进行中」这类列无限堆积：达到上限后，所有移入操作都会被拒绝。')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')

      PrimaryButton({
        label: '添加',
        busy: false,
        onTap: (): void => {
          this.saveColumn();
        }
      })

      Button('取消')
        .width('100%')
        .height(38)
        .fontSize(14)
        .fontColor(Tok.text2(this.dark))
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.colSheet = false;
        })
    }
    .width('100%')
    .padding(20)
  }
}
