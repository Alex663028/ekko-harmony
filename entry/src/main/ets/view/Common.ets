/**
 * 公共组件库：一处改样式，全站跟随。
 * 注意：自定义组件的 prop 不能叫 size/width/height/padding/margin/border/clip，
 * 这些是 CustomComponent 继承的 CommonAttribute 方法名，会编译冲突。
 */

import { Tok } from './Theme';
import { Segment, parseInlineMd } from '../common/Core';

/** 主题感知包装：所有需要随暗色切换的组件都从这里取色 */
@Component
export struct Themed {
  @StorageProp('themeDark') dark: boolean = false;
  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
  }
  @Builder
  content() {
    Blank()
  }
}

/**
 * 卡片容器。
 *
 * 内容插槽必须是 `@BuilderParam`，否则调用处的尾随 lambda 写法
 * `Card({...}) { ... }` 会报：
 *   "In the trailing lambda case, 'Card' must have one and only one
 *    property decorated with '@BuilderParam'"
 * ——这是本工程 11 处卡片用法的共同根因，改这里比在每个页面绕开要正确得多。
 */
@Component
export struct Card {
  @StorageProp('themeDark') dark: boolean = false;
  pad: number = Tok.cardPad;

  @BuilderParam
  slot: () => void = this.emptySlot;

  @Builder
  emptySlot() {
    Blank()
  }

  build() {
    Column() {
      this.slot()
    }
    .width('100%')
    .padding(this.pad)
    .backgroundColor(Tok.cardBg(this.dark))
    .borderRadius(Tok.radius)
    .border({ width: 1, color: Tok.line(this.dark) })
  }
}

/** 章节标题 */
@Component
export struct SectionTitle {
  @Prop text: string = '';
  @StorageProp('themeDark') dark: boolean = false;
  @Prop trailing: string = '';

  build() {
    Row() {
      Text(this.text)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tok.text3(this.dark))
      Blank()
      if (this.trailing.length > 0) {
        Text(this.trailing)
          .fontSize(12)
          .fontColor(Tok.text3(this.dark))
      }
    }
    .width('100%')
    .padding({ left: 4, right: 4, bottom: 6 })
  }
}

/** 空状态 */
@Component
export struct EmptyState {
  @Prop icon: string = '○';
  @Prop text: string = '';
  @Prop hint: string = '';
  @StorageProp('themeDark') dark: boolean = false;

  build() {
    Column({ space: 8 }) {
      Text(this.icon).fontSize(40).fontColor(Tok.text3(this.dark))
      if (this.text.length > 0) {
        Text(this.text)
          .fontSize(15)
          .fontColor(Tok.text2(this.dark))
      }
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(12)
          .fontColor(Tok.text3(this.dark))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ top: 60, bottom: 60, left: 40, right: 40 })
    .alignItems(HorizontalAlign.Center)
  }
}

/**
 * 主按钮。
 *
 * 注意：属性名不能叫 `enabled` —— 那是 CustomComponent 继承的
 * CommonAttribute 方法（`.enabled(boolean)`），重名会报
 * "Property 'enabled' in type 'PrimaryButton' is not assignable to the
 *  same property in base type 'CustomComponent'"。
 * 所以叫 `enabledState`。
 */
@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop enabledState: boolean = true;
  @Prop busy: boolean = false;
  @StorageProp('themeDark') dark: boolean = false;
  onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        if (this.busy) {
          LoadingProgress().width(14).height(14).color('#FFFFFF')
        }
        Text(this.label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(46)
    .borderRadius(Tok.radius)
    .backgroundColor(this.enabledState ? Tok.brand : Tok.text3(this.dark))
    .onClick(() => {
      if (this.enabledState && !this.busy) {
        this.onTap();
      }
    })
  }
}

/** 次按钮（描边） */
@Component
export struct GhostButton {
  @Prop label: string = '';
  @Prop danger: boolean = false;
  onTap: () => void = () => {};

  build() {
    Button(this.label, { type: ButtonType.Normal })
      .width('100%')
      .height(42)
      .fontSize(14)
      .fontColor(this.danger ? Tok.danger : Tok.brand)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: this.danger ? Tok.danger : Tok.brand })
      .borderRadius(Tok.radiusSmall)
      .onClick(() => this.onTap())
  }
}

/** 设置项：标题 + 说明 + 右侧值 */
@Component
export struct SettingRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop value: string = '';
  @Prop showArrow: boolean = false;
  @StorageProp('themeDark') dark: boolean = false;
  onTap: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(15)
          .fontColor(Tok.text1(this.dark))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(12)
            .fontColor(Tok.text3(this.dark))
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(13)
          .fontColor(Tok.text2(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 140 })
      }
      if (this.showArrow) {
        Text('›')
          .fontSize(20)
          .fontColor(Tok.text3(this.dark))
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: Tok.cardPad, right: Tok.cardPad })
    .backgroundColor(Tok.cardBg(this.dark))
    .onClick(() => this.onTap())
  }
}

/** 输入框 */
@Component
export struct LabeledInput {
  @Prop label: string = '';
  @Prop placeholder: string = '';
  @Prop value: string = '';
  @Prop secret: boolean = false;
  @StorageProp('themeDark') dark: boolean = false;
  onChange: (v: string) => void = () => {};

  build() {
    Column({ space: 6 }) {
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(12)
          .fontColor(Tok.text2(this.dark))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      TextInput({ placeholder: this.placeholder, text: this.value })
        .type(this.secret ? InputType.Password : InputType.Normal)
        .fontSize(15)
        .placeholderColor(Tok.text3(this.dark))
        .backgroundColor(this.dark ? '#11141A' : '#F2F3F5')
        .borderRadius(Tok.radiusSmall)
        .height(44)
        .onChange((v: string) => this.onChange(v))
    }
    .width('100%')
  }
}

