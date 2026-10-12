/**
 * Agent 与模型管理页：供应商（Provider）+ Agent 配置。
 * 对应原版 views/hermes/ModelsView.vue + CodingAgentConfigView.vue。
 */

import { router, promptAction } from '@kit.ArkUI';
import { Provider, ProviderApiMode, AgentProfile, AgentRuntime } from '../model/Types';
import { ProviderRepo, AgentProfileRepo, newId } from '../data/Repos';
import { AppStore } from '../viewmodel/AppStore';
import { StudioApi } from '../net/StudioApi';
import { NetConfig, errorMessage } from '../net/Http';
import { LlmEngine } from '../net/LlmEngine';
import { SettingRow, SectionTitle, Card, GhostButton, LabeledInput, PrimaryButton, EmptyState, SegmentedTabs } from '../view/Common';
import { Tok } from '../view/Theme';

// P1-1：下拉只暴露已实现的接口模式（OpenAI 兼容 + Anthropic）。
// responses / openai_responses / gemini 尚未在 LlmEngine 实现，之前客户可选到
// 必然 404 的配置。历史数据仍保留，但编辑时会收敛到 OpenAI 兼容。
const API_MODES: string[] = [
  'OpenAI 兼容',
  'Anthropic'
];

const RUNTIMES: string[] = [
  'ekko', 'hermes', 'claude-code', 'codex', 'pi', 'grok',
  'opencode', 'dsh', 'kimi', 'qwen', 'qoder', 'codebuddy'
];

@Entry
@Component
struct AgentManagerPage {
  @StorageProp('themeDark') dark: boolean = false;

  @State tab: number = 0;
  @State providers: Provider[] = [];
  @State agents: AgentProfile[] = [];
  @State editorOpen: boolean = false;
  @State editing: Provider | null = null;
  @State isNew: boolean = false;

  // 编辑表单
  @State fId: string = '';
  @State fName: string = '';
  @State fBaseUrl: string = '';
  @State fApiKey: string = '';
  @State fMode: number = 0;
  @State fModels: string = '';
  @State probing: boolean = false;
  @State probeMsg: string = '';

  aboutToAppear() {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.providers = await ProviderRepo.list(AppStore.db());
    this.agents = await AgentProfileRepo.list(AppStore.db());
  }

  // ───────── 供应商编辑 ─────────

  private newProvider(): void {
    this.isNew = true;
    this.fId = newId(Date.now());
    this.fName = '';
    this.fBaseUrl = 'https://api.openai.com/v1';
    this.fApiKey = '';
    this.fMode = 0;
    this.fModels = '';
    this.probeMsg = '';
    this.editorOpen = true;
  }

  private editProvider(p: Provider): void {
    this.isNew = false;
    this.fId = p.id;
    this.fName = p.name;
    this.fBaseUrl = p.baseUrl;
    this.fApiKey = p.apiKey;
    this.fMode = API_MODES.indexOf(this.modeLabel(p.apiMode));
    if (this.fMode < 0) {
      this.fMode = 0;
    }
    this.fModels = p.models.join('\n');
    this.probeMsg = '';
    this.editorOpen = true;
  }

  private modeLabel(m: ProviderApiMode): string {
    if (m === 'anthropic') {
      return 'Anthropic';
    }
    if (m === 'gemini') {
      return 'Gemini';
    }
    if (m === 'openai_responses' || m === 'responses') {
      return 'OpenAI Responses';
    }
    return 'OpenAI 兼容';
  }

