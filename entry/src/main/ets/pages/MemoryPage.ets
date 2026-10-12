/**
 * 记忆管理页。
 *
 * 这一页最要紧的是「透明」：记忆不是普通备注，它会被拼进**系统提示词**发给模型。
 * 所以顶部固定挂一条说明，用户改一条记忆前就知道它会影响什么。
 *
 * 作用域三选一（用 MemoryRepo.effective，它会把全局记忆一起返回）：
 *   global  全局：所有会话都生效
 *   session 当前会话：只对这个 sessionId 生效
 *   room    当前群聊：只对这个 roomId 生效
 */

import { router, promptAction } from '@kit.ArkUI';
import { MemoryItem, Breakpoint } from '../model/Extend';
import { MemoryRepo } from '../data/ExtendRepos';
import { AppStore } from '../viewmodel/AppStore';
import { RemoteView } from '../viewmodel/RemoteView';
import { blockLocalWrite } from '../viewmodel/ServerMode';
import { relativeTime, previewOf, compactNumber } from '../common/Core';
import {
  EmptyState, Card, SectionTitle, PrimaryButton, GhostButton,
  LabeledInput, SegmentedTabs, CodeBlock
} from '../view/Common';
import { AdaptiveGrid } from '../view/Responsive';
import { Tok } from '../view/Theme';

// ───────────────────────── 路由参数 ─────────────────────────

interface MemoryRouteParams {
  sessionId: string;
  roomId: string;
}

/** 三种作用域 */
type MemoryScope = 'global' | 'session' | 'room';

const SCOPES: MemoryScope[] = ['global', 'session', 'room'];

/** 记忆类型 */
type MemoryKind = 'note' | 'fact' | 'preference';

const KINDS: MemoryKind[] = ['note', 'fact', 'preference'];

// ───────────────────────── 纯函数 / 工厂 ─────────────────────────

function scopeLabel(scope: string): string {
  if (scope === 'global') {
    return '全局';
  }
  if (scope === 'session') {
    return '会话';
  }
  if (scope === 'room') {
    return '群聊';
  }
  return scope;
}

function kindLabel(kind: string): string {
  if (kind === 'fact') {
    return '事实';
  }
  if (kind === 'preference') {
    return '偏好';
  }
  return '备注';
}

function kindAt(idx: number): string {
  if (idx === 1) {
    return 'fact';
  }
  if (idx === 2) {
    return 'preference';
  }
  return 'note';
}

function kindIndex(kind: string): number {
  if (kind === 'fact') {
    return 1;
  }
  if (kind === 'preference') {
    return 2;
  }
  return 0;
}

function errText(e: Error, fallback: string): string {
  return e !== null && e.message.length > 0 ? e.message : fallback;
}

/**
 * 拼出「这次会真正注入系统提示词的内容」。
 *
 * 让用户能直接看到模型会读到什么 —— 这是这个页面的核心价值，
 * 否则用户只能凭「我改了数据库」盲猜效果。
 */
function composePrompt(items: MemoryItem[]): string {
  const lines: string[] = [];
  lines.push('（示例）以下是用户为你保存的长期记忆，请始终遵守：');
  for (const m of items) {
    lines.push('');
    lines.push(`## ${kindLabel(m.kind)}${m.pinned ? '（置顶）' : ''}`);
    lines.push(m.content);
  }
  if (lines.length === 1) {
    lines.push('（当前作用域下还没有任何记忆）');
  }
  return lines.join('\n');
}

