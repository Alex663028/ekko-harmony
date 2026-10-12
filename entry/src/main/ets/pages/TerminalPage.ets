/**
 * 终端页：在手机上操作**电脑上**的终端。
 *
 * ## 场景（老板 2026-10-06 明确要求）
 *
 * 「终端是 PC 本机操作，手机不在局域网可以远程操作」
 *
 * ## 协议更正（重要）
 *
 * 之前我照安卓版写成了 socket.io 命名空间 /terminal，连上后服务端回
 * `44/terminal,{"message":"terminal_forbidden"}` —— 我据此判断「PC 端没开放权限」。
 *
 * 挖了 PC 上的服务端 bundle 才发现：**socket.io 里根本没有这个命名空间**，
 * 那个 forbidden 是「命名空间不存在」的兜底文案。
 * 真实端点是**原生 WebSocket** `ws://<电脑IP>:8748/api/hermes/terminal?token=`，
 * 且**不要求 super_admin**（`Ec()` 恒真）—— 也就是**不需要开任何权限**，
 * 拿有效 token 就能用。
 *
 * 详见 `net/TerminalClient.ets` 的协议说明。
 *
 * ## 渲染
 *
 * 输出含 ANSI 转义序列（颜色/光标控制）。本页面：
 *   ①剥掉 ANSI，避免显示 `[31m` 这种乱码
 *   ② `\r` 转成换行（否则整屏挤成一行）
 *   ③ 用 Text 显示（等宽字体）
 * 完整 ANSI（光标定位、擦除行）要 Canvas 绘制，暂不做。
 */

import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TermClient, TermHandlers, TermSession } from '../net/TerminalClient';
import { NetConfig } from '../net/Http';
import { EmptyState, PrimaryButton, GhostButton } from '../view/Common';
import { Tok } from '../view/Theme';

/** 最多保留多少字符 —— 再多 Text 渲染会明显掉帧 */
const MAX_BUFFER: number = 20000;

@Entry
@Component
struct TerminalPage {
  @StorageProp('themeDark') dark: boolean = false;

  @State output: string = '';
  @State sessions: TermSession[] = [];
  @State activeId: string = '';
  @State connected: boolean = false;
  @State statusText: string = '连接中…';
  @State input: string = '';

  private term: TermClient = new TermClient();
  /** 上次发送的时刻（用于挡掉同一次点击触发的双发送，见 sendInput） */
  private lastSendAt: number = 0;

  aboutToAppear() {
    this.connect();
  }

  aboutToDisappear() {
    this.term.close();
  }

  private serverMode(): boolean {
    return (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
  }

  private async connect(): Promise<void> {
    if (!this.serverMode()) {
      this.statusText = '需要先在「设置 → 服务端」连上电脑';
      return;
    }
    this.statusText = '连接中…';
    const handlers: TermHandlers = {
      onStatus: (status: string, detail: string): void => {
        if (status === 'disconnected' || status === 'error') {
          this.connected = false;
          this.statusText = status === 'error' ? detail : '连接断开';
        }
      },
      onOutput: (chunk: string): void => {
        this.appendText(chunk);
      },
      onCreated: (s: TermSession): void => {
        this.connected = true;
        this.activeId = s.id;
        this.statusText = `已连接 · ${s.shell}`;
        this.refreshSessions();
      },
      onExited: (id: string, exitCode: number): void => {
        this.appendText(`\n[会话 ${id} 已退出，code=${exitCode}]\n`);
        this.refreshSessions();
      },
      onError: (message: string): void => {
        this.appendText(`\n[错误] ${message}\n`);
      }
    };
    const ok: boolean = await this.term.open(
      NetConfig.getBaseUrl(), NetConfig.getToken(), handlers);
    if (!ok) {
      this.connected = false;
      if (this.statusText === '连接中…') {
        this.statusText = '连接失败，检查电脑上的服务';
      }
    }
    // 连上后立刻设一次窗口大小，否则 pty 用默认 80x24，手机上会错行
    if (ok) {
      this.term.resize(80, 20);
    }
  }

  private refreshSessions(): void {
    this.sessions = this.term.list();
  }

  private appendText(s: string): void {
    if (s.length === 0) {
      return;
    }
    const clean: string = TerminalPage.normalize(s);
    let merged: string = this.output + clean;
    if (merged.length > MAX_BUFFER) {
      merged = merged.slice(merged.length - MAX_BUFFER);
    }
    this.output = merged;
  }

  /**
   * 规范化终端输出：
   *   ① 剥掉 ANSI 转义序列（CSI / OSC / 孤立 ESC）
   *   ② `\r` 换成 `\n` —— Windows PowerShell 里是 `\r\n`，只处理 `\n` 会让
   *      光标回车的行为丢失，整屏输出挤成一行
   *   ③ 去掉退格符（`\b`）及其前一个字符 —— 覆盖打印用
   */
  private static normalize(s: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      const c: string = s.charAt(i);
      // ESC 序列
      if (c === '\u001b') {
        const next: string = i + 1 < s.length ? s.charAt(i + 1) : '';
        if (next === '[') {
          let j: number = i + 2;
          while (j < s.length) {
            const code: number = s.charCodeAt(j);
            if (code >= 0x40 && code <= 0x7E) {
              j++;
              break;
            }
            j++;
          }
          i = j;
          continue;
        }
        if (next === ']') {
          let j: number = i + 2;
          while (j < s.length) {
            if (s.charCodeAt(j) === 0x07) {
              j++;
              break;
            }
            if (s.charAt(j) === '\u001b' && j + 1 < s.length && s.charAt(j + 1) === '\\') {
              j += 2;
              break;
            }
            j++;
          }
          i = j;
          continue;
        }
        i += 2;
        continue;
      }
      // 退格：删掉已输出的最后一个字符（模拟覆盖）
      if (c === '\b') {
        if (out.length > 0) {
          out = out.slice(0, out.length - 1);
        }
        i++;
        continue;
      }
      // 回车：换行（终端里 \r 是回到行首，紧跟的 \n 会造成空行）
      if (c === '\r') {
        if (i + 1 < s.length && s.charAt(i + 1) === '\n') {
          out += '\n';
          i += 2;
          continue;
        }
        out += '\n';
        i++;
        continue;
      }
      out += c;
      i++;
    }
    return out;
  }

