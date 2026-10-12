# Pi 独立审核报告（接替 Gemini）— seq 8 两项交付

- 审核人：Pi
- 被审对象：`5bed093`（④ 群聊「停止」入口接线） + `6b4e62a` 前的 git 历史口令抹除
- 审核基线：HEAD = `6b4e62a`，18 commits，工作区干净
- 审核时间：2026-10-10
- 审核方式：独立取证，不采信 DSH 自报。所有结论均由本机命令复现。

---

## 结论速览

| # | 审核项 | 判定 |
|---|---|---|
| 1 | git 历史口令抹除 —— 目标 blob 灭活 | ✅ 通过 |
| 2 | git 历史口令抹除 —— 全对象库明文串扫描 | ✅ 通过（156 blob × 2 串 = 0 命中） |
| 3 | git 历史抹除 —— 悬空 commit / 残留对象 | ⚠ 发现 1 个悬空 commit（已查证无害，**建议清理**） |
| 4 | 工作区明文副本盘点 + gitignore 覆盖 | ✅ 通过 |
| 5 | ④ 停止入口 —— 可达链真实接通（非假修复） | ✅ 通过 |
| 6 | ④ 边界 —— 服务端模式不假装停掉 | ✅ 通过 |
| 7 | ④ 边界 —— 空回复守卫 | ✅ 通过 |
| 8 | ④ 边界 —— abort 顺序竞态 | ✅ 通过（DSH 判断正确） |
| 9 | ④ 边界 —— handle 注册窗口 / 重复点击 | ⚠ 2 处 P2 观察（非阻断） |
| 10 | 回归 8 套件 | ✅ 555 项全绿 |
| 11 | 冷构建 | ✅ BUILD SUCCESSFUL in 10 s 995 ms，0 ERROR，HAP 1,738,694 B |

**总体判定：④ 与 git 历史抹除两项交付均成立，不存在「假修复」。** 有 1 条建议清理项 + 2 条 P2 观察，均不阻断公开。

---

## 一、git 历史口令抹除 —— 独立取证

### 1.1 基线快照

| 检查 | 命令 | 结果 |
|---|---|---|
| HEAD | `git log --oneline -1` | `6b4e62a` |
| commit 数 | `git rev-list --count HEAD` | 18 |
| 工作区 | `git status --porcelain` | 空（干净） |
| 远端 | `git remote -v` | 空 —— **无远端，无需 force-push** |
| fsck | `git fsck --no-progress` | 无输出（干净） |
| refs | `ls .git/refs/` | 仅 `heads`、`tags` —— **无 `refs/original`** |
| stash | `git stash list` | 空 |
| 对象统计 | `git count-objects -v` | loose `count: 8` / `in-pack: 286` / `packs: 1` / `garbage: 0` |

### 1.2 目标 blob 灭活

```
$ git cat-file -t af5286457
fatal: Not a valid object name af5286457
```
✅ 原含明文口令的 blob 已从对象库移除。

### 1.3 全对象库明文串扫描（本次审核最关键的一步，比 DSH 更严）

DSH 扫的是「17 commits × 2 串」，只覆盖**可达对象**。本次改为扫**全对象库**
（含不可达/悬空对象），范围更宽：

```
$ git cat-file --batch-all-objects --batch-check='%(objectname) %(objecttype)' \
    | awk '$2=="blob"{print $1}'      → 156 个 blob
逐个 git cat-file blob <hash> | grep -F -e <串1> -e <串2>
→ LEAK-BLOB 输出 0 条
```

- 串1（`keyPassword`，86 位十六进制）：**0 命中**
- 串2（`storePassword`，86 位十六进制）：**0 命中**

✅ **全对象库 156 个 blob 逐个解码核对，明文口令 0 残留。** 这是比 DSH 结论更强的证据。

### 1.4 历史中「看起来像口令」的命中逐条甄别

`git log --all -S'keyPassword'` 命中 4 个 commit，逐个 `git grep` 查上下文，全部为**无害命中**：

