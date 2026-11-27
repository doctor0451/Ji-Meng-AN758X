#!/bin/bash
# ================================================================
# diy-part3.sh —— 补充插件 / 主题 / Docker 支持
# 执行时机：Load custom configuration 和 Apply device profile 之后，defconfig 之前
# ================================================================
set -euo pipefail

PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

: "${INSTALL_PLUGINS:=true}"
: "${INSTALL_CARBON:=true}"
: "${DOCKER_KERNEL_ENABLED:=true}"
: "${DOCKER_APPS_ENABLED:=false}"

# 查找 plugin.txt
PLUGIN_FILE="$(dirname "$0")/../plugin.txt"
[ -f "$PLUGIN_FILE" ] || PLUGIN_FILE="${GITHUB_WORKSPACE:-.}/plugin.txt"
if [ ! -f "$PLUGIN_FILE" ]; then
    echo "::warning::plugin.txt 不存在，跳过插件解析"
fi

echo "=========================================="
echo "diy-part3.sh 开始"
echo "  插件=$INSTALL_PLUGINS  Carbon=$INSTALL_CARBON"
echo "  Docker内核=$DOCKER_KERNEL_ENABLED  Docker用户态=$DOCKER_APPS_ENABLED"
echo "=========================================="

# 确保 .config 存在
[ -f .config ] || : > .config

# ---------------------------------------------------------
# 通用配置函数：修改或追加配置项（去重）
# 用法：set_config CONFIG_KERNEL_CGROUPS y
# ---------------------------------------------------------
set_config() {
  local sym="$1"
  local val="$2"
  # 删除旧值（无论是 =y 还是 # ... is not set）
  sed -i "/^${sym}=/d; /^# ${sym} is not set/d" .config 2>/dev/null || true
  # 追加新值
  echo "${sym}=${val}" >> .config
  echo "  ✅ ${sym}=${val}"
}

# 包装一层设置 Package 的函数
enable_pkg() {
  set_config "CONFIG_PACKAGE_$1" "y"
}

clone() {
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

# ---------------------------------------------------------
# 1. 解析 plugin.txt
# ---------------------------------------------------------
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
        pkg="luci-app-$line"
        enable_pkg "$pkg"
        ;;
      bin)
        pkg="$line"
        enable_pkg "$pkg"
        ;;
      theme)
        case "$line" in
          Argon)  enable_pkg "luci-theme-argon" ;;
          Carbon) : ;;   # 第 2 节单独处理
          *)      echo "::warning::未知主题: $line" ;;
        esac
        ;;
    esac
  done < "$PLUGIN_FILE"
}

if [ "$INSTALL_PLUGINS" = "true" ] && [ -f "$PLUGIN_FILE" ]; then
  echo "--- 解析 plugin.txt ---"
  parse_and_enable
fi

# ---------------------------------------------------------
# 2. luci-theme-carbon
# ---------------------------------------------------------
if [ "$INSTALL_CARBON" = "true" ]; then
  if ! clone https://github.com/mrjoechen/luci-theme-carbon "$PKG_DIR/luci-theme-carbon" main; then
    echo "::error::luci-theme-carbon 拉取失败"
    exit 1
  fi
  if [ ! -f "$PKG_DIR/luci-theme-carbon/Makefile" ]; then
    echo "::error::$PKG_DIR/luci-theme-carbon/Makefile 不存在"
    exit 1
  fi
  enable_pkg "luci-theme-carbon"
fi

# ---------------------------------------------------------
# 3. 启用 Docker 内核支持
# ---------------------------------------------------------
if [ "$DOCKER_KERNEL_ENABLED" = "true" ]; then
    echo "Docker 内核支持已启用，开始配置..."
    set_config CONFIG_KERNEL_CGROUPS           y
    set_config CONFIG_KERNEL_NAMESPACES        y
    set_config CONFIG_KERNEL_CGROUP_DEVICE     y
    set_config CONFIG_KERNEL_MEMCG             y
    set_config CONFIG_KERNEL_CGROUP_FREEZER    y
    set_config CONFIG_KERNEL_CGROUP_PIDS       y
    set_config CONFIG_KERNEL_VETH              y
    set_config CONFIG_KERNEL_BRIDGE            y
    set_config CONFIG_KERNEL_OVERLAY_FS        y
    set_config CONFIG_KERNEL_IPVLAN            y

    for kmod in \
        kmod-veth \
        kmod-ipt-nat \
        kmod-ipt-nat6 \
        kmod-ipt-physdev \
        kmod-ipt-extra \
        kmod-nf-ipvs \
        kmod-br-netfilter \
        kmod-nft-compat \
        kmod-dm \
        kmod-fs-ext4 \
        kmod-fs-btrfs \
        kmod-ipvlan \
    ; do
        enable_pkg "$kmod"
    done
    echo "Docker 内核支持配置完成。"
else
    echo "Docker 内核支持未启用，跳过。"
fi

# ---------------------------------------------------------
# 4. 启用 Docker 用户态软件（默认关闭）
# ---------------------------------------------------------
if [ "$DOCKER_APPS_ENABLED" = "true" ]; then
    echo "Docker 用户态软件已启用，开始配置..."
    for pkg in \
        docker \
        dockerd \
        docker-compose \
        luci-app-dockerman \
        luci-i18n-dockerman-zh-cn \
    ; do
        enable_pkg "$pkg"
    done
    echo "Docker 用户态软件配置完成。"
else
    echo "Docker 用户态软件未启用，跳过。"
fi

# ---------------------------------------------------------
# 4.5 针对 h3c_hm2004-du 补齐基础依赖（修复 fitblk 缺失问题）
# ---------------------------------------------------------
if [ "${PROFILE:-}" = "h3c_hm2004-du" ]; then
    echo "--- 针对 h3c_hm2004-du 补齐可能缺失的基础依赖 ---"
    # 补全依赖，防止 fitblk 因为底层包没选上而被 defconfig 剔除
    enable_pkg "libblkid"
    enable_pkg "libubootenv"
    enable_pkg "fitblk"
    # 尝试补全 diy-part1.sh 拉取的私有仓库依赖
    enable_pkg "kmod-fiberhome-fsl" || true
fi

# ---------------------------------------------------------
# 5. 包索引重建 + 校验
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  echo "--- 重建包索引（让 Carbon 等新克隆的包被 defconfig 识别）---"
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/info/.files* 2>/dev/null
  find "$PKG_DIR" -type f -exec touch {} + 2>/dev/null || true

  make prepare-tmpinfo OPENWRT_BUILD= V=s 2>&1 | tail -30
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "::error::prepare-tmpinfo 失败"
    exit 1
  fi
fi

echo "🎉 diy-part3.sh 执行完毕"
