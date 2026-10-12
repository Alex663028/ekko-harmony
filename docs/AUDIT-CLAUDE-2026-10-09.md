# Ekko Studio HarmonyOS 独立审计报告

- **审计人**：Claude（独立第三方 / 外部审查员视角）
- **日期**：2026-10-09
- **范围**：D:\EkkoStudioHarmonyOS 全项目（纯逻辑层 / 数据层 / 网络层 / 页面层 / 构建与配置）
- **方法**：逐文件通读全部 41 个 .ets 源码文件 + 构建配置 + 测试目录盘点；用 Grep 精确定位每个问题的行号；未修改任何源码。
- **分级**：P0（必须立即修复）/ P1（高危，建议尽快修复）/ P2（改进 / 维护性）

---

## 一、P0 —— 必须立即修复

### P0-1 build-profile.json5 明文签名口令入库

- **位置**：`build-profile.json5:35-49`
- **问题**：`signingConfigs` 中明文包含：
  - `certpath`（指向本机 `%USERPROFILE%\.ohos\config\*.cer` 的绝对路径）
  - `keyAlias`：`debugKey`
  - `keyPassword`：`0000…E157F121AA977630A85E8F47`（真实值已脱敏，完整口令见本地私有备份）
  - `storeFile`（`.p12` 完整路径）
  - `storePassword`：`0000…3B371E089EB51DA3A82B5BCC287`（真实值已脱敏）
- ⚠️ **本报告为公开仓库做了脱敏处理：真实签名口令已用 `…` 遮蔽，切勿在公开版本中还原。**
- 这些是 DevEco「自动签名」写入的**真实设备调试证书口令**，持有者即可用同一 `.p12` 冒充本项目签名。文件已被 git 跟踪（`git ls-files` 确认），一旦仓库外泄（哪怕私有仓库被误公开），等于泄露华为开发者账号的签名身份。
- 讽刺的是文件头注释第 19 行明确写着「⚠⚠ 签名材料不要入库（证书路径、密钥口令、.p12 文件名都等于泄露身份）」，但实际内容与注释自相矛盾。
- **改法**：
  1. 立即用 `git rm --cached build-profile.json5` 将其移出跟踪，并加入 `.gitignore`（`.p12/.p7b/.cer` 已在 ignore 列表，但 `build-profile.json5` 本身不在）。
  2. 在仓库中只保留**占位模板** `build-profile.json5.example`（字段留空 + 说明由 DevEco 自动填写），真实签名文件由开发者本地生成。
  3. 如果仓库已推送到远端，视为签名口令已泄露：到 AGC 后台**吊销并重新签发**该调试证书。
  4. 历史记录中该口令已存在，即使删除文件，git 历史仍保留明文——需要重写历史或接受并轮换证书。

---

## 二、P1 —— 高危

### P1-1 hvigor 关闭 ArkTS 类型检查 + code-linter 缺 ArkTS 规则集

- **位置**：`hvigor/hvigor-config.json5:9`（`"typeCheck": false`）；`code-linter.json5:14-31`
- **问题**：命令行构建时 ArkTS 类型检查被显式关闭；lint 规则集只有 `@performance/recommended` 与 `@typescript-eslint/recommended`，**没有启用 `@arkts/recommended`**。这意味着 `arkts-no-any`、`arkts-no-untyped-obj-literals`、`arkts-no-structural-typing` 等硬约束在 CI/命令行构建时**不会被拦截**，只有 DevEco IDE 内打开时才可能提示。项目大量代码是靠 IDE 手动约束才符合 ArkTS 规范，一旦有人提交违反约束的代码，构建不会失败。
- **改法**：
  1. 把 `"typeCheck"` 改为 `true`（先验证全项目能通过再开启；若短期做不到，至少开 `"analyze": "strict"`）。
  2. 在 `code-linter.json5` 的 `ruleSet` 中加入 `plugin:@arkts/recommended`（HarmonyOS 官方 ArkTS 规则集）。
  3. 本地验证：`hvigorw assembleHap` 在命令行跑一遍，确保 typeCheck 开启后能过。

### P1-2 SocketClient connect() 失败时 bridge 未关闭（连接泄漏）