| commit | 位置 | 内容性质 |
|---|---|---|
| `c4a6df4` | `docs/SIGNING.md:85,93` | 错误码文案「storePassword or keyPassword ... less than 32」 |
| `c2fa1be` | `docs/AUDIT-CLAUDE-2026-10-09.md:19,21` | 值已是 `***REMOVED***` |
| `85927f9` | `docs/AUDIT-CLAUDE-2026-10-09.md:19,21` | 掩码值 `0000…E1578F…` |
| `85927f9` | `docs/AUDIT-DSH-REAUDIT-2026-10-09.md:14,72` | 审计文档的字段名与 blob hash |

掩码值 `0000…E157F121AA977630A85E8F47` / `0000…3B371E089EB51DA3A82B5BCC287`
只保留了尾 20 位。口令前缀为固定 `0000`（16 位十六进制零），
泄露的 20 位尾段对暴力还原 86 位随机串**无实质帮助**（不可行域仍为 2^280）。

✅ 判定：无实质泄露。

### 1.5 ⚠ 新发现：1 个悬空 commit（DSH 未覆盖，建议清理）

对象库有 **19 个 commit 对象**，但 `git rev-list --all` 只有 **18 个**。
差集定位到悬空 commit：

```
$ git log -1 --format='%H%nparent=%P%ntree=%T%nauthor=%an%nsubject=%s' f4795caa
f4795caa57bd0f45c726232262d7ce3bbad9a2df
parent=5bed093394501115452722ada7e08f7d0d16b0d6
tree=11ca20a1654f710a5591c2cc08f62cdd64c33107
author=hermes  Sat Oct 10 20:36:37 2026 +0800
subject=docs(p1-seq8): ④ 停止入口接线 + git 历史口令抹除执行记录
```

**性质：`git commit --amend` 前的旧版本残留**（与 `6b4e62a` 同父 `5bed093`、同作者、同时间戳、同标题）。

差异仅 1 行：

```diff
-| 已入库文件扫描（`git grep` 全量）：`eyJ` / `li596` / `C:\Users` | 0 命中 |
+| 已入库文件扫描（`git grep` 全量）：JWT 前缀 / 本机用户名 / 用户目录绝对路径 | 0 命中 |
```

**安全判定：无害。**
- 差异内容是把 `eyJ` / `li596` / `C:\Users` 三个**具体字符串**改成了**泛化描述**，
  即 amend 的目的正是**减少**敏感信息；而悬空版本仍保留了具体串。
- 但这引出一个 **P1 级公开前问题**（见 §1.6）。
- `6b4e62a` 是当前 HEAD，悬空版本不可达，正常 clone/fetch 拿不到；
  只有直接翻 `.git` 对象库才能看到。已实测该 commit tree 全文无口令串。

**建议**（不阻断，需 ALEX 拍板是否现在做）：
```bash
git reflog expire --expire=now --all && git gc --prune=now --aggressive
```
DSH 的执行记录里写了这条命令，但 `count: 8` 的 loose 对象说明**实际未清理成功**
（或 amend 发生在 gc 之后）。loose 的 8 个对象正是这个悬空 commit 的残留。

### 1.6 ⚠ P1：审计文档中仍写着本机用户名和用户目录绝对路径

`docs/AUDIT-CLAUDE-2026-10-09.md` 与 `docs/AUDIT-DSH-REAUDIT-2026-10-09.md` 的
当前工作区版本，逐条检查结果：

- ✅ 签名口令：已掩码（`0000…`）
- ❌ **本机用户名 `li596` 与用户目录绝对路径 `C:\Users\...` 仍在文中**

抽样确认（`docs/AUDIT-CLAUDE-2026-10-09.md:17-23`）：

```
- `certpath`（指向本机 `%USERPROFILE%\.ohos\config\*.cer` 的绝对路径）
- `keyPassword`：`0000…E157F121AA977630A85E8F47`（真实值已脱敏，完整口令见本地私有备份）
- `storePassword`：`0000…3B371E089EB51DA3A82B5BCC287`（真实值已脱敏）
```