  private async saveProvider(): Promise<void> {
    if (this.fName.trim().length === 0 || this.fBaseUrl.trim().length === 0) {
      promptAction.showToast({ message: '名称与地址都要填' });
      return;
    }
    const models = this.fModels
      .split(/[\n,]/)
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
    const p: Provider = {
      id: this.fId,
      name: this.fName.trim(),
      baseUrl: this.fBaseUrl.trim(),
      apiKey: this.fApiKey.trim(),
      // 表单保存：当前输入即明文，状态按是否非空判定（保存后落库加密，读取时重新计算三态）
      apiKeyState: this.fApiKey.trim().length > 0 ? 'ok' : 'empty',
      apiMode: this.modeToApi(this.fMode),
      models: models,
      enabled: true,
      builtin: false,
      updatedAt: Date.now()
    };
    // 服务端模式：写到 PC（服务端有 POST /api/hermes/config/providers）
    if ((AppStorage.get<string>('dataSource') ?? 'local') === 'server') {
      try {
        // P1-10：服务端模式下省略 apiKey，让服务端复用已有配置。
        // 手机端不需要配 key（Repos.ets:1044-1046 的占位 Provider 逻辑），
        // 明文 POST apiKey 到 PC 端会被记录到日志或数据库。
        await StudioApi.createRemoteProvider(
          NetConfig.getToken(), p.name, p.baseUrl,
          p.models.length > 0 ? p.models[0] : 'default');
        this.editorOpen = false;
        await this.reload();
        promptAction.showToast({ message: '已保存到电脑' });
      } catch (e) {
        promptAction.showToast({ message: '保存失败：' + errorMessage(e) });
      }
      return;
    }

    try {
      await ProviderRepo.upsert(AppStore.db(), p, Date.now());
      await AppStore.reloadProviders();
      this.editorOpen = false;
      await this.reload();
      promptAction.showToast({ message: '已保存' });
    } catch (e) {
      promptAction.showToast({ message: '保存失败：' + errorMessage(e) });
    }
  }

  private modeToApi(idx: number): ProviderApiMode {
    if (idx === 1) {
      return 'anthropic';
    }
    return 'chat_completions';
  }

  private async probe(): Promise<void> {
    if (this.fApiKey.trim().length === 0) {
      this.probeMsg = '先填 API Key';
      return;
    }
    this.probing = true;
    this.probeMsg = '检测中…';
    const target: Provider = this.newProviderDraft();
    const res = await LlmEngine.probe(target);
    this.probing = false;
    this.probeMsg = res.ok ? `✓ ${res.message}` : `✗ ${res.message}`;
    if (res.modelCount > 0) {
      // probe 只回了数量，具体名单再拉一次，方便直接填进模型列表
      const fetched = await LlmEngine.listModels(target);
      if (fetched.length > 0) {
        this.fModels = fetched.join('\n');
      }
    }
  }

  /** 用当前表单内容造一个临时 Provider 供探测用 */
  private newProviderDraft(): Provider {
    const models: string[] = [];
    const raw = this.fModels.split(/[\n,]/);
    for (const s of raw) {
      const t = s.trim();
      if (t.length > 0) {
        models.push(t);
      }
    }
    const p: Provider = {
      id: this.fId,
      name: this.fName,
      baseUrl: this.fBaseUrl.trim(),
      apiKey: this.fApiKey.trim(),
      // 探测用草稿：表单当前输入即明文，状态按是否非空判定
      apiKeyState: this.fApiKey.trim().length > 0 ? 'ok' : 'empty',
      apiMode: this.modeToApi(this.fMode),
      models: models,
      enabled: true,
      builtin: false,
      updatedAt: Date.now()
    };
    return p;
  }

