# 客户视角审核报告 — DSH

- 项目：`D:\EkkoStudioHarmonyOS`（HarmonyOS / ArkTS）
- 审核人：DSH
- 日期：2026-10-09
- 基线：HEAD = `cff080e`，工作区干净
- 基线构建：`BUILD SUCCESSFUL in 38 s 77 ms`，exit code 0，0 ERROR
- 视角声明：跳出「开发者自检」心态，以**真实客户在手机上使用这个 App**的视角审核。
  判据是「客户会看到什么」，不是「代码是否优雅」。

## 结论摘要

| 级别 | 数量 | 说明 |
|---|---|---|
| P0 | 2 | 「清空全部会话」只删一半，群聊全留存 / 技能功能整个是假象，文案承诺生效实际从未注入 |
| P1 | 4 | 客户可亲手配出必然失败的模型配置 / 群聊失败气泡不收尾 / 刷新读错文件 / P1-4 修复无实际效果 |
| P2 | 5 | 中止语义不完整 / 群聊上下文角色错乱 / 清数据后页面缓存不失效 / P2-13 死代码与来源显示矛盾 / 技能页静默失败 |

**一句话结论**：构建质量过关（0 ERROR、typeCheck 已开），但**产品承诺与实际行为的差距**是当前最大风险。
两处 P0 都是「界面/文案说了什么」与「代码做了什么」直接矛盾 —— 这类问题编译器查不出、回归测试也测不出，
只有以客户视角实读代码才能发现。

---

## P0-1 「清空全部会话」只删了一半，群聊记录全部留存

**位置**：`viewmodel/AppStore.ets:485-491`、`pages/SettingsPage.ets:64-76`、`data/Repos.ets:368-385`

**现象**：
客户在「设置 → 数据 → 清空全部会话记录」，弹窗白纸黑字写着：

> 将删除所有单聊、群聊与消息记录。供应商与 Agent 配置会保留。此操作不可恢复。

客户点「清空」，App 弹出 Toast「已清空」。客户认为所有聊天记录都没了，放下手机。
第二天重新打开 App 进群聊，**之前的群聊消息、房间、Agent 成员全都在**，一条没少。

**证据**：
`AppStore.ets:485-491`
```ts
static async wipeAll(): Promise<void> {
  await SessionRepo.deleteAll(AppStore.db());
  AppStorage.setOrCreate<string>(K.ACTIVE_SESSION, '');
  AgentOrchestrator.setHooks(newEmptyHooks());
}
```
`Repos.ets:368-385` —— 只删了 6 张单聊相关表：
```ts
await store.executeSql('DELETE FROM messages');
await store.executeSql('DELETE FROM session_archives');
await store.executeSql('DELETE FROM session_shares');
await store.executeSql('DELETE FROM attachments');
await store.executeSql('DELETE FROM usage_records');
await store.executeSql('DELETE FROM sessions');
```
而 `data/Database.ets` 里建的表还有：
`gc_rooms`、`gc_room_agents`、`gc_messages`、`gc_execution_queue`、`kanban_cards`、`kanban_columns`。

**影响**：
这是本轮最严重的问题。理由有三条：
1. **文案明确承诺「群聊」，实际群聊一条没删** —— 客户会据此认为数据已清，是虚假安全感。
2. `gc_messages` 留存意味着隐私场景下「删除我的聊天记录」这个基本诉求没被满足。
3. `AgentOrchestrator.setHooks(newEmptyHooks())` 会把正在进行的群聊流式推送静默掐断，且没有提示。

**建议改法**：
- `wipeAll` 增删 `gc_messages` / `gc_room_agents` / `gc_rooms` / `gc_execution_queue`，与文案对齐；
- 若产品本意是「只清单聊」，则必须改文案为「将删除所有单聊记录（群聊保留）」，二选一，不能既不删也不改；
- `setHooks` 前先判断是否有 running 任务，有则提示客户。

---

## P0-2 技能功能整个是假象：页面承诺「启用后立刻生效」，实际从未注入

**位置**：`pages/SkillsPage.ets:345`、`pages/ChatPage.ets:700-714`、`net/Orchestrator.ets:412-434`