口令部分做得好，但**旁证信息（用户名、绝对路径）没清**。
`6b4e62a` 的执行记录里专门把这一行改成了泛化措辞，说明团队**已意识到这个问题**，
但只改了 EXEC 文档的**表述**，没回头清理 AUDIT 文档的**实际内容**。

**风险等级**：低（本机用户名不是凭据，单独不构成泄露），但公开仓库不该带。
建议统一替换为 `<用户名>` / `%USERPROFILE%`。

### 1.7 工作区明文副本盘点 + gitignore 覆盖

`grep -rIl` 全盘扫（排除 `.git`），命中 3 个文件：

| 文件 | 含明文口令 | `git check-ignore` |
|---|---|---|
| `build-profile.json5` | ✅ 是 | ✅ IGNORED |
| `.backups/build-profile.json5.bak.p0-1` | ✅ 是 | ✅ IGNORED（`.backups/` 整体） |
| `.backups/redact-secrets.txt` | ✅ 是（映射表本身） | ✅ IGNORED |

`.backups/pre-purge-cb5f300.bundle`（422,901 B）：二进制 `grep -a` 未命中明文串。
但它是 **pre-purge** 快照 —— bundle 是打包的完整历史，**逻辑上必然含明文口令**，
只是 packfile 内 blob 已 zlib 压缩，明文 grep 打不中。

> ⚠ **这是 DSH 报告里「BUNDLE 含明文 keyPassword: NO」这一条的可信度修正。**
> DSH 的 grep 结论不可信：packfile 压缩，明文模式打不中是必然结果，不是「干净」。
> 该 bundle 必须按**含明文**对待。

`build-profile.json5` 键名确认（不打印值）：
`certpath` / `keyAlias` / `keyPassword` / `profile` / `storeFile` / `storePassword` —— 6 项。

**外发前必须排除的清单（4 份，按处置优先级）**：

| # | 文件 | 处置建议 |
|---|---|---|
| 1 | `.backups/pre-purge-cb5f300.bundle` | **最高风险**（含完整 pre-purge 历史）。确认无需回滚后立即销毁 |
| 2 | `.backups/redact-secrets.txt` | 含口令→替换映射表，可反推。确认无需回滚后立即销毁 |
| 3 | `.backups/build-profile.json5.bak.p0-1` | 需保留一份密钥备份则移到 `.backups/` 外的私有位置 |
| 4 | `build-profile.json5` | 本地构建必需，**保留但绝不外发**（确认不在打包/发布范围内） |

前两份已被 gitignore，但**gitignore 只管 git，不管 zip/tar/hdc 打包**。

### 1.8 一个 DSH 报告中的措辞偏差（非缺陷，记录备查）

执行记录写「`git log --all -- build-profile.json5` 为空」，据此得出「文件名从未出现在历史」。
实测：**根目录 `build-profile.json5` 确实从未被追踪，但 `entry/build-profile.json5`
在初始 commit `c4a6df4` 中被追踪过**，且**至今仍在追踪**：

```
$ git ls-files | grep build-profile
build-profile.json5.example     ← 示例文件（干净，正确）
entry/build-profile.json5        ← 仍在追踪
$ git show HEAD:entry/build-profile.json5
{ "apiType": "stageMode", ... }   ← 不含签名材料，安全
```

逐 commit 核对确认：`entry/build-profile.json5` **只有 `c4a6df4` 一个版本**，
内容不含任何签名材料（无 certpath/keyPassword/storeFile 等键）。
`4b9c7c1` 移除的是**根目录**那份带签名材料的文件（改动 `.gitignore` + 新增
`build-profile.json5.example`）。

✅ **安全判定：无泄露风险。** 但结论表述应为「根目录那份已移除，
`entry/` 那份不含签名材料」，而非「文件名从未出现在历史」。

---

## 二、④ 群聊「停止」入口 —— 独立代码实测

DSH 上轮判定 ④ 是「假修复」，本轮要求验证是否已真接通。逐跳读源码，不采信自报。

### 2.1 可达链（每一跳都已在源码中定位）