  private async deleteProvider(p: Provider): Promise<void> {
    if (p.builtin) {
      promptAction.showToast({ message: '内置供应商不可删除，可改地址与 Key' });
      return;
    }
    const res = await promptAction.showDialog({
      title: '删除供应商',
      message: `确定删除「${p.name}」？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await ProviderRepo.delete(AppStore.db(), p.id);
    await AppStore.reloadProviders();
    await this.reload();
  }

  private async toggleProvider(p: Provider): Promise<void> {
    p.enabled = !p.enabled;
    try {
      await ProviderRepo.upsert(AppStore.db(), p, Date.now());
      await AppStore.reloadProviders();
      await this.reload();
    } catch (e) {
      // 回滚内存态：开关失败不能让 UI 停留在与数据库不一致的状态
      p.enabled = !p.enabled;
      promptAction.showToast({ message: '更新失败：' + errorMessage(e) });
    }
  }

  // ───────── Agent 编辑 ─────────

  @State agentSheet: boolean = false;
  @State aId: string = '';
  @State aName: string = '';
  @State aRuntime: string = 'ekko';
  @State aProviderId: string = '';
  @State aModel: string = '';
  @State aPrompt: string = '';
  @State aEnabled: boolean = true;

  private newAgent(): void {
    const providers = AppStore.providers();
    const p = providers.length > 0 ? providers[0] : null;
    this.aId = newId(Date.now());
    this.aName = '';
    this.aRuntime = 'ekko';
    this.aProviderId = p !== null ? p.id : '';
    this.aModel = p !== null && p.models.length > 0 ? p.models[0] : '';
    this.aPrompt = '';
    this.aEnabled = true;
    this.agentSheet = true;
  }

  private editAgent(a: AgentProfile): void {
    this.aId = a.id;
    this.aName = a.name;
    this.aRuntime = a.runtime;
    this.aProviderId = a.provider;
    this.aModel = a.model;
    this.aPrompt = a.systemPrompt;
    this.aEnabled = a.enabled;
    this.agentSheet = true;
  }

  private async saveAgent(): Promise<void> {
    if (this.aName.trim().length === 0) {
      promptAction.showToast({ message: 'Agent 名称不能为空' });
      return;
    }
    const p = this.providers.find((x) => x.id === this.aProviderId);
    const a: AgentProfile = {
      id: this.aId,
      name: this.aName.trim(),
      runtime: this.aRuntime as AgentRuntime,
      provider: this.aProviderId,
      model: this.aModel,
      apiMode: p !== undefined ? p.apiMode : 'chat_completions',
      systemPrompt: this.aPrompt,
      reasoningEffort: '',
      toolsEnabled: false,
      enabled: this.aEnabled,
      updatedAt: Date.now()
    };
    await AgentProfileRepo.upsert(AppStore.db(), a, Date.now());
    await AppStore.reloadAgents();
    this.agentSheet = false;
    await this.reload();
    promptAction.showToast({ message: '已保存' });
  }

  private async deleteAgent(a: AgentProfile): Promise<void> {
    const res = await promptAction.showDialog({
      title: '删除 Agent',
      message: `确定删除「${a.name}」？`,
      buttons: [{ text: '取消', color: '#61666E' }, { text: '删除', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await AgentProfileRepo.delete(AppStore.db(), a.id);
    await AppStore.reloadAgents();
    await this.reload();
  }

  private onProviderPick(idx: number): void {
    const p = this.providers[idx];
    if (p === undefined) {
      return;
    }
    this.aProviderId = p.id;
    if (p.models.length > 0) {
      this.aModel = p.models[0];
    }
  }

  private modelsOfCurrentProvider(): string[] {
    const p = this.providers.find((x) => x.id === this.aProviderId);
    return p !== undefined ? p.models : [];
  }

  /** Scheme A 三态：供应商列表的 Key 状态文案 */
  private keyStateLabel(p: Provider): string {
    if (p.apiKeyState === 'undecryptable') {
      return '解密失败';
    }
    return p.apiKey.length > 0 ? 'Key 已填' : '未填 Key';
  }

  /** Scheme A 三态：Key 状态文案的颜色 */
  private keyStateColor(p: Provider): ResourceColor {
    if (p.apiKeyState === 'undecryptable') {
      return Tok.danger;
    }
    return p.apiKey.length > 0 ? Tok.success : Tok.warn;
  }

  /** Scheme A 三态：Agent 选择器里的可用性文案 */
  private keyAvailabilityLabel(p: Provider): string {
    if (p.apiKeyState === 'undecryptable') {
      return '解密失败';
    }
    return p.apiKey.length > 0 ? '可用' : '缺 Key';
  }

  /** Scheme A 三态：Agent 选择器里的可用性颜色 */
  private keyAvailabilityColor(p: Provider): ResourceColor {
    if (p.apiKeyState === 'undecryptable') {
      return Tok.danger;
    }
    return p.apiKey.length > 0 ? Tok.success : Tok.warn;
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(24)
          .onClick(() => router.back())
        Text('模型与 Agent')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('＋').fontSize(22).fontColor(Tok.brand)
          .width(32)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            if (this.tab === 0) {
              this.newProvider();
            } else {
              this.newAgent();
            }
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      SegmentedTabs({
        items: ['供应商', 'Agent'],
        active: this.tab,
        onChange: (idx: number) => {
          this.tab = idx;
        }
      })
      .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 10 })

      Scroll() {
        Column({ space: 10 }) {
          if (this.tab === 0) {
            this.providerList()
          } else {
            this.agentList()
          }
        }
        .width('100%')
        .padding({ left: Tok.pagePad, right: Tok.pagePad, bottom: 30 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // P1-17: 一个组件节点只能挂一个 bindSheet，原来 provider / agent 两个 sheet
      // 都挂在根 Column 上，后者覆盖前者 —— 供应商「编辑」和「＋」点了没反应。
      // 拆到两个不同宿主节点：provider sheet 挂 Scroll，agent sheet 挂根 Column。
      .bindSheet($$this.editorOpen, this.providerEditor(), {
        height: SheetSize.LARGE,
        dragBar: true
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
    .bindSheet($$this.agentSheet, this.agentEditor(), {
      height: SheetSize.LARGE,
      dragBar: true
    })
  }

  @Builder
  providerList() {
    Column({ space: 10 }) {
      SectionTitle({ text: `${this.providers.length} 个供应商` })
      ForEach(this.providers, (p: Provider) => {
        Card({ pad: 12 }) {
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(p.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tok.text1(this.dark))
                Text(p.baseUrl)
                  .fontSize(11)
                  .fontColor(Tok.text3(this.dark))
                  .maxLines(1)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(p.enabled ? '启用' : '停用')
                .fontSize(11)
                .fontColor(p.enabled ? Tok.success : Tok.text3(this.dark))
                .padding({ left: 8, top: 4, bottom: 4 })
                .onClick(() => this.toggleProvider(p))
            }
            .width('100%')

            Row({ space: 6 }) {
              Text(this.modeLabel(p.apiMode))
                .fontSize(11)
                .fontColor(Tok.brand)
                .backgroundColor(Tok.brandSoft)
                .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                .borderRadius(4)
              Text(`${p.models.length} 个模型`)
                .fontSize(11)
                .fontColor(Tok.text3(this.dark))
              Blank()
              Text(this.keyStateLabel(p))
                .fontSize(11)
                .fontColor(this.keyStateColor(p))
            }
            .width('100%')

            Row({ space: 8 }) {
              Button('编辑')
                .layoutWeight(1)
                .height(34)
                .fontSize(13)
                .fontColor(Tok.brand)
                .backgroundColor(Tok.brandSoft)
                .borderRadius(Tok.radiusSmall)
                .onClick(() => this.editProvider(p))
              Button('删除')
                .layoutWeight(1)
                .height(34)
                .fontSize(13)
                .fontColor(Tok.danger)
                .backgroundColor(Color.Transparent)
                .border({ width: 1, color: Tok.danger })
                .borderRadius(Tok.radiusSmall)
                .onClick(() => this.deleteProvider(p))
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }, (p: Provider) => p.id)
    }
    .width('100%')
  }

  @Builder
  providerEditor() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: this.isNew ? '新增供应商' : '编辑供应商' })

        LabeledInput({
          label: '名称',
          placeholder: '如 LongCat',
          value: this.fName,
          onChange: (v: string) => {
            this.fName = v;
          }
        })

        LabeledInput({
          label: 'API 地址',
          placeholder: 'https://api.openai.com/v1',
          value: this.fBaseUrl,
          onChange: (v: string) => {
            this.fBaseUrl = v;
          }
        })

        LabeledInput({
          label: 'API Key',
          placeholder: 'sk-...',
          value: this.fApiKey,
          secret: true,
          onChange: (v: string) => {
            this.fApiKey = v;
          }
        })

        Column({ space: 6 }) {
          Text('接口协议')
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
          SegmentedTabs({
            items: API_MODES,
            active: this.fMode,
            onChange: (idx: number) => {
              this.fMode = idx;
            }
          })
        }
        .width('100%')

        LabeledInput({
          label: '模型列表（每行一个，或用逗号分隔）',
          placeholder: 'gpt-4o\ndeepseek-chat',
          value: this.fModels,
          onChange: (v: string) => {
            this.fModels = v;
          }
        })

        Row({ space: 8 }) {
          Button(this.probing ? '检测中…' : '测试连接')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Tok.brand)
            .backgroundColor(Tok.brandSoft)
            .borderRadius(Tok.radiusSmall)
            .enabled(!this.probing)
            .onClick(() => this.probe())
          PrimaryButton({
            label: '保存',
            busy: false,
            onTap: () => this.saveProvider()
          })
        }
        .width('100%')

        if (this.probeMsg.length > 0) {
          Text(this.probeMsg)
            .fontSize(12)
            .fontColor(this.probeMsg.indexOf('✓') === 0 ? Tok.success : Tok.danger)
            .width('100%')
        }
      }
      .width('100%')
      .padding(20)
    }
    .width('100%')
  }

  @Builder
  agentList() {
    Column({ space: 10 }) {
      if (this.agents.length === 0) {
        EmptyState({
          icon: '🤖',
          text: '还没有 Agent',
          hint: 'Agent 决定「谁」来回答：名称、模型、人设提示词'
        })
      } else {
        SectionTitle({ text: `${this.agents.length} 个 Agent` })
        ForEach(this.agents, (a: AgentProfile) => {
          Card({ pad: 12 }) {
            Column({ space: 8 }) {
              Row({ space: 10 }) {
                Circle({ width: 36, height: 36 }).fill(a.enabled ? Tok.brand : Tok.text3(this.dark))
                Column({ space: 3 }) {
                  Text(a.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tok.text1(this.dark))
                  Text(`${a.model.length > 0 ? a.model : '未选模型'} · ${a.runtime}`)
                    .fontSize(11)
                    .fontColor(Tok.text3(this.dark))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')

              if (a.systemPrompt.length > 0) {
                Text(a.systemPrompt)
                  .fontSize(11)
                  .fontColor(Tok.text3(this.dark))
                  .maxLines(2)
                  .width('100%')
              }

              Row({ space: 8 }) {
                Button('编辑')
                  .layoutWeight(1)
                  .height(34)
                  .fontSize(13)
                  .fontColor(Tok.brand)
                  .backgroundColor(Tok.brandSoft)
                  .borderRadius(Tok.radiusSmall)
                  .onClick(() => this.editAgent(a))
                Button('删除')
                  .layoutWeight(1)
                  .height(34)
                  .fontSize(13)
                  .fontColor(Tok.danger)
                  .backgroundColor(Color.Transparent)
                  .border({ width: 1, color: Tok.danger })
                  .borderRadius(Tok.radiusSmall)
                  .onClick(() => this.deleteAgent(a))
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }, (a: AgentProfile) => a.id)
      }
    }
    .width('100%')
  }

  @Builder
  agentEditor() {
    Scroll() {
      Column({ space: 14 }) {
        SectionTitle({ text: 'Agent 配置' })

        LabeledInput({
          label: '名称',
          placeholder: '如 架构师',
          value: this.aName,
          onChange: (v: string) => {
            this.aName = v;
          }
        })

        LabeledInput({
          label: '运行时类型',
          placeholder: 'ekko / claude-code / codex…',
          value: this.aRuntime,
          onChange: (v: string) => {
            this.aRuntime = v;
          }
        })

        Column({ space: 6 }) {
          Text('供应商')
            .fontSize(12)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
          Column({ space: 6 }) {
            ForEach(this.providers, (p: Provider, idx: number) => {
              Row({ space: 8 }) {
                Circle({ width: 8, height: 8 })
                  .fill(this.aProviderId === p.id ? Tok.brand : Tok.text3(this.dark))
                Text(p.name)
                  .fontSize(14)
                  .fontColor(this.aProviderId === p.id ? Tok.text1(this.dark) : Tok.text2(this.dark))
                Blank()
                Text(this.keyAvailabilityLabel(p))
                  .fontSize(11)
                  .fontColor(this.keyAvailabilityColor(p))
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .onClick(() => this.onProviderPick(idx))
            }, (p: Provider) => p.id)
          }
          .width('100%')
          .padding(Tok.cardPad)
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radiusSmall)
          .border({ width: 1, color: Tok.line(this.dark) })
        }
        .width('100%')

        if (this.modelsOfCurrentProvider().length > 0) {
          Column({ space: 6 }) {
            Text('模型')
              .fontSize(12)
              .fontColor(Tok.text2(this.dark))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.modelsOfCurrentProvider(), (m: string) => {
                Text(m)
                  .fontSize(12)
                  .fontColor(this.aModel === m ? '#FFFFFF' : Tok.text2(this.dark))
                  .backgroundColor(this.aModel === m ? Tok.brand : Tok.cardBg(this.dark))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .margin({ right: 6, bottom: 6 })
                  .onClick(() => {
                    this.aModel = m;
                  })
              }, (m: string) => m)
            }
            .width('100%')
          }
          .width('100%')
        }

        LabeledInput({
          label: '系统提示词（人设）',
          placeholder: '你是…',
          value: this.aPrompt,
          onChange: (v: string) => {
            this.aPrompt = v;
          }
        })

        Row({ space: 10 }) {
          Button(this.aEnabled ? '已启用' : '已停用')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(this.aEnabled ? Tok.success : Tok.text3(this.dark))
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: this.aEnabled ? Tok.success : Tok.text3(this.dark) })
            .borderRadius(Tok.radiusSmall)
            .onClick(() => {
              this.aEnabled = !this.aEnabled;
            })
          PrimaryButton({
            label: '保存',
            busy: false,
            onTap: () => this.saveAgent()
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