- **位置**：`entry/src/main/ets/net/SocketClient.ets:674-679`
- **问题**：`connect()` 的 catch 块只做了 `log + onStatus('error') + return false`，**没有关闭已创建的 `bridge`**。失败路径上 `this.bridge` 仍指向一个可能半开的 WebSocket 对象，占用系统资源；后续再次调用 connect() 时旧 bridge 的 `on('close')/on('error')` 回调仍挂在新 bridge 上方的旧对象上，可能产生脏回调。
- **改法**：在 catch 中补：
  ```ts
  try { await bridge.close(); } catch (x) { /* ignore */ }
  this.bridge = null;
  ```
  然后再 return false。

### P1-3 JWT 放在 URL query 中（TerminalClient / SocketClient）

- **位置**：
  - `entry/src/main/ets/net/TerminalClient.ets:449`：`${wsPart}/api/hermes/terminal?token=${encodeURIComponent(token)}`
  - `entry/src/main/ets/net/SocketClient.ets:477`：`&token=${encodeURIComponent(token)}`
- **问题**：登录 JWT 被拼在 WebSocket URL 的 query 参数里。URL 会出现在代理日志、访问日志、抓包工具、历史记录中；`maskToken`（TerminalClient.ets:436-443）只掩盖了日志显示，掩盖不了传输路径上的泄露。虽然 `SocketClient.ets:476` 注释说「令牌通过 auth 传递（socket.io 的 auth 字段），拼在 query 里服务端不认」，但既然服务端不认 query 里的 token，就**完全没有必要**把它拼上去。
- **改法**：
  1. SocketClient：删除 query 里的 `token=`，只走 socket.io auth 帧（服务端实测已支持，见注释 661-672 行）。
  2. TerminalClient：若服务端必须从 query 取 token，则改为连接建立后通过协议帧发送；若无法改服务端，至少把 token 换成短期一次性票据（如 30s 有效期的短时 token），降低泄露面。

### P1-4 AppStore.currentUser() 硬编码 super_admin

- **位置**：`entry/src/main/ets/viewmodel/AppStore.ets:192-201`
- **问题**：`currentUser()` 无条件返回 `id: 1`、`role: 'super_admin'`、`status: 'active'`，完全忽略服务端实际返回的用户信息。任何依赖该角色的权限判断（如设置页、管理功能）都会认为当前用户是超管，即使实际登录的是普通账号。
- **改法**：
  1. 登录成功后从 `StudioApi.authStatus()` / `/api/auth/me` 的响应中解析真实 `id` / `role` / `status`，缓存到 AppStorage。
  2. `currentUser()` 优先读缓存；缓存缺失时返回 `null` 或抛错，而不是伪造超管。

### P1-5 token 明文持久化到 preferences

- **位置**：`entry/src/main/ets/viewmodel/AppStore.ets:97-101, 137-143`
- **问题**：登录令牌明文写入 `preferences`（`K.TOKEN`），文件位于应用沙箱内。虽然沙箱有一定隔离，但 HarmonyOS 的 preferences 是明文存储，root 设备上可被直接读取；且 `_test` 里已有读取 preferences 的脚本（`mkprefs.py`），说明这块数据可被工具化访问。
- **改法**：使用系统 keystore（`@ohos.security.asset`）存储 token，或至少用设备级加密（如 `@kit.CryptoArchitectureKit` 的 AesGcm 加密后落盘，密钥存 keystore）。

### P1-6 Orchestrator.pump() 异常不触发 hooks.onError

- **位置**：`entry/src/main/ets/net/Orchestrator.ets:155-161`
- **问题**：`runOne()` 抛出的异常只被 catch 用来更新队列状态为 `failed`，**没有调用 `hooks.onError`**。UI 层订阅的 `onError` 钩子永远不会收到失败通知，用户在群聊页看到的只是「消息一直没回」，没有错误提示。
- **改法**：在 catch 中补 `AgentOrchestrator.hooks.onError?.(next.id, err.message)`（注意 hooks 是可选成员，需判空）。同时把该异常也通过 `LogRepo.error` 落库，便于排查。

### P1-7 Orchestrator.finalize() 未 await GroupMessageRepo.insert

