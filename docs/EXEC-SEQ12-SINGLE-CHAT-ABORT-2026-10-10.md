# 执行记录：单聊停止建连窗口静默丢失（P1-NEW-1）+ 群聊发送幂等（SEQ12）

- 执行人：DSH
- 授权：ALEX（群聊原话「修复，然后艾特hermes真机测试」，回应 Pi SEQ12 审核两问）
- 基线：`631e561`（20 commits），工作区干净
- 审核来源：Pi `docs/AUDIT-PI-SEQ12-REAUDIT-2026-10-10.md`（P1-NEW-1 + 观察 O-1/O-2/O-3）
- 结论：**P1-NEW-1 已修 + O-3（群聊发送幂等）一并修；冷构建 0 ERROR；8 套件 576 全绿；防退化守卫负样本验证通过**
- 未动：O-1（毫秒级更窄窗口，建议单独排期）、O-2（`LlmEngine.isRunning` 仍零调用，见文末「遗留」）

---

## 一、P1-NEW-1：ChatPage 单聊「停止」在建连窗口被静默丢弃

### 1.1 复现（读源码，非自报）

Pi 的结论逐条复核成立：

- `ChatPage.ets:1382`（原 `:1358`）`this.handle = await LlmEngine.run(...)` —— 句柄要等**整段流结束**才赋值（建连 `connectTimeout=20000`、流式 `readTimeout=300000`）。
- 窗口内 `this.handle === null`，原 `stopIfRunning()` 只看 `if (this.handle !== null)` → **abort 分支整体跳过**。
- 后果：`streaming` 置 false、按钮变回「↑」**假装已停止**，请求继续烧 token；`onPageHide:481` / `aboutToDisappear:503` 兜底同样落空，run 泄漏到自然结束。
- 佐证：`LlmEngine.abortRun` 调用点原先只有 `Orchestrator.ets:529`，`isRunning` 零调用 —— 上轮 P2-1 的修法确实只覆盖了群聊。

### 1.2 修法（与群聊 `Orchestrator.activeRunIds` 同源同构，只加不改结构）

| 位置 | 改动 |
|---|---|
| `ChatPage.ets:450` | 新增字段 `private liveLocalRunId: string = '';`（本地模式的 runId 登记位） |
| `ChatPage.ets:1327-1328` | `const localRunId = this.liveBubbleId; this.liveLocalRunId = localRunId;` —— 在 `await LlmEngine.run` **之前**登记 |
| `ChatPage.ets:1373-1375` | `buildContext()` 之后、发起前加归属校验：`if (this.liveLocalRunId !== localRunId) return;` —— 停止后不再补发请求 |
| `ChatPage.ets:1380-1383` | 句柄只在「仍是当前这轮」时才挂：`if (this.liveLocalRunId === localRunId) this.handle = h;` —— 杜绝陈旧句柄 |
| `ChatPage.ets:1429` | `finishRun()` 收尾摘登记 `this.liveLocalRunId = '';` |
| `ChatPage.ets:1605-1608` | `stopIfRunning()` 新增回落：`if (this.liveLocalRunId.length > 0) { LlmEngine.abortRun(this.liveLocalRunId); this.liveLocalRunId = ''; }` |

关键点：回落分支与句柄分支**不互斥**。句柄可能属于上一轮（陈旧句柄），`abortRun(runId)` 才是建连窗口的权威路径；`LlmEngine.abortRun:167` 命中 `aborts` 表登记的回调，走与句柄 abort **完全相同**的收尾路径（`abortFn` → `abort.completed` → `releaseSlot` + `client.destroy()`）。

### 1.3 覆盖的三个窗口

