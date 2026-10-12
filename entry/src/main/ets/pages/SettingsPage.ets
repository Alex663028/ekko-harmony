/**
 * 设置页：外观、模型与 Agent 入口、服务端连接、数据管理。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppStore } from '../viewmodel/AppStore';
import { isReadOnly } from '../viewmodel/ServerMode';
import { StudioApi } from '../net/StudioApi';
import { SessionRepo } from '../data/Repos';
import {
  SettingRow, SectionTitle, PrimaryButton, LabeledInput, GhostButton
} from '../view/Common';
import { Tok } from '../view/Theme';

@Entry
@Component
struct SettingsPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('serverUrl') serverUrl: string = '';
  @StorageLink('userName') userName: string = '';
  @StorageLink('userRole') userRole: string = '';

  @State serverSheet: boolean = false;
  @State editUrl: string = '';
  @State serverStatus: string = '未检测';
  @State testing: boolean = false;
  @State sessionCount: number = 0;

  aboutToAppear() {
    this.refresh();
  }

  private async refresh(): Promise<void> {
    try {
      // 只需要计数，不必把整张会话表拉进内存
      this.sessionCount = await SessionRepo.count(AppStore.db());
    } catch (e) {
      this.sessionCount = 0;
    }
  }

  /** router.pushUrl 只接受 RouterOptions 对象，不能直接传 url 字符串 */
  private openAgentManager(): void {
    const opts: router.RouterOptions = { url: 'pages/AgentManagerPage' };
    router.pushUrl(opts);
  }

  /**
   * 统一跳转。
   * router.pushUrl 只接受 RouterOptions 对象，直接传 url 字符串会编译失败
   * 且在运行时静默不跳转——所以这里收口，避免各处重复踩坑。
   */
  private open(url: string): void {
    const opts: router.RouterOptions = { url: url };
    router.pushUrl(opts);
  }

  private async testConnection(): Promise<void> {
    this.testing = true;
    const res = await StudioApi.testServer(this.editUrl);
    this.testing = false;
    this.serverStatus = res.ok ? `✓ ${res.message}` : `✗ ${res.message}`;
  }

  private async wipe(): Promise<void> {
    // 服务端模式下本地库是只读的：直接隐藏入口，但这里再兜底一次，
    // 防止未来有人绕过 UI 直接调 wipe() 造成「假成功」。
    if (isReadOnly()) {
      promptAction.showToast({ message: '服务端模式下不能清空本地数据' });
      return;
    }
    const res = await promptAction.showDialog({
      title: '清空全部会话',
      // P2-SEQ7-⑫：deleteAll 实际连看板表一起清（P0-2 修复时加入），
      // 文案必须与行为一致，否则用户以为只清会话，看板数据被意外清空。
      message: '将删除所有单聊、群聊与消息记录，以及看板卡片与分组。供应商与 Agent 配置会保留。此操作不可恢复。',
      buttons: [{ text: '取消', color: '#61666E' }, { text: '清空', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await AppStore.wipeAll();
    await this.refresh();
    promptAction.showToast({ message: '已清空' });
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(24)
          .onClick(() => router.back())
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 12 })

      Scroll() {
        Column({ space: 14 }) {
          // 账号
          // Card 组件没有 @BuilderParam，不能用尾随 lambda 传内容，
          // 这里用同样配色的 Column 本地承载。
          Column() {
            SettingRow({
              title: '当前用户',
              value: this.userName.length > 0 ? this.userName : '未登录'
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              // 与用量页的「30天内会话数」口径不同：这里是库里全部会话
              title: '会话总数',
              value: `${this.sessionCount}`
            })
          }
          .width('100%')
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })

          // 模型
          SectionTitle({ text: '模型' })
          Column() {
            SettingRow({
              title: '供应商与 Agent',
              subtitle: '配置 API Key、模型列表、人设提示词',
              showArrow: true,
              onTap: (): void => {
                this.openAgentManager();
              }
            })
          }
          .width('100%')
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })
          .visibility(isReadOnly() ? Visibility.None : Visibility.Visible)

          // 工具：效率工具全家桶。这些页面已实现但必须从此处可达，
          // 否则就是「编译通过却点不到」的死代码。
          SectionTitle({ text: '工具' })
          Column() {
            SettingRow({
              title: '定时任务',
              subtitle: 'Cron 定时自动执行 Agent',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/JobsPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '看板',
              subtitle: '任务分列流转，支持 WIP 上限',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/KanbanPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '用量统计',
              subtitle: 'Token 消耗与费用分布',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/UsagePage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '会话关系图',
              subtitle: '群聊与会话的归属关系',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/JourneyPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '日志与性能',
              subtitle: '运行日志、渲染耗时、构建信息',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/LogsPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '文件浏览',
              subtitle: '查看本机文件与 Agent 工作区',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/FilesPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '记忆管理',
              subtitle: '查看与编辑长期记忆、统计命中',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/MemoryPage');
              }
            })
          }
          .width('100%')
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })

          // 扩展能力
          SectionTitle({ text: '扩展能力' })
          Column() {
            SettingRow({
              title: '电脑上的 Agent',
              subtitle: '切换 PC 当前激活的 profile',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/ProfilesPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '电脑上的模型',
              subtitle: '查看并切换 PC 默认模型',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/ModelsPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '电脑工作区',
              subtitle: '浏览 Agent 改过的文件',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/WorkspacePage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: '电脑终端',
              subtitle: '远程操作 PC 上的 shell',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/TerminalPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: 'Skills 技能',
              subtitle: '注入系统提示词，本机生效',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/SkillsPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: 'Plugins 插件',
              subtitle: '需 PC 服务端执行',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/PluginsPage');
              }
            })
            Divider().color(Tok.line(this.dark))
            SettingRow({
              title: 'MCP 服务器',
              subtitle: 'stdio / sse / http 配置',
              showArrow: true,
              onTap: (): void => {
                this.open('pages/McpPage');
              }
            })
          }
          .width('100%')
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })

          // 外观
          SectionTitle({ text: '外观' })
          Column() {
            SettingRow({
              title: '深色模式',
              value: this.dark ? '开' : '关',
              onTap: (): void => {
                AppStore.setDark(!this.dark);
              }
            })
          }
          .width('100%')
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })

          // 连接
          SectionTitle({ text: '连接' })
          Column() {
            SettingRow({
              title: 'Studio 服务端',
              subtitle: this.serverUrl,
              showArrow: true,
              onTap: (): void => {
                this.editUrl = this.serverUrl;
                this.serverStatus = '未检测';
                this.serverSheet = true;
              }
            })
            if (isReadOnly()) {
              Divider().color(Tok.line(this.dark))
              SettingRow({
                title: '退出登录 / 切换服务器',
                subtitle: '清除令牌并返回本地模式',
                showArrow: true,
                onTap: async (): Promise<void> => {
                  await AppStore.clearToken();
                  const opts: router.RouterOptions = { url: 'pages/LoginPage' };
                  router.replaceUrl(opts);
                }
              })
            }
          }
          .width('100%')
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })

          // 数据
          SectionTitle({ text: '数据' })
          Column({ space: 10 }) {
            if (!isReadOnly()) {
              GhostButton({
                label: '清空全部会话记录',
                danger: true,
                onTap: (): void => {
                  this.wipe();
                }
              })
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })

          // 关于
          SectionTitle({ text: '关于' })
          Column({ space: 6 }) {
            Text('Ekko Studio鸿蒙版')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
            Text('版本 0.1.0')
              .fontSize(12)
              .fontColor(Tok.text3(this.dark))
            Text('原生 ArkTS 实现，单聊 + 群聊多 Agent 协作，数据全部落在本机。')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .margin({ top: 4 })
          }
          .width('100%')
          .padding(14)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(Tok.cardBg(this.dark))
          .borderRadius(Tok.radius)
          .border({ width: 1, color: Tok.line(this.dark) })

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
    .bindSheet($$this.serverSheet, this.serverEditor(), {
      height: SheetSize.MEDIUM,
      dragBar: true
    })
  }

  @Builder
  serverEditor() {
    Column({ space: 14 }) {
      SectionTitle({ text: 'Studio 服务端' })

      LabeledInput({
        label: '地址',
        placeholder: 'http://192.168.1.10:8748',
        value: this.editUrl,
        onChange: (v: string) => {
          this.editUrl = v;
        }
      })

      Text('留空则纯本地模式：所有对话直接经手机网络调模型 API，不经过任何服务端。填入 PC 上 Ekko Studio 的地址则可复用服务端已有的 Agent 运行时。')
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width('100%')

      Text(this.serverStatus)
        .fontSize(12)
        .fontColor(this.serverStatus.indexOf('✓') === 0 ? Tok.success : Tok.text3(this.dark))
        .width('100%')

      Row({ space: 8 }) {
        Button(this.testing ? '检测中…' : '测试连接')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(Tok.brand)
          .backgroundColor(Tok.brandSoft)
          .borderRadius(Tok.radiusSmall)
          .enabled(!this.testing)
          .onClick(() => this.testConnection())

        PrimaryButton({
          label: '保存',
          busy: false,
          onTap: async () => {
            await AppStore.setServerUrl(this.editUrl.trim());
            this.serverSheet = false;
            promptAction.showToast({ message: '已保存' });
          }
        })
      }
      .width('100%')

      Button('关闭')
        .width('100%')
        .height(38)
        .fontSize(14)
        .fontColor(Tok.text2(this.dark))
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.serverSheet = false;
        })
    }
    .width('100%')
    .padding(20)
  }
}