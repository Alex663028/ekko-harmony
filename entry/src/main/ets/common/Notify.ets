/**
 * 本地通知：Agent 请求审批 / 澄清时弹系统通知。
 *
 * ## 为什么必须走系统通知（老板 2026-10-06 明确要求）
 *
 * ChatPage 里已经做了「审批遮罩面板」，但那只在**页面在前台**时有效。
 * 实际场景：Agent 在 PC 上跑着，手机锁屏 / 切到别的 App ——
 * 这恰恰是「等审批」最常见的状态（Agent 跑几分钟，人不可能一直盯着屏幕）。
 * 没有通知的话表现为「Agent 一直转、5 分钟后超时失败」，用户完全不知道它在等什么。
 *
 * 两条路径都要有：
 *   前台 → 页面内遮罩面板（体验更好：能直接选选项）
 *   后台 → 系统通知横幅 → **点通知直接跳到对应会话**并把面板亮起来
 *
 * ## 踩过的坑（写之前务必知道）
 *
 * 1. **SlotType 有两份且不兼容**：
 *    `NotificationSlot.type` 用 `@ohos.notification.SlotType`（旧命名空间），
 *    `NotificationRequest.slotType` 用 `notificationManager.SlotType`（新）。
 *    写任何一边都会报 "not assignable to type 'SlotType'"。
 *    绕法：先 `addSlot()` + `setSlot()` 建好 slot，发通知时**只带 slotId 不带类型**。
 *
 * 2. **`WantAgentInfo.requestCode` 是必填的**，漏了直接编译不过。
 *
 * 3. **没有 `new WantAgent()`**：本SDK 只导出 `wantAgent.getWantAgent(info)`。
 *
 * 4. **ArkTS 禁止在独立函数里用 `this`** → `getContext()` 不传参。
 *
 * 5. **枚举名别凭直觉**：`SlotType.OTHER_TYPES`（不是 OTHER）、
 *    重要级别是 `SlotLevel.LEVEL_HIGH`（没有 `Importance` 枚举）、
 *    声音在 slot 里是普通 `string`（没有 `SoundType` 枚举）。
 *    写之前先 grep SDK 的 d.ts。
 */

import { notificationManager } from '@kit.NotificationKit';
import notification from '@ohos.notification';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 通知 slot id：固定一个，方便后续 set / cancel */
const ASK_SLOT_ID: string = 'ekko_agent_ask';
/** 审批通知 id */
const ASK_NOTIFY_ID_APPROVAL: number = 9001;
/** 澄清通知 id */
const ASK_NOTIFY_ID_CLARIFY: number = 9002;

/** 从通知跳进来时带的参数值：审批 */
export const ASK_APPROVAL: string = 'approval';
/** 从通知跳进来时带的参数值：澄清 */
export const ASK_CLARIFY: string = 'clarify';

/**
 * 通知点击后的跳转目标。
 *
 * ⚠ 之前只传 sessionId、页面路径写死 `pages/ChatPage`，
 *   结果**群聊审批也会跳到单聊页** —— 而群聊页面根本没有审批遮罩，
 *   用户点完通知落到一个空会话，压根不知道自己批了什么（实测会这样）。
 *   ⇒ 必须让调用方明确给出目标页面。
 */
export interface AskTarget {
  /** 会话 id。URI 里统一用 `sessionId` 这个键名（群聊页也读这个，见 GroupChatPage） */
  id: string;
  /** 目标页面路径，如 `pages/ChatPage` / `pages/GroupChatPage` */
  page: string;
}

/**
 * 🔑 SlotType 在 ArkTS 里的类型陷阱（卡了半小时）
 *
 * `NotificationSlot` 上有两套枚举：
 *   `type`               → `@ohos.notification.SlotType`（旧，已 deprecated）
 *   `notificationType`   → `notificationManager.SlotType`（新）
 * 而 `NotificationRequest.slotType` 声明的又是另一份，且 SDK 自己的
 * .d.ts 里路径分隔符都不统一（`G:\` vs `G:/`），ArkTS 判成不同类型。
 *
 * 实测结论：**这版 SDK 上自定义 slot 写不通**，所以 notifyAsk 里
 * 完全不带 slot 字段，走系统默认。见 publish 处注释。
 */

/**
 * 确保通知权限与默认 slot 就绪。
 *
 * 另外 `notificationManager` **没有 setSlot 方法**（只有 addSlot/getSlot/getSlots），
 * slot 只能随 publish 请求一起带，不能事后改。
 */
async function ensureSlot(): Promise<void> {
  try {
    await notificationManager.addSlot(notificationManager.SlotType.OTHER_TYPES);
  } catch (e) {
    // 已存在会抛错，忽略
  }
}

