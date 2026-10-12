/**
 * Profiles 页：管理台式机上的 Ekko Studio profile。
 *
 * ## 为什么单独一页（老板 2026-10-06 明确要求）
 *
 * 部署形态是「**PC 当服务端 + 手机远程控制**」。这个形态下，
 * 「切Agent」不是切手机上的本地配置，而是**改 PC 当前激活的 profile**：
 *   PUT /api/hermes/profiles/active   body {name}
 * 这是全局状态 —— 切了之后 PC 上开的所有会话都用新 Agent。
 * 所以它必须有一个显式、可确认的入口，不能藏在聊天页顶栏的小三角里。
 *
 * 与 AgentManagerPage 的区别（别混淆）：
 *   AgentManagerPage → 供应商 / 本地 Agent 配置（本机生效，直连模型 API）
 *   ProfilesPage      → PC 上的 profile（远程生效，切换 PC 的 active profile）
 *
 * ⚠ schema 全空，字段靠「候选键逐个挑」容错解析（见 StudioApi.fetchList）。
 */

import { router, promptAction } from '@kit.ArkUI';
import { StudioApi } from '../net/StudioApi';
import { RemoteProfile } from '../model/Types';
import { NetConfig } from '../net/Http';
import { AppStore } from '../viewmodel/AppStore';
import {
  Card, SectionTitle, EmptyState, GhostButton, PrimaryButton, LabeledInput
} from '../view/Common';
import { Tok } from '../view/Theme';

@Entry
@Component
struct ProfilesPage {
  @StorageProp('themeDark') dark: boolean = false;

  @State profiles: RemoteProfile[] = [];
  @State active: string = '';
  @State loading: boolean = false;
  @State errorText: string = '';

  @State creating: boolean = false;
  @State newName: string = '';
  @State busy: boolean = false;

