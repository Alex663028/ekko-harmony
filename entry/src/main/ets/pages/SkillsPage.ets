/**
 * 技能（Skill）管理页。
 *
 * 关键认知（决定了这一页和插件/MCP 页的根本差别）：
 * Skill 的正文是「注入到 system prompt 的指令」，不是需要拉起的外部进程，
 * 所以启停与编辑**完全可以在本机生效**，无需 PC 服务端。
 * 启用后，聊天时会把 instructions 拼在系统提示词之后。
 *
 * 因此本页的重点是：把「将要注入的内容」透明地摊开给用户看。
 */

import { router, promptAction } from '@kit.ArkUI';
import { Skill, Breakpoint } from '../model/Extend';
import { SkillRepo, composeSystemPrompt } from '../data/ExtendRepos';
import { newId } from '../data/Repos';
import { AppStore } from '../viewmodel/AppStore';
import { RemoteView } from '../viewmodel/RemoteView';
import {
  MdText, EmptyState, Card, SectionTitle, PrimaryButton, GhostButton,
  SettingRow, LabeledInput, SegmentedTabs, CodeBlock
} from '../view/Common';
import { AdaptiveGrid } from '../view/Responsive';
import { Tok } from '../view/Theme';
import { compactNumber, relativeTime, previewOf } from '../common/Core';

/** 来源枚举：local=本地自建 / bundled=随包内置 / server=服务端下发 */
const SOURCES: string[] = ['local', 'bundled', 'server'];

function sourceLabel(s: string): string {
  if (s === 'bundled') {
    return '内置';
  }
  if (s === 'server') {
    return '服务端';
  }
  return '本地';
}

/** 编辑表单的来源下标 ↔ 存储值 */
function sourceAt(idx: number): string {
  if (idx === 1) {
    return 'bundled';
  }
  if (idx === 2) {
    return 'server';
  }
  return 'local';
}

function sourceIndex(s: string): number {
  if (s === 'bundled') {
    return 1;
  }
  if (s === 'server') {
    return 2;
  }
  return 0;
}

/**
 * 拼一段示例系统提示词。
 * 逐字模拟启用这些技能后真正会发给模型的内容，让用户能验证效果。
 * 与聊天侧实际注入共用 data/ExtendRepos.composeSystemPrompt（P0-1）。
 */