1. **建连/流式窗口**（Pi 报的主窗口）：`liveLocalRunId` 已登记、`aborts` 已命中 → `abortRun` 生效。
2. **发请求前的 DB/上下文 await 窗口**（`MessageRepo.insert` / `SessionRepo.*` / `buildContext`）：停止会清 `liveLocalRunId` → `:1373` 归属校验直接 return，不再发起请求。
3. **陈旧句柄窗口**：`this.handle` 只在归属命中时赋值，下一轮停止不会走错分支。

---

## 二、O-3：群聊「发送」缺幂等位（P2，一并修）

- 原 `GroupChatPage.ets:992` `send()` 入口只判 `text.length === 0`，没有 `sending` 位；`send()` 内有多处 await（`ProviderRepo.get` / `RoomRepo.get` / `dispatch`），连点两次会并行走第二遍 → **队列 2 条重复任务、agent 对同一条消息回两遍**。ChatPage 侧靠 `if (this.streaming) return;` 守住，群聊侧原先不对称。
- 修法：
  - `GroupChatPage.ets:363` 新增 `@State sending: boolean = false;`
  - `:1008-1018` `send()` 入口 `if (this.sending) return;`，`try/finally` 包裹实体并复位（异常路径也复位）。
  - `:1022` 原方法体拆为 `sendInner(text)`（仅方法改名，逻辑零改动）。
  - `:1402` 发送按钮 `.enabled(this.draft.trim().length > 0 && !this.sending)`，发送中置灰。

---

## 三、防退化守卫（+10 条，198→**219**）

`_test/run_uiguard.ts` 新增两节：

- **第 8 节（P1-SEQ12，6 条）**：ChatPage 有 runId 登记位 / runId 在 `await LlmEngine.run` 之前登记 / `stopIfRunning` 回落到 `LlmEngine.abortRun` / 停止后不再补发请求 / 句柄只挂「当前轮」/ 收尾与停止都摘登记。
- **第 9 节（P2-SEQ12，4 条）**：群聊有 `sending` 位 / `send` 入口挡重复点击 / `sending` 在 `finally` 复位 / 发送按钮在发送中禁用。

### 负样本验证（`.backups\negtest-seq12\` 临时镜像，验证后已销毁）

注入三处回归：① 删 `LlmEngine.abortRun(this.liveLocalRunId)`；② `if (this.sending)` → `if (false)`；③ 移除按钮 `&& !this.sending`。

```
UI 防退化守卫：  通过 216 · 失败 3
  ✗ ChatPage stopIfRunning 回落到 LlmEngine.abortRun
  ✗ send 入口挡重复点击
  ✗ 发送按钮在发送中禁用
exit=1
```

三条精确命中，守卫真实生效（不是假绿灯）。镜像 `D:\EkkoStudioHarmonyOS\.backups\negtest-seq12` 已删除（`Test-Path` = False）。

---

## 四、验证结果（DSH 亲自复跑）

| 项 | 结果 |
|---|---|
| 冷构建（`clean` + `assembleHap`） | `BUILD SUCCESSFUL in 13 s 1000 ms`，**ERROR 计数 0** |
| HAP 产物 | `entry\build\default\outputs\default\entry-default-signed.hap` = **1,752,593 B** |
| 回归 8 套件（先 `sync_all.mjs`） | `run` 103 · `run_sse` 35 · `run_socket` 57 · `run_ext` 101 · `run_anthropic` 26 · 端点契约 25 · **UI 防退化 219** · SQL 列参 10 = **576 全绿** |
| 基线口径同步 | 根 `README.md`（198→219、209→219、566→576）、`_test/README.md`（209→219、566→576） |

---

## 五、备份（源码树外，ALEX 命名口径）

