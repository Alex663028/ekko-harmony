# 调试报告

工程：Ekko Studio 鸿蒙版（`com.ekkostudio.harmony`）
日期：2026-10-05
状态：**编译 0 错误 · 回归 453 项全绿 · 装机待签名**

---

## 结论速览

| 项目 | 结果 |
|---|---|
| 编译（debug / release） | BUILD SUCCESSFUL，0 错误 |
| 回归测试 | **453 项全绿**（6 个套件） |
| 静态守卫 | SQL 列↔实参 33 项、UI 防退化 142 项 |
| 本轮修掉的缺陷 | **16 个**（含 4 个必崩 / 白屏级） |
| 装机 | **卡在签名** —— 见 `SIGNING.md` |

---

## 一、本轮修掉的缺陷

### P0 必崩（2 个）

**1. `ChatPage.ets` 路由参数解引用 undefined**
```ts
// 改前 —— getParams() 声明返回 Object，可能整个是 undefined
const p = router.getParams() as ChatRouteParams;
this.sessionId = p.sessionId ?? '';     // p 为 undefined 时崩
```
`as` 只骗过编译期，不插入任何判空。触发场景：进程被系统回收后从恢复栈重建页面，
此时 `params` 会丢。改法：`p?.sessionId ?? ''`，并且拿不到 sessionId 时主动退回列表页。

**2. `GroupChatPage.ets` 同一问题 + 下标访问**
```ts
const p = router.getParams() as Record<string, string>;
this.roomId = p['roomId'] ?? '';        // 更脆：还叠了个下标访问
```

### P1 白屏 / 功能失效（4 个）

**3. `AdaptiveGrid` 硬编码 9 格 → 长列表第 10 条起完全不渲染**（本轮最严重）
```ts
// 改前（view/Responsive.ets）
ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8], (_i: number) => { ... })
```
`AdaptiveGrid` 被 5 个页面（Skills / Plugins / Mcp / Memory / Files）当作列表容器用，
但数据源写死 9 格 —— 任何超过 9 条的列表，**第 10 条开始看不见也点不到，界面无任何提示**。
用户只会以为数据丢了。

改法：加 `count` 入参，`range()` 按 `max(9, count)` 生成；5 个调用点补
`count: this.xxx.length`。

**4. `RoomAgentRepo.upsert` 把 `agent.id` 写进了 `room_id` 列**
```ts
`INSERT OR REPLACE INTO gc_room_agents (id, room_id, ...) VALUES (?,?,...)`,
[ agent.id, agent.id, agent.agentId, ... ]   // ← 第2位应是房间 id
```
`RoomAgent` 当时根本没有 `roomId` 字段，调用方也无从传。结果所有行的
`room_id` 都等于自身 `id`，而查询是 `WHERE room_id = ?` →
**群聊里加的 Agent 存进去就永远查不出来** → @ 提及解析不出候选 →
`validateGroupMessage` 报「需要 @ 至少一个 Agent」→ **群聊功能整体不可用，且无任何报错**。

改法：`RoomAgent` 加必填 `roomId`；`upsert` 第 2 个参数改传 `agent.roomId`；
`toAgent` 映射补 `room_id`；`StudioApi.toRoomAgent` 补 `roomId`。
（改成必填后编译器立刻揪出了 `StudioApi` 里漏改的那处 —— 这就是让它必填的价值。）

**5. `Orchestrator` 等待竞态 → 群聊永久卡死**
```ts
// 改前
const handle = await LlmEngine.run(llmReq, msgId, sink);
AgentOrchestrator.running.set(ctxKey, handle);
await AgentOrchestrator.waitFor(ctxKey);      // 注册太晚
```
`LlmEngine.run()` 在参数非法（如 API Key 未填）时会**同步**回调 `sink(run.failed)`
→ `finalize()` 去找 waiter，而 waiter 还没注册 → resolve 被丢弃 →
`waitFor` 永远等不到 → 队列项卡在 `running`，该房间后续所有消息全部堵死，
只能等 10 分钟兜底超时。

改法：先注册 waiter 再发起 run；`finalize` 在 waiter 未注册时打 `finished` 标记，
让随后到来的 `waitFor` 立即返回；`try/finally` 保证句柄清理；
正常完成时 `clearTimeout` 掉兜底定时器（原来每次成功回复都残留一个 10 分钟的定时器）。

**6. `AppStore.wipeAll` 往字符串键里塞数组**
```ts
AppStorage.setOrCreate<SessionSummary[]>(K.ACTIVE_SESSION, empty);  // 该键是 string
```
`activeSessionId` 在 `EntryAbility` 是按 `string` 初始化的，这里塞数组造成
AppStorage 同键混装类型，订阅方拿到的值随订阅时序漂移。改法：重置为 `''`。

### P2 边界缺陷（6 个）

**7. `JobsPage` 编辑任务会清空运行历史**
`upsert` 是 `INSERT OR REPLACE`（整行覆盖），而 `save()` 硬编码
`lastRunAt: 0, lastStatus: '', createdAt: nowTs` —— 编辑任意字段后，
「上次运行时间 / 执行状态 / 创建时间」全部丢失。改法：`findJob()` 取回旧值一并写回。

**8. `JobsPage` 病态 cron 阻塞 UI 线程**
```ts
// 改前，在 build 里：
Text(`合法 · 下次 ${relativeTime(nextCronRun(parseCron(this.fCron), Date.now()), ...)}`)
```
`nextCronRun` 对「一年内无命中」的 cron（如 `0 9 30 2 *` = 2 月 30 日）要逐分钟
扫 **527040 次**。放在 build 里，输入框每敲一个字符就重算一次 → sheet 卡死。
改法：移到 `revalidateCron()` 算一次并缓存文案。

