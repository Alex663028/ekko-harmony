/**
 * 日志与性能页：应用内日志 + 构建信息 + 渲染耗时。
 * 对应原版 LogsView。
 *
 * 日志级别配色：debug 灰 / info 蓝 / warn 橙 / error 红。
 * 级别字段是 LogLevel 具名联合类型，所以用相等比较，
 * 不能写 levelMap[log.level] 这种动态下标（ArkTS 禁止）。
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppLog, LogLevel } from '../model/Extend';
import { LogRepo } from '../data/ExtendRepos';
import { AppStore } from '../viewmodel/AppStore';
import { RemoteView } from '../viewmodel/RemoteView';
import { relativeTime, previewOf, humanSize } from '../common/Core';
import { Card, SectionTitle, EmptyState, SegmentedTabs } from '../view/Common';
import { Tok } from '../view/Theme';

const LEVELS: LogLevel[] = ['debug', 'info', 'warn', 'error'];

function levelColor(level: LogLevel, dark: boolean): string {
  if (level === 'error') {
    return Tok.danger;
  }
  if (level === 'warn') {
    return Tok.warn;
  }
  if (level === 'debug') {
    return dark ? Tok.t3Dark : Tok.t3;
  }
  return Tok.brand;
}

function levelLabel(level: LogLevel): string {
  if (level === 'error') {
    return 'ERROR';
  }
  if (level === 'warn') {
    return 'WARN';
  }
  if (level === 'debug') {
    return 'DEBUG';
  }
  return 'INFO';
}

@Entry
@Component
struct LogsPage {
  @StorageProp('themeDark') dark: boolean = false;
  @StorageLink('breakpoint') bp: string = 'compact';
  @StorageLink('serverUrl') serverUrl: string = '';

  @State logs: AppLog[] = [];
  @State filter: number = -1;
  @State loadCost: number = 0;
  @State renderCost: number = 0;
  @State now: number = Date.now();

  aboutToAppear() {
    // P2-1：enterAt 必须在 aboutToAppear 里记录，而不是字段初始化时。
    // 字段初始化在组件构造时执行，与 aboutToAppear 几乎同时，导致 renderCost 恒为 0。
    this.enterAt = Date.now();
    this.renderCost = 0;
    this.reload();
  }

  onPageShow() {
    // 首帧渲染完成后再算耗时
    this.renderCost = Date.now() - this.enterAt;
  }

  private enterAt: number = 0;

  private async reload(): Promise<void> {
    const t0 = Date.now();
    try {
      this.logs = await RemoteView.logs(AppStore.db(), 200);
    } catch (e) {
      this.logs = [];
      promptAction.showToast({ message: `加载失败: ${(e as Error).message}` });
    }
    this.loadCost = Date.now() - t0;
    this.now = Date.now();
  }

  private filtered(): AppLog[] {
    if (this.filter < 0) {
      return this.logs;
    }
    const want = LEVELS[this.filter];
    const out: AppLog[] = [];
    for (const l of this.logs) {
      if (l.level === want) {
        out.push(l);
      }
    }
    return out;
  }

  private countOf(level: LogLevel): number {
    let n = 0;
    for (const l of this.logs) {
      if (l.level === level) {
        n++;
      }
    }
    return n;
  }

  private levelTabs(): string[] {
    const out: string[] = [`全部 ${this.logs.length}`];
    for (const lv of LEVELS) {
      out.push(`${levelLabel(lv)} ${this.countOf(lv)}`);
    }
    return out;
  }

  private onTab(idx: number): void {
    this.filter = idx - 1;
  }

  private async clearAll(): Promise<void> {
    const res = await promptAction.showDialog({
      title: '清空日志',
      message: '将删除全部应用日志，不可恢复。',
      buttons: [{ text: '取消', color: '#61666E' }, { text: '清空', color: '#F53F3F' }]
    });
    if (res.index !== 1) {
      return;
    }
    await LogRepo.clear(AppStore.db());
    await this.reload();
    promptAction.showToast({ message: '已清空' });
  }

  /** 只保留最近 100 条，防止日志表无限膨胀 */
  private async trim(): Promise<void> {
    await LogRepo.trim(AppStore.db(), 100);
    await this.reload();
    promptAction.showToast({ message: '已裁剪到最近 100 条' });
  }

  private async writeSample(): Promise<void> {
    await LogRepo.info(AppStore.db(), 'LogsPage', '手动写入的一条测试日志');
    await this.reload();
  }

  private memLine(): string {
    return `日志 ${this.logs.length} 条 · 单条上限 2000 字符`;
  }

  /** 日志总体积估算：按已加载条数 × 单条平均长度算，不去查库求和 */
  private logVolume(): string {
    let chars = 0;
    for (const l of this.logs) {
      chars += l.message.length + l.scope.length;
    }
    return humanSize(chars);
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
        Text('日志与性能')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.text1(this.dark))
          .layoutWeight(1)
        Text('清空').fontSize(14).fontColor(Tok.danger)
          .padding({ left: 6, right: 4 })
          .onClick((): void => {
            this.clearAll();
          })
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })

      SegmentedTabs({
        items: this.levelTabs(),
        active: this.filter + 1,
        onChange: (idx: number): void => {
          this.onTab(idx);
        }
      })
      .margin({ left: Tok.pagePad, right: Tok.pagePad, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          this.perfSection()

          if (this.filtered().length === 0) {
            EmptyState({
              icon: '≡',
              text: '没有日志',
              hint: '应用运行时写入的日志会出现在这里'
            })
          } else {
            SectionTitle({ text: '日志', trailing: this.memLine() })
            ForEach(this.filtered(), (l: AppLog) => {
              Card({ pad: 10 }) {
                Column({ space: 4 }) {
                  Row({ space: 6 }) {
                    Text(levelLabel(l.level))
                      .fontSize(10)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(levelColor(l.level, this.dark))
                      .backgroundColor(Tok.fieldBg(this.dark))
                      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                      .borderRadius(4)
                    Text(l.scope.length > 0 ? l.scope : '-')
                      .fontSize(10)
                      .fontColor(Tok.brand)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(relativeTime(l.createdAt, this.now))
                      .fontSize(10)
                      .fontColor(Tok.text3(this.dark))
                  }
                  .width('100%')

                  Text(previewOf(l.message, 300))
                    .fontSize(12)
                    .fontColor(Tok.text2(this.dark))
                    .fontFamily('monospace')
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }
            }, (l: AppLog) => l.id)
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

  @Builder
  perfSection() {
    Column({ space: 10 }) {
      SectionTitle({ text: '性能与构建', trailing: this.bp })

      if (this.bp === 'expanded') {
        // PC 上两列并排，省得滚动
        Row({ space: 10 }) {
          Column({ space: 10 }) {
            this.metricBox('页面渲染', `${this.renderCost}`, 'ms')
            this.metricBox('日志加载', `${this.loadCost}`, 'ms')
          }
          .layoutWeight(1)
          Column({ space: 10 }) {
            this.metricBox('日志条数', `${this.logs.length}`, '条')
            this.metricBox('断点', this.bp, '')
          }
          .layoutWeight(1)
        }
        .width('100%')
        this.buildInfo()
      } else {
        this.metricBox('页面渲染', `${this.renderCost}`, 'ms')
        this.metricBox('日志加载', `${this.loadCost}`, 'ms')
        this.metricBox('日志条数', `${this.logs.length}`, '条')
        this.buildInfo()
      }

      Row({ space: 8 }) {
        Text('写入测试日志')
          .fontSize(13)
          .fontColor(Tok.brand)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(Tok.brandSoft)
          .borderRadius(Tok.radiusSmall)
          .onClick((): void => {
            this.writeSample();
          })
        Text('裁剪到 100 条')
          .fontSize(13)
          .fontColor(Tok.text2(this.dark))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(Tok.fieldBg(this.dark))
          .borderRadius(Tok.radiusSmall)
          .onClick((): void => {
            this.trim();
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  metricBox(label: string, value: string, unit: string) {
    Card({ pad: 12 }) {
      Row({ space: 6 }) {
        Text(label)
          .fontSize(12)
          .fontColor(Tok.text3(this.dark))
        Blank()
        Text(value)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tok.brand)
        if (unit.length > 0) {
          Text(unit)
            .fontSize(11)
            .fontColor(Tok.text3(this.dark))
        }
      }
      .width('100%')
    }
  }

  @Builder
  buildInfo() {
    Card({ pad: 12 }) {
      Column({ space: 6 }) {
        this.infoLine('构建模式', 'debug')
        this.infoLine('ArkTS', 'HarmonyOS 原生')
        this.infoLine('服务端', this.serverUrl.length > 0 ? this.serverUrl : '未配置')
        this.infoLine('断点', this.bp === 'expanded' ? '宽屏（PC）' :
          (this.bp === 'medium' ? '中屏' : '窄屏（手机）'))
        this.infoLine('数据库', 'RDB 本机存储')
        this.infoLine('存储占用', this.logVolume())
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  infoLine(label: string, value: string) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(11)
        .fontColor(Tok.text3(this.dark))
        .width(72)
      Text(value)
        .fontSize(11)
        .fontColor(Tok.text2(this.dark))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }
}
