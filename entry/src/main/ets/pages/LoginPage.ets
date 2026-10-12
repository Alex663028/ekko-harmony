/**
 * 登录页：两种模式
 *  A. 本地模式（默认）：填昵称即可，不联网，数据落在本机
 *  B. 连接 Ekko Studio 服务端：填 PC 地址 + 账号密码，复用服务端 Agent 运行时
 */

import { router, promptAction } from '@kit.ArkUI';
import preferences from '@ohos.data.preferences';
import { AppStore, K } from '../viewmodel/AppStore';
import { StudioApi } from '../net/StudioApi';
import { NetConfig } from '../net/Http';
import { ProviderRepo } from '../data/Repos';
import { Provider } from '../model/Types';
import { LabeledInput, PrimaryButton, SegmentedTabs } from '../view/Common';
import { Tok } from '../view/Theme';
import { errorMessage } from '../net/Http';

/**
 * 调试开关（P2-15）：不再硬编码 true，改由运行时构建类型决定。
 * aboutToAppear 读 applicationInfo.releaseType：release 包不渲染按钮，
 * debug 包（releaseType === 'debug'）才显示「一键登录本机」。
 * 凭据仍从 preferences 的 debug.quicklogin.* 读，源码不留明文口令。
 * 写入方式见 docs/DEBUG-QUICKLOGIN.md。
 */

/**
 * 登录页可选的内置供应商。
 * 顺序必须与下方 SegmentedTabs 的 items 一一对应。
 * id 取自 AppStore.ensureBuiltinProviders() 里的 seeds。
 */
const LOGIN_PROVIDER_IDS: string[] = [
  'builtin-openai', 'builtin-deepseek', 'builtin-anthropic', 'builtin-longcat'
];
const LOGIN_PROVIDER_LABELS: string[] = ['OpenAI', 'DeepSeek', 'Claude', 'LongCat'];

@Entry
@Component
struct LoginPage {
  @StorageLink('themeDark') dark: boolean = false;
  @StorageLink('serverUrl') serverUrl: string = 'http://127.0.0.1:8748';

  @State mode: number = 0;          // 0=本地  1=连接服务端
  @State nickname: string = '';
  @State username: string = '';
  @State password: string = '';
  @State apiKey: string = '';
  /**
   * 本地模式下 key 落到哪个供应商。
   *
   * 必须显式指定，**不能取 providers[0]**：ProviderRepo.list 的排序是
   * `ORDER BY builtin DESC, name`，按字母序第一个是 Claude(Anthropic)，
   * 与登录页「走 OpenAI 兼容接口」的承诺不符 ——
   * 填 OpenAI / DeepSeek 的 key 会被存到 Anthropic 供应商上，调用必然 401。
   */
  @State providerId: string = 'builtin-openai';
  @State baseUrl: string = '';
  @State busy: boolean = false;
  @State error: string = '';
  @State probeMsg: string = '';
  /** P2-15：调试包才显示一键登录，由 aboutToAppear 按 releaseType 置位 */
  @State debugLoginEnabled: boolean = false;

  aboutToAppear() {
    this.baseUrl = this.serverUrl;
    // P2-15：releaseType 由构建类型决定，release 包恒为 'release' → 按钮不渲染
    this.debugLoginEnabled = AppStore.context().applicationInfo.releaseType !== 'release';
    this.nickname = AppStorage.get<string>(K.USER_NAME) ?? '';
    this.apiKey = AppStorage.get<string>('seedApiKey') ?? '';

    // ⚠ 恢复上次的模式，否则每次都停在「本地模式」。
    //   实测踩过：服务端登录过一次，再打开还是本地模式 → 群聊读的是
    //   手机本地库（空的），看起来「群聊不存在」，其实压根没连 PC。
    if ((AppStorage.get<string>(K.DATA_SOURCE) ?? 'local') === 'server') {
      this.mode = 1;
    }

    // 已经登录过就直接进工作台，别再让人登一遍。
    // 判据：服务端模式 + 令牌还在（AppStore.init 已经把它恢复到 NetConfig 了）
    if (this.mode === 1 && NetConfig.getToken().length > 0) {
      this.gotoSessionList();
    }
  }

