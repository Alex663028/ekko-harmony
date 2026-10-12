/**
 * 插件（Plugin）管理页。
 *
 * 诚实声明（老板「混合：能本地就本地」原则下的结论）：
 * 插件的本质是装在 PC 服务端的 Node/Python 运行时进程，**鸿蒙端拉不起来**。
 * 所以本页只做一件事：把插件的配置条目存下来、启停标记管起来，
 * 真正的加载与执行必须连到 PC 上的 Ekko Studio 服务端。
 * 界面上不提供任何"运行/测试"按钮，避免给出能本地跑的错误暗示。
 */

import { router, promptAction } from '@kit.ArkUI';
import { Plugin, Breakpoint } from '../model/Extend';
import { PluginRepo } from '../data/ExtendRepos';
import { newId } from '../data/Repos';
import { AppStore } from '../viewmodel/AppStore';
import {
  EmptyState, Card, SectionTitle, PrimaryButton, GhostButton,
  SettingRow, LabeledInput, CodeBlock
} from '../view/Common';
import { AdaptiveGrid } from '../view/Responsive';
import { Tok } from '../view/Theme';
import { relativeTime } from '../common/Core';

/** JSON 校验结果：ok=false 时 message 直接可以显示给用户 */
interface ConfigCheck {
  ok: boolean;
  message: string;
  /** 校验通过时给回格式化后的文本；失败时为空串 */
  formatted: string;
}

function okConfig(formatted: string): ConfigCheck {
  const c: ConfigCheck = { ok: true, message: 'JSON 合法', formatted: formatted };
  return c;
}

function badConfig(message: string): ConfigCheck {
  const c: ConfigCheck = { ok: false, message: message, formatted: '' };
  return c;
}

/**
 * 校验插件 config。
 *
 * config 是「一个 JSON 对象」：允许 {} 这种空壳，但不能是数组或标量。
 * ArkTS 禁 any，所以先按 interface 接住，再用首字符做形状判定。
 */
function checkPluginConfig(raw: string): ConfigCheck {
  const t = raw.trim();
  if (t.length === 0) {
    return badConfig('配置不能为空，最少写 {}');
  }
  const head = t.charAt(0);
  if (head !== '{') {
    if (head === '[') {
      return badConfig('这里要填 JSON 对象（{...}），不是数组');
    }
    return badConfig('必须以 { 开头，例如 {"key":"value"}');
  }
  try {
    const parsed = JSON.parse(t) as Record<string, Object>;
    if (parsed === null || typeof parsed !== 'object') {
      return badConfig('解析结果不是对象');
    }
    return okConfig(JSON.stringify(parsed, null, 2));
  } catch (e) {
    return badConfig('JSON 语法错误：请检查引号、逗号与括号是否配对');
  }
}

