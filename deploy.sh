#!/bin/bash
# 一键部署到真机：构建 → 校验签名 → 安装 → 启动
#
# 前置条件：已在 DevEco Studio 里配置「自动签名」，且
#           build-profile.json5 里同时有 signingConfigs 和 products[].signingConfig。
# 原理与踩坑见 docs/SIGNING.md。
set -o pipefail

cd "$(dirname "$0")"

# 工程根目录 —— **自动推导，不写死绝对路径**。
# 之前这里写死过绝对路径（<项目根>），工程一移动就失效（而工程路径恰恰不能带空格，
# 见 docs/SIGNING.md 步骤 0，必须允许随意放置）。
PROJECT_ROOT_POSIX="$(pwd)"                                   # MSYS 风格：/d/xxx
PROJECT_ROOT_WIN="$(pwd -W 2>/dev/null || pwd)"               # Windows 风格：D:/xxx
# Windows 风格要转成反斜杠给 PowerShell 用
PROJECT_ROOT_BACKSLASH=$(printf '%s' "$PROJECT_ROOT_WIN" | sed 's|/|\\|g')

# ⚠ 路径要准备两份：
#   HDC     —— bash 用的 MSYS 风格（/g/...）
#   HDC_WIN —— PowerShell 用的 Windows 风格（G:\...）
# 把 /g/... 直接传进 PowerShell 会静默失败（找不到可执行文件，
# 2>&1 也被 $ErrorActionPreference 吞掉 → 表现为"安装结果："后面空无一物）。
# P2-SEQ7-⑥： hdc 路径优先从环境变量读取，避免换机器/换盘符失效。
#   优先级：HDC_HOME（sdk 的父目录）→ DEVECO_SDK_HOME（sdk 目录本身）
#           → 旧硬编码默认值（本机 G 盘，保留兜底兼容）。
#   先只解出 POSIX 路径 $HDC，再统一转成 Windows 风格 $HDC_WIN，
#   保证两份路径必然同源（分开推导曾出现 win 版拿到空串的缺口）。
HDC_TOOLCHAIN='sdk/default/openharmony/toolchains/hdc.exe'
HDC="/g/DevEco Studio/${HDC_TOOLCHAIN}"
if [ -n "${HDC_HOME:-}" ] && [ -f "${HDC_HOME}/${HDC_TOOLCHAIN}" ]; then
  HDC="${HDC_HOME}/${HDC_TOOLCHAIN}"
elif [ -n "${DEVECO_SDK_HOME:-}" ] && [ -f "${DEVECO_SDK_HOME}/${HDC_TOOLCHAIN}" ]; then
  # DEVECO_SDK_HOME 直指 sdk 目录（含 default/、openharmony/）
  HDC="${DEVECO_SDK_HOME}/${HDC_TOOLCHAIN}"
fi
if [ ! -f "$HDC" ]; then
  echo "✗ 找不到 hdc: $HDC"
  echo "  请设置 HDC_HOME 或 DEVECO_SDK_HOME，或确认 DevEco Studio 安装位置"
  exit 1
fi
# POSIX → Windows 风格（PowerShell 用反斜杠）。cygpath 优先，没有就 sed 兜底。
HDC_WIN=$(cygpath -w "$HDC" 2>/dev/null) || HDC_WIN=''
if [ -z "$HDC_WIN" ]; then
  # /g/x → G:\x。先把双斜杠归一，再整体替换
  HDC_WIN=$(printf '%s' "$HDC" | sed 's|//*|/|g; s|^/\([a-zA-Z]\)/|\1:\\|g; s|/|\\|g')
fi
BUNDLE="com.ekkostudio.harmony"
ABILITY="EntryAbility"
# 临时 PowerShell 脚本必须放在 Windows 看得见的路径。
# 坑：Git Bash 的 /tmp 与 Windows 文件视图不互通，PowerShell -File /tmp/x.ps1 会报
# "文件不存在"，脚本静默失败（表现为"安装结果："后面什么都没有）。
TMP_PS_DIR="${PROJECT_ROOT_POSIX}/_test"
# bash 检查文件存在性用正斜杠；传给 hdc 必须反斜杠 ——
# hdc 会把 "D:/x/y.hap" 当成相对路径拼到 cwd 后面，报
# "no such file or directory, path:<cwd>\D:/x/y.hap"。
OUT_DIR="${PROJECT_ROOT_POSIX}/entry/build/default/outputs/default"
OUT_WIN="${PROJECT_ROOT_BACKSLASH}\\entry\\build\\default\\outputs\\default"

rm -f "$TMP_PS_DIR"/.tmp-*.ps1 2>/dev/null

echo "==> 1/7 检查设备"
# 多设备在线时优先选真机：hdc list targets 中模拟器形如 127.0.0.1:5555（含冒号），
# 真机 UDID 不含冒号。可用环境变量 HDC_TARGET 显式覆盖目标设备。
if [ -n "${HDC_TARGET:-}" ]; then
  DEV="$HDC_TARGET"
else
  DEV=$("$HDC" list targets 2>/dev/null | tr -d '\r' | awk 'NF && $0 !~ /:/ {print $1; exit}')
fi
if [ -z "$DEV" ]; then
  # 没有真机时回退到列表第一台（通常是模拟器）
  DEV=$("$HDC" list targets 2>/dev/null | head -1 | tr -d '\r\n ')
fi
if [ -z "$DEV" ]; then
  echo "✗ 没有检测到设备。请确认已开启 USB 调试并授权本机。"
  exit 1
fi
echo "   设备: $DEV"