  /**
   * 发一条命令。
   *
   * ⚠ 双重发送的坑（实测 2026-10-07）：发送键 `↵` 的onClick 与输入框的
   *   onSubmit 在部分鸿蒙版本上会被**同一次点击同时触发**，
   *   结果命令发了两遍（终端里出现 `whoamiwhoami`）。
   *   ⇒ 用一个极短的时间窗做去重：同一个输入只允许发一次。
   *   时间窗取120ms —— 足够挡住同一次点击的两个回调，
   *   又不会影响用户「很快地连续发两条命令」这种正常操作。
   */
  private sendInput(): void {
    const data: string = this.input;
    if (data.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastSendAt < 120) {
      return;
    }
    this.lastSendAt = now;
    this.input = '';
    // ⚠ 必须补 `\r`：send() 发的是纯键盘输入，不带换行的话
    //   PowerShell 只会把命令打在提示符后面、**不会执行**。
    //   （实测踩过：App 看起来"发出去了"，PC 那边一直等着回车。）
    const payload: string = `${data}\r`;
    if (this.term.send(payload)) {
      this.appendText(data);
    } else {
      promptAction.showToast({ message: '发送失败，检查连接' });
    }
  }

  /** 发控制键 */
  private sendKey(code: string): void {
    this.term.send(code);
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 12 }) {
        Text('‹').fontSize(24).fontColor(Tok.text1(this.dark))
          .width(28)
          .onClick(() => router.back())
        Column({ space: 2 }) {
          Text('电脑终端')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tok.text1(this.dark))
          Text(this.statusText)
            .fontSize(11)
            .fontColor(this.connected ? Tok.text3(this.dark) : Tok.danger)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.connected) {
          Text('+')
            .fontSize(20)
            .fontColor(Tok.brand)
            .width(28)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.term.createSession('');
            })
        }
      }
      .width('100%')
      .padding({ left: Tok.pagePad, right: Tok.pagePad, top: 6, bottom: 10 })
      .backgroundColor(Tok.pageBg(this.dark))

      if (!this.connected && this.output.length === 0) {
        Column() {
          EmptyState({
            icon: this.statusText.indexOf('连接中') >= 0 ? '◌' : '⚠',
            text: this.statusText,
            hint: '手机上操作电脑的 PowerShell'
          })
          if (this.statusText.indexOf('连接中') < 0) {
            PrimaryButton({
              label: '重试',
              onTap: (): void => {
                this.output = '';
                this.connect();
              }
            })
            .margin({ top: 16 })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 终端输出（黑底等宽）
        Scroll() {
          Text(this.output)
            .fontSize(11)
            .fontColor('#D8DEE9')
            .fontFamily('monospace')
            .width('100%')
            .padding(10)
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#12141A')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)

        if (this.connected) {
          // 快捷键行
          Scroll() {
            Row({ space: 6 }) {
              ForEach(['\u0003', '\u0004', '\u001b', '\u001b[C', '\u001b[D', '\r'],
                (k: string) => {
                  Text(TerminalPage.keyLabel(k))
                    .fontSize(12)
                    .fontColor(Tok.text1(this.dark))
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .backgroundColor(Tok.cardBg(this.dark))
                    .borderRadius(Tok.radiusSmall)
                    .onClick(() => {
                      this.sendKey(k);
                    })
                }, (k: string) => 'k' + k)
            }
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          }
          .width('100%')
          .scrollBar(BarState.Off)

          // 输入行
          Row({ space: 6 }) {
            TextInput({ placeholder: '输入命令…', text: this.input })
              .layoutWeight(1)
              .height(36)
              .fontSize(13)
              .backgroundColor(Tok.cardBg(this.dark))
              .borderRadius(Tok.radius)
              .onChange((v: string): void => {
                this.input = v;
              })
              .onSubmit(() => {
                this.sendInput();
              })
            Button('↵')
              .width(40)
              .height(36)
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor(Tok.brand)
              .onClick(() => {
                this.sendInput();
              })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 4, bottom: 10 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
  }

  /** 控制字符的可读标签 */
  private static keyLabel(k: string): string {
    if (k === '\u0003') {
      return 'Ctrl+C';
    }
    if (k === '\u0004') {
      return 'Ctrl+D';
    }
    if (k === '\u001b') {
      return 'Esc';
    }
    if (k === '\u001b[C') {
      return '→';
    }
    if (k === '\u001b[D') {
      return '←';
    }
    if (k === '\r') {
      return 'Enter';
    }
    return k;
  }
}