`.backups\seq12-single-chat-abort-20261010\`（改动前版本，取自 `HEAD=631e561`）：

- `ChatPage.ets.bak.p1-12`（84,515 B）
- `GroupChatPage.ets.bak.p2-12`（62,642 B）
- `run_uiguard.ts.bak.p2-12`（10,366 B）
- `README.md.bak.p2-12`、`_test_README.md.bak.p2-12`

---

## 六、遗留（未修，非本授权范围）

- **O-1**：`Repos.ets:990-993` `takeNext` 已把行改 `running`，`cancelQueued:963` 只动 `queued`；「pump 认领 → `Orchestrator.ets:265` 登记 runId」之间的**毫秒级**窗口点停止，仍会白烧一次 token、toast 误报「已取消排队任务」。量级远小于已修的 300s 窗口，守卫覆盖不到，建议单独排期（pump 认领即登记，或 `abort()` 落 cancel 标记由 `runOne` 前置检查）。
- **O-2**：`LlmEngine.isRunning`（`:181`）仍**零调用**。本轮未强行接线（`streaming` 已守住发送），建议下批接发送按钮或按死代码清除。
- **唯一硬阻断不变**：AGC 证书轮换（git 历史移除 ≠ 口令失效），只有 ALEX 能做。

---

## 七、真机测试复核补充（DSH 第三方复核 SEQ13/SEQ14，2026-10-10）

hermes 真机测试后，DSH 对 `.backups\AUDIT-DSH-SEQ13-REALDEVICE-2026-10-10.md` 与
`.backups\AUDIT-DSH-SEQ14-C3-RETEST-2026-10-10.md` 逐条对照源码复核，补充口径如下：

1. **用例 a/b 验证的是服务端 abort 路径，不是 P1-NEW-1 本地修复。**
   `ChatPage.send():1307-1310` 在 `dataSource === 'server'` 时直接 `return sendViaServer`，
   本地分支不执行；`liveLocalRunId`（P1-NEW-1 核心）6 处引用全在本地分支
   （`:450/1328/1373/1381/1429/1605`）。本轮用账号密码登录＝服务端模式，
   用例 a/b 实际覆盖的是 `emitChatAbort` 服务端路径，**P1-NEW-1 的本地建连窗口回落仍需
   在本地模式复跑才算验收**（DSH 建议假 Key + accept 不回包监听 + `hdc rport tcp:8899 tcp:8899`）。
2. **「0.5s 变（已中止）」不能单独算证据。** `stopIfRunning():1614` 的
   `finishStreamingBubble('（已中止）')` 是无条件客户端动作。真正有分量的是「10s 无回流」——
   `onSocketDelta:943-959` 遇无占位气泡会**补建新气泡**而非丢弃，没新气泡≈服务端真的没再推。
   这条证明服务端 abort 有效，证明不了本地路径。
3. **用例 c（O-3）判定通过，且不需要本地模式复跑。** `sending` 守卫
   （`GroupChatPage.ets:1008-1012`）在 `serverMode` 分叉（`:1080`）之前，本地/服务端共用。
   判据措辞应为**「连点重复必然相邻且位于可见底部」**，而非「全列表枚举=1」——
   dumpLayout 因虚拟化+自动滚底不能证明全列表枚举。
4. **群聊不带 @ 发送不视为静默丢弃。** `GroupChatPage.ets:1061-1066` 校验失败 →
   `:1064` toast 提示并保留草稿（`Core.ets:265-267`「需要 @ 至少一个 Agent 才会开始执行」），
   是设计行为且带反馈，不是 bug。
5. **F3（P2，存疑，先别动）。** 服务端模式草稿页首轮「停止」在服务端侧必然空转：
   `sessionId` 为空走 HTTP 非流式 `chatRun`（`ChatPage.ets:1237`），无可中止句柄；
   `:1616-1618` 丢弃 `emitChatAbort` 返回值，`StudioApi.ets:1254-1261` socket 未连时返回 false；
   全库无 HTTP abort 端点。同 P1-NEW-1 同源（UI 说停了 PC 继续跑），烧 PC token 故记 P2。
   DSH 明确建议先不动，等 ALEX 决定。

---

*执行记录：DSH · 2026-10-10 · 基线 631e561 · 零结构改动*
