/**
 * 服务端模式下的写操作策略。
 *
 * ## 为什么需要这个
 *
 * 手机端连上 PC 的 Ekko Studio 后，数据源是 PC。此时页面上任何
 * 「写本地 SQLite」的按钮，点了都不会报错、也不会有任何效果 ——
 * 因为数据写在手机上，而真正生效的是 PC。这是最难查的一类 bug：
 * **静默失败**，用户只看到「按钮点了没反应」。
 *
 * 本轮实测到的正是这个：24 处写操作全部只写本地库。
 *
 * ## 两种处理方式
 *
 * A. **有服务端接口的** → 调服务端接口（见 RemoteWrite）
 * B. **没有的 / 不该在手机端改的** → 明确提示，不静默失败
 *
 * 原则：**宁可明确告诉用户「这个要在 PC 上改」，也不要假装成功。**
 */
import { promptAction } from '@kit.ArkUI';

/** 当前是否服务端模式 */
export function isServerMode(): boolean {
  return (AppStorage.get<string>('dataSource') ?? 'local') === 'server';
}

/**
 * 服务端模式下拦截本地写操作。
 *
 * @param what  操作名（用于提示，如「看板卡片」）
 * @param silent  true 时只拦截不弹 toast（内部/编排器路径用，避免非用户触发的提示刷屏）
 * @returns true 表示已拦截，调用方应**立即 return**，不要再写本地库
 */
export function blockLocalWrite(what: string, silent?: boolean): boolean {
  if (!isServerMode()) {
    return false;
  }
  if (!silent) {
    promptAction.showToast({
      message: `服务端模式下不能改「${what}」，请到电脑上的 Ekko Studio 里操作`
    });
  }
  return true;
}

/**
 * 服务端模式下的只读态提示（用于页面级说明）。
 * 返回是否处于服务端模式，页面据此隐藏编辑入口。
 */
export function isReadOnly(): boolean {
  return isServerMode();
}
