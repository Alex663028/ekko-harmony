/**
 * 响应式布局框架：手机单栏 ↔ PC 双栏。
 *
 * 断点判定不依赖屏幕物理尺寸，而用 **可用窗口宽度**（vp）——
 * PC 上窗口可以被用户拉宽拉窄，物理屏宽不变但布局必须跟着变。
 *
 * 断点：
 *   compact  <600vp   手机竖屏，单栏，底部 Tab
 *   medium   600~900 折叠屏展开/小平板，单栏但可用 GridRow
 *   expanded >=900    平板/PC 宽屏，左栏常驻 + 右栏内容
 */

import { Breakpoint, LayoutPrefs } from '../model/Extend';
import { Tok } from './Theme';
import {
  BP_EXPANDED, breakpointOf, isWide, showSidebar, clampRatio,
  readableWidth, rowPadding
} from '../common/Core';

/**
 * 双栏容器。
 *
 * 左栏可拖拽调宽：把 ratio 限制在合理区间，避免拖成 0（内容全没了）
 * 或 0.9（右栏只剩一条缝）。
 * 拖拽结束后由外部持久化（PC 上跨启动要保留）。
 */
@Component
export struct SplitPane {
  @Prop bp: Breakpoint = 'compact';
  @Prop ratio: number = 0.28;
  @Prop collapsed: boolean = false;

  /**
   * 拖拽结束回调。
   *
   * 关键：拖拽后必须把新比例报给外层，否则比例只停在组件内部 @State，
   * 父级不感知 → 无法持久化，PC 上每次启动都回到默认宽度。
   */
  onRatioChange: (r: number) => void = () => {};

  /** 双栏被折叠/展开时通知外层（用于持久化 collapsed） */
  onCollapseToggle: () => void = () => {};

  @BuilderParam
  side: () => void = this.emptySide;

  @BuilderParam
  main: () => void = this.emptyMain;

  @State dragging: boolean = false;
  @State dragRatio: number = 0;

  @Builder
  emptySide() {
    Blank()
  }

  @Builder
  emptyMain() {
    Blank()
  }

  private effectiveRatio(): number {
    const r = this.dragging ? this.dragRatio : this.ratio;
    return clampRatio(r);
  }