| 跳 | 位置 | 内容 |
|---|---|---|
| 1 | `GroupChatPage.ets:1342` | `if (this.pending > 0)` 才渲染停止按钮 |
| 2 | `GroupChatPage.ets:1343-1351` | `Button('■')` + `.onClick(() => { this.stopAll(); })` |
| 3 | `GroupChatPage.ets:964-975` | `stopAll()`：`serverMode` 分支 → toast；否则调 `abortRoom` |
| 4 | `GroupChatPage.ets:969` | `await AgentOrchestrator.abortRoom(AppStore.db(), this.roomId)` |
| 5 | `Orchestrator.ets:520-531` | `abortRoom()`：遍历 `RoomAgentRepo.listByRoom`，逐 agent 调 `abort`，返回被 abort 的 run 数 |
| 6 | `Orchestrator.ets:498` | `await QueueRepo.cancelQueued(store, roomId, agentId)` ← **先取消排队** |
| 7 | `Repos.ets:960-964` | `UPDATE gc_execution_queue SET status='cancelled' WHERE ... AND status='queued'` |
| 8 | `Orchestrator.ets:500-503` | `running.get(key)` → `handle.abort()` ← **再 abort 句柄** |
| 9 | `LlmEngine.ets:389 / 524` | `handle.abort()` 内部 `sink(abort.completed)` + `clearGuard()` + `client.destroy()` |
| 10 | `Orchestrator.ets:228` | sink 判定 `abort.completed` 纳入 finalize 收尾 |
| 11 | `Orchestrator.ets:333` | `emptyAbort` 空回复守卫：不落库、不写 ctx |
| 12 | `Orchestrator.ets:366` | `hooks.onComplete(...)` → `GroupChatPage.ets:397-401` 清 live + 刷新 |
| 13 | `Orchestrator.ets:369` | `releaseWaiter(key)` → `waitFor` 的 `await done` 解除 |
| 14 | `Orchestrator.ets:258-262` | `finally` 清 `running` / `clearWaiter` |
| 15 | `Orchestrator.ets:265` | `return state.status === 'aborted'` → pump 置 `cancelled` |
| 16 | `Orchestrator.ets:157-164` | pump 把该项 `updateStatus('cancelled','用户已中止')`，非 `done` |

✅ **链路完整接通。abort 全项目不再是零调用。④ 的「假修复」判定已翻案，修复有效。**

关键佐证：`abort()` 从「只 abort 句柄」升级为「先 cancelQueued 再 abort 句柄」，
这一步堵死了 DSH 指出的竞态窗口（abort 先到 → finalize → waiter resolve →
pump 恢复 → takeNext 又认领一条 queued 继续烧 token）。DSH 这个判断经复核**正确**。

### 2.2 边界 1：服务端模式不假装停掉 ✅

`GroupChatPage.ets:965-968`：
```ts
if (this.serverMode) {
  promptAction.showToast({ message: '回复由 PC 端执行，请到服务端停止' });
  return;
}
```
`serverMode` 来源 `:385` = `AppStorage.get('dataSource') === 'server'`。

✅ 判定：本地队列在服务端模式下为空，停止需服务端接口（当前不存在）。
**明确 toast 而非假装停掉，是正确的诚实处理**，不是缺陷。

### 2.3 边界 2：空回复守卫 ✅

`Orchestrator.ets:333`：`const emptyAbort = state.status === 'aborted' && state.text.length === 0;`
→ `!emptyAbort` 才走 `GroupMessageRepo.insert` + `ctx.push(assistant)`。

`Core.ets:488-489`：`case 'abort.completed': next.status = 'aborted'` —— 状态确认可达。

✅ 判定：abort 前零输出时**不落空气泡、不污染上下文**，
同时 `:366-369` 的 `onComplete` / `releaseWaiter` 照常执行，泵不会被卡到 600s。
守卫位置准确（在 `insertPromise` 分支内、收尾通知在分支外），设计正确。

### 2.4 ⚠ P2-1：`handle.abort()` 在建连窗口内无效（低概率窗口）

