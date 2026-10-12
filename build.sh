#!/bin/bash
# 鸿蒙构建统一入口。
#
# 为什么用 DevEco 自带的 hvigor，而不是工程内 node_modules 里的那份
# ------------------------------------------------------------------
# 工程里如果存在 `node_modules/`，DevEco Studio 的 Sync（以及 hvigorw 的
# project 模式）会报：
#     00302013 Script Error
#     The root node is not yet available for build.
# 原因是 DevEco 的 hvigor 期望依赖走 `oh_modules/` + `~/.hvigor` 缓存，
# 工程里多出来的 `node_modules/@ohos/hvigor-ohos-plugin` 会干扰它的模块解析，
# 导致它找不到根节点（hvigorfile.ts 对应的 node）。
#
# 所以本工程保持标准结构：不装 node_modules，统一用 DevEco 的 hvigor。
# 这样 IDE 能正常 Sync（才能配自动签名），命令行也能构建。
#
# 另外两个坑：
#   1. DEVECO_SDK_HOME 必须设，且路径要写成双斜杠形式（"G://DevEco Studio//sdk"），
#      单斜杠会被 hvigor 判定为 invalid value。
#   2. 构建任务是位置参数：assembleHap / assembleApp / clean，不能只靠 -p 传。
set -o pipefail
cd "$(dirname "$0")"

# P2-6：路径优先从环境变量读取，避免硬编码本机路径导致换机器失效。
# DEVECO_SDK_HOME 默认指向 DevEco Studio 6.0.2 安装目录（双斜杠形式）。
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-G://DevEco Studio//sdk}"
export HOS_SDK_HOME="${HOS_SDK_HOME:-G://DevEco Studio//sdk//default}"
export NODE_HOME="${NODE_HOME:-G://DevEco Studio//tools//node}"

# NODE 优先使用 DevEco 自带 node，找不到再退回系统 PATH 中的 node
if [ -f "$NODE_HOME/node.exe" ]; then
  NODE="$NODE_HOME/node.exe"
elif command -v node >/dev/null 2>&1; then
  NODE="$(command -v node)"
else
  echo "✗ 找不到 node，请确认 DevEco Studio 已安装或 node 在 PATH 中"
  exit 1
fi

HVIGOR="$DEVECO_SDK_HOME/../tools/hvigor/bin/hvigorw.js"
if [ ! -f "$HVIGOR" ]; then
  # 退回硬编码路径（兼容旧环境）
  HVIGOR="G:/DevEco Studio/tools/hvigor/bin/hvigorw.js"
fi

MODE="${1:-debug}"
shift 2>/dev/null
TASK="${1:-assembleHap}"

if [ ! -f "$HVIGOR" ]; then
  echo "✗ 找不到 hvigor: $HVIGOR"
  echo "  请确认 DevEco Studio 安装在 G:\\DevEco Studio"
  exit 1
fi

"$NODE" "$HVIGOR" \
  --mode module \
  -p product=default \
  -p module=entry@default \
  -p buildMode="$MODE" \
  --no-daemon \
  "$TASK" 2>&1
