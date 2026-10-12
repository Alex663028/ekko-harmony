# P1-SEQ8 执行记录：④ 群聊「停止」入口 + git 历史口令抹除

- 执行人：DSH（受 ALEX 指令）
- 日期：2026-10-10
- 授权来源：ALEX 拍板 ④ 方案 (a)（补群聊停止按钮并接线）+ 明确授权 git 历史抹除
- 最终 HEAD：`5bed093`（父 `85927f9`）

---

## 一、④：群聊「停止」入口并接线（commit `cb5f300` → 抹除后 `5bed093`）

### 问题（DSH 复审发现，CLAUDE `c13e52a` 未处理）

`AgentOrchestrator.abort()` 全项目零调用；群聊页无「停止」控件，用户点不了；
`QueueRepo.cancelQueued` 与 `QueueStatus.cancelled` 虽已写入代码但**不可达**，属「假修复」。
症状：停止后队列里排着的任务照跑，继续烧 token。

### 改动（2 文件，+142/-46）

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/net/Orchestrator.ets` | `abort()`（:493）先 `QueueRepo.cancelQueued`（:498）再 `handle.abort()`（:502）；新增房间级 `abortRoom()`（:520-531）；sink 收尾条件补 `abort.completed`（:228）；空回复 `emptyAbort` 守卫（:335-337）避免中止时落空气泡 |
| `entry/src/main/ets/pages/GroupChatPage.ets` | 新增 `stopAll()`（:964-975）；输入区在有 queued/running 时渲染「停止」按钮（:1339-1350），点击调 `stopAll()` |

### 可达调用链（实测 grep，非自报）

```
GroupChatPage.ets:1350  this.stopAll()
  → GroupChatPage.ets:964 stopAll()
    → GroupChatPage.ets:969 AgentOrchestrator.abortRoom(AppStore.db(), this.roomId)
      → Orchestrator.ets:520 abortRoom()
        → Orchestrator.ets:528 AgentOrchestrator.abort(store, roomId, a.agentId)   // 遍历房间内全部 agent
          → Orchestrator.ets:498 await QueueRepo.cancelQueued(store, roomId, agentId)  // queued → cancelled
          → Orchestrator.ets:502 handle.abort()                                          // 中止在跑的 LlmRunHandle
            → LlmEngine 发 abort.completed
              → Orchestrator.ets:228 run.completed | run.failed | abort.completed → finalize → pump 释放
```

顺序不可颠倒：先 `handle.abort()` 会让 sink 立刻 finalize → waiter resolve → pump 恢复并 `takeNext`，
而 `cancelQueued` 尚未落库，泵有机会再认领一条继续烧 token。故先取消排队（:494-497 有注释固化）。

边界：仅**本地编排模式**有效。服务端模式下 agent 跑在 PC 上，本地队列为空，
`stopAll()` 明确 toast「回复由 PC 端执行，请到服务端停止」而非假装停掉（服务端停止接口当前不存在）。

---

## 二、git 历史口令抹除

### 问题

blob `af5286457`（源自初提交 `a5854e3`，文件为 `build-profile.json5`）含明文
`keyPassword` / `storePassword`（两条 86 位十六进制串，另有本机证书/profile 路径）。
`98c00f8` 只做了 `git rm --cached`，历史仍可 `git cat-file` 取回 —— **任何人 clone 即可拿到**。
另发现审计报告 `docs/AUDIT-CLAUDE-2026-10-09.md` 的历史版本（已由 `2ca55f9` 脱敏）也含该明文，
因此只抹 `build-profile.json5` 不够，必须按明文串做 `--replace-text` 全历史替换。

### 执行

```
# 1. 全量安全备份（不删，保留至证书轮换完成）
git bundle create .backups/pre-purge-cb5f300.bundle --all      # 422,901 B

# 2. 按明文串替换（.backups/redact-secrets.txt，86 位 hex → ***REMOVED***）
git filter-repo --replace-text .backups/redact-secrets.txt --force