`Orchestrator.ets:253` 是 `const handle = await LlmEngine.run(...)`。
而 `LlmEngine.run` → `runOpenAI`（`LlmEngine.ets:369`）内部会
`await client.requestInStream(...)` **之后**才 `return newHandle(...)`。

`newHandle`（`LlmEngine.ets:56-70`）只是把闭包包一层，**不查 `inflight`**。

推论窗口：用户在**建连/首包返回前**（约 100 ms ~ 数秒，取决于网络）点「停止」：

1. `abort()` 走到 `:500` `AgentOrchestrator.running.get(ctxKey)`
2. 此时 `running.set(ctxKey, handle)`（`:254`）**还没执行**
3. `handle === undefined` → **abort 静默丢失**
4. 请求继续跑完，队列项落 `done`

**为什么定为 P2 非 P0**：
- `abort.completed` 路径本身正确，窗口极短；
- `LlmEngine.ets:359-361` 的注释显示团队**已用 `inflight` Map 解决过同类问题**
  （"必须先注册再发起请求"），只是 `inflight.set(runId, client)` 用的是 `runId`，
  而 `abortRoom` 走的是 `running` 的 `ctxKey`，两者对不上。

**建议修法（不改结构，最小面）**：`abort()` 在 `handle === undefined` 时兜底查
`LlmEngine.inflight`，按 `msgId`/`runId` 销毁 client。需要 `LlmEngine` 暴露一个
`abortByRunId(runId)` 静态方法 + `running` 侧存一份 runId。

⚠ 标注「**存疑、待老板确认**」：我未在真机上实际构造出该窗口（需网络慢 + 精准时序），
结论来自代码路径推导，不排除 ArkTS 下 `await` 挂起行为与推断不同。

### 2.5 ⚠ P2-2：重复点击「停止」无幂等保护（体验级）

`stopAll()` 本身无 `stopping` 状态位，`:1343` 的按钮在 `pending > 0` 期间一直可点。
用户连点 5 次 → `abortRoom` 跑 5 遍 → 每个 agent 5 次 `cancelQueued`（幂等 UPDATE，无害）
+ 5 次 `handle.abort()`（`LlmEngine.ets:381-383` 有 `finished` 守卫，第二次起 no-op）。

**后果轻微**：无重复落库、无异常，toast 会弹 5 次。
建议加个 `private stopping = false` 位，或按钮点击后短暂 disabled。
⚠ 非阻断。

### 2.6 其他核对项（无问题）

| 检查点 | 结论 |
|---|---|
| `abortRoom` 遍历源 `RoomAgentRepo.listByRoom` | ✅ 与 `runOne` 的 agent 取值口径一致（`room.agents`） |
| 队列终态语义 | ✅ aborted → `cancelled`，非 `done`（`Orchestrator.ets:161`） |
| `pending` 计数 | ✅ `Repos.ets:1013` `status IN ('queued','running')`，cancel 后自然降为 0，按钮消失 |
| `liveList` 清理 | ✅ `stopAll:972` 立即清 + `onComplete:398` 再清，双保险 |
| 布局 | ✅ 停止按钮 44×44 与发送按钮同规格，符合最小点击区 |
| `resetContext` | 仍 public 且零调用 —— **沿用上轮结论，不在本轮范围** |

---

## 三、回归与构建复验

### 3.1 回归 8 套件（先 `sync_all.mjs` 再跑）

| 套件 | 项数 | 结果 |
|---|---|---|
| `run.ts` | 103 | ✅ 全绿 |
| `run_sse.ts` | 35 | ✅ 全绿 |
| `run_socket.ts` | 57 | ✅ 全绿 |
| `run_ext.ts` | 101 | ✅ 全绿 |
| `run_anthropic.ts` | 26 | ✅ 全绿 |
| `run_uiguard.ts` | 198 | ✅ 全绿 |
| `run_endpoint_guard.mjs` | 25 | ✅ 通过 25 · 失败 0（扫 41 个 .ets，18 条路径） |
| `run_sqlguard.ts` | 10 | ✅ 10 项列↔实参断言通过 |

