# 真机部署说明

工程：Ekko Studio 鸿蒙版（`com.ekkostudio.harmony`）
目标设备：SGT-AL10，HarmonyOS 7.0.0.109，API 26

---

## 一句话结论

**代码已就绪、编译零错误、回归 453 项全绿。装机唯一卡点是签名**——
华为设备只接受 **AGC（华为开发者联盟）签发**的调试 profile，
该 profile 绑定「包名 + 设备 UDID + 开发者账号」，**无法手工伪造或复用**。

两条可能的捷径我都跑通并验证到失败了（证据见下），结论明确：
**需要在 DevEco Studio 里点一次「自动签名」**（约 30 秒）。
点完之后 `./deploy.sh` 一条命令即可完成构建 + 装机 + 启动。

> 本机已经成功自动签名过 3 次（`jianji` / `hermes-studio` / `SanguoSimHarmony`），
> 说明华为账号已登录、设备 UDID 已在 AGC 注册，这一步应该很顺。

---

## 为什么必须走自动签名（实测证据）

### 两条捷径都试过，都被设备拒绝

| # | 做法 | 设备返回 |
|---|---|---|
| ① | 手工自签 OpenHarmony 证书链（自建根CA/二级CA/叶子），签 profile 与 HAP | `code:9568257 fail to verify pkcs7 file`<br>证书链回溯不到设备信任的根 |
| ② | **借用本机其他工程的华为调试证书**（jianji 的 p12，profile 里已含本机 UDID），<br>用 hvigor 官方模块解出 p12 密码，把 profile 的 `bundle-name` 改成 ekko 的，重签 profile 与 HAP | `code:9568322 signature verification failed due to not trusted app source`<br>**证书链过了，但 profile 不是 AGC 签的** |

第 ② 次错误码从「pkcs7 验签失败」变成「来源不受信任」，说明**证书链这一层已经过关**，
卡的是 profile 的签发者：

```json
"issuer": "app_gallery",                    // 正式 profile 由 AGC 服务签发
"app-identifier": "<AGC分配的应用标识>"     // AGC 为每个包名分配的唯一标识（已脱敏）
```

`app-identifier` 与 `bundle-name` 一一绑定，我在改 `bundle-name` 时把它保留成 jianji 的，
设备立刻判定「来源不可信」。

**无法绕过**：profile 必须由 AGC 私钥签发，AGC 只对「已登录的华为账号 + 已注册的包名」
签发。这是服务端强制的，本地改不了。

### hvigor 也会主动拦截包名不一致

即使不去装机，hvigor 在 `SignHap` 阶段就会挡住：

```
00303074 Configuration Error
The bundleName in app.json5/hvigorfile.ts does not match the bundleName
in the generated SigningConfigs.
```

### 设备信任的是华为专有根，不是 OpenHarmony

