# 服务端模式改造方案

目标：手机端变成「远程操作 PC 上 Agent」的瘦客户端。
数据源全部来自 PC 上的 Ekko Studio，手机端不做业务计算。

---

## 一、服务端事实（实测，非推测）

| 项 | 值 |
|---|---|
| 产品 | Ekko Studio **v0.7.30** |
| 仓库 | `github.com/EKKOLearnAI/ekko-studio` |
| License | BSL-1.1 |
| 服务端栈 | Koa + tsoa + **socket.io** |
| 监听 | `0.0.0.0:8748`（已确认，局域网可达） |
| 接口总数 | **446** |
| 规范文件 | `resources/webui/dist/server/openapi.json`（656 KB） |
| 服务端 bundle | `resources/webui/dist/server/index.js`（12 MB） |

**流式能力已确认存在**，socket.io 服务端广播这些事件：

```
message_stream_delta      ← 正文增量
message_stream_end        ← 流结束
message_reasoning_delta   ← 推理过程增量
message                   ← 完整消息
agents_updated / execution_queue_updated / context_status
member_joined / member_left / member_updated / member_kicked
handoff_updated / message_retracted / message_routing_updated
```

→ **聊天体验可以保持「打字机」效果**，不会退化成「憋几秒一次性出现」。

---

## 二、核心接口清单

### 阶段一：会话 / 群聊 / Agent / 供应商

| 功能 | 端点 | 说明 |
|---|---|---|
| 会话列表 | `GET /api/studio/sessions` | |
| 对话列表 | `GET /api/studio/sessions/conversations` | 参数 `limit` `source` |
| **消息列表** | `GET /api/studio/sessions/conversations/{id}/messages` | 参数 `humanOnly`；另有 `/paginated` |
| **发消息** | `POST /api/studio/chat-run/runs` | 见下方 body/response |
| 会话详情/删除 | `GET,DELETE /api/studio/sessions/{id}` | |
| 会话操作 | `POST /api/studio/sessions/{id}/rename` `/pin` `/model` `/archive` `/category` | |
| 会话用量 | `GET /api/studio/sessions/usage`、`GET /api/studio/sessions/{id}/usage` | |
| 群聊房间 | `GET,POST /api/studio/group-chat/rooms` | |
| 房间详情 | `GET,DELETE /api/studio/group-chat/rooms/{roomId}` | |
| **房间 Agent** | `GET,POST /api/studio/group-chat/rooms/{roomId}/agents` | 增删改 |
| 群聊预设 | `GET,POST /api/studio/group-chat/agent-presets` | |
| Coding Agent | `GET /api/coding-agents`、`GET,POST /api/coding-agents/{id}/mcp/servers` | |
| **供应商** | `POST /api/hermes/config/providers`（新建）、`GET,PATCH /api/hermes/config/providers/{poolKey}`（改）、`DELETE,PUT .../{poolKey}` | |
| 可用模型 | `GET /api/hermes/available-models`、`GET /api/hermes/config/models` | |
| 自定义模型 | `DELETE,PUT /api/hermes/custom-model` | |
| 供应商连通性测试 | `POST /api/hermes/config/providers/{poolKey}/editor/test` | |
| 刷新模型列表 | `POST /api/hermes/config/providers/{poolKey}/models/refresh` | |

#### 发消息端点详情

```
POST /api/studio/chat-run/runs
Request:
  input              any        // 用户输入
  session_id         string
  profile            string
  provider           string
  model              string
  source             enum(cli | builtin_agent | coding_agent | global_agent | workflow | group_chat)
  instructions       string
  workspace          string
  reasoning_effort   string
  agent_id           enum(claude-code | codex | pi | grok | opencode | ekko-agent)
  mode               enum(scoped | global)

Response 200:
  ok        boolean
  status    string
  session_id string
  run_id    string
  output    string      // 完整正文
  reasoning string      // 推理过程
  events    array       // 过程事件
```

> 摘要写明 "Run chat and wait for completion" —— 是**等待式**接口。
> 要流式效果就配合 socket.io 订阅 `message_stream_delta`（用 `session_id` 关联）。