/**
 * 发「Agent 需要你确认 / 有个问题」通知。
 *
 * @param title     标题（一般用 Agent 名）
 * @param detail    正文（问题详情 / 待确认内容）
 * @param target    跳转目标：**会话 id + 页面路径**（单聊 ChatPage / 群聊 GroupChatPage）
 * @param isClarify false=审批，true=澄清
 */
export async function notifyAsk(title: string, detail: string,
  target: AskTarget, isClarify: boolean): Promise<void> {
  // ArkTS：独立函数里不能带 this（arkts-no-standalone-this）
  const ctx = getContext() as common.UIAbilityContext;
  if (ctx === undefined || ctx === null) {
    return;
  }

  // 首次 publish 会被系统静默拦截，必须先显式申请
  try {
    await notificationManager.requestEnableNotification(ctx);
  } catch (e) {
    hilog.warn(0xD01, 'Notify', '申请通知权限失败: %{public}s', (e as Error).message ?? '');
  }
  await ensureSlot();

  const head: string = title.length > 0 ? title
    : (isClarify ? 'Agent 有个问题' : 'Agent 需要你确认');
  const body: string = detail.length > 0 ? detail
    : (isClarify ? '点开回答它的问题' : '点开确认或拒绝');

  const content: notificationManager.NotificationContent = {
    notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
    normal: {
      title: head,
      text: body
    }
  };

  // 点通知 → 跳到对应会话页，ask 参数告诉目标页「直接把面板亮起来」
  const info: wantAgent.WantAgentInfo = {
    wants: [{
      bundleName: 'com.ekkostudio.harmony',
      abilityName: 'EntryAbility',
      uri: `${target.page}?sessionId=${target.id}&ask=${isClarify ? ASK_CLARIFY : ASK_APPROVAL}`
    }],
    operationType: wantAgent.OperationType.START_ABILITY,
    requestCode: isClarify ? ASK_NOTIFY_ID_CLARIFY : ASK_NOTIFY_ID_APPROVAL
  };

  let agent: WantAgent | null = null;
  try {
    agent = await wantAgent.getWantAgent(info);
  } catch (e) {
    // 拿不到不影响发通知，只是点不进页面
    hilog.warn(0xD01, 'Notify', 'getWantAgent 失败（通知仍会发）: %{public}s',
      (e as Error).message ?? '');
  }

  // ⚠⚠ 字段名和直觉差很远，写之前必须 grep SDK 的 d.ts：
//   · `isRemoveWhenClicked`（老名字）**已不存在** → 新名字是 `tapDismissed`
//   · `slotType` 是**旧枚举**（notification.SlotType），
//     新枚举的字段叫 `notificationSlotType`（notificationManager.SlotType）
//   · `slot` 字段**根本没被 NotificationRequest 引用**，
//     想控制优先级只能靠 addSlot 先建好 + notificationSlotType 指向它
//
//   这里只用「旧slotType + tapDismissed」这一组 —— 实测这是唯一能编译通的组合。
//   代价是通知可能走默认优先级（被系统降级成静默），
//   但 publish 至少能成功 —— 宁可通知弱一点，不能发不出去。
const req: notificationManager.NotificationRequest = {
    id: isClarify ? ASK_NOTIFY_ID_CLARIFY : ASK_NOTIFY_ID_APPROVAL,
    slotType: notification.SlotType.OTHER_TYPES,
    content: content,
    // 点一下就消失：处理完就不该再挂着，否则像幽灵 bug
    tapDismissed: true,
    deliveryTime: 0
  };
  if (agent !== null) {
    req.wantAgent = agent;
  }

  try {
    await notificationManager.publish(req);
    hilog.info(0xD01, 'Notify', '已发通知 kind=%{public}s page=%{public}s id=%{public}s',
      isClarify ? ASK_CLARIFY : ASK_APPROVAL, target.page, target.id);
  } catch (e) {
    hilog.warn(0xD01, 'Notify', 'publish 失败: %{public}s', (e as Error).message ?? '');
  }
}

/**
 * 撤掉审批 / 澄清通知。
 *
 * 审批解决后必须调 —— 否则通知挂在下拉栏里，
 * 用户点进来发现已处理完，会以为是幽灵 bug。
 */
export async function cancelAskNotify(): Promise<void> {
  try {
    await notificationManager.cancel(ASK_NOTIFY_ID_APPROVAL);
  } catch (e) {
    // 可能本来就不存在
  }
  try {
    await notificationManager.cancel(ASK_NOTIFY_ID_CLARIFY);
  } catch (e) {
    // 同上
  }
}