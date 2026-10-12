/**
 * MCP 服务器管理页。
 *
 * 诚实声明：MCP 服务器是外部进程（stdio 拉命令行，sse/http 连网络服务），
 * 鸿蒙端无法托管，所以本页只负责「把连接参数存对、启停标记管好」，
 * 真正的握手与工具调用发生在 PC 服务端。
 *
 * 编辑体验的重点：args 是 JSON 数组、env 是 JSON 对象，
 * 手写 JSON 极易出错，所以两个字段都做行内校验 + 一键格式化/纠正。
 */

import { router, promptAction } from '@kit.ArkUI';
import { McpServer, Breakpoint } from '../model/Extend';
import { McpRepo } from '../data/ExtendRepos';
import { newId } from '../data/Repos';
import { AppStore } from '../viewmodel/AppStore';
import { RemoteView } from '../viewmodel/RemoteView';
import {
  EmptyState, Card, SectionTitle, PrimaryButton, GhostButton,
  SettingRow, LabeledInput, SegmentedTabs
} from '../view/Common';
import { AdaptiveGrid } from '../view/Responsive';
import { Tok } from '../view/Theme';
import { previewOf } from '../common/Core';

const TRANSPORTS: string[] = ['stdio', 'sse', 'http'];

/** P2-3：掩蔽 env 中的敏感值（API_KEY / SECRET 等），只保留 key 名 */
function maskEnv(env: string): string {
  // 匹配 "key": "value" 或 "key": "value"，把 value 替换为 ***
  return env.replace(/("(?:key|api_key|secret|token|password|apikey|secret_key|SECRET_KEY|API_KEY|SECRET|TOKEN|PASSWORD)"\s*:\s*)"[^"]*"/gi, '$1"***"');
}

/** 字段级校验结果：ok=false 时 message 可直接展示 */
interface FieldCheck {
  ok: boolean;
  message: string;
  formatted: string;
}

function goodField(formatted: string): FieldCheck {
  const f: FieldCheck = { ok: true, message: '', formatted: formatted };
  return f;
}

function badField(message: string): FieldCheck {
  const f: FieldCheck = { ok: false, message: message, formatted: '' };
  return f;
}

/** args：必须是 JSON 数组。空串等价于 []，直接给默认。 */
function checkArgs(raw: string): FieldCheck {
  const t = raw.trim();
  if (t.length === 0) {
    return goodField('[]');
  }
  const head = t.charAt(0);
  if (head !== '[') {
    if (head === '{') {
      return badField('args 是「参数列表」，要写数组 [...]，不是对象 {...}');
    }
    return badField('args 必须以 [ 开头，例如 ["--port","8080"]');
  }
  try {
    const parsed = JSON.parse(t) as string[];
    if (!Array.isArray(parsed)) {
      return badField('解析结果不是数组');
    }
    // 逐项校验：命令行参数只能是字符串，混进数字对象服务端会起不来
    for (const item of parsed) {
      if (typeof item === 'string') {
        continue;
      }
      if (typeof item === 'number' || typeof item === 'boolean') {
        return badField(`数组第 ${parsed.indexOf(item) + 1} 项是 ${typeof item}，请用字符串写法，例如 "8080"`);
      }
      return badField('数组里只能放字符串参数');
    }
    return goodField(JSON.stringify(parsed, null, 2));
  } catch (e) {
    return badField('JSON 语法错误：请检查引号与括号是否配对');
  }
}

/** env：必须是 JSON 对象（键值都是字符串） */
function checkEnv(raw: string): FieldCheck {
  const t = raw.trim();
  if (t.length === 0) {
    return goodField('{}');
  }
  const head = t.charAt(0);
  if (head !== '{') {
    if (head === '[') {
      return badField('env 是环境变量表，要写对象 {...}，不是数组 [...]');
    }
    return badField('env 必须以 { 开头，例如 {"API_KEY":"xxx"}');
  }
  try {
    const parsed = JSON.parse(t) as Record<string, string>;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return badField('解析结果不是对象');
    }
    return goodField(JSON.stringify(parsed, null, 2));
  } catch (e) {
    return badField('JSON 语法错误：请检查引号、逗号与括号是否配对');
  }
}

function transportLabel(t: string): string {
  if (t === 'sse') {
    return 'SSE';
  }
  if (t === 'http') {
    return 'HTTP';
  }
  return 'stdio';
}