**现象**：
客户在「设置 → 扩展能力 → Skills 技能」新建了一个技能，写好指令正文，**启用**。
页面明确写着（`SkillsPage.ets:345`）：

> 技能的正文就是一段会追加到系统提示词后面的指令，不需要任何外部进程，**启用后立刻在对话中生效**。

客户回到聊天页，问一个必须靠这条技能指令才能答对的问题。**模型的回答完全没有受技能影响。**
客户反复开关技能、反复验证，结果永远一样。页面上「预览系统提示词」里能看到技能内容拼进去了，
但对话里就是不起作用 —— 客户会认为模型随机/失忆，而不是 App 有 bug。

**证据**：
`SkillsPage.ets:345` 的承诺文案（已引用）。
技能指令的**唯一**拼接点是 `composeSystemPrompt`（`SkillsPage.ets:64-81`），
而它的**唯一**调用点是 `SkillsPage.ets:242-244`：
```ts
/** 预览页底部展示的完整系统提示词：只统计启用项 */
private composedPrompt(): string {
  return composeSystemPrompt(this.skills);
}
```
—— 仅用于**页面预览**，纯 UI 展示。

真正构造发给模型的消息列表的地方 `ChatPage.ets:700-714`：
```ts
private buildContext(): LlmMessage[] {
  const ctx: LlmMessage[] = [];
  const sysPrompt = this.agent !== null ? this.agent.systemPrompt : '';
  if (sysPrompt.length > 0) {
    ctx.push(systemMsg(sysPrompt));      // ← 只拼 Agent 的人设提示词
  }
  const real = this.bubbles.filter(...);
  ...
}
```
**没有任何一行涉及 `SkillRepo` 或 `enabled` 技能。**

群聊侧同样如此 —— `Orchestrator.ets:412-434` 的 `buildInitialContext`：
```ts
if (agent.description.length > 0) {
  ctx.push({ role: 'system', content: `你是群聊中的成员「${agent.name}」。...` });
}
```
也只拼 agent 自身描述，不含技能。

**影响**：
比 P0-1 更具欺骗性：
1. **文案是明确的生效承诺**，不是模糊描述，客户据此做决策（配了技能以为有专业能力）；
2. **预览功能反而加重了误导** —— 客户看到「系统提示词里明明有我的技能」，更加确信已生效；
3. 整个技能子系统（表、Repo、启停、编辑、使用计数、UI）是**完整的空壳**，维护成本已付出但零客户价值；
4. `simulateUse()`（`SkillsPage.ets:246-256`）里那句注释「只做一次计数，模拟"这条技能在一次对话里被用到"」
   直接暴露了实现者知情未做 —— 计数是假的。

**建议改法**（需产品定夺优先级）：
- **方案 A（推荐）**：在 `ChatPage.buildContext()` 与 `Orchestrator.buildInitialContext()` 中，
  读取 `SkillRepo.listEnabled(store)`，把启用技能的 `instructions` 拼到 agent systemPrompt 之后；
  此时 `composeSystemPrompt` 从「预览专用」升格为「唯一事实源」，预览与实际自动一致；
- **方案 B（更快，先止血）**：若短期不实现注入，则必须把 `SkillsPage.ets:345` 与 `:290` 的
  「启用后立刻在对话中生效」改为「当前版本仅保存配置，尚未接入对话」，并隐藏预览入口。

⚠ 无论选哪个，`composeSystemPrompt` 的重复实现（预览一处、实际零处）必须收敛，
否则修 A 时极易出现「预览拼了但实际没拼」的第二轮不一致。

---

## P1-1 客户能在界面上选到 3 种必然调用失败的接口模式

**位置**：`net/LlmEngine.ets:155-161`、`pages/AgentManagerPage.ets:16-21`、`model/Types.ets:230`

**现象**：
客户打开「设置 → 模型 → 供应商与 Agent → 新建供应商」，界面上的「接口模式」下拉有 4 个选项：

```
OpenAI 兼容 / OpenAI Responses / Anthropic / Gemini
```