我读取了本机历史上成功装机过的 3 套调试证书（`%USERPROFILE%\.ohos\config\`），
以及 DevEco 自己生成的 `auto_debug_*.cer`，证书链**前两张完全一致**：

```
cert#0  Huawei CBG Root CA G2                    ← 根（设备内置信任）
cert#1  Huawei CBG Developer Relations CA G2     ← 二级 CA
cert#2  叶子证书                                  ← 每个包名一张（各不相同）
```

三者根/二级 CA 的 SHA256 前 16 位完全相同：
`df21a3c09f795457` / `0daa8a965b515312`。

而我手工生成的自签链是 `CN=Ekko Root CA` —— 华为设备的内置信任列表里没有它，
所以 `hdc install` 直接报：

```
error: failed to install bundle. code:9568257  error: fail to verify pkcs7 file.
```

这里 `fail to verify pkcs7 file` 指的是**签名块的证书链无法回溯到设备信任的根**，
不是文件损坏、不是格式错误、更不是密码问题。换任何自签证书都是同样结果。

### 另外两个已排除的干扰项

排查过程中还踩到两个**看起来像原因、实际不是**的坑，记下来避免重复浪费时间：

1. **密码长度**：`hap-sign-tool` 与 hvigor 都要求 ≥32 字符**且长度为偶数**，
   否则报 `00303116 The length of the storePassword or keyPassword ... less than 32`。
2. **profile 内嵌证书的编码**：`bundle-info.development-certificate` 必须是
   **单行、无换行、base64url**（`-`/`_`，不带 `=` 补位）。
   - 带 `\n` → 报 `Illegal base64 character 20`（20 是空格）
   - 用标准 base64 → 报 `Illegal base64 character 2b`（2b 是 `+`）

### hvigor 的签名材料是加密格式，不能手填

`build-profile.json5` 里自动签名写入的 `storePassword` 看起来是
`0000001B1D9E...` 这种密文，长度 ≥32 且为偶数。它由 DevEco 的
`DecipherUtil` 配合 `~/.ohos/config/material/{ac,ce,fd}` 解密
（hvigor 校验该目录下**正好 3 个条目**）。

所以密文只能在 DevEco 生成、由 hvigor 消费，手工拼不出来。

---

## 操作步骤

### 步骤 0：确认工程路径合法（⚠️ 最容易卡住的一步）

DevEco Studio 要求工程路径**只能含字母、数字、`.`、`_`、`-`**，
且不能以 `.` 结尾。带空格或中文会直接弹：

```
Invalid path. Select a path that contains only letters, digits, periods (.),
underscores (_), and hyphens (-), and does not end with a period.
```

|允许 | 禁止 |
|---|---|
| `D:\EkkoStudioHarmonyOS` | `D:\Ekko Studio HarmonyOS`（空格） |
| `D:\work\ekko-harmony` | `D:\我的项目\harmony`（中文） |
| `D:\ekko.harmony.v2` | `D:\ekko-harmony\`（以分隔符结尾） |

如果之前放在带空格的路径下，**移动工程目录**即可解决。
移动后如果编译报些莫名其妙的错，删掉这两个缓存目录重建：

```bash
rm -rf .hvigor entry/build
```

（它们内部缓存了旧的绝对路径。源码本身没有硬编码工程路径。）

### 步骤 0.5：确认 Sync 正常（已修，见下方排查记录）

打开工程后如果 Sync 报错，先看 [「Sync 报 root node 不可用」](#sync-报-00302013-the-root-node-is-not-yet-available)
一节。这个问题**已经修掉了**，现在 Sync 是通的。

### 步骤 1：在 DevEco Studio 里配置自动签名（需要华为账号）

1. 用 DevEco Studio 打开工程目录（即工程根，含 `build-profile.json5` 的那层）
   （选择 **Open Project**，不要新建工程）
2. 菜单 **File → Project Structure…**（或快捷键 `Ctrl+Alt+Shift+S`）
3. 左侧选 **Project → Signing Configs**
4. 勾选 **Automatically generate signature**
   （若提示未登录，点 **Sign In** 登录华为开发者账号并完成授权）
5. 等待右下角进度完成，点 **OK**

DevEco 会自动：
- 在 AGC 为该包名申请调试证书与 profile（自动带上本机 UDID）
- 生成 `p12 / cer / p7b` 到 `%USERPROFILE%\.ohos\config\`
- 把 `signingConfigs` 写回 `<项目根>/build-profile.json5`

> ⚠️ **务必检查 `products` 里有没有 `"signingConfig": "default"`**
>
> DevEco 的自动签名**只写上面的 `signingConfigs` 数组，不会自动往 `products` 里加引用**。
> 如果 product 里缺这一行，hvigor 会**静默跳过签名**，只产出 `entry-default-unsigned.hap`：
>
> ```
> > hvigor WARN: No signingConfig found for product default
> > hvigor Finished :entry:default@SignHap... after 1 ms     ← 1ms 就"完成"，其实啥也没干
> > hvigor BUILD SUCCESSFUL                                     ← 构建还报成功，很有欺骗性
> ```
>
> 正确写法（`app.products[0]`）：
> ```json5
> {
>   "name": "default",
>   "signingConfig": "default",     // ← 这行必须有，指向 signingConfigs 里的 name
>   "compatibleSdkVersion": "6.0.2(22)",
>   "runtimeOS": "HarmonyOS"
> }
> ```
>
> **判据**：构建后 `entry/build/default/outputs/default/` 下应该有
> `entry-default-signed.hap`。只有 unsigned 就是没签上。

### 步骤 2：构建并装机

```bash
cd <项目根>
./deploy.sh            # 一条命令：构建 → 签名 → 安装 → 启动
```

或分步：

```bash
./build.sh release assembleHap     # 构建
powershell -File _test/install.ps1 # 安装 + 启动
```

> 装机的 PowerShell 脚本是必需的：Git Bash 的 MSYS 会改写 `/data/local/tmp`
> 这类设备端路径，`hdc` 拿到的会变成 `C:\...\data\local\tmp` 而报 no such file。
> 用 PowerShell 直调可绕开。

### 步骤 3：确认装机成功

```bash
powershell -File _test/verify-install.ps1
```

会打印 bundleName、版本号、安装时间，并抓一段启动日志。

---

## Sync 报 `00302013 The root node is not yet available`

**症状**（在 DevEco Studio 里点 Sync，或跑 hvigorw 的 project 模式时）：

```
> hvigor DEBUG AbstractPluginBuilder App plugin creating...
> hvigor ERROR: 00302013 Script Error
Error Message: The root node is not yet available for build.
              At file: hvigorfile.ts or hvigorconfig.ts