- **位置**：`entry/src/main/ets/net/Orchestrator.ets:299`
- **问题**：`finalize()` 是同步函数，`GroupMessageRepo.insert(store, msg)` 没有 await（也无法 await，因为 finalize 是 `(): void`）。insert 是异步数据库操作，不等待意味着：
  1. 消息可能还没落库，UI 的 onComplete 回调已经触发，用户看到消息但退出页面重进后消息丢失。
  2. 如果 insert 失败，无任何错误处理。
- **改法**：把 `finalize` 改为 `async`，`await GroupMessageRepo.insert(...)`；或者把 insert 放在 `runOne` 中 await 后再调 hooks。注意 `sink` 回调里调用 finalize 的位置（Orchestrator.ets:206）需要相应改为 `void AgentOrchestrator.finalize(...)` 或 `finalize(...).catch(...)`。

### P1-8 群聊上下文无限增长，无 token 截断

- **位置**：`entry/src/main/ets/net/Orchestrator.ets:307-308, 341-358`
- **问题**：每次回复后 `ctx.push({role:'assistant', content: state.text})`，上下文只在首次进房时用 `page(store, roomId, 20)` 限制为 20 条，但**此后每次对话都会无限追加**。长对话（几十轮）后上下文长度超出模型窗口，调用 LLM API 会直接报 400（context length exceeded），且每次请求 token 费用随上下文线性增长。
- **改法**：
  1. 在 `ctx.push` 前检查总 token 数（可用近似估算：中文字符数 × 1.5，英文 × 0.3），超过阈值（如 24k tokens）时丢弃最早的消息，只保留最近的 N 条。
  2. 或在 `buildInitialContext` 处限制为最近的 20 条，并在每次 push 后 `if (ctx.length > MAX_CTX) ctx.shift()`。

### P1-9 LlmEngine abort 后 300s 超时定时器未清除

- **位置**：`entry/src/main/ets/net/LlmEngine.ets:315-329（runOpenAI）, 447-461（runAnthropic）`
- **问题**：`newHandle()` 的 abort 回调中直接 `finished = true` 并 destroy client，但**没有调用 `clearGuard()`**。abort 后 300 秒，`timeoutId` 定时器仍会触发 `failWith('模型请求超时（300s），已中止')`。虽然 `failWith` 开头有 `if (finished) return` 保护不会重复发事件，但**定时器仍悬挂 300 秒**，浪费资源；且若用户连续 abort 多次，会积累多个悬挂定时器。
- **改法**：在 abort 回调开头调用 `clearGuard()`：
  ```ts
  const handle = newHandle((): void => {
    if (finished) return;
    finished = true;
    clearGuard();          // ← 补上
    LlmEngine.inflight.delete(runId);
    ...
  });
  ```

### P1-10 AgentManagerPage 将 API Key 明文 POST 到 PC

- **位置**：`entry/src/main/ets/pages/AgentManagerPage.ets:125-127`
- **问题**：服务端模式下保存供应商时，把 `p.apiKey` 明文随 `createRemoteProvider` 请求发送到 PC 服务端。API Key 是最高敏感度的凭据，明文 POST 意味着：
  1. 传输中可被中间人截获（虽然走 HTTPS，但服务端可记录）。
  2. PC 服务端可能把它写进日志或数据库。
- **改法**：
  1. 若 PC 端已有该供应商的 key（服务端模式本来就不需要手机端配 key，见 `Repos.ets:1044-1046` 的占位 Provider 逻辑），**不要在手机端重复上传**；创建远程供应商时省略 apiKey 字段，服务端复用已存配置。
  2. 若必须上传，至少提示用户「API Key 将保存在电脑上」，并优先使用已存在的 key（key 为空时传占位符让服务端保留旧值）。

---

## 三、P2 —— 改进 / 维护性

### P2-1 LogsPage renderCost 恒为 0