客户是照着某篇教程填的，选了「Gemini」，填上 Gemini 的 key 和地址，保存成功，**没有任何报错**。
回到聊天页发消息，模型请求必然失败。客户看到的是一个「我明明按教程配了但就是不通」的死局，且 App 没告诉他这个模式其实没实现。

**证据**：
`AgentManagerPage.ets:16-21` —— UI 提供了全部 4 个选项：
```ts
const API_MODES: string[] = [
  'OpenAI 兼容', 'OpenAI Responses', 'Anthropic', 'Gemini'
];
```
`Types.ets:230` —— 类型也声明了 5 个值：
```ts
export type ProviderApiMode = 'chat_completions' | 'responses' | 'anthropic' | 'gemini' | 'openai_responses';
```
但 `LlmEngine.ets:155-161` 只实现了 2 个：
```ts
private static buildUrl(p: Provider): string {
  const base = p.baseUrl.replace(/\/+$/, '');
  if (p.apiMode === 'anthropic') {
    return base.endsWith('/v1/messages') ? base : `${base}/v1/messages`;
  }
  return base.endsWith('/chat/completions') ? base : `${base}/chat/completions`;
}
```
`responses` / `openai_responses` / `gemini` 全部落进 else 分支，被拼成 `/chat/completions`，
请求体也是 chat 格式（`buildChatBody`），这三档配置了必然 404 或 400。

**影响**：
UI 承诺了后端没实现的能力。客户能亲手制造一个必然失败的配置，且**没有任何提示告诉他这是无效选项**。
这不是「少一个功能」，是「界面撒了谎」。

**建议改法**（择一，需产品定夺）：
- 方案 A（推荐，最快且零风险）：`AgentManagerPage` 的 `API_MODES` 暂时只保留已实现的 `['OpenAI 兼容', 'Anthropic']`，其余两项标注「暂未支持」并禁用；
- 方案 B：补齐 `responses` / `gemini` 的 buildUrl 与 buildBody 分支（工作量较大）。

**注意**：此条为上一轮我已报告过的缺陷，本轮**仍未修复**。

---

## P1-2 群聊失败时，客户的流式气泡永远转圈不收尾

**位置**：`net/Orchestrator.ets:163-167`、`pages/GroupChatPage.ets:402-406`

**现象**：
客户在群聊里 @某个 Agent，Agent 回复到一半报错（比如供应商 key 被删了）。
客户看到的是：气泡里的文字停住了，但**转圈动画一直不停**，同时右上角弹出一个 Toast 显示错误。
客户既不知道这些半截文字最终是什么，也不知道该不该重发，只能退出重进页面。

**证据**：
`Orchestrator.ets:163-167` —— P1-6 补的 onError 传的是**队列项 id**：
```ts
if (AgentOrchestrator.hooks.onError !== undefined) {
  AgentOrchestrator.hooks.onError(next.id, msg);   // ← next.id 是队列任务 id
}
```
而 `GroupChatPage.ets:402-406` 的消费方把它当 **messageId** 用：
```ts
hooks.onError = (messageId: string, error: string): void => {
  this.removeLive(messageId);
  promptAction.showToast({ message: error });
  this.refreshMessages();
};
```
`liveList` 里的 key 是 `runOne` 里生成的 `msgId`（`Orchestrator.ets:209`），与队列 id 无关，
所以 `removeLive(messageId)` 匹配不到任何条目，气泡永远留在 `liveList` 里转圈。

**影响**：
P1-6 的修复本意是「让用户看到失败」，但失败提示到位了、气泡没收尾，反而制造了一个新的客户困扰。
且半截消息会被 `finalize` 落库吗？—— 不会，`run.failed` 只走 onError 不走 finalize，
所以客户看到的半截文字**刷新后会消失**，等于白看。

**建议改法**：
- `OrchestratorHooks.onError` 签名补上真实 messageId，或在 `runOne` 内捕获失败、调用 `hooks.onError(msgId, msg)`；
- 队列项 id 与消息 id 是两个概念，不要混用同一个参数。

---

