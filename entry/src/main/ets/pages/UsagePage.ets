/**
 * 用量统计页：token 与花费汇总。
 * 对应原版 UsageView。
 *
 * 条形图不引图表库：纯 Row + 百分比宽度。
 * 宽度计算一律先判总量为 0，避免除零得到 NaN 让布局塌掉。
 */

import { router, promptAction } from '@kit.ArkUI';
import { UsageSummary, UsageBucket } from '../model/Extend';
import { UsageRepo } from '../data/ExtendRepos';
import { AppStore } from '../viewmodel/AppStore';
import { RemoteView } from '../viewmodel/RemoteView';
import { formatNumber, compactNumber } from '../common/Core';
import { Card, SectionTitle, EmptyState } from '../view/Common';
import { Tok } from '../view/Theme';

/** 空汇总，避免加载完成前渲染未初始化对象 */
function emptySummary(): UsageSummary {
  const s: UsageSummary = {
    totalInput: 0,
    totalOutput: 0,
    totalCost: 0,
    sessionCount: 0,
    byModel: [],
    daily: []
  };
  return s;
}

/** 百分比宽度（0~100），总量为 0 时直接给 0，绝不返回 NaN */
function ratioWidth(value: number, total: number): string {
  if (!isFinite(total) || total <= 0) {
    return '0%';
  }
  const r = value / total;
  if (!isFinite(r) || r <= 0) {
    return '0%';
  }
  if (r >= 1) {
    return '100%';
  }
  return `${(r * 100).toFixed(1)}%`;
}

@Entry
@Component
struct UsagePage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';

  @State summary: UsageSummary = emptySummary();
  @State loading: boolean = true;
  @State modelMax: number = 0;
  @State dayMax: number = 0;

  aboutToAppear() {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.loading = true;
    try {
      const s = await RemoteView.usage(AppStore.db());
      this.summary = s;
      this.modelMax = this.maxTokens(s.byModel);
      this.dayMax = this.maxTokens(s.daily);
    } catch (e) {
      this.summary = emptySummary();
      promptAction.showToast({ message: `加载失败: ${(e as Error).message}` });
    }
    this.loading = false;
  }

  private maxTokens(list: UsageBucket[]): number {
    let max = 0;
    for (const b of list) {
      if (b.tokens > max) {
        max = b.tokens;
      }
    }
    return max;
  }

  private totalTokens(): number {
    return this.summary.totalInput + this.summary.totalOutput;
  }

  private hasData(): boolean {
    return this.totalTokens() > 0 || this.summary.byModel.length > 0;
  }

  /** 宽屏三列、中屏两列、窄屏一列 */
  private statColumns(): string {
    if (this.bp === 'expanded') {
      return '1fr 1fr 1fr';
    }
    if (this.bp === 'medium') {
      return '1fr 1fr';
    }
    return '1fr';
  }

  private async clearAll(): Promise<void> {
    const res = await promptAction.showDialog({
      title: '清空用量记录',
      message: '将删除全部 token 与花费记录，不可恢复。',
      buttons: [{ text: '取消', color: '#61666E' }, { text: '清空', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await UsageRepo.clear(AppStore.db());
    await this.reload();
    promptAction.showToast({ message: '已清空' });
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
        Text('用量统计')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('清空').fontSize(14).fontColor(Tok.danger)
          .padding({ left: 8, right: 4 })
          .onClick((): void => {
            this.clearAll();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 14 }) {
          if (!this.loading && !this.hasData()) {
            EmptyState({
              icon: '📊',
              text: '还没有用量记录',
              hint: '每完成一次模型调用就会记一条：token 数、模型与花费'
            })
          } else {
            this.overview()
            this.modelSection()
            this.dailySection()
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

  /** 汇总数字：Grid 按断点自动 3/2/1 列 */
  @Builder
  overview() {
    Column({ space: 10 }) {
      SectionTitle({ text: '近 30 天汇总' })
      Grid() {
        GridItem() {
          this.statTile('输入 token', compactNumber(this.summary.totalInput),
            formatNumber(this.summary.totalInput, 0), Tok.brand)
        }
        GridItem() {
          this.statTile('输出 token', compactNumber(this.summary.totalOutput),
            formatNumber(this.summary.totalOutput, 0), Tok.success)
        }
        GridItem() {
          // 这里的「会话」是近 30 天有用量记录的不同会话数，
          // 与设置页的「会话总数」（库里全部会话）口径不同，两者对不上是正常的。
          this.statTile('总花费', `$${formatNumber(this.summary.totalCost, 4)}`,
            `${this.summary.sessionCount} 个会话（30天内）`, Tok.warn)
        }
      }
      .columnsTemplate(this.statColumns())
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  statTile(label: string, big: string, sub: string, accent: string) {
    Card({ pad: 12 }) {
      Column({ space: 4 }) {
        Text(label)
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
        Text(big)
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(accent)
        Text(sub)
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  modelSection() {
    Column({ space: 10 }) {
      SectionTitle({
        text: '按模型分布',
        trailing: `${this.summary.byModel.length} 个模型`
      })
      if (this.summary.byModel.length === 0) {
        Card({ pad: 12 }) {
          Text('暂无数据')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }
      } else {
        Card({ pad: 12 }) {
          Column({ space: 12 }) {
            ForEach(this.summary.byModel, (b: UsageBucket) => {
              this.barRow(b.key, b.tokens, b.cost, this.modelMax, Tok.brand)
            }, (b: UsageBucket) => b.key)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
  }

  @Builder
  dailySection() {
    Column({ space: 10 }) {
      SectionTitle({
        text: '每日趋势',
        trailing: `${this.summary.daily.length} 天有记录`
      })
      if (this.summary.daily.length === 0) {
        Card({ pad: 12 }) {
          Text('暂无数据')
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .width('100%')
        }
      } else {
        Card({ pad: 12 }) {
          Column({ space: 10 }) {
            ForEach(this.summary.daily, (b: UsageBucket) => {
              this.barRow(b.key, b.tokens, b.cost, this.dayMax, Tok.success)
            }, (b: UsageBucket) => b.key)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
  }

  /**
   * 一条横向条形。
   * max 为 0（全为 0 或空列表）时 ratioWidth 返回 '0%'，
   * 外层 Row 仍画底槽，所以不会因为除零而塌掉。
   */
  @Builder
  barRow(label: string, tokens: number, cost: number, max: number, color: string) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(label)
          .fontSize(11)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(compactNumber(tokens))
          .fontSize(11)
          .fontColor(Tok.text2(this.dark))
        Text(`$${formatNumber(cost, 4)}`)
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
      }
      .width('100%')

      Row() {
        Row()
          .height(8)
          .width(ratioWidth(tokens, max))
          .backgroundColor(color)
          .borderRadius(4)
      }
      .width('100%')
      .height(8)
      .backgroundColor(Tok.fieldBg(this.dark))
      .borderRadius(4)
    }
    .width('100%')
  }
}