@Entry
@Component
struct PluginsPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';
  @StorageLink('serverUrl') serverUrl: string = '';

  @State plugins: Plugin[] = [];
  @State isNew: boolean = false;
  @State editorOpen: boolean = false;

  // 编辑表单
  @State fId: string = '';
  @State fName: string = '';
  @State fVersion: string = '';
  @State fDesc: string = '';
  @State fConfig: string = '{}';
  @State fEnabled: boolean = true;
  @State fError: string = '';

  aboutToAppear() {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.plugins = await PluginRepo.list(AppStore.db());
    } catch (e) {
      this.plugins = [];
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

  private enabledCount(): number {
    let n = 0;
    for (const p of this.plugins) {
      if (p.enabled) {
        n++;
      }
    }
    return n;
  }

  private serverHint(): string {
    return this.serverUrl.trim().length > 0
      ? `当前服务端：${this.serverUrl.trim()}`
      : '尚未配置服务端地址，插件无法被服务端加载';
  }

  /** 跳到设置页去填 PC 服务端地址 */
  private gotoSettings(): void {
    const opts: router.RouterOptions = { url: 'pages/SettingsPage' };
    router.pushUrl(opts);
  }

  // ───────── 编辑 ─────────

  private newPlugin(): void {
    this.isNew = true;
    this.fId = newId(Date.now());
    this.fName = '';
    this.fVersion = '1.0.0';
    this.fDesc = '';
    this.fConfig = '{\n  "enabled": true\n}';
    this.fEnabled = true;
    this.fError = '';
    this.editorOpen = true;
  }

  private editPlugin(p: Plugin): void {
    this.isNew = false;
    this.fId = p.id;
    this.fName = p.name;
    this.fVersion = p.version;
    this.fDesc = p.description;
    this.fConfig = p.config;
    this.fEnabled = p.enabled;
    this.fError = '';
    this.editorOpen = true;
  }

  /** 点了"格式化"才真的重排，编辑过程中不打断输入 */
  private formatConfig(): void {
    const c = checkPluginConfig(this.fConfig);
    if (!c.ok) {
      this.fError = c.message;
      return;
    }
    this.fConfig = c.formatted;
    this.fError = '';
  }

  private async savePlugin(): Promise<void> {
    if (this.fName.trim().length === 0) {
      this.fError = '插件名称不能为空';
      return;
    }
    const c = checkPluginConfig(this.fConfig);
    if (!c.ok) {
      this.fError = c.message;
      return;
    }
    // upsert 是整行覆盖，编辑时必须带回原安装时间，
    // 否则卡片上的「记录于 …」每次编辑都变成「刚刚」。
    const prev = this.findPlugin(this.fId);
    const p: Plugin = {
      id: this.fId,
      name: this.fName.trim(),
      version: this.fVersion.trim().length > 0 ? this.fVersion.trim() : '0.0.0',
      description: this.fDesc.trim(),
      enabled: this.fEnabled,
      config: c.formatted,
      installedAt: prev !== null ? prev.installedAt : Date.now()
    };
    await PluginRepo.upsert(AppStore.db(), p);
    this.editorOpen = false;
    await this.reload();
    promptAction.showToast({ message: '配置已保存（需 PC 服务端加载）' });
  }

  /** 按 id 查找；新增时返回 null */
  private findPlugin(id: string): Plugin | null {
    for (const it of this.plugins) {
      if (it.id === id) {
        return it;
      }
    }
    return null;
  }

  private async togglePlugin(p: Plugin): Promise<void> {
    await PluginRepo.setEnabled(AppStore.db(), p.id, !p.enabled);
    await this.reload();
  }

  private async deletePlugin(p: Plugin): Promise<void> {
    const res = await promptAction.showDialog({
      title: '删除插件条目',
      message: `确定删除「${p.name}」？只删本机这条配置，不会改动 PC 上的插件本体。`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await PluginRepo.remove(AppStore.db(), p.id);
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
        Text('插件')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('＋').fontSize(22).fontColor(Tok.brand)
          .width(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.newPlugin();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          this.noticeCard()

          if (this.plugins.length === 0) {
            EmptyState({
              icon: '🧩',
              text: '还没有插件条目',
              hint: '这里只保存插件的配置，实际执行由 PC 服务端完成'
            })
          } else {
            SectionTitle({
              text: `${this.plugins.length} 个插件`,
              trailing: `${this.enabledCount()} 个已启用`
            })
            AdaptiveGrid({
              count: this.plugins.length,
              bp: this.gridBp(),
              items: (i: number): void => {
                this.pluginAt(i);
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.editorOpen, this.pluginEditor(), {
      height: SheetSize.LARGE,
      dragBar: true
    })
  }

  /** 顶部诚实标注：不能本地执行 */
  @Builder
  noticeCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('需 PC 服务端执行').fontSize(11).fontColor(Tok.warn)
          .backgroundColor(this.dark ? '#2B1F10' : '#FFF3E6')
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(4)
        Blank()
        Text('去配置服务端 ›').fontSize(12).fontColor(Tok.brand)
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.gotoSettings();
          })
      }
      .width('100%')

      Text('插件是跑在 PC 上的 Node / Python 进程，鸿蒙端无法拉起。这里保存的仅是配置与启停状态，真正的加载执行要由 PC 上的 Ekko Studio 服务端完成。')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')

      Text(this.serverHint())
        .fontSize(11)
        .fontColor(this.serverUrl.trim().length > 0 ? Tok.success : Tok.warn)
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
  pluginAt(i: number) {
    if (i < this.plugins.length) {
      this.pluginCard(this.plugins[i])
    } else {
      Blank()
    }
  }

  @Builder
  pluginCard(p: Plugin) {
    Card({ pad: 12 }) {
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(p.name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
              .maxLines(1)
            Text(p.version.length > 0 ? `v${p.version}` : '未填版本')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(p.enabled ? '启用' : '停用')
            .fontSize(11)
            .fontColor(p.enabled ? Tok.success : Tok.text3(this.dark))
            .padding({ left: 8, top: 4, bottom: 4 })
            .onClick((): void => {
              this.togglePlugin(p);
            })
        }
        .width('100%')

        if (p.description.length > 0) {
          Text(p.description)
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .maxLines(2)
            .width('100%')
        }

        Text('在 PC 端执行')
          .fontSize(10)
          .fontColor(Tok.warn)
          .backgroundColor(this.dark ? '#2B1F10' : '#FFF3E6')
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(4)

        CodeBlock({ body: p.config, lang: 'config', dark: this.dark })

        Row({ space: 6 }) {
          Text(p.installedAt > 0 ? `记录于 ${relativeTime(p.installedAt, Date.now())}` : '')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
          Blank()
        }
        .width('100%')

        Row({ space: 6 }) {
          Button('编辑配置')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.editPlugin(p);
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
              this.deletePlugin(p);
            })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  pluginEditor() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: this.isNew ? '新增插件条目' : '编辑插件配置' })

        Text('仅保存配置。插件代码在 PC 上运行，本页不会也无法在此启动它。')
          .fontSize(11)
          .fontColor(Tok.warn)
          .width('100%')

        LabeledInput({
          label: '名称',
          placeholder: '如 网页抓取',
          value: this.fName,
          onChange: (v: string): void => {
            this.fName = v;
          }
        })

        LabeledInput({
          label: '版本',
          placeholder: '1.0.0',
          value: this.fVersion,
          onChange: (v: string): void => {
            this.fVersion = v;
          }
        })

        LabeledInput({
          label: '描述',
          placeholder: '这个插件做什么',
          value: this.fDesc,
          onChange: (v: string): void => {
            this.fDesc = v;
          }
        })

        Column({ space: 6 }) {
          Row() {
            Text('配置（JSON 对象）')
              .fontSize(12)
              .fontColor(Tok.text2(this.dark))
              .layoutWeight(1)
            Text('格式化').fontSize(12).fontColor(Tok.brand)
              .padding({ left: 8, top: 4, bottom: 4 })
              .onClick((): void => {
                this.formatConfig();
              })
          }
          .width('100%')

          TextArea({ placeholder: '{ "timeout": 30 }', text: this.fConfig })
            .fontSize(13)
            .fontFamily('monospace')
            .placeholderColor(Tok.text3(this.dark))
            .backgroundColor(Tok.fieldBg(this.dark))
            .borderRadius(Tok.radiusSmall)
            .height(150)
            .width('100%')
            .onChange((v: string): void => {
              this.fConfig = v;
            })

          // 行内错误提示：非法 JSON 在这里说清楚，不让用户点保存才吃Toast
          if (this.fError.length > 0) {
            Row({ space: 6 }) {
              Text('✗').fontSize(12).fontColor(Tok.danger)
              Text(this.fError)
                .fontSize(12)
                .fontColor(Tok.danger)
                .layoutWeight(1)
            }
            .width('100%')
            .padding(8)
            .backgroundColor(this.dark ? '#2A1414' : '#FFECE8')
            .borderRadius(Tok.radiusSmall)
          } else {
            Text('提示：必须是 JSON 对象，最少 {}。数组请包一层，例如 {"tags":["a","b"]}。')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        SettingRow({
          title: '启用',
          subtitle: '关闭后服务端不会加载这个插件',
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
              this.savePlugin();
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