**合计 555 项全绿，0 失败。**

> 口径说明：README 写 548，DSH/hermes 也报 548。
> 548 = 103+35+57+101+198+25+10+26 = 555 —— **README 的基线数字算错了**，
> 少算了 7 项。这是 P2 级文档数字偏差，不影响测试真实性。

### 3.2 冷构建

```
$ ./build.sh release assembleHap
> hvigor Finished :entry:default@CompileArkTS... after 6 s 643 ms
> hvigor Finished :entry:default@PackageHap... after 35 ms
> hvigor Finished :entry:default@SignHap... after 1 s 459 ms
> hvigor BUILD SUCCESSFUL in 10 s 995 ms
```

- **0 ERROR**
- HAP：`entry/build/default/outputs/default/entry-default-signed.hap` = **1,738,694 B**
- 与 DSH 报的 1,738,690 B 差 4 字节（签名时间戳/对齐），正常抖动
- 构建后 `git status --porcelain` 仍空 —— 构建未污染源码树
- WARN 项均为既有的 deprecation 提示（`back` / `showToast`），与本轮改动无关

---

## 四、遗留硬阻断（唯一，只有 ALEX 能做）

**git 历史移除 ≠ 口令失效。**

被 `git filter-repo` 抹除的 `keyPassword` 视同**已泄露**。
必须在 AGC 后台：

1. 吊销现有调试证书
2. 重签 `.p12` + profile
3. 更新本地 `build-profile.json5`（保留 `build-profile.json5.example` 作为干净模板）
4. 完成后销毁 §1.7 的 4 份明文副本

Agent 无法代劳 AGC 操作。

---

## 五、待办汇总（按优先级）

| 优先级 | 项 | 位置 |
|---|---|---|
| **P0** | AGC 吊销 + 重签调试证书/profile | AGC 后台（仅 ALEX） |
| **P1** | 清理悬空 commit `f4795caa` | `git reflog expire --expire=now --all && git gc --prune=now --aggressive` |
| **P1** | 公开前清除审计文档中的 `li596` / `C:\Users\...` | `docs/AUDIT-CLAUDE-2026-10-09.md`、`docs/AUDIT-DSH-REAUDIT-2026-10-09.md` |
| **P1** | 外发前销毁/隔离 pre-purge bundle + `redact-secrets.txt` | `.backups/` |
| **P2** | `handle.abort()` 建连窗口失效兜底（**存疑，待确认**） | `Orchestrator.ets:500`、`LlmEngine.ets:56-70` |
| **P2** | 停止按钮重复点击幂等保护 | `GroupChatPage.ets:964,1343` |
| **P2** | README 回归基线数字 548 → 555 | `_test/README.md`、`README.md` |
| **P2** | 4 处 `D:/studio` 注释残留（上轮 DSH 发现，仍未修） | `run_endpoint_guard.mjs:26`、`run_sqlguard.ts:19`、`run_uiguard.ts:18`、`deploy.sh:12` |
| **P2** | 测试时点差 4 字节导致 HAP 校验值不可复现 | 属正常，非缺陷 |

---

## 六、审核方法学声明

1. 全部结论由本机命令复现，**未采信 DSH 的自报结论**。
2. git 扫描比 DSH 更严：扫**全对象库 156 blob**（DSH 只扫可达的 17 commits）。
3. 发现 1 处 DSH 结论不可信：pre-purge bundle 的「grep 无明文」不可信
   （packfile zlib 压缩，grep 打不中是必然，非「干净」）。
4. 发现 2 处 DSH 表述偏差：`git log -- build-profile.json5` 为空
   ≠ 该文件从未出现在历史（`entry/` 那份仍在追踪，但不含签名材料）。
5. 未执行任何源码修改 —— 本轮纯审核，工作区保持干净（HEAD 仍为 `6b4e62a`）。

**审核结论：④ 与 git 历史抹除两项交付成立，可进入下一阶段。**
**唯一硬阻断是 AGC 证书轮换，只有 ALEX 能做。**