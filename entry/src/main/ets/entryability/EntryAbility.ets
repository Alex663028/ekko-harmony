import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import type Want from '@ohos.app.ability.Want';
import type AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { KeyboardAvoidMode, UIContext } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { AppStore } from '../viewmodel/AppStore';
import { breakpointOf } from '../common/Core';

const TAG = 'EkkoStudio';
const DOMAIN = 0x0001;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // ArkUI 的 @StorageLink 读不到会退化成 undefined，
    // 所以所有页面用到的键都必须在 Ability 起来时先建好。
    AppStorage.setOrCreate<boolean>('themeDark', false);
    AppStorage.setOrCreate<string>('serverUrl', 'http://127.0.0.1:8748');
    AppStorage.setOrCreate<string>('userName', '');
    AppStorage.setOrCreate<string>('userRole', 'local');
    AppStorage.setOrCreate<string>('activeSessionId', '');
    AppStorage.setOrCreate<string>('activeRoomId', '');
    AppStorage.setOrCreate<number>('topSafeHeight', 0);
    AppStorage.setOrCreate<number>('bottomSafeHeight', 0);
    // 响应式状态：断点 + 侧栏比例 + 是否折叠
    AppStorage.setOrCreate<string>('breakpoint', 'compact');
    AppStorage.setOrCreate<number>('sidebarRatio', 0.28);
    AppStorage.setOrCreate<boolean>('sidebarCollapsed', false);
    AppStorage.setOrCreate<boolean>('isHoverCapable', false);
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    const ctx = this.context as common.UIAbilityContext;
    try {
      await AppStore.init(ctx);
      hilog.info(DOMAIN, TAG, 'AppStore 初始化完成');
    } catch (e) {
      const err = e as Error;
      hilog.error(DOMAIN, TAG, 'AppStore 初始化失败: %{public}s', err.message);
    }

    windowStage.loadContent('pages/LoginPage', (err) => {
      if (err.code !== 0) {
        hilog.error(DOMAIN, TAG, '页面加载失败: %{public}s', `${err.code}`);
        return;
      }
      EntryAbility.setupSafeArea(ctx);
      EntryAbility.watchWindow(ctx);
      EntryAbility.setupKeyboardAvoid(ctx);
    });
  }

  /**
   * 键盘避让模式：**必须显式设成 RESIZE**（实测 2026-10-06 踩坑）。
   *
   * 默认是 OFFSET —— 键盘弹出时整个页面上移。聊天页是
   * `Column { 顶栏 + layoutWeight(1) 的消息列表 + 输入区 }`，
   * 整页上移后顶栏和消息列表会被推出可视区，
   * 表现就是「键盘一弹，消息全没了，只剩输入框」，
   * 而实际数据都在、退出重进又能看到，极难定位。
   *
   * RESIZE 会压缩窗口高度，Column 的 layoutWeight 自动收缩，各层都在。
   */
  private static setupKeyboardAvoid(ctx: common.UIAbilityContext): void {
    try {
      // UIContext 挂在 Window 上（UIAbilityContext 没有 getUIContext）
      window.getLastWindow(ctx).then((win: window.Window) => {
        const root: UIContext = win.getUIContext();
        root.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      }).catch(() => {
        hilog.warn(DOMAIN, TAG, '键盘避让模式设置失败（取 Window 失败）');
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '键盘避让模式设置失败');
    }
  }

  /**
   * 监听窗口尺寸 → 更新响应式断点。
   *
   * 为什么用窗口尺寸而不是屏幕尺寸：PC 上窗口可以被自由拉伸，
   * 物理屏宽不变但布局必须跟着变。折叠屏展开同理。
   * 所以这一段是「鸿蒙 PC 能用」的关键。
   */
  private static watchWindow(ctx: common.UIAbilityContext): void {
    try {
      window.getLastWindow(ctx).then((win: window.Window) => {
        const apply = (wPx: number, hPx: number): void => {
          const wVp = px2vp(wPx);
          const bp = breakpointOf(wVp);
          AppStorage.setOrCreate<string>('breakpoint', bp);
          AppStorage.setOrCreate<number>('windowWidthVp', wVp);
          AppStorage.setOrCreate<number>('windowHeightVp', px2vp(hPx));
          // 指针设备（鼠标）才启用悬停态
          AppStorage.setOrCreate<boolean>('isHoverCapable', bp === 'expanded');
        };

        const props = win.getWindowProperties();
        apply(props.windowRect.width, props.windowRect.height);

        win.on('windowSizeChange', (size: window.Size) => {
          apply(size.width, size.height);
        });

        // 折叠屏展开/合上
        try {
          display.getDefaultDisplaySync().on('availableAreaChange', (): void => {
            const rect = win.getWindowProperties().windowRect;
            apply(rect.width, rect.height);
          });
        } catch (e) {
          // 非可折叠设备忽略
        }
      }).catch(() => {});
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '窗口监听失败');
    }
  }

  /**
   * 安全区换算。
   *
   * 关键：getWindowAvoidArea 返回的是 **px**，而 ArkUI 的 margin/padding/height
   * 单位是 **vp**。不转换的后果：在 480dpi 设备上留白被放大 3 倍
   * （用户反馈"顶部空了一大块"的典型原因）。
   */
  private static setupSafeArea(ctx: common.UIAbilityContext): void {
    try {
      window.getLastWindow(ctx).then((win: window.Window) => {
        const applySystem = (): void => {
          // getWindowAvoidArea 是同步方法，返回 AvoidArea
          const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          AppStorage.setOrCreate<number>('topSafeHeight', px2vp(area.topRect.height));
        };
        const applyNav = (): void => {
          const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          AppStorage.setOrCreate<number>('bottomSafeHeight', px2vp(area.bottomRect.height));
        };
        applySystem();
        applyNav();
        // 旋转 / 折叠屏展开时安全区会变，必须监听重算，
        // 只在 aboutToAppear 读一次是不会更新的。
        win.on('avoidAreaChange', () => {
          applySystem();
          applyNav();
        });
      }).catch(() => {});
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '安全区获取失败');
    }
  }

  onBackground(): void {
    // App 退到后台时申请长任务 —— 否则 socket 会被系统回收，
    // Agent 的审批/澄清请求就收不到了（表现为「Agent 一直转、5 分钟后超时」）。
    EntryAbility.startBackgroundTask(this.context);
  }

  onDestroy(): void {
    EntryAbility.stopBackgroundTask(this.context);
    AppStore.close();
  }

  onForeground(): void {
    EntryAbility.stopBackgroundTask(this.context);
  }

  // ─────────────── 后台长任务（保住socket）───────────────

  private static bgRunning: boolean = false;

  /**
   * 启动后台长任务（continuous task）。
   *
   * ## 为什么必须要（老板 2026-10-06 要求「Agent 要审批时手机能弹窗」）
   *
   * 链路是：PC 的 Agent 发approval.requested → **手机 socket 收到** → 发系统通知。
   * App 一旦退到后台，socket 会被系统回收，第三步就断了 ——
   * 用户只看到「Agent 一直转、5 分钟后超时」，根本不知道它在等什么。
   * 所以必须申请长任务把进程保活。
   *
   * mode选 DATA_TRANSFER：我们的场景（保持与PC 的实时连接、接收 Agent 推送）
   * 与官方给「数据同步」的定义最接近。
   *
   * ⚠ 申请失败只warn 不抛 —— 拿不到长任务只是退化成「前台可用」，
   *   不该让 App 起不来。
   */
  private static startBackgroundTask(ctx: common.UIAbilityContext): void {
    if (EntryAbility.bgRunning) {
      return;
    }
    // 先取 WantAgent（点通知栏回 App，系统要求必填）
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.ekkostudio.harmony',
        abilityName: 'EntryAbility'
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1
    };
    wantAgent.getWantAgent(info).then((agent: WantAgent): void => {
      EntryAbility.doStartBackgroundTask(ctx, agent);
    }).catch((): void => {
      EntryAbility.doStartBackgroundTask(ctx, null);
    });
  }

  private static doStartBackgroundTask(ctx: common.UIAbilityContext,
    agent: WantAgent | null): void {
    try {
      const req: backgroundTaskManager.ContinuousTaskRequest =
        new backgroundTaskManager.ContinuousTaskRequest();
      req.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      req.backgroundTaskSubmodes = [];
      if (agent !== null) {
        req.wantAgent = agent;
      }

      backgroundTaskManager.startBackgroundRunning(ctx, req)
        .then((): void => {
          EntryAbility.bgRunning = true;
          hilog.info(DOMAIN, TAG, '后台长任务已启动');
        })
        .catch((e: BusinessError): void => {
          hilog.warn(DOMAIN, TAG, '后台长任务申请失败（退化为仅前台可用）code=%{public}d', e.code);
        });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '后台长任务启动异常');
    }
  }

  private static stopBackgroundTask(ctx: common.UIAbilityContext): void {
    if (!EntryAbility.bgRunning) {
      return;
    }
    try {
      backgroundTaskManager.stopBackgroundRunning(ctx)
        .then((): void => {
          EntryAbility.bgRunning = false;
        })
        .catch((): void => {
          EntryAbility.bgRunning = false;
        });
    } catch (e) {
      EntryAbility.bgRunning = false;
    }
  }
}