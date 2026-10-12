# EXEC-SEQ11：修两条 P2 + 销毁明文副本（2026-10-10）

> 触发：ALEX 指令「除了 AGC 外，其他都修复掉」。
> 上游：Pi 独立审核（`docs/AUDIT-PI-SEQ8-INDEPENDENT-2026-10-10.md`）提出的 2 条 P2
> + DSH 复核确认的 3 份明文副本待销毁。
> 父提交：`436117f`。执行：Pi。审核：DSH（待）。

---

## 一、本轮做了什么

| # | 项 | 来源 | 处置 |
|---|---|---|---|
| A | 建连窗口 abort 静默丢失 | Pi 审核 P2-1 | **已修**（代码 + 8 条守卫） |
| B | 停止按钮无幂等保护 | Pi 审核 P2-2 | **已修**（代码 + 3 条守卫） |
| C | 3 份明文副本待销毁 | DSH 复核第 1 条 | **已销毁**（覆写 0 + 删除） |

**未做**：AGC 证书吊销重签。只有 ALEX 能做，仍是唯一硬阻断。

---

## 二、P2-A：建连窗口 abort 被静默丢弃

### 2.1 缺陷

`LlmRunHandle` 是 `await client.requestInStream(...)` **返回之后**才交给调用方的，
而请求要等整段流结束（`readTimeout=300s`）才 resolve；建连本身最长也有
`connectTimeout=20s`。

这段窗口里 `AgentOrchestrator.running` 是**空的** → `abort()` 查不到句柄 →
abort 无声丢弃 → 用户点了「停止」，请求还在跑，token 继续烧。

编译不报、单测全绿、跑起来也没有任何异常日志。**只有真在那个窗口点停止才会发现**。
Pi 复核时标「存疑、待老板确认」，ALEX 本轮授权修。

### 2.2 修法（两层，都必要）

**第一层 — `LlmEngine` 增加「句柄未到手时的中止入口」**

- 新增 `private static aborts = new Map<string, () => void>()`（runId → 收尾回调）
- 新增 `private static releaseSlot(runId)`：成对释放 `inflight` + `aborts`
- `abortRun(runId)` 改为优先查 `aborts`，命中即调（**而不是只 `destroy()`**）
  - 只 destroy 会让 `requestInStream` 抛错，落到 `failWith('连接模型服务失败')`
    → 上报 `run.failed` → 队列项落 `failed` 而不是 `cancelled`，且气泡显示成报错。
    走 `abortFn` 才是 `abort.completed`，与句柄路径**完全同源**。
- `runOpenAI` / `runAnthropic` 的 abort 收尾各自抽成具名 `abortFn` 闭包，
  在 `inflight.set` 之后、`requestInStream` 之前 `aborts.set(runId, abortFn)`，
  句柄返回时 `return newHandle(abortFn)` —— **两条路径共用同一份逻辑**。
- 所有终态（正常完成 / 失败 / abort）统一走 `releaseSlot`，不留裸 `inflight.delete`
  （否则 `aborts` 是只进不出的 static Map，内存泄漏）。
- `isRunning` 改为查两张表任一命中。

**第二层 — `Orchestrator` 在 `await run` 之前登记 runId**

- 新增 `private static activeRunIds = new Map<string, string>()`（ctxKey → runId）
- `runOne` 里 `await LlmEngine.run(...)` **之前** `activeRunIds.set(ctxKey, msgId)`，
  `finally` 里删除。
- `abort()` 在拿不到句柄时回落到 `LlmEngine.abortRun(activeRunIds.get(key))`。
- `abortRoom()` 的计数改为「句柄表 或 runId 表 命中即算在跑」，与实际停止数一致。

> 只有第一层不够：`abort()` 根本走不到 `abortRun`（先 `return` 掉了）。
> 只有第二层也不够：`abortRun` 原来只 `destroy()`，会误报 failed。
> 两层必须配套。

### 2.3 改动位置

| 文件 | 行 | 内容 |
|---|---|---|
| `entry/src/main/ets/net/LlmEngine.ets` | 137–183 | `aborts` 表 / `releaseSlot` / `abortRun` 重写 / `isRunning` |
| `entry/src/main/ets/net/LlmEngine.ets` | 343–378 | `runOpenAI` 抽 `abortFn`、两表成对释放 |
| `entry/src/main/ets/net/LlmEngine.ets` | 417–440 | `aborts.set` + `return newHandle(abortFn)` |
| `entry/src/main/ets/net/LlmEngine.ets` | 467–500 | `runAnthropic` 抽 `abortFn`、两表成对释放 |
| `entry/src/main/ets/net/LlmEngine.ets` | 559–581 | `aborts.set` + `return newHandle(abortFn)` |
| `entry/src/main/ets/net/Orchestrator.ets` | 57–65 | `activeRunIds` 表 |
| `entry/src/main/ets/net/Orchestrator.ets` | 263–276 | `await run` 前登记、`finally` 清理 |
| `entry/src/main/ets/net/Orchestrator.ets` | 508–530 | `abort()` 兜底 `abortRun` |
| `entry/src/main/ets/net/Orchestrator.ets` | 554 | `abortRoom()` 计数口径 |

