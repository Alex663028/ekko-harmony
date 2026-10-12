# Ekko Studio 鸿蒙版

把 [Ekko Studio](https://github.com/EKKOLearnAI/ekko-studio)（Electron + Vue3 + Koa + SQLite 的本地优先多Agent 工作台）
用**原生 ArkTS / ArkUI 重写**成鸿蒙应用。

**支持手机与鸿蒙 PC**：手机单栏，PC 宽屏自动双栏（会话列表常驻 + 可拖拽分栏 + 布局记忆）。

> **当前状态**：编译 0 错误，回归测试全绿（`run` 103 · `run_sse` 35 · `run_socket` 57 ·
> `run_ext` 101 · `run_anthropic` 26 · 端点契约 25 · UI 防退化 219 · SQL 列参 10，合计 576）。

---

## ⚠️ 接手前必读（7 条）

### 0. ⚠️ 工程路径**不能有空格**

DevEco Studio 会直接报：
```
Invalid path. Select a path that contains only letters, digits, periods (.),
underscores (_), and hyphens (-), and does not end with a period.
```

**允许**：字母、数字、`.`、`_`、`-`
**禁止**：空格、中文、全角字符、特殊符号，路径也不能以 `.` 结尾

正确示范：`D:\EkkoStudioHarmonyOS`、`D:\work\ekko-harmony`
错误示范：`D:\Ekko Studio HarmonyOS`、`D:\我的项目\harmony`

> 之前放在 `D:\Ekko Studio HarmonyOS` 就踩了这个坑 —— 带空格直接打不开。
> 移动工程路径后如果编译报奇怪的错，删掉 `.hvigor/` 和 `entry/build/` 重建即可
> （这两个目录会缓存旧的绝对路径）。

### 1. 签名要自己配 —— 交付副本不带任何人的证书

`build-profile.json5` 里的 `signingConfigs` 是**空数组**，等DevEco 自动签名填：
`File → Project Structure → Signing Configs → Automatically generate signature`。

不配的后果：hvigor 跳过签名，只产出 `entry-default-unsigned.hap`。
**模拟器能装，真机直接拒**：
```
error: failed to install bundle. code:9568320 error: no signature file.
```

⚠ 首次生成签名时，真机必须**已开启 USB 调试并已信任电脑** ——
DevEco 靠 hdc 读设备 UDID 把它写进证书白名单，
否则包能编译但装不上（提示「未包含在证书白名单中」）。

详见 [docs/SIGNING.md](docs/SIGNING.md)。

### 2. `local.properties` 不入库（含本机绝对路径）

首次使用请手建：

```properties
sdk.dir=<你的 DevEco SDK 路径>
nodejs.dir=<你的 DevEco node 路径>
```

### 3. 命令里的绝对路径都改成相对了

本文档与 `_test/` 下的脚本**不再写死任何人的路径**（原先的绝对项目路径、
`<你的用户名>` 下的路径全部改为按脚本自身位置解析）。换目录、改用户名都不会失效。

### 4. 零第三方依赖

`dependencies` 与 `devDependencies` 基本是空的，`ohpm install` 不用拉什么东西。
**不要 `npm install`** —— 工程里出现 `node_modules/` 会让 DevEco 的 Sync 报
`00302013 The root node is not yet available for build`，原因见
[docs/SIGNING.md](docs/SIGNING.md)。

### 5. 两条硬协议，改代码前必须看

**socket.io 帧格式**

```
4<subType><ns>,<ackId><payload>
```

subType：`0`=CONNECT `2`=EVENT `3`=ACK；ns 段以逗号结尾；ackId 可选且在 subType **之后**。
实测样例：`42["ev",data]`、`42/group-chat,["join",{...}]`、`40/group-chat,{"token":JWT}`

⚠️ 本服务端**不支持带 ackId 的上行帧** —— 发出去既不回 ack，连普通推送都停。
群聊 join / message 必须用 `SocketClient.emitNoAck()`（fire-and-forget）。

建连五步，一步不能少：
```
← 0{"sid":...}              等 Engine.IO OPEN
→ 40{"token":JWT}           默认 ns CONNECT with auth
← 40{"sid":...}             auth 通过
→ 40/<ns>,{"token":JWT}     命名空间 CONNECT（必须再带一次 auth）
← 40/<ns>,{"sid":...}       命名空间回执 —— 收到才算进 ns，之后才能发 join
```

**事件名**

- 单聊（`/chat-run`）：`run.started` / **`message.delta`** / `thinking.delta` /
  `reasoning.available` / `usage.updated` / `session.activity` / `run.completed` /
  `approval.requested` / `clarify.requested`
- 群聊（`/group-chat`）：`message_stream_start` / `message_stream_delta` /
  `message_stream_end` / `group.message.created` / `group.approval.requested` /
  `group.clarification.requested` / `group.run.updated`

⚠️ 文本增量是 `message.delta`，**不是** `run.delta`。
⚠️ 群聊审批走 `group.*`，不是 chat-run 那套。
⚠️ 用量消息（id 以 `gcusage_` 开头）不要当正文渲染。

这些全部有回归测试覆盖，改坏了守卫会红。

### 6. 跑测试（不需要设备）

`_test/` 公开**回归测试套件**（`run*.ts` / `run*.mjs` / `sync_all.mjs` / `extract*.mjs`）。
探针与调试脚本（连接真实服务端抓包、设备侧自动化）属内部工具，**不随仓库分发**。

```bash
N="<你的 node 22 路径>"

"$N" _test/sync_all.mjs                                            # 必须先跑
"$N" --experimental-transform-types --no-warnings _test/run.ts        # 103
"$N" --experimental-transform-types --no-warnings _test/run_sse.ts    # 35
"$N" --experimental-transform-types --no-warnings _test/run_socket.ts # 57
"$N" --experimental-transform-types --no-warnings _test/run_ext.ts    # 101
"$N" --experimental-transform-types --no-warnings _test/run_anthropic.ts # 26
"$N" _test/run_endpoint_guard.mjs                                   # 25
"$N" --experimental-transform-types --no-warnings _test/run_uiguard.ts # 219
"$N" --experimental-transform-types --no-warnings _test/run_sqlguard.ts
```

⚠ `--experimental-transform-types` 不能省（`enum` 需要它）。
⚠ **永远不要跳过 `sync_all.mjs`** —— 测试读的是从生产代码抽取的副本，不同步就测旧逻辑。

细节见 `_test/README.md`。

**提交前自查**：`local.properties`、签名材料、JWT、内网 IP —— 一个都不能带进提交。

---

## 一句话说明架构差异

原版是「桌面应用」：浏览器 UI → Socket.IO → Koa 服务 → spawn Claude Code/Codex 进程。
鸿蒙是「手机应用」：**没有 Node 运行时，也拉不起 CLI Agent**。

所以鸿蒙版的做法是：

| 层| 原版 | 鸿蒙版 |
|---|---|---|
| UI | Vue3 + Naive UI（Web） | ArkUI 声明式组件 |
| 通信 | Socket.IO `/chat-run`、`/group-chat` | `@ohos.net.webSocket` 手写 Engine.IO/Socket.IO 帧编解码（仅用于对接 PC 服务端） |
| Agent 执行 | Koa 服务 spawn CLI 进程 | `LlmEngine` 直连模型 API（SSE 流式） |
| 群聊调度 | 服务端 `processMentions` + 执行队列 | `AgentOrchestrator` 本地调度 + 本地队列表 |
| 存储 | better-sqlite3 | `relationalStore`（SQLite，表名沿用原版） |

**能真正跑通的是单聊与群聊多 Agent 协作** —— 因为它们依赖的是模型 API，不是 CLI 进程。

---

## 编译与部署

### 命令行
```bash
cd <项目根>
./build.sh debug assembleHap     # 调试包
./build.sh release assembleHap   # 发布包
```

> 构建统一走 DevEco 自带的 hvigor。
> **不要 `npm install`** —— 工程里出现 `node_modules/` 会让 DevEco 的 Sync
> 报 `00302013 The root node is not yet available for build`，
> 原因与解法见 [docs/SIGNING.md](docs/SIGNING.md)。

### DevEco Studio
直接点 Run（首次会提示 Sync —— 前提是工程里没装 `node_modules`）。

### 部署到真机
```bash
./deploy.sh          # 构建 → 校验签名 → 安装 → 启动（一条命令）
```
前置条件：已在 DevEco Studio 配置「自动签名」（File → Project Structure →
Signing Configs → Automatically generate signature）。
华为设备只信任 `Huawei CBG Root CA G2` 签发的证书，手工自签装不上，
完整排查记录见 [docs/SIGNING.md](docs/SIGNING.md)。

### 用起来
1. 装好 HAP，启动后选**本地模式**：填昵称 + 模型 API Key。
2. 进入会话列表 → 右上角 ＋ 开新对话 → 直接发消息，AI 流式回复。
3. 切到**群聊** Tab → ＋ 建群 → 点右上「成员」把 Agent 搬进群 → 输入 `@名字 你的问题`。
   **群聊里必须 @ 至少一个 Agent 才会开始执行**（与原版一致）。
4. 「模型与 Agent」页可增删供应商、填 Key、拉取模型列表、配置 Agent 人设提示词。

---

## 已实现功能（16 个页面）

### 核心对话
| 页面 | 内容 |
|---|---|
| LoginPage | 登录（本地模式 / 连接服务端双模式） |
| SessionListPage | 会话列表：搜索、分类 Tab、归档、分享链接、置顶；**宽屏双栏** |
| ChatPage | 单聊：流式对话、Markdown、代码块复制、工具轨迹、思考区、中止、附件、记忆提示、分享 |
| GroupChatPage | 群聊：多 Agent @ 协作、邀请码、Agent 交接链、群记忆 |
| AgentManagerPage | 供应商与 Agent 管理、Key 校验、拉取模型列表、人设提示词 |

### 效率工具（全部本机执行）
| 页面 | 内容 |
|---|---|
| JobsPage | 定时任务：Cron 解析校验、预设、启停、跑一次、下次运行 |
| KanbanPage | 看板：列管理、卡片跨列移动、**WIP 上限拦截**、优先级 |
| UsagePage | 用量：Token/费用汇总、按模型分布、近 30 天趋势 |
| JourneyPage | 会话关系图：群聊↔Agent、会话归属 |
| LogsPage | 日志（分级过滤）与性能指标、构建信息 |
| FilesPage | 本地文件浏览、图片/文本预览、新建删除、会话附件；**路径安全检查** |
| MemoryPage | 记忆：全局/会话/群聊作用域、置顶、编辑、命中统计 |

### 扩展能力（配置存本地，**执行需 PC 服务端**）
| 页面 | 内容 | 说明 |
|---|---|---|
| SkillsPage | 技能管理 + 注入预览 | **提示词注入，本机生效** |
| PluginsPage | 插件管理 | 需 PC 执行，UI 已诚实标注 |
| McpPage | MCP 服务器（stdio/sse/http） | 需 PC 执行，UI 已诚实标注 |

### 设置
SettingsPage：深色模式、Studio 服务端连接、清空数据、全部工具入口、布局偏好。

---

## 鸿蒙 PC 适配

`deviceTypes` 已含 `phone` / `tablet` / `2in1`。

**断点**（依据**可用窗口宽度**而非屏幕宽度 —— PC 窗口可自由拉伸）：
- `compact < 600vp` 手机竖屏：单栏
- `medium 600~900` 折叠屏展开 / 小平板：单栏 + 栅格
- `expanded >= 900` 平板 / PC 宽屏：**左栏常驻 + 右栏内容**，可拖拽分栏

**宽屏能力**：
- `SplitPane` 双栏，分栏线可拖拽（比例限制 0.18~0.46，防止左栏消失或右栏被挤没）
- 比例**防抖 600ms 落库**，跨启动保留
- 左栏可折叠，顶栏有重新展开入口
- 悬停态、宽屏三列栅格、正文限制舒适行长（`readableWidth`）

**窗口监听**：`windowSizeChange` + `display.availableAreaChange` → 实时更新断点，折叠屏展开/PC 拉窗口都能跟随。

---

## 执行位置说明（混合模式）

| 功能 | 执行位置 | 原因 |
|---|---|---|
| 单聊 / 群聊 / Agent | **本机** | 直接调模型 API，不需要本地进程 |
| 定时任务 | **本机** | Cron 解析 + 本地队列 + 应用内调度 |
| 看板 / 用量 / 记忆 / 文件 | **本机** | 纯本地数据 |
| Skills | **本机** | 只是注入系统提示词 |
| Plugins / MCP | **PC 服务端** | 需要 Node/Python 进程拉起，鸿蒙拉不动 |

Plugins / MCP 的 UI 上已明确标注「需 PC 服务端执行」，并提供跳转配置的入口 —— 不做「看起来能跑其实跑不了」的假功能。

---

## 目录结构

```
<工程根>/
├── build.sh                    构建入口（见下方「构建踩坑」）
├── build-profile.json5         产品配置（compatibleSdkVersion 必须与本机 SDK 严格匹配）
├── oh-package.json5            含 modelVersion，必须与 hvigor-config 一致
├── hvigor/hvigor-config.json5  modelVersion = 6.0.2
├── oh_modules/                 依赖（**只走 ohpm，不要 npm install**）
│                               工程里出现 node_modules 会让 DevEco Sync 挂掉，
│                               详见 docs/SIGNING.md
├── entry/src/main/ets/
│   ├── entryability/EntryAbility.ets  启动 + 安全区换算 + 窗口/断点监听
│   ├── model/
│   │   ├── Types.ets                  核心领域模型（含具名联合类型）
│   │   ├── Extend.ets                 附件/分享/Skills/任务/看板/记忆/用量/日志/布局
│   │   └── Json.ets                   所有 JSON.parse 落地用的显式 interface
│   ├── common/Core.ets                纯逻辑：格式化 / @提及 / 流式归约 / SSE / JWT
│   │                                   / Cron / 看板 / 路径安全 / 响应式断点
│   ├── data/
│   │   ├── Database.ets               relationalStore 封装 + 6 版幂等迁移链
│   │   ├── Repos.ets                  会话/消息/群聊/队列/供应商/Agent
│   │   └── ExtendRepos.ets            附件/分享/归档/Skills/插件/MCP/任务/看板/记忆/用量/日志/偏好
│   ├── net/
│   │   ├── Http.ets                   HTTP 客户端
│   │   ├── LlmEngine.ets              SSE 流式推理（OpenAI 兼容 + Anthropic）
│   │   ├── Orchestrator.ets           多 Agent 群聊调度
│   │   ├── SocketClient.ets           Socket.IO 协议编解码（对接 PC 服务端）
│   │   └── StudioApi.ets              Ekko Studio 服务端 API
│   ├── view/
│   │   ├── Theme.ets                  设计令牌
│   │   ├── Common.ets                 公共组件库
│   │   └── Responsive.ets             PC 宽屏自适应（SplitPane / AdaptiveGrid / ReadableContent）
│   ├── pages/                         16 个页面
│   └── viewmodel/AppStore.ets         全局状态（对应原版 Pinia stores）
└── _test/                             Node 端纯逻辑回归测试
```

---

## 关键设计决策

### 1. 事件名与原版保持一致
`run.started` / `message.delta` / `reasoning.delta` / `tool.started` / `run.completed` /
`abort.completed` / `session.title.updated` …… 全部沿用原版命名，事件载荷结构也对齐。
好处：UI 层不需要为「本地推理」和「连接 PC 服务端」写两套渲染逻辑。

### 2. @ 提及必须用 agentId
这是原版踩过的坑：群聊消息里的 `mentions[].participantId` 必须填**全局 agentId**，
不是房间内记录 id（本机原版曾因取错导致 `Invalid structured mentions`，消息被服务端拒绝）。
代码里由 `RoomAgentRepo.mentionCandidates()` 专门提供这两个 id，由 `resolveMentions()` 做映射。

### 3. SSE 分片处理
流式响应会被网络切碎，`parseSseChunk()` 只消费**完整事件**（以 `\n\n` 或 `\r\n\r\n` 为界），
残缺尾巴留在 `rest` 等下一片。这是最容易写错的地方，已用「逐字节喂入」的用例覆盖。

### 4. 安全区 px → vp
`getWindowAvoidArea()` 返回 **px**，ArkUI 的 margin/padding 是 **vp**。
不换算在 480dpi 设备上留白会被放大 3 倍（用户看到的「顶部空一大块」）。
`EntryAbility.setupSafeArea()` 里统一 `px2vp()`，并监听 `avoidAreaChange` 以适配旋转/折叠屏。

---

## 构建踩坑记录（本机实测）

这些都是实际卡住过的，按报错顺序：

### 1. `modelVersion` 必须两处一致且匹配 SDK
`hvigor/hvigor-config.json5` 与 `oh-package.json5` 的 `modelVersion` 要相同，
且取值来自本机 SDK 的平台版本（`sdk-pkg.json` 的 `platformVersion`）。
本机 HarmonyOS 6.0.2 / API 22 → `"modelVersion": "6.0.2"`。

### 2. `compatibleSdkVersion` 的平台版本与 API 必须匹配
写 `"6.0.0(22)"` 会报：
```
The platform version '6.0.0' and API version '22' of compatibleSdkVersion ... do not match
```
正确写法 `"6.0.2(22)"`（与 `sdk-pkg.json` 一致）。

### 3. entry 模块的 hvigorfile 必须是 `hapTasks`，不是 `appTasks`
用 `appTasks` 会让 hvigor 用 project schema 去校验模块配置，报：
```
The project-level build-profile.json5 file does not comply with the schema
```
这个报错信息完全指错方向 —— 真正的原因是 `entry/hvigorfile.ts` 的 task 类型写错了。

### 4. 两个 build-profile 的顶层键互斥
project 的 `build-profile.json5` 只放 `app` / `modules`；
entry 的只放 `apiType` / `targets` / `buildOption` / `buildOptionSet`。
两个 schema 都用 `propertyNames.enum` 限死顶层键，混写必挂。

### 5. release 构建需要 `entry/obfuscation-rules.txt`
即使 `enable: false`，文件也必须存在，否则报
`The obfuscation rule file './obfuscation-rules.txt' cannot be found`。

### 6. 任务名是位置参数
`build.sh` 里的 `assembleHap` 必须放在最后作为位置参数，只给 `-p module=entry@default` 会报
`Task [] was not found in the project`。

### 7. 不要装 `node_modules`（会让 DevEco Studio 的 Sync 挂掉）
工程里只要存在 `node_modules/`，DevEco 的 Sync 和 hvigorw 的 project 模式就会报：
```
00302013 Script Error
The root node is not yet available for build.
```
根因：DevEco 的 hvigor 期望依赖走 `oh_modules/` + `~/.hvigor` 缓存，
多出来的 `node_modules/@ohos/hvigor-ohos-plugin` 会干扰它的模块解析，
导致它找不到 `hvigorfile.ts` 对应的根节点。

**现在的做法**：工程保持标准结构（不装 `node_modules`），
`build.sh` 统一调 **DevEco 自带的 hvigor**：
`G:\DevEco Studio\tools\hvigor\bin\hvigorw.js`。
这样 **CLI 构建与 IDE Sync 都能正常工作**（已双向验证）。

另外 `DEVECO_SDK_HOME` 必须设，且路径要用**双斜杠**：`G://DevEco Studio//sdk`，
单斜杠会报 `00303217 Invalid value of 'DEVECO_SDK_HOME'`。
（IDE 内部会自动设，命令行才需要手动设。）

> 早期为了避免 wrapper 的软链问题，曾把 `@ohos/hvigor` 与插件整份拷进
> `node_modules/@ohos/`。那是权宜之计，副作用就是 IDE 无法 Sync —— 已废弃。

### 8. 本机网络限制
`curl` 与 `git` 访问 GitHub 全部失败（直连和 127.0.0.1:60531 代理都不通，`CRYPT_E_NO_REVOCATION_CHECK`）。
但 **`gh` CLI 与 ohpm 可用** —— 参考源码是逐文件用 `gh api` 取的（见 `_work/fetch-src.mjs`）。

---

## ArkTS 迁移要点

ArkTS 不是 TypeScript，以下是编译器实测会拦的写法（本工程 109→0 全程踩过）：

| 规则 | 错误码 | 正确做法 |
|---|---|---|
| 禁止 `any` / `unknown` | `arkts-no-any-unknown` | JSON.parse 结果 `as` 成显式 interface |
| 禁止对象字面量当类型 | `arkts-no-obj-literals-as-types` | 先 `interface Xxx` |
| 对象字面量须对应已声明类型 | `arkts-no-untyped-obj-literals` | 用具名工厂函数，或先 `const x: T = {...}` |
| 禁止对象展开 | `arkts-no-spread` | 逐字段赋值 |
| 禁止字符串下标取字符 | `arkts-no-props-by-index` | `charAt()` |
| 禁止动态键访问字段 | `arkts-no-props-by-index` | 改具名 interface 字段 |
| 禁止 `delete` | `arkts-no-delete` | 重建数组 |
| 禁止 `X['key']` 类型断言 | `arkts-no-aliases-by-index` | 具名联合类型 `type MessageRole = 'user' \| ...` |
| 禁止隐式返回类型 | `arkts-no-implicit-return-types` | 显式标注 |

**组件属性名不能撞内置方法名**：`size` / `width` / `height` / `padding` / `margin` /
`border` / `clip` / `enabled` 都撞。实例：
- `PrimaryButton` 的 `enabled` 改名 `enabledState`
- `Tok.border()` 改名 `Tok.line()`

**`@State` 数组必须整体重新赋值**：`this.arr = newArr` 才会刷新，单独 `push` 界面不更新。

---

## 测试覆盖

`_test/` 随仓库分发**回归测试套件**（纯 Node 逻辑，无设备依赖）。探针类脚本与
设备侧自动化属内部调试工具，不随仓库分发。下表为当前回归基线：

| 套件 | 项数 | 覆盖内容 |
|---|---|---|
| `run_uiguard.ts` | 219 | **AdaptiveGrid 防退化**、组件保留名冲突（防止列表第 10 条起不渲染）、**中止链路守卫**（建连窗口 runId 登记/成对释放，群聊 + 单聊两条路径）、**停止/发送按钮幂等** |
| `run_socket.ts` | 57 | Engine.IO/Socket.IO 帧编解码、命名空间、ack、PING/PONG、token URL、**真实报文回放** |
| `run_ext.ts` | 101 | 响应式断点边界、Cron 解析/匹配/下次运行、看板流转、**路径穿越防护** |
| `run.ts` | 103 | 格式化、CJK 宽度、@提及解析（四级匹配）、流式事件归约、Markdown 分段、SQL 构造、JWT/base64 |
| `run_sse.ts` | 35 | SSE 事件边界、CRLF、**逐字节喂入**、注释行、多行 data、`[DONE]` |
| `run_anthropic.ts` | 26 | Anthropic SSE 帧解析、`|IN|` 前缀边界 |
| `run_endpoint_guard.mjs` | 25 | 服务端端点契约（18 条路径，防多写/少写 `studio/` 前缀） |
| `run_sqlguard.ts` | 10 | SQL 占位符↔实参配对、**列↔实参位置断言** |
| **合计** | **576** | 全绿 |

> 说明：`run_endpoint_guard.mjs` 的 `--live` 模式会连真实服务端，默认关闭；
> 需要复现「真实报文回放」类断言时，请按 `run_socket.ts` 内注释自行抓包替换。

### 测试踩过的坑（血泪，务必读）

**① 「测试全绿」不等于「测到了东西」**

抽取器 `extract.mjs` 曾有 bug：大括号配对没排除注释里的括号，导致函数体从中间被截断，
产物里留下**半个块注释**，后面所有代码都被当成注释 —— `run_socket.ts` 一直报「54 项全绿」，
实际只测了 4 个函数，`decodeFrame` 这种关键函数根本没在测。

修复后产物 7554 → 15879 字节，导出函数 4 个 → 11 个。

> **⇒ 抽取型测试必须验证产物的结构完整性**（导出数、字节数、注释配平），
> 不能只看断言数。`extract.mjs` 现在有 FATAL 自检，抽取失效会直接报错而不是假装通过。

**② 测试期望值必须来自服务端抓包，不能来自「照着实现写一遍」**

之前 `decodeFrame` 的测试期望值和错误实现一起错，测试反而把 bug 锁住了。
用探针抓真实报文再写断言：`probe_sio2.js`（握手）、`probe_events.js`（单聊事件）、
`probe_gcmsg.js`（群聊全链路）。

**③ 路径不能写死绝对路径**

`extract-socket.json` 原本写死 `<工程根>//...`，项目复制到别的目录后，
抽取器仍从**旧目录**读源码 —— 副本里是旧代码，你改的是新目录，测试绿灯是假的。
现在配置用 `<root>/` 前缀表示相对项目根，守卫脚本按自身位置解析。

**④ 改完生产代码必须 `sync_all.mjs`**

`_test/SocketClient.ts` 是从 `SocketClient.ets` **抽取生成**的副本，不是手抄的。
不重新同步就测的是旧逻辑。

### 测试抓到的真实缺陷（都是「编译通过但逻辑错」）

1. `parseSseChunk` 里 `while (idx >= 0)` 对 `null` 恒真 → 首帧即崩
2. `decodeFrame` 把帧格式解析错 → **群聊全部消息无法解析**、连接被服务端关闭
3. `utf8Decode` 缺低位掩码 → 中文与 emoji 全乱码
4. Cron 周字段定义域写成 0..6，导致 `7`（周日）永远不合法
5. `isSafeRelativePath` 深度判断错误，`../secret` 竟被判为安全 → **沙箱逃逸风险**
6. `guessMime('.jpg')` 产出 `image/jpg`（非法 MIME）
7. 编码 socket 帧时 subType 位置错 → 服务端解析不了，**发完直接关连接**

---

## 已知未验证项

- **审批端到端**：遮罩渲染与响应都验过（临时注入模拟事件），
  但没有真实 Agent 触发审批的场景。
- **通知点击跳转**：发出链路通（会弹系统授权框），点横幅跳回正确页面未在真机验证。
- 群聊历史里可能有早期测试留下的 `gcusage_` 用量 JSON（已落库，不会因代码修复消失）。

---

## 尚未实现

老板明确不要的：**可视化工作流编排**、**语音输入输出（TTS/STT）**。

其他原版有但本版未移植的（多为依赖桌面环境的特性）：
- Web 终端、Desktop Agent Browser（需本机浏览器自动化环境）
- 平台渠道（Telegram / Discord / Slack 等 10 个平台的接入配置，需长连接服务）
- Hermes 运行时管理（安装/更新 CLI Agent，鸿蒙无法拉起）
- Ekko Memory 页的完整向量检索（当前为关键词存储）

---

## 参考

- 原仓库：<https://github.com/EKKOLearnAI/ekko-studio>（MIT-ish，11.2k star）
- 原始架构说明：`_work/ARCHITECTURE.md`（从仓库取的原文）
- 抽出的参考源码：`_work/src/`（257 个文件，供逐字段对照用）

---

## 许可证

本项目以 **Apache License 2.0** 发布，全文见 [LICENSE](LICENSE)。

> 说明：本仓库引用了原版 [Ekko Studio](https://github.com/EKKOLearnAI/ekko-studio) 的架构与协议约定，
> 但代码为鸿蒙 ArkTS 独立重写。`_test/` 下的抓取产物（如 `openapi.json` 等数据快照）仅作测试用，
> 与其对应服务端的许可条款以服务端自身为准。