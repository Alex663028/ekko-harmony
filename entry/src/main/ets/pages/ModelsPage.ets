/**
 * Models 页：查看并切换**电脑上**的模型配置。
 *
 * ## 部署形态的前提（老板 2026-10-06 说明）
 *
 * PC 当服务端 + 手机远程控制。所以模型 API Key、base_url 全在电脑上，
 * 手机端**永远不该也不能**拿到 Key —— 模型调用一律走
 * `POST /api/studio/chat-run/runs` 由PC 执行。
 *
 * 因此本页只做两件手机端真能做的事：
 *   1. 看电脑上都配了哪些供应商 / 模型（只读）
 *   2. 切电脑的默认模型（PUT /api/hermes/config/model {default, provider}）
 *
 * 加/删供应商在 PC 上更方便，且要填 Key —— 不在手机上做。
 * 与AgentManagerPage 的区别：那页管手机本地配置（本地模式下直连模型 API）。
 */

import { router, promptAction } from '@kit.ArkUI';
import { StudioApi, RemoteModelGroup } from '../net/StudioApi';
import { NetConfig } from '../net/Http';
import {
  Card, SectionTitle, EmptyState, PrimaryButton, GhostButton
} from '../view/Common';
import { Tok } from '../view/Theme';

@Entry
@Component
struct ModelsPage {
  @StorageProp('themeDark') dark: boolean = false;

  @State groups: RemoteModelGroup[] = [];
  @State defaultModel: string = '';
  @State loading: boolean = false;
  @State errorText: string = '';
  @State busy: boolean = false;

  /** 展开的供应商名（收起态只看概要） */
  @State expanded: string = '';

  aboutToAppear() {
    this.reload();
  }

  private async reload(): Promise<void> {
    if ((AppStorage.get<string>('dataSource') ?? 'local') !== 'server') {
      this.errorText = '需要先在「设置 → 服务端」连上电脑';
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const cfg = await StudioApi.modelsConfig(NetConfig.getToken());
      this.groups = cfg.groups;
      this.defaultModel = cfg.default;
      if (cfg.groups.length === 0) {
        this.errorText = '电脑上还没有配置模型';
      }
    } catch (e) {
      this.groups = [];
      this.errorText = '加载失败：' + ((e as Error).message ?? '未知错误');
    }
    this.loading = false;
  }

  private async pick(model: string, provider: string): Promise<void> {
    if (this.busy || model === this.defaultModel) {
      return;
    }
    this.busy = true;
    try {
      await StudioApi.setDefaultModel(NetConfig.getToken(), model, provider);
      this.defaultModel = model;
      promptAction.showToast({ message: `默认模型已切到 ${model}` });
    } catch (e) {
      promptAction.showToast({
        message: `切换失败：${(e as Error).message ?? '未知错误'}`
      });
    }
    this.busy = false;
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(28)
          .onClick(() => router.back())
        Column({ space: 2 }) {
          Text('电脑上的模型')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tok.text1(this.dark))
          Text(this.defaultModel.length > 0 ? `默认：${this.defaultModel}` : '未设置默认模型')
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
        Text('刷新')
          .fontSize(13)
          .fontColor(Tok.brand)
          .width(36)
          .textAlign(TextAlign.End)
          .onClick(() => {
            this.reload();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })
      .backgroundColor(Tok.pageBg(this.dark))

      if (this.loading) {
        Text('加载中…')
          .fontSize(13)
          .fontColor(Tok.text3(this.dark))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 40, bottom: 40 })
      } else if (this.errorText.length > 0) {
        EmptyState({ icon: '⚠', text: this.errorText, hint: '检查是否已连接电脑' })
      } else {
        Scroll() {
          Column({ space: 10 }) {
            Text('点模型名可设为电脑的默认模型')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .width('100%')

            ForEach(this.groups, (g: RemoteModelGroup) => {
              this.groupCard(g)
            }, (g: RemoteModelGroup) => g.provider)
          }
          .width('100%')
          .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 10, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
  }

  @Builder
  groupCard(g: RemoteModelGroup) {
    Card() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(g.provider)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tok.text1(this.dark))
            .layoutWeight(1)
          Text(`${g.models.length} 个模型`)
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
          Text(this.expanded === g.provider ? '▾' : '›')
            .fontSize(13)
            .fontColor(Tok.text3(this.dark))
            .width(16)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.expanded = this.expanded === g.provider ? '' : g.provider;
            })
        }
        .width('100%')
        .onClick(() => {
          this.expanded = this.expanded === g.provider ? '' : g.provider;
        })

        // 收起时只展示前 3 个 + 当前默认
        if (this.expanded === g.provider) {
          ForEach(g.models, (m: string) => {
            this.modelRow(m, g.provider)
          }, (m: string) => g.provider + '|' + m)
        } else {
          Column({ space: 4 }) {
            ForEach(g.models.slice(0, 3), (m: string) => {
              this.modelRow(m, g.provider)
            }, (m: string) => 'c' + g.provider + '|' + m)
            if (g.models.length > 3) {
              Text(`还有 ${g.models.length - 3} 个，点上面展开`)
                .fontSize(11)
                .fontColor(Tok.text3(this.dark))
                .width('100%')
                .padding({ left: 4, top: 2 })
            }
          }
          .width('100%')
        }
      }
    }
  }

  @Builder
  modelRow(model: string, provider: string) {
    Row({ space: 8 }) {
      Text(model)
        .fontSize(13)
        .fontColor(model === this.defaultModel ? Tok.brand : Tok.text2(this.dark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (model === this.defaultModel) {
        Text('默认')
          .fontSize(10)
          .fontColor(Tok.brand)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(Tok.brandSoft)
          .borderRadius(4)
      } else {
        GhostButton({
          label: this.busy ? '…' : '设为默认',
          onTap: (): void => {
            this.pick(model, provider);
          }
        })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4, left: 4, right: 2 })
    .onClick(() => {
      if (model !== this.defaultModel) {
        this.pick(model, provider);
      }
    })
  }
}