  /** providerId → SegmentedTabs 下标 */
  private providerIndex(): number {
    for (let i = 0; i < LOGIN_PROVIDER_IDS.length; i++) {
      if (LOGIN_PROVIDER_IDS[i] === this.providerId) {
        return i;
      }
    }
    return 0;
  }

  private async testServer(): Promise<void> {
    if (this.baseUrl.trim().length === 0) {
      this.probeMsg = '请先填写地址';
      return;
    }
    this.probeMsg = '检测中…';
    const res = await StudioApi.testServer(this.baseUrl.trim());
    this.probeMsg = res.ok ? `✓ ${res.message}` : `✗ ${res.message}`;
  }

  /**
   * ⚠ 仅调试包可用：一键填入联调账号并直接登录。
   *
   * 为什么需要：hdc 的 uinput 无法可靠地操作登录页
   * （退格键无效、键盘弹出后点不到被遮挡的输入框），
   * 没法自动跑「登录 → 点会话 → 看消息」这条链路去自测。
   * 单次点击是可靠的，所以把登录做成一个按钮。
   *
   * 🔐 凭据来源：preferences 的 `debug.quicklogin.{url,username,password}`。
   *   **源码里不留任何明文口令**。没配置时按钮会提示，不静默失败。
   */
  private async runDebugQuickLogin(): Promise<void> {
    if (!this.debugLoginEnabled) {
      return;
    }
    const prefs: preferences.Preferences = await preferences.getPreferences(AppStore.context(), {
      name: 'debug'
    });
    const url: string = (await prefs.get('quicklogin.url', '')) as string;
    const user: string = (await prefs.get('quicklogin.username', '')) as string;
    const pwd: string = (await prefs.get('quicklogin.password', '')) as string;
    if (url.length === 0 || user.length === 0 || pwd.length === 0) {
      this.mode = 1;
      this.error = '未配置联调凭据：请在 preferences/debug 里填 quicklogin.url / username / password';
      return;
    }
    this.mode = 1;
    this.baseUrl = url;
    this.username = user;
    this.password = pwd;
    await this.submit();
  }

  private async submit(): Promise<void> {
    this.error = '';
    if (this.mode === 0) {
      if (this.nickname.trim().length === 0) {
        this.error = '请填写昵称';
        return;
      }
      if (this.apiKey.trim().length === 0) {
        this.error = '请填写 API Key，否则无法对话';
        return;
      }
      this.busy = true;
      try {
        await AppStore.setUser(this.nickname.trim(), 'local');
        await AppStore.setServerUrl(this.baseUrl.trim());
        // 切回本地数据源（可能上一次用的是服务端模式）
        await AppStore.setDataSource('local');
        // 把 key 落到用户选中的供应商（默认 builtin-openai）。
        // 用 id 精确匹配，而不是取列表第一个 —— 见 providerId 字段的注释。
        const providers = await ProviderRepo.list(AppStore.db());
        let target: Provider | null = null;
        for (const it of providers) {
          if (it.id === this.providerId) {
            target = it;
            break;
          }
        }
        if (target === null && providers.length > 0) {
          target = providers[0];
        }
        if (target !== null) {
          target.apiKey = this.apiKey.trim();
          await ProviderRepo.upsert(AppStore.db(), target, Date.now());
          await AppStore.reloadProviders();
        }
        AppStorage.setOrCreate<string>('seedApiKey', '');
        // 默认 Agent 必须挂到同一个供应商，否则 key 填了也用不上
        await AppStore.ensureDefaultAgent(this.providerId);
        this.gotoSessionList();
      } catch (e) {
        this.error = errorMessage(e);
      } finally {
        this.busy = false;
      }
      return;
    }

    // 服务端模式
    if (this.baseUrl.trim().length === 0 || this.username.trim().length === 0) {
      this.error = '请填写服务器地址与账号';
      return;
    }
    this.busy = true;
    try {
      await AppStore.setServerUrl(this.baseUrl.trim());
      const res = await StudioApi.login(this.username.trim(), this.password);
      // 持久化令牌：服务端模式下所有请求都要带，放内存重启就丢了
      await AppStore.setToken(res.token);
      const me = await StudioApi.me(res.token);
      await AppStore.setUser(me.username, me.role);
      // 切到服务端数据源 —— 从这一刻起，所有 Repo 都改读 PC 上的 Ekko Studio
      await AppStore.setDataSource('server');
      await AppStore.ensureDefaultAgent();
      this.gotoSessionList();
    } catch (e) {
      this.error = errorMessage(e);
    } finally {
      this.busy = false;
    }
  }