---

## 三、P2-B：停止按钮无幂等保护

### 3.1 缺陷

`stopAll()` 没有重入门。连点 5 次 → 发起 5 次 `abortRoom`、弹 5 次 toast、
触发 5 轮 `refreshPending`。

abort 本身幂等（`finished` 守卫），所以**无功能副作用**，只是重复提示 —— P2 而非 P1。

### 3.2 修法

- `GroupChatPage.ets:349-356` 新增 `@State stopping: boolean = false`
- `stopAll()` 开头 `if (this.stopping) return;`，整段包 `try/finally`，
  `finally` 里复位（异常路径不复位会把按钮永久禁用）
- 按钮加 `.enabled(!this.stopping)`，停止中置灰（`Tok.text3`）

### 3.3 改动位置

| 文件 | 行 | 内容 |
|---|---|---|
| `entry/src/main/ets/pages/GroupChatPage.ets` | 349–356 | `stopping` 状态位 |
| `entry/src/main/ets/pages/GroupChatPage.ets` | 968–989 | `stopAll()` 重入门 + `try/finally` |
| `entry/src/main/ets/pages/GroupChatPage.ets` | 1345–1356 | 按钮置灰 + 禁用 |

---

## 四、防退化守卫（11 条）

按 `_test/README.md` 第三节「每条修复配一个可 grep 的锚点」的纪律，
在 `run_uiguard.ts` 补 11 条静态守卫（198 → **209**）：

- 中止链路 8 条：runId 表存在、`await run` 前登记、`finally` 清理、
  `abort()` 兜底 `abortRun`、`abortRun` 入口存在、`aborts.set` 早于 `requestInStream`
  且两条路径都有、两条路径共用 `abortFn`、无裸 `inflight.delete`
- 停止幂等 3 条：`stopping` 状态位、`stopAll` 重入门、`finally` 复位

**负样本验证**（守卫不是假绿灯）：

```
# 注入：删掉 activeRunIds.set + 把 stopping 判断改成 false
UI 防退化守卫：  通过 207 · 失败 2
  ✗ runId 在 await LlmEngine.run 之前登记
  ✗ stopAll 入口挡重复点击
# 还原后
UI 防退化守卫：  通过 209 · 失败 0
```

---

## 五、明文副本销毁

ALEX 本轮授权「其他都修复掉」，据此销毁 DSH 复核确认的 3 份：

| 文件 | 大小 | 处置 |
|---|---|---|
| `.backups/pre-purge-cb5f300.bundle` | 422,901 B | 覆写 0 + 删除 |
| `.backups/redact-secrets.txt` | 208 B | 覆写 0 + 删除 |
| `.backups/build-profile.json5.bak.p0-1` | 3,437 B | 覆写 0 + 删除 |

处置方式：先以只写模式打开、整块覆写为 0，再 `Remove-Item -Force`。
删后 `.backups` 全目录扫描 `bundle|secret|p12|p7b|csr|build-profile` → **0 命中**。

> 保留的两份（**不是副本，本机构建必需**）：
> - `D:\EkkoStudioHarmonyOS\build-profile.json5` — 含明文签名口令，gitignore 覆盖，删了签不了包
> - `D:\EkkoStudioHarmonyOS\entry\build-profile.json5` — 自初提交起追踪，仅 1 版，**不含签名材料**

### 销毁后对象库复核

```
git cat-file -t af5286457 → fatal: Not a valid object name   （旧 build-profile blob）
git cat-file -t 1bb21699 → fatal: Not a valid object name   （旧 AUDIT-CLAUDE blob）
git cat-file -t de5a88ed → fatal: Not a valid object name   （amend 前残留）
git fsck --unreachable    → 空
git fsck                  → 干净
对象库：163 blobs（可追溯者），无 secret-bearing blob 可达或悬空
```

---

## 六、验证结果

| 项 | 结果 |
|---|---|
| 冷构建 | `BUILD SUCCESSFUL in 9 s 974 ms`，**0 ERROR** |
| HAP | `entry-default-signed.hap` **1,737,419 B** |
| 回归 8 套件 | **566 项全绿**（103·35·57·101·26·209·10·25） |
| 守卫负样本 | 有效（注入后精确报出 2 条失败） |
| 源码改动 | 4 文件 +210/-50（其中 `run_uiguard.ts` +63） |
| 备份 | `.backups\seq11-p2-abort-20261010\{LlmEngine,Orchestrator,GroupChatPage}.ets.bak.seq11` |

**回归基线变化：555 → 566**（新增 11 条守卫），已同步
`README.md`（合计行 / `run_uiguard` 行 / 命令注释行）与 `_test/README.md`（基线行 / 命令注释行）。

---

## 七、仍然未闭环（只有 ALEX 能做）

**AGC 证书吊销 + 重签调试证书/profile，然后更新本地 `build-profile.json5`。**

git 历史移除 ≠ 口令失效。被抹除的 `keyPassword` 视同已泄露，必须在 AGC 后台吊销重签。
这一步任何 Agent 都代替不了。

外发打包时仍须排除本机的 `build-profile.json5`（含明文口令）。
.gitignore 只管 git，**不管 zip / hdc 打包**。