## P1-3 工作区「刷新」读到的是文件夹，不是客户正在看的文件

**位置**：`pages/WorkspacePage.ets:165-175`

**现象**：
客户在「设置 → 电脑工作区」里点开一个文件（假设是 `src/main.ts`），看到内容。
客户发现内容不全或想刷新一下，点右上角「刷新」。
App 重新请求后，屏幕上显示的**变成了文件夹 `src` 的内容（或报错）**，客户的文件预览没了。

**证据**：
`WorkspacePage.ets:165-175`
```ts
if (this.previewing) {
  Text('刷新')
    .fontSize(12).fontColor(Tok.brand).width(30)
    .textAlign(TextAlign.End)
    .onClick(() => {
      // P2-11：刷新用当前目录 rel，不能传空 path ——
      // 否则文件不在根目录时 full 退化为 fileName，读错路径导致刷新失败。
      this.openFile({ name: this.fileName, path: this.rel });   // ← path 传的是目录
    })
}
```
`openFile` 的 `full` 取 `f.path` 优先：
```ts
const full: string = f.path.length > 0 ? f.path
  : (this.rel.length > 0 ? `${this.rel}/${f.name}` : f.name);
```
`this.rel` 是**当前目录**，不是文件路径。`StudioApi.readRemoteFile` 打的是
`/api/studio/files/read?path=<目录>`，读回来的根本不是客户在看的那份文件。

**影响**：
这是上一轮 P2-11 修复**引入的新缺陷**（把空 path 改成目录 path，修对了列表刷新，但预览刷新用错了变量）。
客户的原始诉求「刷新看最新内容」变成了「刷新看别的文件」，比不修更糟 —— 因为它显示了错误内容而不是报错。

**建议改法**：
预览态单独记住被打开文件的完整路径（`openedPath: string`），刷新时用它，而不是用目录 `rel`。

---

## P1-4 P1-4 修复在客户侧没有任何实际效果（假修复）

**位置**：`viewmodel/AppStore.ets:326-337`、`pages/SettingsPage.ets:20,100`

**现象**：
上一轮 P1-4 修复的声明是：「之前无条件返回 id=1 / super_admin，等于把任何登录者都当超管。现在读服务端 /api/auth/me 的真实缓存，不再伪造超管。」
但客户在 App 里**看不到任何变化** —— 因为全项目**没有任何一处调用 `currentUser()`**。

**证据**：
`AppStore.ets:326` 定义了 `currentUser()`，我在全项目 grep `currentUser` 的结果里，
**除定义本身和 `saveCurrentUser` / `restoreCurrentUser` 的内部实现外，零调用点**。
实际展示用户身份的地方走的是完全另一条链路：
```ts
// SettingsPage.ets:20,100
@StorageLink('userRole') userRole: string = '';
...
value: this.userName.length > 0 ? this.userName : '未登录'
```
`userRole` 由 `setUser(name, role)` 写入（`AppStore.ets:310-317`），登录时由 `LoginPage.ets:196` 用
`me.role` 填入 —— 这条链路本来就是真实的，`currentUser` 根本没参与。

**影响**：
P1-4 花了力气加了 preferences 持久化、keystore 清缓存、跨重启恢复（提交 `7b86552`），
但客户侧零感知。真正的问题是「两套用户状态并存且其中一套是死代码」，
后续维护者改 `currentUser()` 会以为改了权限逻辑，实际不生效 —— 这是**维护陷阱**。

**建议改法**：
二选一，明确一个唯一事实源：
- 删除 `currentUser()` 及其持久化链路，UI 统一走 `userName`/`userRole`；
- 或反过来，把 `SettingsPage` 等消费点切到 `currentUser()`。

**另注**：`onboarded`（`AppStore.ets:91-92`）同样是只写不读的死键，`K.ONBOARDED` 全项目零消费。

---

## P2-1 中止只停当前回复，队列里排队的任务照跑

**位置**：`net/Orchestrator.ets:436-443`、`data/Repos.ets:941-975`