/** Markdown 分段渲染：文本/粗体/行内代码/代码块着色 */
@Component
export struct MdText {
  @Prop source: string = '';
  @Prop fontSize: number = 15;
  @StorageProp('themeDark') dark: boolean = false;

  build() {
    Column({ space: 6 }) {
      ForEach(parseInlineMd(this.source), (seg: Segment, idx: number) => {
        if (seg.kind === 'codeblock') {
          CodeBlock({ body: seg.value, lang: seg.lang, dark: this.dark })
        } else if (seg.kind === 'code') {
          Text(` ${seg.value} `)
            .fontSize(this.fontSize - 2)
            .fontColor(this.dark ? '#7FD1AE' : '#0A7A5A')
            .backgroundColor(this.dark ? '#11141A' : '#EEF1F4')
            .borderRadius(4)
            .padding({ left: 3, right: 3 })
        } else if (seg.kind === 'bold') {
          Text(seg.value)
            .fontSize(this.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tok.text1(this.dark))
        } else {
          Text(seg.value)
            .fontSize(this.fontSize)
            .fontColor(Tok.text1(this.dark))
            .lineHeight(this.fontSize * 1.5)
        }
      }, (seg: Segment, idx: number) => `${idx}-${seg.kind}-${seg.value.length}-${seg.value.slice(-16)}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 代码块：等宽字体 + 深色底 + 可复制 */
@Component
export struct CodeBlock {
  @Prop body: string = '';
  @Prop lang: string = '';
  @Prop dark: boolean = false;
  @State copied: boolean = false;
  /** 「已复制」提示的复位定时器；组件销毁必须清，否则回调打在已销毁的组件上 */
  private resetTimer: number = -1;

  aboutToDisappear() {
    if (this.resetTimer !== -1) {
      clearTimeout(this.resetTimer);
      this.resetTimer = -1;
    }
  }

  build() {
    Column() {
      Row() {
        Text(this.lang.length > 0 ? this.lang : 'code')
          .fontSize(11)
          .fontColor(Tok.text3(this.dark))
        Blank()
        Text(this.copied ? '已复制' : '复制')
          .fontSize(11)
          .fontColor(Tok.brand)
          .padding({ left: 8, right: 4, top: 4, bottom: 4 })
          .onClick(() => {
            this.copied = true;
            // 连续点击会叠定时器，先清掉上一个
            if (this.resetTimer !== -1) {
              clearTimeout(this.resetTimer);
            }
            this.resetTimer = setTimeout(() => {
              this.copied = false;
              this.resetTimer = -1;
            }, 1500);
          })
      }
      .width('100%')
      .padding({ left: 10, right: 6, top: 4 })

      Text(this.body)
        .width('100%')
        .fontSize(12)
        .fontFamily('monospace')
        .fontColor(this.dark ? '#D8DEE9' : '#24292F')
        .backgroundColor(Tok.codeBg(this.dark))
        .padding(10)
        .borderRadius(Tok.radiusSmall)
        .maxLines(200
        )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 流式光标（AI 正在输出时显示） */
@Component
export struct StreamingDots {
  @StorageProp('themeDark') dark: boolean = false;
  @State phase: number = 0;

  aboutToAppear() {
    this.timer = setInterval(() => {
      this.phase = (this.phase + 1) % 3;
    }, 350);
  }

  aboutToDisappear() {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private timer: number = -1;

  build() {
    Row({ space: 3 }) {
      ForEach([0, 1, 2], (i: number) => {
        Circle({ width: 5, height: 5 })
          .fill(this.phase === i ? Tok.brand : Tok.text3(this.dark))
      }, (i: number) => `${i}`)
    }
  }
}

/** 工具轨迹条目 */
@Component
export struct ToolTraceRow {
  @Prop name: string = '';
  @Prop status: string = 'ok';
  @Prop detail: string = '';
  @StorageProp('themeDark') dark: boolean = false;
  @State expanded: boolean = false;

  build() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.status === 'running' ? '◌' : (this.status === 'ok' ? '✓' : '✗'))
          .fontSize(12)
          .fontColor(this.status === 'ok' ? Tok.success : (this.status === 'failed' ? Tok.danger : Tok.text3(this.dark)))
        Text(this.name)
          .fontSize(12)
          .fontColor(Tok.text2(this.dark))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detail.length > 0) {
          Text(this.expanded ? '收起' : '详情')
            .fontSize(11)
            .fontColor(Tok.brand)
            .onClick(() => {
              this.expanded = !this.expanded;
            })
        }
      }
      .width('100%')

      if (this.expanded && this.detail.length > 0) {
        Text(this.detail)
          .width('100%')
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(Tok.text3(this.dark))
          .backgroundColor(Tok.codeBg(this.dark))
          .padding(8)
          .borderRadius(6)
          .maxLines(30)
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
  }
}

/** 分段选择器（单聊/群聊切换用） */
@Component
export struct SegmentedTabs {
  @Prop items: string[] = [];
  @Prop active: number = 0;
  @StorageProp('themeDark') dark: boolean = false;
  onChange: (idx: number) => void = () => {};

  build() {
    Row() {
      ForEach(this.items, (label: string, idx: number) => {
        Text(label)
          .fontSize(14)
          .fontWeight(this.active === idx ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.active === idx ? '#FFFFFF' : Tok.text2(this.dark))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(this.active === idx ? Tok.brand : Color.Transparent)
          .onClick(() => this.onChange(idx))
      }, (label: string, idx: number) => `${idx}-${label}`)
    }
    .width('100%')
    .backgroundColor(this.dark ? Tok.darkBgCard : '#EDEFF2')
    .borderRadius(Tok.radiusSmall)
    .padding(3)
  }
}