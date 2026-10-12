# Pi 独立重新审核报告（SEQ12）

- 审核人：Pi（接替 Gemini 独立审核位）
- 基线：`631e561`（20 commits），工作区干净
- 审核方式：**全部读真实源码 + 独立复跑**，不采信任何 Agent 自报
- 结论：**基线全部复现通过；发现 1 条真问题（P1，同源复发）；另有 3 条非阻断观察**

---

## 一、基线复现（全部由 Pi 亲自执行）

| 项目 | 结果 |
|---|---|
| `git log --oneline \| wc -l` | **20** ✅ |
| `git status --porcelain` | 空 ✅ |
| 冷构建 `./build.sh release assembleHap` | `BUILD SUCCESSFUL in 9 s 589 ms`，**0 ERROR** ✅ |
| HAP 产物 | `entry-default-signed.hap` = **1,737,418 B** ✅ |
| 回归 8 套件 | **103 · 35 · 57 · 101 · 26 · 25 · 209 · 10 = 566 项全绿** ✅ |

回归执行顺序按 `_test/README.md` 强制要求：先 `sync_all.mjs` 刷新抽取产物，再跑 8 个套件。抽取自检通过（`SocketClient.ts` 15174 B、`Core.ts` 43363 B，均远超 1000 B 阈值）。

---

## 二、安全复核（git 全对象库，非仅可达 commits）

| 检查 | 方法 | 结果 |
|---|---|---|
| 悬空/不可达对象 | `git fsck --unreachable --dangling` | **0 输出** ✅ |
| reflog | `git reflog \| wc -l` | 1（仅当前 HEAD，无历史残留） ✅ |
| 对象库规模 | `git count-objects -v` | 170 blobs / 1 pack，garbage 0 ✅ |
| **明文签名口令** | 对 **全部 170 个 blob** 逐个 `git cat-file` 后正则扫 `keyPassword/storePassword/keyAlias/certificate/profile` 的字面量赋值 | **0 命中** ✅ |
| JWT | 全 170 blob 扫 `eyJ[A-Za-z0-9_-]{10,}` | **0 命中** ✅ |
| API Key 字面量 | 全 170 blob 扫 `sk-* / ghp_* / AKIA*` | **0 命中** ✅ |
| 残留 secret-bearing 文件 | `.backups` / `_backup` / `_work` 按 `*bundle* / *secret* / *.p12 / *.p7b / *.csr / build-profile*` 扫文件名 | **0 命中**（唯一命中 `_work/src/.../skill-bundles.ts` 是源码文件名，非敏感产物） ✅ |
| 3 份明文副本 | 逐一确认存在性 | `pre-purge-cb5f300.bundle` / `redact-secrets.txt` / `build-profile.json5.bak.p0-1` **均已消失** ✅ |

> 口径说明：本次扫的是**全对象库 170 blob**，比只扫可达 commits 更严。DSH 上一轮记录为 163 blob，本次 170 是因为新增了 `631e561` 的审计文档与守卫改动，属正常增长。

**安全侧结论：git 历史明文口令已彻底闭环，无残留。** 唯一剩余硬阻断仍是 AGC 侧证书轮换（需 ALEX 在 AGC 后台吊销重签），代码侧无法替代。

---

## 三、P2-1 / P2-2 修复逐行复核（重点验收对象）

### 3.1 P2-1 建连窗口 abort（`LlmEngine.ets` + `Orchestrator.ets`）

逐行读完，确认**闭环成立**：

**表登记与释放配对**
- `LlmEngine.ets:157-160` `releaseSlot()` 同时删 `inflight` 与 `aborts` 两张表，是**唯一释放点**。
- `LlmEngine.ets:419-422`（OpenAI）、`:561-563`（Anthropic）：两表在**同一点连续登记**，中间无 `await`，不存在一表有一表无的交错窗口。
- 三条终态闭包 `finishOk:341` / `failWith:352` / `abortFn:369`（Anthropic `:465/:478/:496`）**全部**先 `releaseSlot` 再 `sink`。全文件无裸 `inflight.delete`（仅 `abortRun:167` 的 `releaseSlot` 内统一删）。

**abort 路径**
- `abortRun:167-176`：先 `releaseSlot` 摘登记，再回调；命中 `aborts` 走 `abortFn` 发 `abort.completed`，未命中才回落 `req.destroy()`。
- `Orchestrator.ets:265` `activeRunIds.set(ctxKey, msgId)` 位于 `await LlmEngine.run`（`:267`）**之前**，中间无 `await`。
- `Orchestrator.ets:273-274` `finally` 无条件清 `running` 与 `activeRunIds`。
- `Orchestrator.ets:512-530` `abort()` 顺序正确：`cancelQueued` 在前，句柄命中则 `handle.abort()` 返回，否则回落 `abortRun(liveRunId)`。