@Entry
@Component
struct MemoryPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';

  @State sessionId: string = '';
  @State roomId: string = '';

  @State scopeIdx: number = 0;
  @State items: MemoryItem[] = [];
  @State loading: boolean = false;
  @State loadErr: string = '';

  // 编辑表单
  @State editorOpen: boolean = false;
  @State isNew: boolean = true;
  @State fId: string = '';
  @State fContent: string = '';
  @State fKindIdx: number = 0;
  @State fPinned: boolean = false;

  @State previewOpen: boolean = false;

  aboutToAppear() {
    this.readParams();
    this.reload();
  }

  private readParams(): void {
    try {
      const p = router.getParams() as MemoryRouteParams;
      this.sessionId = p !== null && p !== undefined ? (p.sessionId ?? '') : '';
      this.roomId = p !== null && p !== undefined ? (p.roomId ?? '') : '';
    } catch (e) {
      this.sessionId = '';
      this.roomId = '';
    }
  }

  private gridBp(): Breakpoint {
    if (this.bp === 'expanded') {
      return 'expanded';
    }
    if (this.bp === 'medium') {
      return 'medium';
    }
    return 'compact';
  }

  /** 当前作用域。切换 tab 时下标越界要夹住，否则 effective 会拿 undefined 去查库。 */
  private scope(): MemoryScope {
    const i = this.scopeIdx;
    if (i >= 0 && i < SCOPES.length) {
      return SCOPES[i];
    }
    return 'global';
  }

  /** 当前作用域对应的 scopeId */
  private scopeId(): string {
    const s = this.scope();
    if (s === 'session') {
      return this.sessionId;
    }
    if (s === 'room') {
      return this.roomId;
    }
    return '';
  }

  /** 会话/群聊作用域必须有一个非空 id，否则会误查到别人的记忆 */
  private scopeReady(): boolean {
    return this.scopeId().length > 0;
  }

  private scopeHint(): string {
    const s = this.scope();
    if (s === 'global') {
      return '全局记忆对所有会话生效。';
    }
    if (s === 'session') {
      return this.sessionId.length > 0 ?
        `仅对当前会话 ${this.sessionId} 生效。` :
        '当前没有传入会话 id，此作用域暂不可用。';
    }
    return this.roomId.length > 0 ?
      `仅对当前群聊 ${this.roomId} 生效。` :
      '当前没有传入群聊 id，此作用域暂不可用。';
  }

  private async reload(): Promise<void> {
    if (!this.scopeReady() && this.scope() !== 'global') {
      this.items = [];
      this.loadErr = this.scopeHint();
      return;
    }
    this.loading = true;
    this.loadErr = '';
    try {
      // effective 会把全局记忆一起带出来：这才是「模型实际能读到的全集」
      this.items = await RemoteView.memory(AppStore.db(), this.scope(), this.scopeId());
    } catch (e) {
      this.items = [];
      this.loadErr = `读取失败：${errText(e as Error, '未知错误')}`;
    }
    this.loading = false;
  }

  private onScopeChange(idx: number): void {
    this.scopeIdx = idx;
    this.reload();
  }

  private findById(id: string): MemoryItem | null {
    for (const m of this.items) {
      if (m.id === id) {
        return m;
      }
    }
    return null;
  }

  private pinnedCount(): number {
    let n = 0;
    for (const m of this.items) {
      if (m.pinned) {
        n++;
      }
    }
    return n;
  }

  private globalCount(): number {
    let n = 0;
    for (const m of this.items) {
      if (m.scope === 'global') {
        n++;
      }
    }
    return n;
  }

  // ───────── 增删改 ─────────

  private openNew(): void {
    if (!this.scopeReady() && this.scope() !== 'global') {
      promptAction.showToast({ message: this.scopeHint() });
      return;
    }
    this.isNew = true;
    this.fId = '';
    this.fContent = '';
    this.fKindIdx = 0;
    this.fPinned = false;
    this.editorOpen = true;
  }

  private openEdit(m: MemoryItem): void {
    this.isNew = false;
    this.fId = m.id;
    this.fContent = m.content;
    this.fKindIdx = kindIndex(m.kind);
    this.fPinned = m.pinned;
    this.editorOpen = true;
  }

  /**
   * 保存。
   *
   * 新增走 MemoryRepo.add；编辑走 MemoryRepo.update —— 后者保住 id 与 hit_count。
   * 之前编辑只能「删旧建新」（add 内部用 newId(now) 自造 id、无法指定），
   * 代价是每次编辑记忆的使用统计就归零。现在数据层补了 update，不再需要那套。
   */
  private async save(): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已新增」假成功 toast
    if (blockLocalWrite('记忆')) {
      return;
    }
    const content = this.fContent.trim();
    if (content.length === 0) {
      promptAction.showToast({ message: '记忆内容不能为空' });
      return;
    }
    const now = Date.now();
    try {
      if (this.isNew) {
        // P2-12：add 现在返回新记录 id，直接按 id 置顶，
        //   不再用「同内容+同时间」反查（并发下可能 pin 错记录）。
        const newId = await MemoryRepo.add(
          AppStore.db(), this.scope(), this.scopeId(), kindAt(this.fKindIdx), content, now);
        if (this.fPinned && newId.length > 0) {
          await MemoryRepo.setPinned(AppStore.db(), newId, true);
        }
      } else {
        const old = this.findById(this.fId);
        if (old === null) {
          promptAction.showToast({ message: '这条记忆已不存在' });
          return;
        }
        // update 只改 kind/content/updated_at，id 与 hit_count 不动
        await MemoryRepo.update(
          AppStore.db(), old.id, kindAt(this.fKindIdx), content, now);
        // 置顶按「用户意图」而非旧值：表单里勾了才置顶，取消勾选才取消
        if (this.fPinned !== old.pinned) {
          await MemoryRepo.setPinned(AppStore.db(), old.id, this.fPinned);
        }
      }
      this.editorOpen = false;
      await this.reload();
      promptAction.showToast({
        message: this.isNew ? '已新增' : '已保存'
      });
    } catch (e) {
      promptAction.showToast({ message: `保存失败：${errText(e as Error, '未知错误')}` });
    }
  }

  /**
   * 刚 add 完的那条置顶。
   *
   * P2-12 后已不需要：MemoryRepo.add 直接返回新 id，save 里按 id 置顶。
   * 保留方法签名兼容潜在外部调用 —— ArkTS 不允许死代码警告变错误，先留着。
   */

  private async togglePin(m: MemoryItem): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免假成功
    if (blockLocalWrite('记忆')) {
      return;
    }
    try {
      await MemoryRepo.setPinned(AppStore.db(), m.id, !m.pinned);
      await this.reload();
    } catch (e) {
      promptAction.showToast({ message: `操作失败：${errText(e as Error, '未知错误')}` });
    }
  }

  private async removeMemory(m: MemoryItem): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已删除」假成功 toast
    if (blockLocalWrite('记忆')) {
      return;
    }
    const res = await promptAction.showDialog({
      title: '删除记忆',
      message: `确定删除这条记忆？\n\n${previewOf(m.content, 80)}`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    try {
      await MemoryRepo.remove(AppStore.db(), m.id);
      await this.reload();
      promptAction.showToast({ message: '已删除' });
    } catch (e) {
      promptAction.showToast({ message: `删除失败：${errText(e as Error, '未知错误')}` });
    }
  }

  /** 记一次命中：让用户看到这条记忆确实被对话读到过 */
  private async markHit(m: MemoryItem): Promise<void> {
    // D-R35-3：服务端模式下本地写不会生效，直接短路，避免「已记一次命中」假成功 toast
    if (blockLocalWrite('记忆')) {
      return;
    }
    try {
      await MemoryRepo.markHit(AppStore.db(), m.id);
      await this.reload();
      promptAction.showToast({ message: '已记一次命中' });
    } catch (e) {
      promptAction.showToast({ message: `操作失败：${errText(e as Error, '未知错误')}` });
    }
  }

  // ───────── 布局 ─────────

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(24)
          .onClick((): void => {
            router.back();
          })
        Text('记忆')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('查看注入').fontSize(13).fontColor(Tok.brand)
          .padding({ left: 6, right: 4 })
          .onClick((): void => {
            this.previewOpen = true;
          })
        Text('＋新增').fontSize(14).fontColor(Tok.brand)
          .padding({ left: 6, right: 4 })
          .onClick((): void => {
            this.openNew();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 8 })

      SegmentedTabs({
        items: ['全局', '当前会话', '当前群聊'],
        active: this.scopeIdx,
        onChange: (idx: number): void => {
          this.onScopeChange(idx);
        }
      })
      .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          this.noticeCard()

          if (this.loadErr.length > 0) {
            Card({ pad: 12 }) {
              Row({ space: 8 }) {
                Text('⚠').fontSize(16).fontColor(Tok.warn)
                Text(this.loadErr)
                  .fontSize(12)
                  .fontColor(Tok.text2(this.dark))
                  .layoutWeight(1)
              }
              .width('100%')
            }
          }

          if (this.loading) {
            Text('读取中…')
              .fontSize(12)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
          }

          if (this.items.length === 0) {
            EmptyState({
              icon: '🧠',
              text: '这个作用域下还没有记忆',
              hint: '记忆会被注入系统提示词，用来让模型长期记住你的偏好与事实'
            })
          } else {
            SectionTitle({
              text: `${this.items.length} 条`,
              trailing: `${this.pinnedCount()} 条置顶 · ${this.globalCount()} 条全局`
            })
            AdaptiveGrid({
              count: this.items.length,
              bp: this.gridBp(),
              items: (i: number): void => {
                this.itemAt(i);
              }
            })
          }

          Blank()
        }
        .width('100%')
        .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 30 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // P1-17 同形修复：一个组件节点只能挂一个 bindSheet。原本两个 sheet
      // 都挂在根 Column 上，后者覆盖前者 —— 前者对应的入口点了没反应。
      // 拆到两个宿主节点：本 sheet 挂 Scroll，另一个 sheet 挂根 Column。
      .bindSheet($$this.editorOpen, this.editorSheet(), {
        height: SheetSize.LARGE,
        dragBar: true
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.previewOpen, this.previewSheet(), {
      height: SheetSize.LARGE,
      dragBar: true
    })
  }

  /** 顶部说明：把「记忆会进系统提示词」这件事说透 */
  @Builder
  noticeCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('会注入系统提示词')
          .fontSize(11)
          .fontColor(Tok.warn)
          .backgroundColor(this.dark ? '#2A1F0E' : '#FFF3E0')
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(4)
        Blank()
        Text('预览注入内容').fontSize(12).fontColor(Tok.brand)
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.previewOpen = true;
          })
      }
      .width('100%')

      Text('这里的每一条记忆都会被拼进系统提示词，模型在每次对话开始时都会读到。' +
        '「全局」作用域对所有会话生效；「当前会话」「当前群聊」只对对应对象生效，' +
        '但列表里始终包含全局记忆 —— 那部分模型同样读得到。')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')

      Text(this.scopeHint())
        .fontSize(11)
        .fontColor(Tok.text2(this.dark))
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tok.cardBg(this.dark))
    .borderRadius(Tok.radius)
    .border({ width: 1, color: Tok.line(this.dark) })
  }

  @Builder
  itemAt(i: number) {
    if (i < this.items.length) {
      this.itemCard(this.items[i])
    } else {
      Blank()
    }
  }

  @Builder
  itemCard(m: MemoryItem) {
    Card({ pad: 12 }) {
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          if (m.pinned) {
            Text('📌')
              .fontSize(11)
              .fontColor(Tok.warn)
          }
          Text(kindLabel(m.kind))
            .fontSize(10)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(4)
          Text(scopeLabel(m.scope))
            .fontSize(10)
            .fontColor(m.scope === 'global' ? Tok.success : Tok.text3(this.dark))
            .backgroundColor(m.scope === 'global' ?
              (this.dark ? '#12281A' : '#E8F8EC') : Tok.fieldBg(this.dark))
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(4)
          Blank()
          Text(relativeTime(m.updatedAt, Date.now()))
            .fontSize(10)
            .fontColor(Tok.text3(this.dark))
        }
        .width('100%')

        Text(m.content)
          .fontSize(13)
          .fontColor(Tok.text1(this.dark))
          .width('100%')
          .maxLines(6)

        Text(`命中 ${compactNumber(m.hitCount)} 次 · 创建于 ${relativeTime(m.createdAt, Date.now())}`)
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')

        Row({ space: 6 }) {
          Button(m.pinned ? '取消置顶' : '置顶')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.warn)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.togglePin(m);
            })
          Button('记一次命中')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .backgroundColor(Tok.fieldBg(this.dark))
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.markHit(m);
            })
          Button('编辑')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.openEdit(m);
            })
          Button('删除')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.danger)
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: Tok.danger })
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.removeMemory(m);
            })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  editorSheet() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: this.isNew ? '新增记忆' : '编辑记忆' })

        Column({ space: 6 }) {
          Text('类型')
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
          SegmentedTabs({
            items: ['备注', '事实', '偏好'],
            active: this.fKindIdx,
            onChange: (idx: number): void => {
              this.fKindIdx = idx;
            }
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        LabeledInput({
          label: '记忆内容',
          placeholder: '如：我习惯用中文回答，代码注释也写中文',
          value: this.fContent,
          onChange: (v: string): void => {
            this.fContent = v;
          }
        })

        Text('这段文字会原样进入系统提示词。写「事实」或「偏好」比写「备注」更有效 —— ' +
          '模型对明确陈述的响应比对模糊描述更稳定。')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')

        Text(`将保存到：${scopeLabel(this.scope())}作用域`)
          .fontSize(11)
          .fontColor(Tok.text2(this.dark))
          .width('100%')

        Row({ space: 6 }) {
          Text(this.fPinned ? '已置顶（保存后生效）' : '未置顶')
            .fontSize(13)
            .fontColor(this.fPinned ? Tok.warn : Tok.text2(this.dark))
            .layoutWeight(1)
          GhostButton({
            label: this.fPinned ? '取消置顶' : '设为置顶',
            onTap: (): void => {
              this.fPinned = !this.fPinned;
            }
          })
        }
        .width('100%')

        Row({ space: 8 }) {
          if (!this.isNew) {
            GhostButton({
              label: '取消',
              onTap: (): void => {
                this.editorOpen = false;
              }
            })
          }
          PrimaryButton({
            label: '保存',
            busy: false,
            onTap: (): void => {
              this.save();
            }
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }

  @Builder
  previewSheet() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: '将注入的内容', trailing: `${this.items.length} 条` })

        Text('下面是当前作用域下（含全局）全部记忆拼成的提示词片段。' +
          '真实发送时它会追加在系统提示词的固定前缀之后。')
          .fontSize(12)
          .fontColor(Tok.text2(this.dark))
          .width('100%')

        CodeBlock({
          body: composePrompt(this.items),
          lang: 'system',
          dark: this.dark
        })

        Text('置顶的记忆排在最前，模型更容易优先遵守；命中次数反映它在过往对话里被读取的频次。')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')

        Row({ space: 8 }) {
          Button('刷新')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.reload();
            })
          PrimaryButton({
            label: '关闭',
            busy: false,
            onTap: (): void => {
              this.previewOpen = false;
            }
          })
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }
}