  build() {
    if (!showSidebar(this.bp, this.collapsed)) {
      // 单栏：只渲染主区
      Column() {
        this.main()
      }
      .width('100%')
      .height('100%')
    } else {
      Row() {
        Row() {
          this.side()
        }
        .width(`${(this.effectiveRatio() * 100).toFixed(1)}%`)
        .height('100%')

        // 拖拽把手：PC 上有鼠标才好拖，宽屏才显示
        if (this.bp === 'expanded') {
          Row() {
            // 折叠按钮：宽屏下左栏常常要临时收起，把宽度全给内容区
            Text('‹')
              .fontSize(14)
              .fontColor(Tok.text3(false))
              .width(6)
              .height('100%')
              .textAlign(TextAlign.Center)
              .backgroundColor(this.dragging ? Tok.brand : '#00000000')
              .onClick(() => {
                this.onCollapseToggle();
              })

            // 分隔线兼拖拽把手
            Column()
              .width(3)
              .height('100%')
              .backgroundColor(this.dragging ? Tok.brand : Tok.line(false))
              .onTouch((e: TouchEvent) => this.onDrag(e))
          }
          .width(9)
          .height('100%')
        }

        Row() {
          this.main()
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
  }

  private onDrag(e: TouchEvent): void {
    if (e.type === TouchType.Down) {
      this.dragging = true;
      this.dragRatio = this.ratio;
    }
    if (e.type === TouchType.Move) {
      const w = this.getUIContext() !== undefined ? this.currentWidthVp() : 0;
      if (w > 0) {
        const x = e.touches.length > 0 ? e.touches[0].x : 0;
        this.dragRatio = clampRatio(x / w);
      }
    }
    if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      if (this.dragging) {
        this.dragging = false;
        this.ratio = this.dragRatio;
        // 报给外层持久化：只在拖拽结束时发一次，不在 Move 里刷库
        this.onRatioChange(clampRatio(this.dragRatio));
      }
    }
  }

  /** 拖拽时取当前窗口宽度（vp）。AppStorage 里由 EntryAbility 持续更新。 */
  private currentWidthVp(): number {
    return AppStorage.get<number>('windowWidthVp') ?? 0;
  }
}

/*
 * clampRatio / breakpointOf 等断点判定统一放在 common/Core.ets，
 * 这里不再重复定义 —— 两处实现必然漂移，且同名导入会与本地声明冲突
 * (arkts-unique-names)。
 */

/**
 * 移动优先的栅格：宽屏 3 列 / 中屏 2 列 / 手机 1 列。
 *
 * ⚠ `count` 必须传实际元素个数。
 *
 * 早期版本把 ForEach 的数据源写死成 `[0..8]`（9 格），
 * 结果任何长度 >9 的列表**第 10 条起完全不渲染**，
 * 且界面上没有任何截断提示 —— 用户只会以为数据丢了。
 * 现在按 max(9, count) 生成，最少 9 格（保证 3×3 的宽屏布局稳定），
 * 超出 9 就按真实数量铺。
 */
@Component
export struct AdaptiveGrid {
  @Prop bp: Breakpoint = 'compact';
  @Prop minItemWidth: number = 300;
  /** 元素个数。漏传会退化成 9 格，长列表第 10 条起不可见。 */
  @Prop count: number = 0;

  @BuilderParam
  items: (index: number) => void = this.noItems;

  private columns(): number {
    if (this.bp === 'expanded') {
      return 3;
    }
    if (this.bp === 'medium') {
      return 2;
    }
    return 1;
  }

  /** 生成 0..n-1 的下标数组 */
  private range(): number[] {
    const min = 9;
    const n = this.count > min ? this.count : min;
    const out: number[] = [];
    for (let i = 0; i < n; i++) {
      out.push(i);
    }
    return out;
  }

  @Builder
  noItems(_index: number) {
    Blank()
  }

  build() {
    Grid() {
      ForEach(this.range(), (i: number) => {
        GridItem() {
          this.items(i)
        }
      }, (i: number) => `${i}`)
    }
    .columnsTemplate(this.bp === 'expanded'
      ? '1fr 1fr 1fr'
      : (this.bp === 'medium' ? '1fr 1fr' : '1fr'))
    .columnsGap(10)
    .rowsGap(10)
    .width('100%')
  }
}

/**
 * 内容最大宽度容器。
 *
 * PC 上宽屏铺满会让正文行长到 200+ 字符，阅读体验很差；
 * 这里把聊天内容限制在舒适行长内并居中。
 */
@Component
export struct ReadableContent {
  @Prop maxWidthVp: number = 760;
  @BuilderParam
  content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
    Blank()
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .constraintSize({ maxWidth: `${this.maxWidthVp}vp` })
  }
}

/** 键鼠提示：宽屏下按钮/行项目可悬停高亮，这里统一给光标 */
@Component
export struct Hoverable {
  @Prop bp: Breakpoint = 'compact';
  /** 悬停底色。必须是 string，Color 类型与 ArkUI 的 backgroundColor 不匹配。 */
  @Prop bg: string = '#00000000';
  @BuilderParam
  content: () => void = this.emptyContent;

  @State hovered: boolean = false;

  @Builder
  emptyContent() {
    Blank()
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .backgroundColor(this.hovered ? this.bg : '#00000000')
    .borderRadius(Tok.radiusSmall)
    .onHover((enter: boolean) => {
      // 手机没有指针设备，悬停态无意义
      this.hovered = enter && this.bp === 'expanded';
    })
  }
}