@Entry
@Component
struct SkillsPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';

  @State skills: Skill[] = [];
  @State isNew: boolean = false;
  @State editorOpen: boolean = false;
  @State previewOpen: boolean = false;
  /** 预览中的技能 id；空串表示看全部启用项拼出来的完整系统提示词 */
  @State previewId: string = '';

  // 编辑表单
  @State fId: string = '';
  @State fName: string = '';
  @State fDesc: string = '';
  @State fSource: number = 0;
  @State fBody: string = '';
  @State fEnabled: boolean = true;

  aboutToAppear() {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.skills = await RemoteView.skills(AppStore.db());
    } catch (e) {
      this.skills = [];
    }
  }

  /** AppStorage 里存的是 string，这里收敛成 Breakpoint 联合类型再喂给 AdaptiveGrid */
  private gridBp(): Breakpoint {
    if (this.bp === 'expanded') {
      return 'expanded';
    }
    if (this.bp === 'medium') {
      return 'medium';
    }
    return 'compact';
  }

  private enabledCount(): number {
    let n = 0;
    for (const s of this.skills) {
      if (s.enabled) {
        n++;
      }
    }
    return n;
  }

  private findById(id: string): Skill | null {
    for (const s of this.skills) {
      if (s.id === id) {
        return s;
      }
    }
    return null;
  }

  // ───────── 编辑 ─────────

  private newSkill(): void {
    this.isNew = true;
    this.fId = newId(Date.now());
    this.fName = '';
    this.fDesc = '';
    this.fSource = 0;
    this.fBody = '';
    this.fEnabled = true;
    this.editorOpen = true;
  }

  private editSkill(s: Skill): void {
    this.isNew = false;
    this.fId = s.id;
    this.fName = s.name;
    this.fDesc = s.description;
    this.fSource = sourceIndex(s.source);
    this.fBody = s.instructions;
    this.fEnabled = s.enabled;
    this.editorOpen = true;
  }

  private async saveSkill(): Promise<void> {
    if (this.fName.trim().length === 0) {
      promptAction.showToast({ message: '技能名称不能为空' });
      return;
    }
    if (this.fBody.trim().length === 0) {
      promptAction.showToast({ message: '指令正文为空，启用后没有任何效果' });
      return;
    }
    // 保留原有的使用统计与 builtin 标记，编辑不该把计数清零
    const old = this.findById(this.fId);
    const s: Skill = {
      id: this.fId,
      name: this.fName.trim(),
      description: this.fDesc.trim(),
      instructions: this.fBody,
      // P2-13：来源由系统决定，表单不再让用户选，恒为 local
      source: 'local',
      enabled: this.fEnabled,
      usageCount: old !== null ? old.usageCount : 0,
      lastUsedAt: old !== null ? old.lastUsedAt : 0,
      builtin: old !== null ? old.builtin : false,
      updatedAt: Date.now()
    };
    await SkillRepo.upsert(AppStore.db(), s);
    this.editorOpen = false;
    await this.reload();
    promptAction.showToast({ message: '已保存' });
  }

  private async toggleSkill(s: Skill): Promise<void> {
    await SkillRepo.setEnabled(AppStore.db(), s.id, !s.enabled);
    await this.reload();
  }

  private async deleteSkill(s: Skill): Promise<void> {
    if (s.builtin) {
      promptAction.showToast({ message: '内置技能不可删除，可改指令正文' });
      return;
    }
    const res = await promptAction.showDialog({
      title: '删除技能',
      message: `确定删除「${s.name}」？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await SkillRepo.remove(AppStore.db(), s.id);
    await this.reload();
  }

  // ───────── 预览注入内容 ─────────

  private previewOne(s: Skill): void {
    this.previewId = s.id;
    this.previewOpen = true;
  }

  private previewAll(): void {
    this.previewId = '';
    this.previewOpen = true;
  }

  private previewTarget(): Skill | null {
    if (this.previewId.length === 0) {
      return null;
    }
    return this.findById(this.previewId);
  }

  /** 预览页底部展示的完整系统提示词：固定前缀 + 启用技能追加段（P0-1 收敛为唯一事实源） */
  private composedPrompt(): string {
    const base = '你是 Ekko Studio 的编程助手。用用户的语言回答，结论优先，保持简洁。';
    const skillsPart = composeSystemPrompt(this.skills);
    return skillsPart.length > 0 ? `${base}\n\n${skillsPart}` : base;
  }

  /** 只做一次计数，模拟"这条技能在一次对话里被用到" */
  private async simulateUse(): Promise<void> {
    const t = this.previewTarget();
    if (t === null) {
      promptAction.showToast({ message: '先在上面选一个技能' });
      return;
    }
    await SkillRepo.markUsed(AppStore.db(), t.id, Date.now());
    await this.reload();
    promptAction.showToast({ message: `已记一次使用：${t.name}` });
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
        Text('技能')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('＋').fontSize(22).fontColor(Tok.brand)
          .width(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.newSkill();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          this.noticeCard()

          if (this.skills.length === 0) {
            EmptyState({
              icon: '🧩',
              text: '还没有技能',
              hint: '技能是一段会注入系统提示词的指令，纯本地生效'
            })
          } else {
            SectionTitle({
              text: `${this.skills.length} 个技能`,
              trailing: `${this.enabledCount()} 个已启用`
            })
            AdaptiveGrid({
              count: this.skills.length,
              bp: this.gridBp(),
              items: (i: number): void => {
                this.skillAt(i);
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
      .bindSheet($$this.editorOpen, this.skillEditor(), {
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

  /** 顶部说明：把「本地生效」这件事说清楚，别让用户以为要连 PC */
  @Builder
  noticeCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('本机生效').fontSize(11).fontColor(Tok.success)
          .backgroundColor(this.dark ? '#12281A' : '#E8F8EC')
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(4)
        Blank()
        Text('查看注入内容').fontSize(12).fontColor(Tok.brand)
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.previewAll();
          })
      }
      .width('100%')

      Text('技能的正文就是一段会追加到系统提示词后面的指令，不需要任何外部进程，启用后立刻在对话中生效。')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tok.cardBg(this.dark))
    .borderRadius(Tok.radius)
    .border({ width: 1, color: Tok.line(this.dark) })
  }

  /** AdaptiveGrid 固定铺 9 格，超出列表长度的格子留空 */
  @Builder
  skillAt(i: number) {
    if (i < this.skills.length) {
      this.skillCard(this.skills[i])
    } else {
      Blank()
    }
  }

  @Builder
  skillCard(s: Skill) {
    Card({ pad: 12 }) {
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(s.name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
              .maxLines(1)
            Text(sourceLabel(s.source) + (s.builtin ? ' · 内置' : ''))
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(s.enabled ? '启用' : '停用')
            .fontSize(11)
            .fontColor(s.enabled ? Tok.success : Tok.text3(this.dark))
            .padding({ left: 8, top: 4, bottom: 4 })
            .onClick((): void => {
              this.toggleSkill(s);
            })
        }
        .width('100%')

        if (s.description.length > 0) {
          Text(previewOf(s.description, 70))
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .maxLines(2)
            .width('100%')
        }

        Text(previewOf(s.instructions, 80))
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .maxLines(2)
          .width('100%')
          .padding(8)
          .backgroundColor(Tok.fieldBg(this.dark))
          .borderRadius(Tok.radiusSmall)

        Row({ space: 6 }) {
          Text(`用了 ${compactNumber(s.usageCount)} 次`)
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
          Blank()
          Text(s.lastUsedAt > 0 ? relativeTime(s.lastUsedAt, Date.now()) : '未使用过')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
        }
        .width('100%')

        Row({ space: 6 }) {
          Button('注入预览')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.previewOne(s);
            })
          Button('编辑')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .backgroundColor(Tok.fieldBg(this.dark))
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.editSkill(s);
            })
          if (!s.builtin) {
            Button('删除')
              .layoutWeight(1)
              .height(32)
              .fontSize(12)
              .fontColor(Tok.danger)
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: Tok.danger })
              .borderRadius(Tok.radiusSmall)
              .onClick((): void => {
                this.deleteSkill(s);
              })
          }
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  skillEditor() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: this.isNew ? '新建技能' : '编辑技能' })

        if (this.fDesc.length > 0) {
          Column({ space: 4 }) {
            Text('描述').fontSize(12).fontColor(Tok.text2(this.dark)).width('100%')
            MdText({ source: this.fDesc, fontSize: 12 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        LabeledInput({
          label: '名称',
          placeholder: '如 代码审查',
          value: this.fName,
          onChange: (v: string): void => {
            this.fName = v;
          }
        })

        LabeledInput({
          label: '描述（一句话说明这个技能做什么）',
          placeholder: '提交前自动检查空指针与竞态',
          value: this.fDesc,
          onChange: (v: string): void => {
            this.fDesc = v;
          }
        })

        Column({ space: 6 }) {
          Text('来源').fontSize(12).fontColor(Tok.text2(this.dark)).width('100%')
          // P2-13：来源是系统决定的属性（local=本机自建），不是用户输入。
          //   之前把 bundled/server 暴露成可选项，选了也只改标签、不会随包分发，
          //   容易误导。新建固定 local；编辑时只读展示来源标签，不允许修改。
          Text(sourceLabel(this.isNew ? 'local' : sourceAt(this.fSource)))
            .fontSize(14)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(this.dark ? Tok.darkBgCard : '#EDEFF2')
            .borderRadius(Tok.radiusSmall)
        }
        .width('100%')

        Column({ space: 6 }) {
          Row() {
            Text('指令正文（注入到系统提示词）')
              .fontSize(12)
              .fontColor(Tok.text2(this.dark))
              .layoutWeight(1)
            Text(`${this.fBody.length} 字`)
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
          }
          .width('100%')

          TextArea({ placeholder: '写下希望模型始终遵守的规则…', text: this.fBody })
            .fontSize(14)
            .placeholderColor(Tok.text3(this.dark))
            .backgroundColor(Tok.fieldBg(this.dark))
            .borderRadius(Tok.radiusSmall)
            .height(170)
            .width('100%')
            .onChange((v: string): void => {
              this.fBody = v;
            })

          Text('这段文字会原样追加到系统提示词末尾，不做任何改写。')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        SettingRow({
          title: '启用',
          subtitle: '关闭后不注入系统提示词',
          value: this.fEnabled ? '开' : '关',
          onTap: (): void => {
            this.fEnabled = !this.fEnabled;
          }
        })

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
              this.saveSkill();
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
        SectionTitle({ text: '将注入的内容' })

        if (this.previewTarget() === null) {
          Text('下面是当前所有已启用技能拼出的系统提示词（示例）。停用某个技能，这里就会少一段。')
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
        } else {
          Column({ space: 6 }) {
            Text(`${this.previewTarget()?.name ?? ''} 的指令正文`)
              .fontSize(12)
              .fontColor(Tok.text2(this.dark))
              .width('100%')
            Text(this.previewTarget()?.enabled === true ? '状态：已启用（会注入）' : '状态：已停用（不会注入）')
              .fontSize(11)
              .fontColor(this.previewTarget()?.enabled === true ? Tok.success : Tok.text3(this.dark))
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          CodeBlock({
            body: this.previewTarget()?.instructions ?? '',
            lang: 'markdown',
            dark: this.dark
          })
        }

        Column({ space: 6 }) {
          Text('实际发送时的系统提示词（示例）')
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
          CodeBlock({
            body: this.composedPrompt(),
            lang: 'system',
            dark: this.dark
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Text('提示词里除技能指令外的文字是应用自带的固定前缀，仅作示意，不代表服务端最终拼装结果。')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')

        Row({ space: 8 }) {
          Button('记一次使用')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.simulateUse();
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