- **位置**：`entry/src/main/ets/pages/LogsPage.ets:62-66`
- **问题**：`enterAt` 是字段初始化时（`private enterAt: number = Date.now()`）就设好的，而 `aboutToAppear` 里立刻算 `Date.now() - this.enterAt`，两者几乎同时，恒为 0ms 或极小值。「页面渲染耗时」指标无意义。
- **改法**：在 `aboutToAppear` 记录 `enterAt`，然后在 `onPageShow` 或首帧 `onAreaChange` 后再算；或者干脆删除该指标。

### P2-2 ProfilesPage pickActive 启发式可能显示错误激活项

- **位置**：`entry/src/main/ets/pages/ProfilesPage.ets:82-94`
- **问题**：服务端没有「查 active」的端点，`pickActive` 用「先找 `p.active`，再找 `name==='default'`，否则取第一个」的启发式。若 PC 上默认 profile 被改名，页面会显示错误的当前激活项，用户看到的状态与 PC 实际不一致。
- **改法**：在服务端暴露 `GET /api/hermes/profiles/active` 端点（或让 `listProfiles` 响应带 active 标记）；鸿蒙端收到后直接使用，删除启发式。

### P2-3 McpPage 卡片明文展示 env（可能含密钥）

- **位置**：`entry/src/main/ets/pages/McpPage.ets:531-537`
- **问题**：MCP 服务器的 `env` 是环境变量 JSON（可能含 `API_KEY` / `SECRET`），卡片上 `previewOf(m.env, 50)` 明文展示。虽然本机使用，但旁边有人时屏幕内容会泄露密钥。
- **改法**：预览时用正则掩蔽 `"key"\s*:\s*"..."` 中的值（保留前后几个字符）；或在卡片上仅显示 `env: {N 个变量}` 而不展示内容。

### P2-4 LogRepo / UsageRepo 的 INSERT OR REPLACE 语义错误

- **位置**：`entry/src/main/ets/data/ExtendRepos.ets:915`（`INSERT OR REPLACE INTO app_logs`）、`820`（`INSERT OR REPLACE INTO usage_records`）
- **问题**：两处插入的主键 `id` 都是 `newId(now)` 随机生成的。`INSERT OR REPLACE` 的语义是「主键冲突时先 DELETE 再 INSERT」。随机 id 冲突概率极低，但一旦冲突（极端情况或时钟回拨），会**删除已有日志/用量记录再插入新记录**，造成数据丢失。日志和用量应该是纯追加的，用 `INSERT` 即可。
- **改法**：两处都改为 `INSERT INTO ...`（不带 OR REPLACE）。

### P2-5 Database.ets 迁移失败吞掉原始错误

- **位置**：`entry/src/main/ets/data/Database.ets` 各迁移 catch（v1~v7，约 128-131、212-215、225-228、270-273、316-319、405-408、419-422、440-443 行）
- **问题**：所有 catch 都是 `store.rollBack(); throw new Error('迁移 vN 失败，已回滚');`，**原始异常被丢弃**。迁移失败时开发者看不到真正的 SQL 错误（表已存在？列类型不匹配？），只能看到泛化消息。
- **改法**：改为 `throw new Error('迁移 vN 失败，已回滚: ' + (e instanceof Error ? e.message : String(e)))`，或至少 `console.error` 原始错误后再抛。

### P2-6 build.sh 硬编码本机路径

- **位置**：`build.sh:24-28`
- **问题**：`DEVECO_SDK_HOME="G://DevEco Studio//sdk"`、`NODE_HOME="G://DevEco Studio//tools//node"`、`NODE="<本机个人工具链>/node.exe"` 全部硬编码当前机器的绝对路径。换机器或换 SDK 目录即失效，且 `<本机个人工具链>` 是个人工具链路径，不应出现在仓库脚本里。
- **改法**：改为从环境变量读取（`${DEVECO_SDK_HOME:-默认值}`），或提供 `local.properties` 式的本地配置覆盖；`NODE` 优先使用 `DEVECO_SDK_HOME/tools/node/node.exe`（DevEco 自带 node）。

### P2-7 Http.bodyToString 静默返回空串

- **位置**：`entry/src/main/ets/net/Http.ets:155-159`
- **问题**：`bodyToString` 对非 string 的 `result` 静默返回 `''`。调用方拿到空串后继续 `JSON.parse('')` 会抛异常，或把空串当正常数据使用——失败被静默吞掉，难以排查。
- **改法**：非 string 时返回带标记的错误提示（如 `'[非文本响应]'`），或让调用方显式处理该情况并记日志。