# 3. 清理 reflog / 悬挂对象
git reflog expire --expire=now --all && git gc --prune=now --aggressive
```

- `git filter-repo` 版本：`a40bce548d2c`
- 替换文件 `.backups/redact-secrets.txt`（208 B，含明文 → **不得公开**）

### 抹除后核验（全部由 DSH 独立执行）

| 核验项 | 结果 |
|---|---|
| `git cat-file -t af5286457` | `fatal: Not a valid object name` —— 旧对象已不存在 |
| 明文串全历史扫描（`git grep -F <literal>` × 17 commits × 2 串） | **0 命中** |
| `git log --all -- build-profile.json5`（**仅根目录路径**） | 空。⚠ 更正：根目录那份从未被追踪 ≠ 该文件名不在历史中 —— `entry/build-profile.json5` 自初提交 `c4a6df4` 起一直被追踪（内容无签名材料），见文末 §六 |
| `git rev-list --all` 提交数 | 17（原 17，全数保留，仅重写 hash） |
| `.git/filter-repo/commit-map` | 17 条 old→new 映射齐全 |
| `.git/filter-repo/ref-map` | `cb5f300 → 5bed093  refs/heads/master` |
| `git for-each-ref refs/original` | 空 |
| `git stash list` | 空 |
| `git count-objects -v`（filter-repo 刚跑完那一刻） | `count: 0`、`in-pack: 286`、`packs: 1`、`garbage: 0`；⚠ 随后提交 `6b4e62a` 又产生 8 个 loose 对象 + 1 个悬挂 commit，见文末 §六 |
| `git fsck --no-progress` | 无输出（干净） |
| `git remote -v` | 空 —— **无远端，无需 force-push** |
| 已入库文件扫描（`git grep` 全量）：JWT 前缀 / 本机用户名 / 用户目录绝对路径 | 0 命中 |

`suboptimal-issues` 仅一条误报：某 commit message 引用的字符串被识别为哈希 `b'20261007'`（实为日期），无实际影响。

### hash 变更对照（团队引用需同步换）

| 旧 hash | 新 hash | 说明 |
|---|---|---|
| `c13e52a` | `85927f9` | 公开面整改（Apache-2.0 / _test 白名单 / 文档脱敏 / P3） |
| `cb5f300` | `5bed093` | 本次 ④ 修复（最终 HEAD） |
| `cff080e` | `d8c306b4` | |
| `7b86552` | `f24b3f4f` | |
| `50b5880` | `c2fa1be4` | |
| `6f36429` | `e87802b1` | |
| `98c00f8` | `4b9c7c19` | |
| `68125c4` | `5d296f03` | |
| `a5854e3` | `c4a6df47` | 初提交（口令引入点） |
| `18d24da` | `0216b59b` | |
| `39e67e6` | `9912e037` | |
| `52f3b7a` | `2346556d` | |
| `5a009fb` | `dbd52e68` | |
| `80a82ac` | `775e0b99` | |
| `978a54d` | `613a208a` | |
| `e40f888` | `d92cdaa6` | |
| `3c3873cd` | `2ca55f99` | 公开前脱敏审计报告 |

完整映射见 `.git/filter-repo/commit-map`。

---

## 三、抹除后回归与构建（在 `5bed093` 上重跑）

- 回归 8 套件全绿：`run 103 · sse 35 · socket 57 · ext 101 · anthropic 26 · uig 198 · sql 10 · endpoint_guard 25(18 路径)` = **555 项，0 失败**
- 冷构建：**`BUILD SUCCESSFUL in 12 s 3 ms`，0 ERROR**（仅既有 WARN：`Function may throw exceptions`、`showToast`/`back`/`showDialog`/`pushUrl`/`getContext`/`getParams` 弃用、混淆未启用、entry 版本号 SemVer 提示）
- 产物：`entry/build/default/outputs/default/entry-default-signed.hap` = **1,738,690 B**
- 日志存档：`.backups/seq9-build.log`、`.backups/seq9-regress.log`

---

## 四、遗留：必须由 ALEX 处理 / 绝不可外发

### 4.1 仍需 ALEX 动手（P1，阻塞公开）

1. **AGC 吊销并重签调试证书 + profile**。被抹除的 `keyPassword` 已随历史存在过，
   视同泄露；仅从 git 历史移除不等于口令失效。需在 AGC 后台吊销现有调试证书/profile 并重新申请，
   然后更新本地 `build-profile.json5`（该文件已被 `.gitignore:35` 忽略，不入库）。
   —— 这项工作 DSH 无法代理执行。

### 4.2 工作区仍有明文副本（均已被 gitignore，但**绝不可打包外发**）

| 路径 | 内容 | 忽略规则 |
|---|---|---|
| `build-profile.json5` | 本机签名配置明文 | `.gitignore:35` |
| `.backups/build-profile.json5.bak.p0-1` | 同上（备份） | `.gitignore:64`（`/.backups/`） |
| `.backups/redact-secrets.txt` | 明文→替换 映射 | `.gitignore:64` |
| `.backups/pre-purge-cb5f300.bundle` | **抹除前全量历史（含旧 blob）** | `.gitignore:64` |

建议：证书轮换完成、确认无需回滚后，由 ALEX 决定销毁 `pre-purge-cb5f300.bundle` 与
`redact-secrets.txt`（按 ALEX 纪律，DSH 不擅自删备份）。

### 4.3 其它克隆

本仓库无远端。若任一 agent 工作区曾持有独立 clone，旧 hash 与其本地历史仍含明文，
需删除并重新 clone —— 历史重写只对本地对象库生效。

---

## 五、结论

- ④ 已由「假修复（隐患已建模、写入点不可达）」升级为**真实可达**：按钮 → `abortRoom` → `abort`
  → `cancelQueued` + `handle.abort()` → `abort.completed` 收尾，全链路可 grep 追踪。
- git 历史中的明文签名口令已**从全部 17 个 commit 中移除**，对象库干净（0 loose / fsck 干净 / 无 refs/original）。
- 公开前**剩余唯一硬阻断**：AGC 证书/profile 吊销重签（ALEX 执行）。

---

## 六、更正与补充核验（2026-10-10，依据 Pi 独立复核 + DSH 复验）

Pi 独立审核报告：`docs/AUDIT-PI-SEQ8-INDEPENDENT-2026-10-10.md`。以下 3 条经 DSH 逐条复验**成立**，
本记录前文已就地更正/撤销。

| # | Pi 指出的问题 | DSH 复验证据 | 处置 |
|---|---|---|---|
| 1 | 「pre-purge bundle grep 无明文」不可信 | `git bundle verify` → bundle HEAD=`cb5f300`（抹除前）；重建临时 bare 仓后 `git rev-list --objects` 显示 bundle 内**原样存在被抹除的两个旧 blob**：`af5286457`=`build-profile.json5`（3356 B）、`1bb21699`=`docs/AUDIT-CLAUDE-2026-10-09.md`。压缩 packfile 明文打不中是必然结果，不是「干净」。 | **撤销**任何「bundle 干净」表述：`.backups/pre-purge-cb5f300.bundle` **按含明文对待**，外发前必须销毁 |
| 2 | 对象库有悬挂 commit、loose 未清 | gc 前 `git fsck --unreachable`：commit `f4795caa` + 2 tree + blob `de5a88ed`；`count: 8`。`f4795caa` 是 `6b4e62a` amend 前旧版（仅 EXEC 文档 1 行差）。 | 已补跑 `git reflog expire --expire=now --all && git gc --prune=now --aggressive`；gc 后 `count: 0` / `in-pack: 290` / unreachable 空 / reflog 0 / `fsck` 干净 |
| 3 | `git log -- build-profile.json5` 为空 ≠ 该文件名从未进历史 | `git ls-files` → `entry/build-profile.json5` 自初提交 `c4a6df4` 起**持续被追踪**，仅 1 个版本、不含签名材料；根目录那份确实从未追踪。 | 已在第二节核验表就地更正 |

### 6.1 DSH 补做的更强扫描（全对象库 156 blob，含 unreachable）

从 pre-purge blob `af5286457` 解出两条 86 位口令字面值（**全程不打印、不落盘**，仅内存比对），
对主仓 `git cat-file --batch-all-objects` 的全部 **156 个 blob** 逐字节比对：明文值 **0 命中**。
另按字段名 `keyPassword` 扫到 8 个 blob（`docs/SIGNING.md`×2、`docs/AUDIT-CLAUDE`×3、
`docs/AUDIT-DSH-REAUDIT`×1、本文件×2），逐个确认**只有字段名/讲述文本、无明文值**；
悬挂 blob `de5a88ed`（amend 前旧版本文档）同样只含字段名。

⇒ 主对象库无明文残留；`pre-purge-cb5f300.bundle` 是当前唯一明文快照。

### 6.2 DSH 复验后一并处理

- 4 处 `D:/studio` 注释残留统一为 `<项目根>`（`_test/run_endpoint_guard.mjs:26`、
  `_test/run_sqlguard.ts:19`、`_test/run_uiguard.ts:18`、`deploy.sh:12`）。
- README 回归基线 `548` → `555`：表内各套件行 `198+57+101+103+35+26+25+10` 本就等于 555，
  原合计数少 7；`_test/README.md:27` 同步更正。
- 复测：8 套件 **555 项全绿**（`103·35·57·101·26·25·198·10`）；冷构建
  `BUILD SUCCESSFUL in 10 s 494 ms`，**0 ERROR**，HAP 1,738,693 B。
  日志 `.backups/seq10-regress.log` / `seq10-build.log`；
  改动前备份 `.backups/p2-residue-fix-20261010-2/`。

### 6.3 仍未闭环

- **AGC 证书/profile 吊销重签（唯一硬阻断，ALEX 执行）**。
- 外发前销毁明文副本：`pre-purge-cb5f300.bundle`（**已确认含明文**）、`redact-secrets.txt`、
  `.backups/build-profile.json5.bak.p0-1`；`build-profile.json5` 本地构建必需但绝不外发。
- Pi 新增 2 条 P2（不阻断，待 ALEX 定夺）：① 建连窗口内 `handle.abort()` 可能静默丢失
  （`Orchestrator.ets:253` await 期间 handle 未注册，与 `LlmEngine.ets:359` 的 `inflight`
  同类问题但键不一致）；② 停止按钮无幂等保护，连点会重复 toast。
