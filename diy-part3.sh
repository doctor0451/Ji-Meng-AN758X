#!/bin/bash
# ================================================================
# diy-part3.sh —— 补充插件 / 主题 / Docker 支持
# 运行目录：ponwrt 源码根目录
# 执行时机：diy-part1.sh 之后、diy-part2.sh 之前
#
# 开关（环境变量覆盖）：
#   INSTALL_PLUGINS  : true  (plugin.txt 里的插件，默认装)
#   INSTALL_CARBON   : true  (luci-theme-carbon，默认装)
#   DOCKER_KERNEL    : true  (Docker 内核支持，通过 dockerd 包依赖带出，默认开)
#   DOCKER_USERLAND  : false (docker-compose + luci-app-dockerman，默认关)
# ================================================================
set -euo pipefail

PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

: "${INSTALL_PLUGINS:=true}"
: "${INSTALL_CARBON:=true}"
: "${DOCKER_KERNEL:=true}"
: "${DOCKER_USERLAND:=false}"

# plugin.txt 定位：优先脚本同目录上一级，其次 GITHUB_WORKSPACE
PLUGIN_FILE="$(dirname "$0")/../plugin.txt"
[ -f "$PLUGIN_FILE" ] || PLUGIN_FILE="${GITHUB_WORKSPACE:-.}/plugin.txt"
[ -f "$PLUGIN_FILE" ] || { echo "::error::plugin.txt 不存在"; exit 1; }

echo "=========================================="
echo "diy-part3.sh 开始"
echo "  插件=$INSTALL_PLUGINS  Carbon=$INSTALL_CARBON  Docker内核=$DOCKER_KERNEL  Docker用户态=$DOCKER_USERLAND"
echo "=========================================="

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="${3:-}"
  [ -d "$dir" ] && { echo "已存在，跳过: $dir"; return 0; }
  echo "--- git clone $url -> $dir ---"
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir" 2>&1 | tail -3
  else
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -3
  fi
  [ -d "$dir" ] && { echo "✅ 克隆成功: $dir"; return 0; }
  echo "::error::克隆失败: $url"
  return 1
}

# 把 CONFIG_PACKAGE_<pkg>=y 写入 .config（去重：先删旧行）
enable_pkg() {
  local pkg="$1"
  sed -i "/^CONFIG_PACKAGE_${pkg}=/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config 2>/dev/null || true
  echo "CONFIG_PACKAGE_${pkg}=y" >> .config
  echo "  ✅ ${pkg}=y"
}

# ---------------------------------------------------------
# 1. 解析 plugin.txt
# ---------------------------------------------------------
# 三类：luci插件（需要 LuCI 前端）/ 插件（纯二进制）/ 主题
# '#' 开头为注释，跳过。
# 非 luci 插件名 → 实际包名映射（feeds 里名字可能不同）
declare -A BIN_MAP=(
  [usteer]="usteer"
  [btop]="btop"
)

parse_and_enable() {
  local section="" raw line pkg
  while IFS= read -r raw; do
    line="${raw%%#*}"                       # 去行内注释
    line="$(printf '%s' "$line" | xargs)"   # trim
    [ -z "$line" ] && continue

    case "$line" in
      *luci插件*) section="luci" ; continue ;;
      *插件*)     section="bin"  ; continue ;;
      *主题*)     section="theme"; continue ;;
    esac

    case "$section" in
      luci)
        pkg="${BIN_MAP[$line]:-luci-app-$line}"
        enable_pkg "$pkg"
        ;;
      bin)
        pkg="${BIN_MAP[$line]:-$line}"
        enable_pkg "$pkg"
        ;;
      theme)
        case "$line" in
          Argon)  enable_pkg "luci-theme-argon" ;;
          Carbon) : ;;   # 第 2 节单独处理（需要 clone）
          *)      echo "::warning::未知主题: $line" ;;
        esac
        ;;
      *)
        echo "::warning::未识别分类行: $line"
        ;;
    esac
  done < "$PLUGIN_FILE"
}

if [ "$INSTALL_PLUGINS" = "true" ]; then
  echo "--- 解析 plugin.txt ---"
  parse_and_enable
fi

# ---------------------------------------------------------
# 2. luci-theme-carbon（唯一需要 clone 的，根目录即包）
# ---------------------------------------------------------
# 默认分支为 main，显式指定，不依赖远程 HEAD 指向
if [ "$INSTALL_CARBON" = "true" ]; then
  if ! clone https://github.com/mrjoechen/luci-theme-carbon "$PKG_DIR/luci-theme-carbon" main; then
    echo "::error::luci-theme-carbon 拉取失败"
    exit 1
  fi
  if [ ! -f "$PKG_DIR/luci-theme-carbon/Makefile" ]; then
    echo "::error::$PKG_DIR/luci-theme-carbon/Makefile 不存在，包无法被索引"
    exit 1
  fi
  enable_pkg "luci-theme-carbon"
fi

# ---------------------------------------------------------
# 3. Docker 内核支持
# ---------------------------------------------------------
# dockerd / containerd 的 DEPENDS 与 Config.in 会自动 select
# 所需内核符号（KERNEL_CGROUP_* / kmod-veth / kmod-nf-nat 等），
# 故只需打开 dockerd，内核支持随依赖带出，不必手改内核 config。
if [ "$DOCKER_KERNEL" = "true" ]; then
  echo "--- Docker 内核支持（通过 dockerd 依赖带出）---"
  enable_pkg "dockerd"
  enable_pkg "containerd"
fi

# ---------------------------------------------------------
# 4. Docker 用户态（默认关闭）
# ---------------------------------------------------------
if [ "$DOCKER_USERLAND" = "true" ]; then
  echo "--- Docker 用户态 ---"
  enable_pkg "docker-compose"
  enable_pkg "luci-app-dockerman"
fi

# ---------------------------------------------------------
# 5. 包索引重建 + 校验（同 diy-part1.sh 的判据）
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  echo "--- 重建包索引 ---"
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/info/.files* 2>/dev/null
  find "$PKG_DIR" -type f -exec touch {} + 2>/dev/null || true

  echo ">>> make prepare-tmpinfo"
  make prepare-tmpinfo OPENWRT_BUILD= V=s 2>&1 | tail -30
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "::error::prepare-tmpinfo 失败"
    exit 1
  fi

  # 硬校验：Carbon 必须进索引
  if [ "$INSTALL_CARBON" = "true" ] && \
     ! grep -qx "Package: luci-theme-carbon" tmp/.packageinfo 2>/dev/null; then
    echo "::error::luci-theme-carbon 未进 tmp/.packageinfo"
    for f in logs/package/custom/luci-theme-carbon/dump.txt \
             logs/package/luci-theme-carbon/dump.txt; do
      [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
    done
    exit 1
  fi
  echo "✅ 索引校验通过"
else
  echo "package/custom 为空，跳过索引重建"
fi

echo "🎉 diy-part3.sh 执行完毕"