**唯一非永久窗口**：pump 认领（`Repos.ets:990` 把行改 `running`）到 `Orchestrator.ets:265` 登记 runId 之间的**毫秒级 DB 窗口**。与 DSH 上轮记录一致，量级远小于已修的 300s 窗口，非本轮新发现，非阻断。

### 3.2 P2-2 停止按钮幂等（`GroupChatPage.ets`）

- `:355` `@State stopping: boolean = false`
- `:971-973` 重入门 `if (this.stopping) return;`
- `:979` 置位，`:988` `finally` 复位（异常路径也复位，不会永久卡死）
- `:1363-1365` 停止中按钮置灰 `.enabled(!this.stopping)`

**结论：P2-1 / P2-2 修复真实生效，非假修复。**

---

## 四、新发现问题

### 🔴 P1-NEW-1：ChatPage 单聊「停止」在建连窗口静默丢失（与已修的群聊同源，上轮漏修）

**这是本轮最有价值的发现：P2-1 只修了群聊 Orchestrator 一条路径，单聊 ChatPage 是同源问题且未修。**

**证据链（逐行）**

1. `ChatPage.ets:1358`
   ```ts
   this.handle = await LlmEngine.run(req, this.liveBubbleId, sink);
   ```
   句柄要等 `LlmEngine.run` **返回之后**才赋给 `this.handle`。

2. `LlmEngine.ets:430-437 / 573-580`：`requestInStream` 要等**整段流结束**才 resolve。期间：
   - `connectTimeout: 20000`（建连最长 20s）
   - `readTimeout: 300000`（流式最长 300s）

3. `ChatPage.ets:1568-1581` `stopIfRunning()`：
   ```ts
   private stopIfRunning(): void {
     if (this.handle !== null) {   // ← 建连/流式窗口内恒为 null
       this.handle.abort();
       this.handle = null;
     }
     this.streaming = false;
     ...
   }
   ```
   全文件 `this.handle` 仅 4 处（`:1358` 赋值、`:1402` 置 null、`:1569/1570/1571` 使用）。**窗口内 `this.handle === null` → `abort()` 分支整体跳过**。

4. 后果链条：
   - 用户的「停止」按钮被点 → `streaming` 被置 false → **UI 上按钮变回「↑」，看起来已停止**
   - 实际请求仍在跑，`sink` 继续回调（`sink` 只在 `patchLive()` 里靠 `if (!this.streaming …) return;` 挡住 UI 刷新，**挡不住请求本身**）
   - `LlmEngine.inflight` / `aborts` 里该 runId 继续驻留直到流结束或 300s 超时
   - **token 继续烧**，且用户在 UI 上完全无感
   - 若此刻退出页面，`aboutToDisappear:503` 再次调 `stopIfRunning()` —— 同样因 `handle === null` 跳过，**run 泄漏到自然结束**

5. 关键佐证：`LlmEngine.abortRun` 与 `LlmEngine.isRunning` 这两个新 API **全项目只有 Orchestrator 调用**（`abortRun` 调用点仅 `Orchestrator.ets:529`；`isRunning` **零调用点**）。说明 P2-1 的修法**没有推广到 ChatPage**。

6. 守卫覆盖缺口：`run_uiguard.ts:248-249` 只断言了 `GroupChatPage` 的停止幂等位，**对 ChatPage 的 `stopIfRunning` 无任何断言**。即使修好，未来回归也测不出来。

**影响面**：单聊是 App 使用频次最高的入口（ChatPage 2608 行，是 GroupChatPage 的使用主体）。发生概率取决于用户是否在「模型服务建连慢 / 首 token 慢」时点停止——恰恰是**弱网、首次连大模型、慢速供应商**场景，恰好也是用户最想点停止的场景。

**与已修群聊路径的对照**

| | 群聊（已修） | 单聊（本条） |
|---|---|---|
| 句柄登记 | `Orchestrator.ets:267` | `ChatPage.ets:1358` |
| 建连窗口回落 | ✅ `activeRunIds` + `abortRun`（`:265/:529`） | ❌ 无任何回落 |
| 退出页面兜底 | — | ❌ `aboutToDisappear:503` 同样落空 |

**建议修法**（与群聊同构，改动面小）

```ts
// ChatPage：与 Orchestrator.activeRunIds 同构
private liveRunKey: string = '';   // liveBubbleId 即 runId，本就已存在

private stopIfRunning(): void {
  if (this.handle !== null) {
    this.handle.abort();
  } else if (this.liveRunId.length > 0) {
    LlmEngine.abortRun(this.liveRunId);   // ← 建连/流式窗口回落
  }
  this.handle = null;
  ...
}
```
并在 `run_uiguard.ts` 补 2 条断言（ChatPage 有 `LlmEngine.abortRun` 回落 + `aboutToDisappear` 有兜底），防止未来再次漏修。