### 阶段二：定时 / 看板 / 用量 / 记忆（只读展示）

| 功能 | 端点 |
|---|---|
| 定时任务列表 | `GET /api/hermes/jobs`、`POST /api/hermes/jobs` |
| 任务详情 | `GET,DELETE,PATCH /api/hermes/jobs/{id}` |
| 任务控制 | `POST /api/hermes/jobs/{id}/run` `/pause` `/resume` |
| 运行历史 | `GET /api/cron-history`、`GET /api/cron-history/{jobId}/{fileName}` |
| 投递目标 | `GET /api/hermes/jobs/delivery-targets` |
| 看板列表 | `GET,POST /api/hermes/kanban`、`GET,POST /api/hermes/kanban/boards` |
| 看板详情 | `GET /api/hermes/kanban/{id}`、`.../{id}/log`、`GET /api/hermes/kanban/stats` |
| 看板操作 | `POST /api/hermes/kanban/complete` `/dispatch` `/unblock`、`.../{id}/assign` `/block` `/comments` |
| 用量 | `GET /api/studio/sessions/usage`、`GET /api/hermes/api-relay/usage`、`GET /api/hermes/skills/usage/stats` |
| 记忆 | `GET /api/ekko/memory`、`GET,POST /api/hermes/memory`、`DELETE,PATCH /api/ekko/memory/{id}` |

---

## 三、改造设计

### 3.1 数据源开关（核心机制）

在 `AppStorage` 增加：

```
dataSource: 'local' | 'server'     // 由登录页选模式时写入
```

**每个 Repo 方法内部判断**，页面层完全不改：

```ts
export class SessionRepo {
  static async list(store: RdbStore): Promise<SessionSummary[]> {
    if (AppStore.isServerMode()) {
      return RemoteRepos.sessions();     // 走服务端
    }
    return /* 原来的本地实现 */;
  }
}
```

**好处**：本地模式行为零变化；服务端模式自动切换；改动集中在 data 层。

### 3.2 新增文件

| 文件 | 职责 |
|---|---|
| `data/RemoteRepos.ets` | 所有服务端数据访问，一个方法对一个端点 |
| `net/SocketClient.ts` | socket.io 客户端，订阅 `message_stream_delta` 等 |

`SocketClient` 已有雏形（`_test/SocketClient.ts` 是它的测试版），需移植到 `ets/net/`。

### 3.3 分阶段落地顺序

**阶段二先做**（便宜、风险低）：
1. `RemoteRepos` 加 5 组只读方法（jobs / kanban / usage / memory）
2. 对应 5 个页面加「服务端模式分支」——只读，不显示编辑按钮
3. 验证：手机能看到 PC 上的定时任务、看板、用量、记忆

**阶段一后做**（核心、改动大）：
1. `RemoteRepos` 加 sessions / conversations / messages / rooms / agents / providers
2. `RemoteRepos` 加 `chatRun()` 对接 `POST /api/studio/chat-run/runs`
3. `SocketClient` 订阅流式事件，驱动打字机效果
4. 验证：手机发消息，PC 端能看到；PC 改动手机能刷新

---

## 四、风险与对策

| 风险 | 对策 |
|---|---|
| 服务端认证方式不明确（JWT？Cookie？） | 先抓一次真实请求确认（登录后看 header） |
| socket.io 事件是否需要 join room | 从 bundle 里 grep `join` 相关逻辑，确认订阅前提 |
| 消息结构字段名与本地模型不一致 | `RemoteRepos` 里做一层映射，不污染本地 `Types.ets` |
| 服务端版本升级导致接口漂移 | 把 `openapi.json` 存一份到工程，作为契约基线 |
| 断线时页面白屏 | socket 加心跳 + 自动重连；HTTP 失败显示离线态 |

---

## 五、开工前要你确认的

1. **服务端登录用的是什么认证？** 我可以自己抓（用你已登录的 PC），但如果你知道更快
2. **阶段二先做还是阶段一先做？** 我建议阶段二先（能立刻看到效果）
3. **手机端在服务端模式下，是否允许写入**（比如在看板上拖卡片）？
   我默认**阶段二只读**，避免和 PC 端冲突