**现象**：
客户在群聊里连着 @ 了 3 个 Agent，其中第一个回复很慢。客户等不及点了「中止」。
正在跑的那个停了 —— 但**队列里排着的另外 2 个仍然会依次执行**，继续消耗 token、继续在群里刷消息。
客户以为「中止 = 全停」，实际只停了当前这一个。

**证据**：
```ts
static abort(roomId: string, agentId: string): void {
  const key = AgentOrchestrator.contextKey(roomId, agentId);
  const handle = AgentOrchestrator.running.get(key);
  if (handle !== undefined) {
    handle.abort();     // ← 只碰 running 句柄，完全没碰队列
  }
}
```
队列表里 status 为 `queued` 的行不受影响，`pump` 的 for 循环会继续 `takeNext`。

**影响**：
客户无法真正停止一次不想要的群聊发言。而且中止后 `run.failed` 不会触发（abort 走的是
`abort.completed` 分支），所以客户连失败提示都拿不到，只看到消息继续冒出来。

**建议改法**：
`abort` 增加一个「取消本房间全部排队任务」的分支：把该房间 `status='queued'` 的行批量置为 `cancelled`，
`takeNext` 只捞 `queued`，自然就不会再执行。需在 `toQueueStatus` 里补 `cancelled` 枚举。

---

## P2-2 群聊上下文把「别人的回复」当成自己说的话

**位置**：`net/Orchestrator.ets:425-433`

**现象**：
客户在群聊里 @ 了 A 和 B。A 先回复，轮到 B 时，B 的上下文里只有用户消息和自己的历史回复。
这部分是对的。但客户如果中途**切走再切回**这个房间，`aboutToDisappear` 调了 `resetRoom` 清空上下文，
下次进入时 `buildInitialContext` 重建 —— 此时逻辑是：
```ts
for (const m of history) {
  if (m.senderKind === 'human') {
    ctx.push({ role: 'user', content: m.content });
  } else if (m.agentId === agent.agentId && m.role === 'assistant') {
    ctx.push({ role: 'assistant', content: m.content });
  }
}
```
这段本身是对的（已过滤），**但 `history` 用的是 `page(store, roomId, 20)` 最近 20 条**，
而客户重建上下文时最近 20 条很可能全是 A 和 B 的来回对话，用户原话已被挤出窗口 ——
B 收到的上下文变成了「user:（A的某句话）… user:（B的某句话）…」这样角色错乱的序列。

**影响**：
客户会看到 B 答非所问、复读 B 自己之前说过的话。属于长对话质量退化，不是一击致命但明显影响可用性。

**建议改法**：
`buildInitialContext` 取历史上限时，只取「用户消息 + 本 agent 回复」的合并序列，
不足 20 条时向更早的历史翻页补齐，而不是先取最近 20 条再过滤。

---

## P2-3 单聊页「清数据」后统计数字不归零

**位置**：`pages/SettingsPage.ets:32-39`、`viewmodel/AppStore.ets:485-491`

**现象**：
客户清空全部会话后，回到设置页，「会话总数」应显示 0。
但如果客户此时**不退出设置页**而是直接 `router.back()` 再进来，`refresh()` 会重新 count，正常显示 0。
**问题出在清理后 `liveList` / `pending` / 页面内缓存没有广播失效**：
客户若停留在群聊页时从设置页执行清空（切过去清空再切回群聊），
群聊页的 `aboutToAppear` 不一定重跑，客户会看到已被删除的房间和消息还在屏幕上。

**影响**：中等。客户会觉得「没删干净」，与 P0-1 叠加后观感更差。

**建议改法**：`wipeAll` 完成后发一个全局失效信号（如 `AppStorage` 写 `dataEpoch`），
各页 `aboutToAppear` 比对 epoch 变化则强制 reload。

---

## P2-4 P2-13 修复遗留死代码，且「来源」显示逻辑自相矛盾

**位置**：`pages/SkillsPage.ets:40-58,100,153,164,504`