**9. `JobsPage` cron 非法但"启用"时永不执行，且提示错误**
`nextCronRun` 无命中返回 0，而 `JobRepo.due` 的 SQL 条件是 `next_run_at > 0`
—— 任务会被标记为「已启用」却永远不跑；同时 toast 把这种情况误报成「未启用」。
改法：启用状态下 `next <= 0` 直接拒绝保存并说明原因。

**10. `ChatPage.patchLive` 可能把已生成的正文清空**
`finishRun` 把 `this.live` 重置为 `emptyStream()` 后，若还有尾部 `dataReceive`
帧进来，`patchLive` 会用空状态覆盖正文。改法：`patchLive` 开头加
`if (!this.streaming || this.liveBubbleId.length === 0) return;`，
并在 `finishRun` 末尾一并清 `liveBubbleId`。

**11. `FilesPage.truncated` 粘滞**
只在置 `true`，从不复位 —— 进过一次 >300 项的目录后再进小目录，
标题一直错报「只显示前 300 项」。改法：`loadDir` 开头复位。

**12. `canMentionAll` 恒为 undefined → `@all` 永久失效**
`gc_rooms` 表没有该列，`toRoom` 也不映射，所以 `resolveMentions` 里的
`if (a.canMentionAll)` 分支永远进不去，而界面有 `@all` 入口。
改法：v7 迁移加列（`DEFAULT 1`），`toRoom` 用 `num(r,'can_mention_all',1) !== 0` 映射。
> 注意这里不能用 `bool()`：它在列缺失时返回 false，会把 `@all` 又关掉。

### P3 隐患（4 个）

**13. `SessionListPage` / `GroupChatPage` 首屏重复查询**
`aboutToAppear` 与 `onPageShow` 都调初始化，而 ArkUI 首次进入两者都会执行。
`GroupChatPage` 首屏 `refreshMessages` 会跑 3 次（`loadRoom` 内部也调了）。
改法：加 `appeared` 标记，首屏跳过 `onPageShow` 的那次。

**14. `PluginsPage` 编辑插件把 `installedAt` 重置为当前时间**
改法：`findPlugin()` 取回旧值。

**15. `CodeBlock` 的 `setTimeout` 没有清理**
1.5 秒后回调打在可能已销毁的组件上。改法：存 timer id，`aboutToDisappear` 清理，
且连续点击时先清上一个。

**16. `Responsive.SplitPane` 的 `sidebarWidthVp` 是死字段**
全工程无人写入、无人读取，`@StorageProp` 却指向一个从未 `setOrCreate` 的键。
改法：删除。

---

## 二、测试与守卫

| 套件 | 项数 | 覆盖 |
|---|---|---|
| `run.ts` | 103 | 格式化、CJK 宽度、@提及解析、流式归约（11 类事件）、Markdown、SQL、JWT |
| `run_sse.ts` | 35 | SSE 边界、CRLF、**逐字节喂入**、多行 data、`[DONE]`、错误体 |
| `run_socket.ts` | 39 | Engine.IO 帧编解码、ack、PING/PONG、原版真实报文回放 |
| `run_ext.ts` | 101 | 响应式断点、Cron 解析/匹配、看板流转、**路径穿越防护** |
| `run_sqlguard.ts` | 33 | SQL 占位符↔实参配对 + **列↔实参位置断言** |
| `run_uiguard.ts` | 142 | **AdaptiveGrid 防退化** + 组件保留名冲突 |
| **合计** | **453** | 全绿 |

### 两个守卫都是「先验证能抓到 bug」才留下的

- `run_sqlguard.ts` 最初只检查**占位符数量 == 实参数**，
  但 `RoomAgentRepo.upsert` 的真实 bug 是**数量对、值错**（`agent.id` 传给了
  `room_id`），数量检查完全放过它。改成「断言某列对应的实参里出现正确字段名」后，
  注入原 bug 能被精确报出。
- `run_uiguard.ts` 的数据源提取最初用 `[^,]+`，会在数组字面量的第一个逗号处截断，
  导致「硬编码数组」这条检查失效。改成按括号深度找顶层逗号后，
  注入 `[0..8]` 能报出 2 项。

> 教训：守卫必须**注入原始 bug 验证它能报错**，否则只是一段看起来很像测试的装饰。

### 这轮修的缺陷里，编译器一个都抓不到

`AdaptiveGrid` 的 9 格、`upsert` 的列错位、`waitFor` 的竞态、
`wipeAll` 的类型污染 —— 全部编译通过、运行不抛异常，
只表现为「功能静默失效」。所以纯逻辑测试 + 静态守卫是必需的，不能只靠 `assembleHap`。

---

## 三、尚未验证的部分（诚实说明）

**真机运行未验证**：装机卡在签名，所以以下都没在真机上跑过 ——
- 首屏启动、页面跳转
- 流式对话的实际渲染效果
- 群聊 @ 提及的端到端链路
- PC 宽屏双栏与拖拽分栏
- 文件浏览的沙箱权限

这些需要签名后装机才能确认。目前的保证只到「编译通过 + 逻辑与静态守卫全绿」这一层。

**建议装机后优先验证的路径**（对应本轮修的缺陷）：
1. 群聊里添加 Agent → 杀掉应用重进 → Agent 是否还在（验证第 4 条）
2. 群聊 @ 一个 Agent 发消息 → 是否正常回复（验证第 5 条）
3. 建 10 个以上 Skills → 第 10 个是否可见（验证第 3 条）
4. 新建定时任务 → 编辑它 → 运行历史是否保留（验证第 7 条）
5. 手机旋转 / PC 拉窗口 → 布局是否跟随（验证响应式断点）