**状态：存疑，待 ALEX 定夺** —— 我是审核位，未擅自改动代码。

---

## 五、非阻断观察（3 条）

### O-1（已由 DSH 记录，本轮复核确认）：更窄的残留窗口

`Repos.ets:990-993` 的 `takeNext` 已把队列行改成 `running`，而 `cancelQueued`（`:963`）只动 `status='queued'`。在「pump 认领 → `Orchestrator.ets:265` 登记 runId」之间的**毫秒级**窗口点停止：
- `cancelQueued` 够不着这行（已是 `running`）
- `activeRunIds` 还没登记
- 结果：该条仍会发请求烧一次 token，toast 误报「已取消排队任务」

量级：毫秒级 vs 已修的 300s 窗口，可忽略。守卫覆盖不到。建议单独排期（pump 认领即登记，或 `abort()` 落 cancel 标记由 `runOne` 前置检查）。

### O-2：`LlmEngine.isRunning` 零调用点

`LlmEngine.ets:181-186` 新增的 `isRunning`（含注释说明「UI 会错误地以为可以再发一次」）**全项目无任何调用**。要么是设计好但接线未做，要么是修 P2-1 时留下的半成品。建议：接到 ChatPage / GroupChatPage 的发送按钮 `.enabled()` 上（发送中的场景本就该禁用），或按死代码清除。

### O-3：群聊「发送」按钮无防重入

`GroupChatPage.ets:1376` 发送按钮 `.enabled(this.draft.trim().length > 0)` —— **只看草稿非空，不看是否正在发送**。而 `send()`（`:992`）的入口守卫也只判 `text.length === 0`，**没有 `sending` 幂等位**（`stopAll` 有 `stopping`，`send` 没有对称的 `sending`）。

快速连点两次发送 → 两次 `dispatch` → 队列出现 2 条重复任务 → agent 对同一条消息回复两次。ChatPage 侧有 `if (this.streaming) return;`（`:1292`）守住，群聊侧**没有对称保护**。

属 P2 量级，非阻断，建议排期补 `@State sending` 幂等位（与 P2-2 同款修法，成本很低）。

---

## 六、本轮未发现问题（已扫且确认健康）

| 面 | 结论 |
|---|---|
| SQL 注入 | `Repos.ets` / `ExtendRepos.ets` **全部参数化**（`?` 占位 + args 数组），字符串插值 SQL **0 处** ✅ |
| 沙箱路径逃逸 | `Core.ets:1533-1557` `isSafeRelativePath` 逐段深度解析，`a/../../b` 能正确判为逃逸（`depth<0` 即拒），历史审计提到的误判已修复 ✅ |
| 定时器泄漏 | `JobsPage:62` / `JourneyPage:95` / `SessionListPage:186` / `Common.ets:367` 四处 `setInterval` **全部**有对应 `clearInterval`；全项目 `setInterval` 仅这 4 处 ✅ |
| 队列认领竞态 | `Repos.ets:979-996` `takeNext` 是「SELECT 取 id → 按 id 带 `status='queued'` 条件 UPDATE 认领 → 按 id 取回」，认领 UPDATE 带条件，与 `cancelQueued` 互斥，不会误抢 ✅ |
| 登出清理 | `AppStore.ets:182` `clearToken()` 清 `NetConfig` + keystore + preferences + 切回 local ✅ |
| Terminal 清理 | `TerminalPage.ets:60-61` `aboutToDisappear` 调 `term.close()`；首帧超时定时器有 `clearFirstFrameTimeout` 配对 ✅ |
| 死分支 | `LlmEngine.ets:174-178` 的 `destroy` 兜底分支不再删 `inflight`，因不变式（`aborts` 缺失 ⇒ `inflight` 已删）不可达，**无泄漏**，建议保留 ✅ |

---

## 七、汇总

**基线健康度：高。** 566 项全绿、0 ERROR 构建、git 历史明文口令 0 残留，全部由 Pi 独立复跑确认。

**P2-1 / P2-2 修复判定：真实生效，非假修复。** 两表成对释放、无 await 交错、终态闭包全覆盖，`stopping` 重入 + try/finally 复位 + 置灰禁用三项齐全。

**唯一需要老板定夺的新问题：P1-NEW-1（ChatPage 单聊建连窗口 abort 丢失）。**
与上轮已修的群聊 P2-1 **同源**，上轮只修了 Orchestrator 一条路径、漏了单聊。这是「停止后仍在烧 token」在单聊入口的复现，且 UI 会假装已停止、退出页面也拦不住，**静默烧 token + 资源泄漏**双重后果。

**唯一需要老板决策的硬阻断仍是 AGC 证书轮换**（git 历史移除 ≠ 口令失效），代码侧已无任何可做动作。

---

*报告生成：Pi · 2026-10-10 · 基线 631e561 · 零代码改动*