  /** router.replaceUrl 只接受 RouterOptions 对象，不能直接传 url 字符串 */
  private gotoSessionList(): void {
    const opts: router.RouterOptions = { url: 'pages/SessionListPage' };
    router.replaceUrl(opts);
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        // 品牌区
        Column({ space: 6 }) {
          Text('Ekko Studio')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tok.text1(this.dark))
          Text('鸿蒙版 · 多 Agent AI 工作台')
            .fontSize(13)
            .fontColor(Tok.text3(this.dark))
        }
        .margin({ top: 40, bottom: 8 })

        SegmentedTabs({
          items: ['本地模式', '连接服务端'],
          active: this.mode,
          onChange: (idx: number) => {
            this.mode = idx;
            this.error = '';
            this.probeMsg = '';
          }
        })

        if (this.mode === 0) {
          Column({ space: 14 }) {
            LabeledInput({
              label: '昵称',
              placeholder: '怎么称呼你',
              value: this.nickname,
              onChange: (v: string) => {
                this.nickname = v;
              }
            })

            LabeledInput({
              label: '模型 API Key',
              placeholder: 'sk-...（保存在本机，不上传）',
              value: this.apiKey,
              secret: true,
              onChange: (v: string) => {
                this.apiKey = v;
              }
            })

            Text('供应商（key 将存到这里）')
              .fontSize(12)
              .fontColor(Tok.text2(this.dark))
              .width('100%')

            SegmentedTabs({
              items: LOGIN_PROVIDER_LABELS,
              active: this.providerIndex(),
              onChange: (idx: number) => {
                this.providerId = LOGIN_PROVIDER_IDS[idx];
              }
            })

            Text('国内可直连 DeepSeek / LongCat；地址与模型可在「设置 → 供应商」里改。')
              .fontSize(11)
              .fontColor(Tok.text3(this.dark))
              .width('100%')
          }
          .width('100%')
        } else {
          Column({ space: 14 }) {
            LabeledInput({
              label: 'Studio 地址',
              placeholder: 'http://192.168.1.10:8748',
              value: this.baseUrl,
              onChange: (v: string) => {
                this.baseUrl = v;
              }
            })

            Row() {
              Text(this.probeMsg)
                .fontSize(12)
                .fontColor(this.probeMsg.indexOf('✓') === 0 ? Tok.success : Tok.text3(this.dark))
                .layoutWeight(1)
                .maxLines(2)
              Text('测试连接')
                .fontSize(13)
                .fontColor(Tok.brand)
                .padding({ left: 8, top: 4, bottom: 4 })
                .onClick(() => {
                  this.testServer();
                })
            }
            .width('100%')

            LabeledInput({
              label: '账号',
              placeholder: '用户名',
              value: this.username,
              onChange: (v: string) => {
                this.username = v;
              }
            })

            LabeledInput({
              label: '密码',
              placeholder: '密码',
              value: this.password,
              secret: true,
              onChange: (v: string) => {
                this.password = v;
              }
            })
          }
          .width('100%')
        }

        if (this.error.length > 0) {
          Text(this.error)
            .width('100%')
            .fontSize(12)
            .fontColor(Tok.danger)
            .backgroundColor('#FFF1F0')
            .padding(10)
            .borderRadius(Tok.radiusSmall)
        }

        PrimaryButton({
          label: this.mode === 0 ? '进入工作台' : '登录并进入',
          busy: this.busy,
          onTap: () => {
            this.submit();
          }
        })

        if (this.debugLoginEnabled) {
          PrimaryButton({
            label: '[调试] 一键登录本机',
            onTap: () => {
              this.runDebugQuickLogin();
            }
          })
        }

        PrimaryButton({
          label: this.dark ? '切换到亮色' : '切换到暗色',
          enabledState: !this.busy,
          onTap: () => {
            AppStore.setDark(!this.dark);
          }
        })
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 40 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tok.pageBg(this.dark))
  }
}