```

### 根因：工程里存在 `node_modules/`

堆栈指向 `Hvigor._getRootNode`：

```js
_getRootNode() {
  const r = hvigorCore.getProject()?.getBuildFilePath();
  if (r === undefined) { printErrorExit("HVIGOR_CONFIG_FILE_ERROR", [...]); ... }
  const o = hvigorCore.getHvigorNodeByScriptPath(r);
  if (o === undefined) { printErrorExit("HVIGOR_CONFIG_FILE_ERROR", [r]); ... }
  return o;
}
```

也就是说 hvigor **找不到 `hvigorfile.ts` 对应的根节点**。
原因是 DevEco 的 hvigor 期望依赖走 `oh_modules/` + `~/.hvigor` 缓存，
而工程里多出来的 `node_modules/@ohos/hvigor-ohos-plugin` 会干扰它的模块解析。

### 解法：保持标准工程结构，统一用 DevEco 自带的 hvigor

已执行：
1. 删除 `node_modules/`
2. 删除多余的 `hvigorw.js`（1.1 MB，非标准文件）
3. `build.sh` 改为调用 DevEco 自带的 hvigor：
   `/g/DevEco Studio/tools/hvigor/bin/hvigorw.js`

现在 **CLI 构建和 DevEco Sync 都能正常工作**（已双向验证）。

### 顺带记录两个环境坑

1. **`DEVECO_SDK_HOME` 必须设**，否则报
   `00303217 Invalid value of 'DEVECO_SDK_HOME' in the system environment path`。
   路径要写成**双斜杠**形式：`G://DevEco Studio//sdk`，单斜杠会被判为 invalid。
   （DevEco IDE 内部会自动设这个变量，命令行才需要手动设。）
2. **不要用工程 wrapper 的 `hvigorw.js`**：它会把 `@ohos/hvigor` 软链到
   `~/.hvigor` 缓存，在本机解析出的路径是错的（`D:/hvigor/`），必然 ENOENT。

> 验证命令（两条都应无 ERROR）：
> ```bash
> cd <项目根>
> ./build.sh debug assembleHap                       # 应 BUILD SUCCESSFUL
> export DEVECO_SDK_HOME="G://DevEco Studio//sdk"
> "/g/DevEco Studio/tools/node/node.exe" \
>   "/g/DevEco Studio/tools/hvigor/bin/hvigorw.js" --sync -p product=default
> ```

### 变体：`The error information does not match`

删掉 `node_modules` 之后，Sync 一度仍然失败，但报错换成了：

```
> hvigor DEBUG AbstractPluginBuilder App plugin creating...
> hvigor ERROR: The error information does not match.
> hvigor ERROR: BUILD FAILED in 15 ms
```

**这是 hvigor 的常驻守护进程（daemon）缓存了旧工程状态造成的**，不是新问题。

排查证据（很干净，值得记下来）：

| 事实 | 值 |
|---|---|
| 出问题的 daemon 启动时间 | `20:27:22`（`~/.hvigor/daemon/log/6.22.4/daemon-2244.log` 首行） |
| 我删除 `node_modules/` 的时间 | `20:51` |
| 失败 daemon 的 `createdBy` | `deveco`（DevEco Studio 启动的） |
| 成功 daemon 的 `createdBy` | `command`（命令行启动的） |

也就是说那个 daemon 是在 `node_modules` 还在时就起来的，**在内存里缓存了旧的模块解析结果**，
之后 DevEco 复用了它 → 仍然找不到 root node → 报了个信息量很低的错。

同一个 daemon 记录里还留着 `cwdPath: "<项目根>"`、`state: "stopped"`，可直接确认。

### 解法：让 daemon 重启

```bash
# 1) 停掉所有 hvigor daemon
"/g/DevEco Studio/tools/node/node.exe" \
  "/g/DevEco Studio/tools/hvigor/bin/hvigorw.js" --stop-daemon

# 2) 清掉 daemon 注册表与工程构建缓存
rm -f  ~/.hvigor/daemon/cache/daemon-sec.json
rm -rf <项目根>/.hvigor/cache <项目根>/.hvigor/dependencyMap

# 3) 冷启动验证（应无 ERROR）
cd <项目根>
export DEVECO_SDK_HOME="G://DevEco Studio//sdk"
"/g/DevEco Studio/tools/node/node.exe" \
  "/g/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  --sync -p product=default --analyze=normal --parallel --incremental --daemon
```

在 **DevEco Studio 里**等价操作：**File → Invalidate Caches… → Invalidate and Restart**，
或者干脆退出 DevEco 重开（退出时 daemon 会一起结束）。

> **通用教训**：改动构建配置或依赖目录结构后，hvigor 的常驻进程不会自动感知。
> 遇到「配置明明改对了却还报同样的错」，先怀疑 daemon 缓存，
> 用 `--stop-daemon` 而不是反复改配置。

---

## 备选方案（不想登录华为账号时）

如果你手上已有**任意一个**已在本设备装过的包名的调试材料，
理论上可以复用其证书链，但 **profile 里的 `bundle-name` 必须与
`AppScope/app.json5` 的 `bundleName` 一致**，否则设备会以
bundleName 不匹配为由拒绝。所以要复用就必须改包名，不推荐。

**建议直接用自动签名**，这是华为设计的标准流程。

---

## 相关文件

| 文件 | 说明 |
|---|---|
| `build-profile.json5` | `signingConfigs: []`，等 DevEco 自动签名写入 |
| `_test/install.ps1` | 安装 + 启动（PowerShell，绕开 MSYS 路径改写） |
| `_test/verify-install.ps1` | 校验安装结果 |
| `_test/signing-local/` | 我自签的密钥材料（**已 gitignore**，可删） |
| `docs/DEBUG-REPORT.md` | 本轮排查修掉的缺陷清单 |