### P2-8 LlmEngine.complete() 用字符串替换关闭 stream + 失败静默

- **位置**：`entry/src/main/ets/net/LlmEngine.ets:546`（`.replace('"stream":true', '"stream":false')`）、`561-567`（catch 返回 `''`）
- **问题**：
  1. `JSON.stringify` 默认无空格，`"stream":true` 是精确匹配，但若未来 `newRequestBody` 里字段顺序/格式变化，replace 会失效——脆弱实现。
  2. `complete()` 任何异常都返回 `''`，调用方（标题生成、群聊摘要）会把「生成失败」当成「生成了空标题」，无提示无日志。
- **改法**：`buildChatBody` 增加 `stream: boolean` 参数；`complete()` 失败时写日志并返回可区分的错误（如 null 或抛错），由调用方决定降级行为。

### P2-9 StudioApi.toMessage 丢弃 blocks / usage / toolTrace / reasoning / error

- **位置**：`entry/src/main/ets/net/StudioApi.ets:610-620`
- **问题**：服务端单聊消息的 `MessagePayload` 除 content 外还带 `blocks`（富文本/工具调用）、`usage`、`toolTrace`、`reasoning`、`error` 等字段，`toMessage` 只保留 role/content/timestamp。结果是：UI 无法展示工具调用轨迹、token 用量、错误详情，信息被静默丢弃。
- **改法**：按需扩展 `ChatMessage` 模型（加 `usage?`、`error?`、`toolTrace?`、`reasoning?`），`toMessage` 逐字段搬运；至少先透传 `error` 让 UI 能显示「这次回复出错了」。

### P2-10 gcMessageToLocal 兜底返回 agentId 而非可读名字

- **位置**：`entry/src/main/ets/net/StudioApi.ets:2002-2003`
- **问题**：`agentNames` 实际是 agentId 列表；当 `senderName` 为空且 senderId 不在列表中时，兜底直接返回 `m.senderId`（形如 `muct8eaayw0yt1`），UI 会显示一串不可读的 id。
- **改法**：构造一个 `agentId → 可读名` 的映射传入；兜底时返回 `'Agent'` 或映射后的名字。

### P2-11 WorkspacePage「刷新」按钮用空 path 重新打开文件

- **位置**：`entry/src/main/ets/pages/WorkspacePage.ets:172`
- **问题**：刷新按钮调用 `openFile({ name: this.fileName, path: '' })`。若当前文件不在根目录（`rel` 为空时 path 传空串 → full 退化为 `fileName`），会读错路径导致刷新失败。
- **改法**：维护当前文件的 `rel` 目录，刷新时用 `{ name: this.fileName, path: this.currentDir }`。

### P2-12 MemoryPage pinLastAdded 并发反查可能错置顶

- **位置**：`entry/src/main/ets/pages/MemoryPage.ets:330-338`
- **问题**：`MemoryRepo.add` 不返回 id，`pinLastAdded` 用「同作用域 + 同类型 + 同内容 + 同创建时间」反查。极端并发下（同一毫秒两条相同内容），可能 pin 到错误记录。低风险但属于脆弱的反查设计。
- **改法**：`MemoryRepo.add` 改为返回新记录 id（SQLite `last_insert_rowid`），`pinLastAdded` 直接按 id 置顶。

### P2-13 SkillsPage 允许用户自选来源（local/bundled/server）

- **位置**：`entry/src/main/ets/pages/SkillsPage.ets:27, 170-197`
- **问题**：`SOURCES` 把 `bundled` / `server` 暴露给用户选择，容易误导（用户以为选了「内置」就会随包分发，实际只改了一个标签）。来源应是系统决定的属性，不是用户输入。
- **改法**：新建时来源固定为 `local`；编辑时仅展示 `sourceLabel` 文本，不允许修改来源。

### P2-14 _test 目录含个人敏感信息（本地）