/** 卡片副标题：stdio 看命令行，sse/http 看地址 */
function endpointOf(m: McpServer): string {
  if (m.transport === 'stdio') {
    if (m.command.trim().length === 0) {
      return '未填命令';
    }
    return m.command.trim();
  }
  if (m.url.trim().length === 0) {
    return '未填地址';
  }
  return m.url.trim();
}

@Entry
@Component
struct McpPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';
  @StorageLink('serverUrl') serverUrl: string = '';

  @State servers: McpServer[] = [];
  @State isNew: boolean = false;
  @State editorOpen: boolean = false;

  // 编辑表单
  @State fId: string = '';
  @State fName: string = '';
  @State fTransport: number = 0;
  @State fCommand: string = '';
  @State fUrl: string = '';
  @State fArgs: string = '[]';
  @State fEnv: string = '{}';
  @State fEnabled: boolean = true;
  @State fArgsErr: string = '';
  @State fEnvErr: string = '';
  @State fFormErr: string = '';

  aboutToAppear() {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      this.servers = await RemoteView.mcpServers(AppStore.db());
    } catch (e) {
      this.servers = [];
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
    for (const m of this.servers) {
      if (m.enabled) {
        n++;
      }
    }
    return n;
  }

  private transportAt(idx: number): string {
    if (idx === 1) {
      return 'sse';
    }
    if (idx === 2) {
      return 'http';
    }
    return 'stdio';
  }

  private transportIndex(t: string): number {
    if (t === 'sse') {
      return 1;
    }
    if (t === 'http') {
      return 2;
    }
    return 0;
  }

  /** 切成 sse/http 时 stdio 专属字段就没什么意义了，界面上直接收起来 */
  private isStdio(): boolean {
    return this.fTransport === 0;
  }

  private gotoSettings(): void {
    const opts: router.RouterOptions = { url: 'pages/SettingsPage' };
    router.pushUrl(opts);
  }

  private serverHint(): string {
    return this.serverUrl.trim().length > 0
      ? `当前服务端：${this.serverUrl.trim()}`
      : '尚未配置 PC 服务端地址，MCP 配置不会被使用';
  }

  // ───────── 编辑 ─────────

  private newServer(): void {
    this.isNew = true;
    this.fId = newId(Date.now());
    this.fName = '';
    this.fTransport = 0;
    this.fCommand = 'npx';
    this.fUrl = '';
    this.fArgs = '[]';
    this.fEnv = '{}';
    this.fEnabled = true;
    this.clearErrors();
    this.editorOpen = true;
  }

  private editServer(m: McpServer): void {
    this.isNew = false;
    this.fId = m.id;
    this.fName = m.name;
    this.fTransport = this.transportIndex(m.transport);
    this.fCommand = m.command;
    this.fUrl = m.url;
    this.fArgs = m.args.length > 0 ? m.args : '[]';
    this.fEnv = m.env.length > 0 ? m.env : '{}';
    this.fEnabled = m.enabled;
    this.clearErrors();
    this.editorOpen = true;
  }

  private clearErrors(): void {
    this.fArgsErr = '';
    this.fEnvErr = '';
    this.fFormErr = '';
  }

  /** 输入时实时清掉该字段的错误，避免旧提示一直挂着 */
  private onArgsChange(v: string): void {
    this.fArgs = v;
    this.fArgsErr = '';
  }

  private onEnvChange(v: string): void {
    this.fEnv = v;
    this.fEnvErr = '';
  }

  /** 一键把 args 规整成多行数组 */
  private formatArgs(): void {
    const c = checkArgs(this.fArgs);
    if (!c.ok) {
      this.fArgsErr = c.message;
      return;
    }
    this.fArgs = c.formatted;
    this.fArgsErr = '';
  }

  private formatEnv(): void {
    const c = checkEnv(this.fEnv);
    if (!c.ok) {
      this.fEnvErr = c.message;
      return;
    }
    this.fEnv = c.formatted;
    this.fEnvErr = '';
  }

  private async saveServer(): Promise<void> {
    this.clearErrors();
    if (this.fName.trim().length === 0) {
      this.fFormErr = '名称不能为空';
      return;
    }
    const transport = this.transportAt(this.fTransport);
    if (transport === 'stdio' && this.fCommand.trim().length === 0) {
      this.fFormErr = 'stdio 方式必须填启动命令';
      return;
    }
    if (transport !== 'stdio' && this.fUrl.trim().length === 0) {
      this.fFormErr = `${transportLabel(transport)} 方式必须填服务地址`;
      return;
    }
    const args = checkArgs(this.fArgs);
    if (!args.ok) {
      this.fArgsErr = args.message;
      return;
    }
    const env = checkEnv(this.fEnv);
    if (!env.ok) {
      this.fEnvErr = env.message;
      return;
    }

    const old = this.findById(this.fId);
    const m: McpServer = {
      id: this.fId,
      name: this.fName.trim(),
      transport: transport,
      // 非 stdio 时命令无意义，存空串而不是留着旧值误导
      command: transport === 'stdio' ? this.fCommand.trim() : '',
      args: args.formatted,
      url: transport === 'stdio' ? '' : this.fUrl.trim(),
      env: env.formatted,
      enabled: this.fEnabled,
      builtin: old !== null ? old.builtin : false,
      updatedAt: Date.now()
    };
    await McpRepo.upsert(AppStore.db(), m);
    this.editorOpen = false;
    await this.reload();
    promptAction.showToast({ message: '已保存（需 PC 服务端连接）' });
  }

  private findById(id: string): McpServer | null {
    for (const m of this.servers) {
      if (m.id === id) {
        return m;
      }
    }
    return null;
  }

  private async deleteServer(m: McpServer): Promise<void> {
    if (m.builtin) {
      promptAction.showToast({ message: '内置条目不可删除，可改地址或停用' });
      return;
    }
    const res = await promptAction.showDialog({
      title: '删除 MCP 服务器',
      message: `确定删除「${m.name}」？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await McpRepo.remove(AppStore.db(), m.id);
    await this.reload();
  }

  private async toggleServer(m: McpServer): Promise<void> {
    const next: McpServer = {
      id: m.id,
      name: m.name,
      transport: m.transport,
      command: m.command,
      args: m.args,
      url: m.url,
      env: m.env,
      enabled: !m.enabled,
      builtin: m.builtin,
      updatedAt: m.updatedAt
    };
    await McpRepo.upsert(AppStore.db(), next);
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
        Text('MCP 服务器')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('＋').fontSize(22).fontColor(Tok.brand)
          .width(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.newServer();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          this.noticeCard()

          if (this.servers.length === 0) {
            EmptyState({
              icon: '🔌',
              text: '还没有 MCP 服务器',
              hint: 'stdio 走命令行，sse / http 连网络服务；都需要 PC 端执行'
            })
          } else {
            SectionTitle({
              text: `${this.servers.length} 个服务器`,
              trailing: `${this.enabledCount()} 个已启用`
            })
            AdaptiveGrid({
              count: this.servers.length,
              bp: this.gridBp(),
              items: (i: number): void => {
                this.serverAt(i);
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
    .bindSheet($$this.editorOpen, this.serverEditor(), {
      height: SheetSize.LARGE,
      dragBar: true
    })
  }

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

      Text('MCP 服务器是需要托管的外部进程：stdio 要拉起本地命令行，sse / http 要保持网络连接。鸿蒙端不具备这些条件，所以本页只保存连接参数与启停状态，实际连接与工具调用由 PC 上的 Ekko Studio 服务端完成。')
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
  serverAt(i: number) {
    if (i < this.servers.length) {
      this.serverCard(this.servers[i])
    } else {
      Blank()
    }
  }

  @Builder
  serverCard(m: McpServer) {
    Card({ pad: 12 }) {
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(m.name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
              .maxLines(1)
            Text(previewOf(endpointOf(m), 46))
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(m.enabled ? '启用' : '停用')
            .fontSize(11)
            .fontColor(m.enabled ? Tok.success : Tok.text3(this.dark))
            .padding({ left: 8, top: 4, bottom: 4 })
            .onClick((): void => {
              this.toggleServer(m);
            })
        }
        .width('100%')

        Row({ space: 6 }) {
          Text(transportLabel(m.transport))
            .fontSize(10)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .borderRadius(4)
          Text(this.argsSummary(m.args))
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
          Blank()
          Text('PC 端执行')
            .fontSize(10)
            .fontColor(Tok.warn)
        }
        .width('100%')

        if (m.env.trim().length > 0 && m.env.trim() !== '{}') {
          Text(`env：${maskEnv(previewOf(m.env, 50))}`)
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .maxLines(1)
            .width('100%')
        }

        Row({ space: 6 }) {
          Button('编辑')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.editServer(m);
            })
          Button('删除')
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .fontColor(m.builtin ? Tok.text3(this.dark) : Tok.danger)
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: m.builtin ? Tok.line(this.dark) : Tok.danger })
            .borderRadius(Tok.radiusSmall)
            .onClick((): void => {
              this.deleteServer(m);
            })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 卡片上把 args 摘要成「3 个参数」，省得贴一长串 JSON */
  private argsSummary(argsJson: string): string {
    const c = checkArgs(argsJson);
    if (!c.ok) {
      return 'args 格式有误';
    }
    try {
      const arr = JSON.parse(c.formatted) as string[];
      if (arr.length === 0) {
        return '无参数';
      }
      return `${arr.length} 个参数`;
    } catch (e) {
      return '无参数';
    }
  }

  @Builder
  serverEditor() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: this.isNew ? '新增 MCP 服务器' : '编辑 MCP 服务器' })

        Text('这里只保存连接参数。实际连接与工具调用需要 PC 上的 Ekko Studio 服务端。')
          .fontSize(11)
          .fontColor(Tok.warn)
          .width('100%')

        LabeledInput({
          label: '名称',
          placeholder: '如 文件系统',
          value: this.fName,
          onChange: (v: string): void => {
            this.fName = v;
          }
        })

        Column({ space: 6 }) {
          Text('传输方式').fontSize(12).fontColor(Tok.text2(this.dark)).width('100%')
          SegmentedTabs({
            items: TRANSPORTS,
            active: this.fTransport,
            onChange: (idx: number): void => {
              this.fTransport = idx;
            }
          })
          Text(this.isStdio()
            ? 'stdio：由 PC 拉起本地命令行进程，通过标准输入输出通信'
            : `${transportLabel(this.transportAt(this.fTransport))}：连接一个已在运行的网络服务`)
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        if (this.isStdio()) {
          LabeledInput({
            label: '启动命令',
            placeholder: 'npx / uvx / python',
            value: this.fCommand,
            onChange: (v: string): void => {
              this.fCommand = v;
            }
          })
        } else {
          LabeledInput({
            label: '服务地址',
            placeholder: 'http://127.0.0.1:3000/sse',
            value: this.fUrl,
            onChange: (v: string): void => {
              this.fUrl = v;
            }
          })
        }

        this.fieldError(this.fFormErr)

        this.argsField()
        this.envField()

        SettingRow({
          title: '启用',
          subtitle: '关闭后服务端不会连接这个 MCP 服务器',
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
              this.saveServer();
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

  /** 统一的红框行内错误；msg 为空时不渲染 */
  @Builder
  fieldError(msg: string) {
    if (msg.length > 0) {
      Row({ space: 6 }) {
        Text('✗').fontSize(12).fontColor(Tok.danger)
        Text(msg)
          .fontSize(12)
          .fontColor(Tok.danger)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(8)
      .backgroundColor(this.dark ? '#2A1414' : '#FFECE8')
      .borderRadius(Tok.radiusSmall)
    }
  }

  @Builder
  argsField() {
    Column({ space: 6 }) {
      Row() {
        Text('args（JSON 数组）')
          .fontSize(12)
          .fontColor(Tok.text2(this.dark))
          .layoutWeight(1)
        Text('格式化').fontSize(12).fontColor(Tok.brand)
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.formatArgs();
          })
      }
      .width('100%')

      TextArea({ placeholder: '["-y", "@modelcontextprotocol/server-filesystem"]', text: this.fArgs })
        .fontSize(13)
        .fontFamily('monospace')
        .placeholderColor(Tok.text3(this.dark))
        .backgroundColor(Tok.fieldBg(this.dark))
        .borderRadius(Tok.radiusSmall)
        .height(110)
        .width('100%')
        .onChange((v: string): void => {
          this.onArgsChange(v);
        })

      if (this.fArgsErr.length > 0) {
        this.fieldError(this.fArgsErr)
      } else {
        Text('命令行参数列表，每项都要加引号；数字也要写成 "8080" 而不是 8080。')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  envField() {
    Column({ space: 6 }) {
      Row() {
        Text('env（JSON 对象）')
          .fontSize(12)
          .fontColor(Tok.text2(this.dark))
          .layoutWeight(1)
        Text('格式化').fontSize(12).fontColor(Tok.brand)
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.formatEnv();
          })
      }
      .width('100%')

      TextArea({ placeholder: '{ "API_KEY": "xxx" }', text: this.fEnv })
        .fontSize(13)
        .fontFamily('monospace')
        .placeholderColor(Tok.text3(this.dark))
        .backgroundColor(Tok.fieldBg(this.dark))
        .borderRadius(Tok.radiusSmall)
        .height(100)
        .width('100%')
        .onChange((v: string): void => {
          this.onEnvChange(v);
        })

      if (this.fEnvErr.length > 0) {
        this.fieldError(this.fEnvErr)
      } else {
        Text('传给进程的环境变量，形如 {"TOKEN":"abc"}；没有就留空。')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
