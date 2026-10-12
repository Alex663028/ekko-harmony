# DSH 独立复审报告（只读）— HEAD `978a54d`

范围：ALEX 三项决策（LICENSE=Apache-2.0、`_test/` 脱敏后公开、API Key 加密延后）落地前，对当前工作区与提交终态做一次完整复核。
方法：直读真实源码 + `git` 元数据核对，**零代码改动**。所有结论附文件与行号。
工作区状态：`git status --porcelain` 为空；HEAD = `978a54d46cd87b4c68a4659f4b2e48ab3fde6443`。

---

## 一、结论汇总

| 级别 | 项 | 结论 |
|---|---|---|
| **P1** | ④ 修复不可达 | `AgentOrchestrator.abort` 全项目零调用，群聊页无停止入口 → 该修复对用户不可见 |
| **P1** | 公开前的 git 历史口令 | blob `af5286457` 仍含明文 `keyPassword`/`storePassword`，`git rm --cached` 不清历史 |
| **P1** | LICENSE 缺失 | 仓库根无 `LICENSE`；ALEX 已定 Apache-2.0，需落文件 + README 段 |
| **P2** | `_test/` 公开发布面 | 238 文件中约 100 个含内网 IP/本机路径/真实 JWT，需先脱敏或收窄公开范围 |
| **P2** | README 与新决定冲突 | `README.md:111/411/423` 仍写「`_test/` 不随仓库分发」且测试数 516 ≠ 实测 548 |
| **P3** | OpenAI body 冗余 `system` 字段 | `LlmEngine.ets:204` 冗余；OpenAI 路径仍序列化 `"system":""` |
| **P3** | 公开面文档/注释脱敏 | `docs/*.md`、`TerminalClient.ets` 注释含本机路径与内网信息 |

**已核实通过（无需改动）**：① ⑥ ⑪ ⑫ ⑬ 与 ⑧（文档表述本身）；② ③ 维持既定处置（服务端配合 / 延后）。

---

## 二、逐条复核证据

### ✅ ① OpenAI system 位置 — 已修且正确
- `net/LlmEngine.ets:201-212` `buildChatBody` 改用 `withSystemFirst(req.messages)`，system 作为 `messages` 首条。
- `net/LlmEngine.ets:250-262` `withSystemFirst`：合并全部 system 为一条置首；无 system 时不插空首条；其余消息保持原序。
- `net/LlmEngine.ets:214-221` `buildAnthropicBody` 保持顶层 `system`，未被破坏。

### ⚠️ ④ 群聊 abort — 代码正确，但**修复不可达（P1）**
- 代码本体与注释一致：`data/Repos.ets:955-965` `cancelQueued`（`queued → cancelled`），`net/Orchestrator.ets:465-472` `abort` 先 `handle.abort()` 再 `cancelQueued`。
- **但调用方为零**。全量检索 `entry/src/main/ets/**/*.ets`：
  - `AgentOrchestrator` 的消费方只有 `pages/GroupChatPage.ets`（`setHooks` / `resetRoom` / `pump` / `dispatch`）与 `viewmodel/AppStore.ets`（`setHooks`）。
  - `pages/GroupChatPage.ets` 全文无 `abort`、无「停止」控件；输入区只有 `Button('↑')`（:1316）发送键。
  - `pages/ChatPage.ets:1570` 的 `this.handle.abort()` 是单聊本地模式的 `LlmRunHandle`，与编排器无关。
- 因此原始症状「点停止后 queued 任务继续跑」当前**无法从任何 UI 路径触发**；该修复无法通过功能验收，`QueueRepo.cancelQueued` 与 `QueueStatus.cancelled` 仍是死写入点。
- 需二选一：**(a)** 在群聊页补停止入口并接线（停止后同时 `refreshPending()` 刷新排队计数）；**(b)** 把 ④ 从「已修」降级为「隐患已建模，待接入」，并在审计报告里如实标注。

### ✅ ⑥ 构建/部署脚本 — 已修且正确
- `build.sh:26-28` `DEVECO_SDK_HOME` / `HOS_SDK_HOME` / `NODE_HOME` 环境变量兜底；:40-44 hvigor 路径兜底。
- `deploy.sh:24-47` 优先级 `HDC_HOME → DEVECO_SDK_HOME → 默认`，且 `HDC_WIN` 由已解析的 `HDC` 统一转换（`cygpath`，无则 `sed`），两路径必然同源，`pwd -W` 空值缺口已消除。

### ✅ ⑪ 空文件 / ⑫ 文案 / ⑬ 版本号 — 已结
- `hvigor/hvigor-wrapper.js` 已不存在于工作区；`hvigorw`、`hvigorw.bat` 引用根目录 `hvigorw.js`。
- `pages/SettingsPage.ets:69` 文案已含「以及看板卡片与分组」，与 `Repos.deleteAll` 行为一致。
- `AppScope/app.json5` 与根 `oh-package.json5` 均为 `0.1.0`（`entry/oh-package.json5` 同为 `0.1.0`）。