**现象**：
上一轮 P2-13 决定「编辑/新建都固定来源为 local 且不可切换」，`saveSkill` 已硬编码 `source: 'local'`。
但表单状态 `fSource` 及配套的 `sourceAt()` / `sourceIndex()` 仍在，且 `editSkill` 仍会把
已有技能的来源读进 `fSource`。客户在服务端模式下编辑一个 `source='server'` 的技能时，
页面显示的来源标签来自 `sourceAt(this.fSource)`，与实际保存的值（恒为 local）**不一致**。

**证据**：
`SkillsPage.ets:504`
```ts
Text(sourceLabel(this.isNew ? 'local' : sourceAt(this.fSource)))
```
`SkillsPage.ets:164`
```ts
this.fSource = sourceIndex(s.source);   // ← 仍读旧值
```
`SkillsPage.ets:186-187`（保存时）
```ts
// P2-13：来源由系统决定，表单不再让用户选，恒为 local
source: 'local',
```
即：读的是旧来源、显示的是旧来源、**存的是 local**。

**影响**：P2 —— 客户看到「服务端」标签，但保存后数据来源已变。属于状态不一致，非阻断。
另外 `fSource` / `sourceAt` / `sourceIndex` 已无实际用途，是 P2-13 的清理遗漏。

**建议改法**：删除 `fSource` / `sourceAt` / `sourceIndex`，
`SkillsPage.ets:504` 直接写 `Text('本地')`；编辑时无需再读旧来源。

---

## P2-5 单聊页 loading/空态三态在服务端模式下退化

**位置**：`pages/ChatPage.ets:700-714`（上下文构造）、`pages/SkillsPage.ets:108-114`

**现象**：
`SkillsPage.reload()`：
```ts
try {
  this.skills = await RemoteView.skills(AppStore.db());
} catch (e) {
  this.skills = [];      // ← 失败与「真的没有技能」表现完全一致
}
```
客户在服务端模式下、技能列表拉取失败时（断网/PC 关了），页面显示「还没有技能」空态，
客户会去新建技能，而真实原因是他连不上电脑。**没有任何错误提示。**

**影响**：P2 —— 误导客户做无用操作。与 P2-4 一样属于「静默失败」类。

**建议改法**：`catch` 里设一个 `errorText` 状态，build 时优先展示错误态，与空态区分。

---

## 已核查但未发现问题

以下方向我实际读过代码，确认当前无客户可感知缺陷，记录以免后续重复排查：

- **登录链路完整性**（`LoginPage.ets` 全文 373 行）：本地/服务端双模式、providerId 精确匹配、
  key 落到正确供应商、错误提示文案、调试按钮 release 态隐藏 —— 均正确。
- **令牌存储**（`AppStore.ets:157-243`）：keystore 存取 + 明文兜底 + 失败告警，逻辑闭环。
- **首次启动 AppStorage 预建**（`EntryAbility.ets:19-35`）：所有 `@StorageLink` 键都已预建，
  不存在 ArkUI 退化成 undefined 的问题。
- **上下文截断**（`Orchestrator.ets:369-409`）：50 条 / 24k token 双阈值，保留 system 角色，实现正确。
- **队列原子认领**（`Repos.ets:941-975`）：SELECT + 条件 UPDATE 双保险，不会重复执行。
- **`wipeAll` 单聊部分**（`Repos.ets:368-385`）：6 张表在同一事务内，单聊确实清干净了（问题在群聊没清）。
- **构建基线**：冷构建 `BUILD SUCCESSFUL in 38 s 77 ms`，0 ERROR。

---

## 修复优先级建议

| 顺序 | 项 | 理由 |
|---|---|---|
| 1 | P0-1 | 唯一涉及数据承诺失真的问题，且改法明确 |
| 2 | P1-1 | 客户可亲手触发，且 UI 撒谎；方案 A 改动极小 |
| 3 | P1-2 | 参数错用导致新缺陷，越晚修越多客户遇到 |
| 4 | P1-3 | 上一轮修复引入的新缺陷，显示错误内容比报错更危险 |
| 5 | P1-4 | 需产品定夺事实源，可与上述并行 |
| 6 | P2-1 | 需补 `cancelled` 枚举，改动中等 |
| 7 | P2-2 / P2-3 | 质量退化类，可排后 |