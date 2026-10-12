/**
 * 设计令牌：对应原版 styles/theme-customization.ts + variables.scss 的角色。
 * 一处改色，全站跟随（ArkUI 无全局 CSS 变量，靠 AppStorage 传播）。
 *
 * 注意：类里的静态属性名不能与 CustomComponent 继承的方法名冲突
 * （size/width/height/padding/margin/border/clip 等），否则 ArkTS 报
 * "Duplicate identifier"。
 */

export class Tok {
  // 品牌色
  static readonly brand: string = '#1677FF';
  static readonly brandDeep: string = '#0E5FD8';
  static readonly brandSoft: string = '#E8F1FF';

  // 语义色
  static readonly danger: string = '#F53F3F';
  static readonly success: string = '#00B42A';
  static readonly warn: string = '#FF7D00';

  // 亮色底
  static readonly bgPage: string = '#F5F6F8';
  static readonly bgCard: string = '#FFFFFF';
  static readonly bgBubbleUser: string = '#1677FF';
  static readonly bgBubbleAi: string = '#FFFFFF';
  static readonly lineLight: string = '#E5E6EB';

  // 暗色底
  static readonly darkBgPage: string = '#0F1115';
  static readonly darkBgCard: string = '#181B21';
  static readonly darkBubbleUser: string = '#2A5CA8';
  static readonly darkBubbleAi: string = '#20242B';
  static readonly darkLine: string = '#2A2F38';

  // 文本
  static readonly t1: string = '#1A1A1A';
  static readonly t2: string = '#61666E';
  static readonly t3: string = '#9AA0A8';
  static readonly t1Dark: string = '#E8E9EA';
  static readonly t2Dark: string = '#A5A9B0';
  static readonly t3Dark: string = '#6B7280';

  /** 等宽数字，避免金额/时间刷新时宽度跳动 */
  static readonly TNUM: string = '"tnum" 1';

  static readonly radius: number = 12;
  static readonly radiusSmall: number = 8;
  static readonly pagePad: number = 16;
  static readonly cardPad: number = 14;

  // ── 依主题取色 ──
  static pageBg(dark: boolean): string {
    return dark ? Tok.darkBgPage : Tok.bgPage;
  }

  static cardBg(dark: boolean): string {
    return dark ? Tok.darkBgCard : Tok.bgCard;
  }

  /** 分隔线 / 描边色（原名 border 会与组件内置方法冲突） */
  static line(dark: boolean): string {
    return dark ? Tok.darkLine : Tok.lineLight;
  }

  static userBubble(dark: boolean): string {
    return dark ? Tok.darkBubbleUser : Tok.bgBubbleUser;
  }

  static aiBubble(dark: boolean): string {
    return dark ? Tok.darkBubbleAi : Tok.bgBubbleAi;
  }

  static text1(dark: boolean): string {
    return dark ? Tok.t1Dark : Tok.t1;
  }

  static text2(dark: boolean): string {
    return dark ? Tok.t2Dark : Tok.t2;
  }

  static text3(dark: boolean): string {
    return dark ? Tok.t3Dark : Tok.t3;
  }

  /** 用户气泡上的文字恒为白，不随主题变 */
  static onBrand(dark: boolean): string {
    return '#FFFFFF';
  }

  static codeBg(dark: boolean): string {
    return dark ? '#11141A' : '#F6F7F9';
  }

  /** 输入框等控件的填充色 */
  static fieldBg(dark: boolean): string {
    return dark ? '#11141A' : '#F2F3F5';
  }
}