### ⚠️ ⑧ README 诚实表述 — 表述本身已改，但**与 ALEX 新决定冲突（P2）**
- `README.md:111`、`README.md:411`：「⚠️ `_test/` 不随本仓库分发」。
- `README.md:423`：合计 **516** 全绿。
- 实测基线为 **548**（103+35+57+101+198+26+10+18）：`run_socket` 已 57（README:120 写 54）、`run_endpoint_guard` 18（README:122 写 25）、另有 `run_sqlguard` 10。
- `_test/README.md:20/24/25/30` 同样停留在 `54 · 25 · 198`。
- ALEX 新决定选「脱敏后公开」，等于回到原方案 A，上述三处须一并改写，否则公开版自相矛盾。

### ⚠️ ②③ 维持既定处置（与决策一致）
- ② 终端 JWT 走 query：`net/TerminalClient.ets` 握手从 query 取 token 属服务端硬协议，客户端单改 header 会断连 → 标「需服务端配合」。`_test/README.md:128` 亦确认日志已脱敏。
- ③ Provider API Key 明文：`data/Repos.ets:146` 直读 `api_key` 列。ALEX 已定「后面再说」，本轮不动。

### P3 建议项
1. `net/LlmEngine.ets:204` `body.system = ''` 冗余（`newRequestBody:95` 已初始化 `system:''`）；OpenAI 路径请求体仍带 `"system":""` 未知字段，严格网关可能 400。建议拆 OpenAI / Anthropic 两个 body interface，从根上不带该字段。
2. 公开面脱敏（见第三节）。
3. 根目录 15 个 `build_out_*.log` 残留（已 gitignore，建议人工清理）。
4. ⑤ ForEach 共 51 处（ChatPage 9 / JourneyPage 6 / GroupChatPage 5 / KanbanPage 4 / AgentManagerPage 4 / FilesPage 4 …）、⑦ 超大文件拆分 → 维持独立重构批次排期。

---

## 三、公开前的阻断项与脱敏清单

### 🔴 阻断 1：git 历史里的签名口令（必须先做，且不可只做一半）
- `git cat-file -t af5286457` → `blob` 存在；其中 `keyPassword|storePassword` 命中 **2** 处。
- 引入 commits：`a5854e3`（initial）、`98c00f8`（仅 `git rm --cached`）。
- 只要仓库被公开（Apache-2.0 + 公开 `_test/` 即视为公开），历史里的调试证书口令随之公开。
- 正确顺序：**① `git filter-repo`/BFG 抹除 blob 与相关路径 → ② AGC 后台吊销并重新签发调试证书 → ③ 再 push 公开**。
- 注意：抹除历史会改写全部 commit hash，`52f3b7a`/`5a009fb`/`e40f888`/`80a82ac`/`978a54d` 等引用全部失效，团队需统一换用新 hash 后再继续开发。

### 🔴 阻断 2：`LICENSE`
- `Test-Path .\LICENSE` = `False`。需新增 Apache-2.0 全文、`README.md` 增加许可证段、并确认 `_test/openapi.json` 等抓取产物与 Apache-2.0 的兼容性说明。

### ⚠️ `_test/` 公开发布面（238 文件）
`.gitignore:70` 当前整体忽略 `/_test/`。要公开需处理：

| 类别 | 实例 | 风险 |
|---|---|---|
| 真实 JWT | `_test/debug-20261007/_d1.log`、`_d4.log`、`_s4.log`（`eyJ…`） | 会话凭证泄露 |
| 内网 IP | `_test/quicklogin.ps1`、`emu.ps1`、`e2e*.ps1`、`probe-*.cjs` 等 | 内网拓扑 |
| 本机路径/用户名 | `_test/README.md:12`（`<本机用户名>/...`）、`cd <本机路径>`、大量旧脚本中的本机盘符路径 | 主机信息 |
| 团队/房间标识 | `_test/README.md:180-183`（测试群 id、成员名单） | 内部信息 |
| 生成物 | `_test/Core.ts`、`_test/SocketClient.ts`（`.gitignore:28-29`） | 需决定公开或改直连源码 |

- 全量扫描：约 **100** 个文件命中内网 IP / 本机路径 / 本机用户名。
- **建议（待 ALEX 确认）**：收窄公开范围为「回归测试套件」`run.ts`、`run_sse.ts`、`run_socket.ts`、`run_ext.ts`、`run_sqlguard.ts`、`run_uiguiard.ts`、`run_endpoint_guard.mjs`、`sync_all.mjs`、`extract.mjs`、`_test/README.md`（脱敏后）；其余 `probe-*`、`*.ps1`、`debug-*/`、`_out/` 继续 ignore。否则需逐个脱敏约 100 个一次性脚本，性价比低。
- `.gitignore` 需重排：去掉 `/_test/` 整体规则，改为按子目录/后缀白名单式排除。

---

## 四、验证边界声明

- 本报告为静态复审：未重跑冷构建、未跑回归套件（HEAD 的构建由 hermes 记录为 `BUILD SUCCESSFUL`，本轮未复验）。
- 未采信任何自报结论；①④⑥⑪⑫⑬ 均以上述真实行号为准。
- 未改动任何代码或配置；本报告为唯一新增文件。