- **位置**：`_test/pg.json`（包含真实手机号、邮箱账号等个人信息，此处已脱敏）、`_test/login.json`、`_test/profiles.json`、`_test/quicklogin.ps1`
- **问题**：这些文件包含真实用户数据（测试账号、手机号、登录凭据等）。已确认**被 `.gitignore` 忽略且未被 git 跟踪**（`git check-ignore` 命中、`git ls-files` 无记录），不会入库；但本地磁盘仍明文存在，若工作区被拷贝/共享会泄露。
- **改法**：清理这些一次性测试产物（或移入加密容器 / 从磁盘删除），保留的数据脱敏后再归档。

### P2-15 LoginPage DEBUG_QUICK_LOGIN 硬编码 true

- **位置**：`entry/src/main/ets/pages/LoginPage.ets:28, 346-349`
- **问题**：`const DEBUG_QUICK_LOGIN: boolean = true` 硬编码，release 构建也渲染「[调试] 一键登录本机」按钮。虽然按钮行为需 preferences 里配置的联调凭据配合（默认无凭据时点了也只是提示），但把调试开关编死在源码里不是好实践。
- **改法**：改为编译期宏（`@ohos.hilog` 的 `BuildProfile.DEBUG` 或 `process.env`），或从 preferences 读取开关；release 构建默认关闭。

---

## 四、正面案例（值得保持）

审计不是只挑毛病。以下设计质量高，建议作为项目规范延续：

1. **FilesPage 沙箱安全**（`FilesPage.ets`）：`safeJoin` 作为唯一路径出口，所有 fileIo 路径必须过 `isSafeRelativePath`；附件路径落在沙箱外直接拒绝。这是本项目安全设计的标杆。
2. **WorkspacePage 只读原则**（`WorkspacePage.ets`）：刻意不暴露服务端写端点，只读浏览远程工作区，降低误操作风险。
3. **TerminalPage 防双发**（`TerminalPage.ets:210-230`）：120ms 时间窗去重 + 补 `\r`，解决鸿蒙 `onSubmit` 同一点击触发两次的兼容问题。
4. **UsagePage 防除零**（`UsagePage.ets:32-44`）：`ratioWidth` 对 `!isFinite`、`total<=0` 全面防护，绝不返回 NaN。
5. **SocketClient 握手时序**（`SocketClient.ets:699-719`）：等 OPEN 8 秒超时也补发 CONNECT，处理了慢网络下握手失败的真实场景。
6. **JobsPage cron 校验**（`JobsPage.ets:83-101, 154-160`）：`nextCronRun` 对一年内无命中的 cron 要扫 527040 次，页面把结果缓存避免 build 卡死，并拒绝保存永远不会执行的任务。
7. **KanbanPage WIP 约束**（`KanbanPage.ets:133-147, 215`）：移动前用 `insertPosition` 检查，`shiftAfter` 正确处理索引偏移；服务端模式下跳过 `ensureDefaults` 防止假数据。
8. **队列泵设计**（`Orchestrator.ets:134-166`）：防重入锁 + 100 任务保护 + 条件认领，waitFor/waiter/finished 标记机制解决了同步失败死锁问题。
9. **Orchestrator 上下文角色修正**（`Orchestrator.ets:303-307`）：明确 assistant 角色写回，避免模型把「自己的回答」当成「用户新提问」。
10. **gitignore 治理**（`.gitignore:67-68`）：`/_test/` 整体忽略，测试脚本与敏感产物不入库。

---

## 五、修复优先级建议

| 优先级 | 项目 | 预估工作量 |
|---|---|---|
| 立即 | P0-1 移除 build-profile 签名口令并轮换证书 | 0.5 天 |
| 本周 | P1-1 开启 typeCheck + ArkTS lint | 0.5~1 天 |
| 本周 | P1-2 ~ P1-5（连接泄漏、token 泄露、伪造超管） | 1 天 |
| 本周 | P1-6 ~ P1-9（群聊失败提示、消息落库丢失、上下文无限增长、悬挂定时器） | 1~1.5 天 |
| 下周 | P1-10（API Key 上传） | 0.5 天 |
| 持续 | P2 各项 | 2~3 天 |

合计约 5~7 个工作日可完成全部 P0/P1。

---

*报告完。本报告仅审计，未修改任何源码。*