  /** PC 上是否有 profile（没有就引导去 PC 建） */
  private serverMode(): boolean {
    return (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
  }

  aboutToAppear() {
    this.reload();
  }

  private async reload(): Promise<void> {
    if (!this.serverMode()) {
      this.errorText = '需要先在「设置 → 服务端」连上电脑';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const list = await StudioApi.listProfiles(NetConfig.getToken());
      this.profiles = list;
      this.active = this.pickActive(list);
      if (list.length === 0) {
        this.errorText = '电脑上还没有 profile，请在电脑上创建';
      }
    } catch (e) {
      this.profiles = [];
      this.errorText = '加载失败：' + ((e as Error).message ?? '未知错误');
    }
    this.loading = false;
  }

  /**
   * 猜当前激活的是哪个。
   *
   * ⚠ 服务端没提供「查询 active」的端点（只有 PUT 切换），
   *   而 listProfiles 的响应也不带 active 标记（实测），
   *   所以只能用约定：name === 'default' 视为当前 active。
   *   如果 PC 上把默认 profile 改名了，这里会显示不出来 ——
   *   切一次就会确定下来。
   */
  private pickActive(list: RemoteProfile[]): string {
    for (const p of list) {
      if (p.active) {
        return p.name;
      }
    }
    for (const p of list) {
      if (p.name === 'default') {
        return p.name;
      }
    }
    return list.length > 0 ? list[0].name : '';
  }

  private async switchTo(name: string): Promise<void> {
    if (this.busy || name === this.active) {
      return;
    }
    this.busy = true;
    try {
      await StudioApi.switchProfile(NetConfig.getToken(), name);
      this.active = name;
      promptAction.showToast({ message: `已切换到 ${name}` });
    } catch (e) {
      promptAction.showToast({
        message: `切换失败：${(e as Error).message ?? '未知错误'}`
      });
    }
    this.busy = false;
  }

  /** 切换后要等 PC 侧重载 runtime 才生效，这里给一次确认 */
  private async restartRuntime(name: string): Promise<void> {
    this.busy = true;
    try {
      await StudioApi.restartProfile(NetConfig.getToken(), name);
      promptAction.showToast({ message: '已让电脑重启该 profile' });
    } catch (e) {
      promptAction.showToast({
        message: `重启失败：${(e as Error).message ?? '未知错误'}`
      });
    }
    this.busy = false;
  }

  private async createProfile(): Promise<void> {
    const name = this.newName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '请输入名称' });
      return;
    }
    this.busy = true;
    try {
      await StudioApi.createProfile(NetConfig.getToken(), name, true);
      this.creating = false;
      this.newName = '';
      await this.reload();
      promptAction.showToast({ message: `已创建 ${name}` });
    } catch (e) {
      promptAction.showToast({
        message: `创建失败：${(e as Error).message ?? '未知错误'}`
      });
    }
    this.busy = false;
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(28)
          .onClick(() => router.back())
        Column({ space: 2 }) {
          Text('电脑上的 Agent')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tok.text1(this.dark))
          Text('切换后电脑上开的会话都用这个 Agent')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
        Text('+')
          .fontSize(22)
          .fontColor(Tok.brand)
          .width(28)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.creating = !this.creating;
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })
      .backgroundColor(Tok.pageBg(this.dark))

      Scroll() {
        Column({ space: 12 }) {
          if (this.creating) {
            Card() {
              Column({ space: 10 }) {
                SectionTitle({ text: '新建 Agent（克隆当前配置）' })
                LabeledInput({
                  label: '名称',
                  value: this.newName,
                  placeholder: '例如 research',
                  onChange: (v: string): void => {
                    this.newName = v;
                  }
                })
                Row({ space: 8 }) {
                  GhostButton({
                    label: '取消',
                    onTap: (): void => {
                      this.creating = false;
                      this.newName = '';
                    }
                  })
                  PrimaryButton({
                    label: this.busy ? '创建中…' : '创建',
                    enabledState: !this.busy && this.newName.trim().length > 0,
                    onTap: (): void => {
                      this.createProfile();
                    }
                  })
                }
              }
            }
          }

          if (this.loading) {
            Text('加载中…')
              .fontSize(13)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 40, bottom: 40 })
          } else if (this.errorText.length > 0) {
            EmptyState({ icon: '⚠', text: this.errorText, hint: '检查是否已连接电脑' })
          } else if (this.profiles.length === 0) {
            EmptyState({ icon: '○', text: '电脑上没有 Agent', hint: '点右上角 + 从当前配置克隆一个' })
          } else {
            SectionTitle({ text: `共 ${this.profiles.length} 个` })
            ForEach(this.profiles, (p: RemoteProfile) => {
              this.profileCard(p)
            }, (p: RemoteProfile) => p.name)
          }
        }
        .width('100%')
        .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 10, bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
  }

  @Builder
  profileCard(p: RemoteProfile) {
    Card() {
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Text(p.initial)
            .fontSize(14)
            .fontColor(Color.White)
            .width(34)
            .height(34)
            .textAlign(TextAlign.Center)
            .borderRadius(17)
            .backgroundColor(p.name === this.active ? Tok.brand : Tok.text3(this.dark))

          Column({ space: 2 }) {
            Text(p.displayName)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tok.text1(this.dark))
            Text(p.name)
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (p.name === this.active) {
            Text('使用中')
              .fontSize(11)
              .fontColor(Tok.brand)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(Tok.brandSoft)
              .borderRadius(4)
          }
        }
        .width('100%')

        if (p.model.length > 0) {
          Text(p.model)
            .fontSize(11)
            .fontColor(Tok.text2(this.dark))
            .width('100%')
        }
        if (p.description.length > 0) {
          Text(p.description)
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        // 非当前激活的才给操作按钮
        if (p.name !== this.active) {
          Row({ space: 8 }) {
            PrimaryButton({
              label: this.busy ? '切换中…' : '切到这个',
              enabledState: !this.busy,
              onTap: (): void => {
                this.switchTo(p.name);
              }
            })
            GhostButton({
              label: '重启',
              onTap: (): void => {
                this.restartRuntime(p.name);
              }
            })
          }
          .width('100%')
        }
      }
    }
  }
}