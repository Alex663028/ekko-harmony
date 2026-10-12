# 联调快速登录配置（DEBUG-QUICKLOGIN）

登录页的「[调试] 一键登录本机」按钮（`LoginPage.ets`）**只在 debug 包里显示**
（`releaseType === 'debug'`）。release 包看不到这个入口，属预期行为。

## 为什么源码里找不到密码

P2-15 的有意设计：**凭据不进代码仓库**。
`LoginPage.ets:122-127` 从 `preferences` 的 `debug` 域读三个键：

| 键 | 含义 | 示例 |
|---|---|---|
| `quicklogin.url` | Studio 后端地址 | `http://127.0.0.1:8748` |
| `quicklogin.username` | 登录账号 | `<你的账号名>` |
| `quicklogin.password` | 登录口令 | （你的 Studio 口令） |

源码里既没有默认值也没有兜底常量。三个键缺任意一个，按钮都会红字提示：

```
未配置联调凭证：请在 preferences/debug 里填 quicklogin.url / username / password
```

这是**预期提示，不是 bug**。

## 真机联调的前提：端口转发

`127.0.0.1` 在真机上指向**手机自己**，不是开发机。必须先把手机的
`127.0.0.1:8748` 转发到开发机的 `8748`：

```bash
hdc -t <设备ID> rport tcp:8748 tcp:8748
```

### 用 `rport`，不要用 `fport`

- `rport tcp:A tcp:B` —— **反向**转发：设备监听 A，流量送到开发机 B。
  设备侧 `127.0.0.1:8748` 直接可用，登录页地址不用改。**这是本场景要用的。**
- `fport tcp:A tcp:B` —— 正向：开发机监听 A，设备访问 `localhost:A`。
  ⚠ 它会在**开发机** `127.0.0.1:A` 上开一个监听，**可能直接遮住本机已有服务**
  （我们实测遮住了 Ekko Studio 的 8748，表现为 `/api/auth/status` 连接被 reset）。

清理正向转发：

```bash
hdc -t <设备ID> fport rm tcp:8748 tcp:8748
```

若反向转发导致行为异常，先 `hdc fport ls` 看当前规则，再按上式逐条删除。

## 验证连通性

设备上没有 curl，只能用 App 内手段：

1. 登录页「Studio 地址」右侧的 **「测试连接」** 按钮 → 出现 ✓ 即通。
2. 或直接点「登录并进入」，能进会话列表即通。

## 常见故障对照

| 现象 | 根因 | 处理 |
|---|---|---|
| `✗ 网络请求失败: Failed to connect to the server` | 未建端口转发 / 转发建成了 `fport` | 改用 `rport tcp:8748 tcp:8748` |
| 测试连接 ✓，登录报 `Username and password are required` | 后端返回了业务错误，网络是通的 | 检查账号口令是否正确 |
| 列表能加载但 `127.0.0.1` 报错 | 用的是 `fport`（正向） | 换成 `rport` |
| 按钮根本不显示 | 当前是 release 包 | 用 debug 包；release 包本就没有该入口 |

## 安全说明

- 本文件**不含任何真实凭据**。
- `quicklogin.*` 写在设备本地 `preferences`，不进 git。
- 打包外发前须排除 `build-profile.json5`（本机签名材料，仓库根目录那份已被 gitignore）。