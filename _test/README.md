# Ekko Harmony 回归测试

无设备 / 无模拟器环境下验证 ArkTS 纯逻辑。
`assembleHap` 通过只证明语法与类型正确，**证明不了业务结果对**。

---

## 一、固定跑测顺序

```bash
# ① 先刷新抽取产物（只读源码，不手抄）—— 不跑这步测的是旧版镜像
node _test/sync_all.mjs

# ② 纯逻辑回归
node --experimental-transform-types --no-warnings _test/run.ts              # 103
node --experimental-transform-types --no-warnings _test/run_sse.ts           # 35
node --experimental-transform-types --no-warnings _test/run_socket.ts        # 57
node --experimental-transform-types --no-warnings _test/run_ext.ts           # 101
node --experimental-transform-types --no-warnings _test/run_anthropic.ts     # 26

# ③ 守卫
node _test/run_endpoint_guard.mjs                                             # 25（18 条路径）
node --experimental-transform-types --no-warnings _test/run_uiguard.ts        # 227
node --experimental-transform-types --no-warnings _test/run_sqlguard.ts      # 10
```

**当前基线：103 · 35 · 57 · 101 · 26 · 25 · 227 · 10 = 584 项全绿。**

⚠ `--experimental-transform-types` 不能省：`enum`（`EnginePacket`）需要它，
默认 strip-only 模式报 `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`。

⚠ **永远不要只跑 run\* 而跳过 `sync_all`** —— 读到的会是上一版源码的镜像。

---

## 二、抽取产物：为什么必须「生成」而不是「手抄」

`_test/SocketClient.ts` 曾是生产代码 `entry/src/main/ets/net/SocketClient.ets`
的**手工副本**。结果生产代码把帧格式修对了、副本和断言还固化着旧格式 ——
**测试不但没报警，反而把 bug 锁住了**。

现在 `sync_all.mjs` 一个入口同步全部抽取产物：
- `SocketClient.ts` ← `SocketClient.ets` 的协议编解码区段（配置驱动 `extract-socket.json`）
- `Core.ts` ← `Core.ets` 的完整镜像
- `AnthropicParser.ts` ← `LlmEngine.ets` 的 `parseAnthropicFrame` 锚点截取

并带自检：产物 < 1000 字节即判失败（抽取失败时测空壳比不测更危险）。
`extract.mjs` 另有 `mustContain` 检查（必须含 `decodeFrame`/`encodeMessage` 等关键符号）。

> 🔴 收尾时发现：之前有**两个**生成器都写 `SocketClient.ts`
> （`extract.mjs` 和另一个专用脚本），产物只差一个无害函数，
> 但跑错顺序就不知道测的哪一版 —— 已合并成 `sync_all.mjs`，专用那个归档到 `_trash/`。

---

## 三、断言纪律（血泪）

1. **期望值必须来自服务端真实抓包，不能来自实现复现。**
   之前 decodeFrame 的测试全绿，是因为期望值和错误实现一起错。
2. **只写不变量**：「@ 提及必须用 agentId」「总字数守恒」；
   不要写会随修复失效的期望：「不得存在 X」「函数被调用 N 次」。
3. **每条修复配一个可 grep 的锚点**（注释里写清「之前错在哪、实测症状是什么」）。
4. `extract.mjs` 自带守卫：产物残留 `@ohos`/`@kit`、长度异常、缺关键符号 → FATAL，
   防止「测试已失效但还在假装通过」。

---

## 四、服务端依赖说明

本仓库只包含**客户端纯逻辑**回归。少数守卫（`run_endpoint_guard.mjs`）会扫描
源码里的端点契约，静态模式不连服务端；`--live` 模式需要自行提供
`EKKO_BASE` / `EKKO_TOKEN` 环境变量，属可选验证，默认不开。

探针类脚本（连接真实服务端抓包）属内部调试工具，**不随本仓库分发**。
需要复现「真实报文回放」类断言时，请按 `run_socket.ts` 内注释自行抓包替换。

---

## 五、测试抓过的真实缺陷（为什么这些守卫值得留）

1. `parseSseChunk` 里 `while (idx >= 0)` 对 `null` 恒真 → 首帧即崩
2. `decodeFrame` 把帧格式解析错 → **群聊全部消息无法解析**、连接被服务端关闭
3. `utf8Decode` 缺低位掩码 → 中文与 emoji 全乱码
4. Cron 周字段定义域写成 0..6，导致 `7`（周日）永远不合法
5. `isSafeRelativePath` 深度判断错误，`../secret` 竟被判为安全 → **沙箱逃逸风险**
6. `guessMime('.jpg')` 产出 `image/jpg`（非法 MIME）
7. 编码 socket 帧时 subType 位置错 → 服务端解析不了，**发完直接关连接**