echo "==> 2/7 配置端口转发（幂等：先清理，再建立 rport）"
# App 默认地址 127.0.0.1:8748 在真机上指向手机自身，须通过 hdc 反向端口转发
# 才能访问宿主后端。rport = 设备监听 → 转发到宿主；fport = 宿主监听 → 设备。
# 若之前误用 fport tcp:8748 tcp:8748，宿主 127.0.0.1:8748 会被 hdc 抢占监听、
# 遮住本机服务。实测 hdc 的 fport rm 可同时移除 forward 与 reverse 规则，
# 故幂等清理只保留一条 fport rm（rm 失败＝该映射本就不存在，忽略即可）。
# 多设备时必须用 -t "$DEV" 指定目标设备，否则 hdc 报 "need connect-key"。
"$HDC" -t "$DEV" fport rm tcp:8748 tcp:8748 2>/dev/null || true
if "$HDC" -t "$DEV" rport tcp:8748 tcp:8748 >/dev/null 2>&1; then
  echo "   ✓ rport tcp:8748 → 宿主 8748 已建立"
else
  echo "   ⚠ rport 建立失败（不影响安装/启动，但 App 内「测试连接」会不通）"
fi

echo "==> 3/7 检查签名配置"
if grep -qE '"signingConfigs"\s*:\s*\[\s*\]' build-profile.json5; then
  echo "✗ signingConfigs 为空，无法产出可安装的包。"
  echo "  请在 DevEco Studio 里执行：File → Project Structure → Signing Configs"
  echo "  → 勾选 Automatically generate signature → 登录华为账号 → OK"
  echo "  详见 docs/SIGNING.md"
  exit 1
fi
if ! grep -qE '"signingConfig"\s*:\s*"default"' build-profile.json5; then
  echo "✗ products 里缺 \"signingConfig\": \"default\" 引用。"
  echo "  DevEco 的自动签名只写 signingConfigs，不会自动加这个引用；"
  echo "  缺了它 hvigor 会静默跳过签名，只产出 unsigned 包。"
  echo "  详见 docs/SIGNING.md「自动签名后仍产出 unsigned 包」一节。"
  exit 1
fi
echo "   签名配置完整"

echo "==> 4/7 构建 ${1:-release} 包"
MODE="${1:-release}"
BUILD_LOG="$TMP_PS_DIR/.tmp-build.log"
./build.sh "$MODE" assembleHap > "$BUILD_LOG" 2>&1
if ! grep -q "BUILD SUCCESSFUL" "$BUILD_LOG"; then
  echo "✗ 构建失败："
  grep -E "Error Message|ERROR" "$BUILD_LOG" | head -10
  exit 1
fi
echo "   构建成功"

echo "==> 5/7 校验产物"
HAP_BASH=""
HAP_WIN=""
if [ -f "$OUT_DIR/entry-default-signed.hap" ]; then
  HAP_BASH="$OUT_DIR/entry-default-signed.hap"
  HAP_WIN="$OUT_WIN\\entry-default-signed.hap"
  echo "   ✓ 已签名包 $(stat -c%s "$HAP_BASH") bytes"
else
  echo "✗ 只找到 unsigned 包，签名没生效。"
  echo "  检查构建日志里是否有：WARN: No signingConfig found for product default"
  grep -n "No signingConfig" "$BUILD_LOG" | head -2
  exit 1
fi

echo "==> 6/7 安装"
cat > "$TMP_PS_DIR/.tmp-install.ps1" <<PS
\$ErrorActionPreference = "SilentlyContinue"
\$hdc = "$HDC_WIN"
\$dev = "$DEV"
\$r = & \$hdc -t \$dev install -r "$HAP_WIN" 2>&1
Write-Output (\$r | Out-String)
PS
INSTALL_OUT=$(powershell -NoProfile -ExecutionPolicy Bypass -File "$TMP_PS_DIR/.tmp-install.ps1" 2>&1)
if echo "$INSTALL_OUT" | grep -qE "install bundle successfully"; then
  echo "   ✓ 安装成功"
else
  echo "   ✗ 安装失败："
  echo "$INSTALL_OUT" | grep -vE "^\s*$" | head -6
  rm -f "$TMP_PS_DIR"/.tmp-*.ps1
  exit 1
fi

echo "==> 7/7 启动"
cat > "$TMP_PS_DIR/.tmp-launch.ps1" <<PS
\$ErrorActionPreference = "SilentlyContinue"
\$hdc = "$HDC_WIN"
\$dev = "$DEV"
\$s = & \$hdc -t \$dev shell aa start -a $ABILITY -b $BUNDLE 2>&1
Write-Output (\$s | Out-String)
PS
LAUNCH_OUT=$(powershell -NoProfile -ExecutionPolicy Bypass -File "$TMP_PS_DIR/.tmp-launch.ps1" 2>&1)
if echo "$LAUNCH_OUT" | grep -qE "start ability successfully"; then
  echo "   ✓ 已启动"
elif echo "$LAUNCH_OUT" | grep -qE "screen is locked"; then
  echo "   ⚠ 设备锁屏，无法启动。请先解锁屏幕（开发者模式下 hdc 不能自动解锁）。"
else
  echo "   ✗ 启动失败："
  echo "$LAUNCH_OUT" | grep -vE "^\s*$" | head -5
fi

rm -f "$TMP_PS_DIR"/.tmp-*.ps1
echo ""
echo "完成。"
echo "  查看运行日志: powershell -File _test/log.ps1"
echo "  检查崩溃:     powershell -File _test/log.ps1 -Crash"
