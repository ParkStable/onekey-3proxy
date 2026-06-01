#!/usr/bin/env bash
#
# 3proxy 安装 / 卸载脚本
#
# 用法:
#   安装:  sudo ./setup-3proxy.sh [install] [用户名] [密码] [HTTP端口] [SOCKS端口]
#          sudo ./setup-3proxy.sh admin mypass 8080 1080
#   卸载:  sudo ./setup-3proxy.sh uninstall
#
set -euo pipefail

# ---------------- 可调参数 ----------------
THREEPROXY_VERSION="0.9.6"
CFG_DIR="/etc/3proxy"
CFG_FILE="${CFG_DIR}/3proxy.cfg"
LOG_FILE="/var/log/3proxy.log"
SERVICE_FILE="/etc/systemd/system/3proxy.service"
SRC_URL="https://github.com/3proxy/3proxy/archive/refs/tags/${THREEPROXY_VERSION}.tar.gz"

# ---------------- 输出辅助 ----------------
info() { echo -e "\033[1;32m[*]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------- 基础检查 ----------------
[ "$(id -u)" -eq 0 ] || die "请使用 root 运行（例如: sudo $0 ...）。"

# 检测包管理器
detect_pm() {
  local pm
  for pm in apt-get dnf yum zypper pacman apk; do
    if command -v "$pm" >/dev/null 2>&1; then echo "$pm"; return 0; fi
  done
  echo ""
}
PM="$(detect_pm)"

# 用包管理器安装若干包
pm_install() {
  case "$PM" in
    apt-get) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)     dnf install -y "$@" ;;
    yum)     yum install -y "$@" ;;
    zypper)  zypper --non-interactive install -y "$@" ;;
    pacman)  pacman -Sy --noconfirm "$@" ;;
    apk)     apk add --no-cache "$@" ;;
    *)       return 1 ;;
  esac
}

# 用包管理器卸载若干包
pm_remove() {
  case "$PM" in
    apt-get) apt-get remove -y "$@" ;;
    dnf)     dnf remove -y "$@" ;;
    yum)     yum remove -y "$@" ;;
    zypper)  zypper --non-interactive remove "$@" ;;
    pacman)  pacman -Rns --noconfirm "$@" ;;
    apk)     apk del "$@" ;;
    *)       return 1 ;;
  esac
}

# 确保某个命令存在，不存在则尝试安装对应的包
ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
  warn "未找到命令 '$cmd'，尝试安装软件包 '$pkg' ..."
  [ -n "$PM" ] || die "未检测到受支持的包管理器，且缺少 '$cmd'，请手动安装后重试。"
  pm_install "$pkg" || die "安装 '$pkg' 失败，请手动安装后重试。"
  command -v "$cmd" >/dev/null 2>&1 || die "安装后仍找不到 '$cmd'。"
}

# 下载（优先 wget，其次 curl，都没有就尝试装一个）
download() {
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  else
    warn "未找到 wget 或 curl，尝试安装 ..."
    pm_install curl || pm_install wget || die "无法获取下载工具（wget/curl）。"
    download "$url" "$out"
  fi
}

# 查找 3proxy 可执行文件的真实路径
find_binary() {
  local p
  p="$(command -v 3proxy 2>/dev/null || true)"
  if [ -n "$p" ]; then echo "$p"; return 0; fi
  for p in /usr/local/bin/3proxy /usr/bin/3proxy /bin/3proxy /usr/local/3proxy/bin/3proxy; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# ---------------- 安装：包管理器 ----------------
install_from_pkg() {
  info "尝试通过包管理器 ($PM) 安装 3proxy ..."
  case "$PM" in
    apt-get) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y 3proxy ;;
    dnf)     dnf install -y epel-release 2>/dev/null || true; dnf install -y 3proxy ;;
    yum)     yum install -y epel-release 2>/dev/null || true; yum install -y 3proxy ;;
    zypper)  zypper --non-interactive install -y 3proxy ;;
    apk)     apk add --no-cache 3proxy ;;
    pacman)  return 1 ;;   # 官方源没有，交给源码编译
    *)       return 1 ;;
  esac
}

# ---------------- 安装：源码编译 ----------------
install_from_source() {
  info "改用源码编译安装 3proxy ${THREEPROXY_VERSION} ..."

  # 编译依赖
  if [ -n "$PM" ]; then
    case "$PM" in
      apt-get) pm_install build-essential || pm_install gcc make ;;
      dnf|yum) pm_install gcc make tar gzip ;;
      zypper)  pm_install gcc make tar gzip ;;
      pacman)  pm_install base-devel ;;
      apk)     pm_install build-base ;;
    esac
  fi

  ensure_cmd make
  ensure_cmd tar
  command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1 || ensure_cmd gcc

  local tmp tarball
  tmp="$(mktemp -d)"
  tarball="${tmp}/3proxy.tar.gz"

  info "下载源码: $SRC_URL"
  download "$SRC_URL" "$tarball"

  tar -xf "$tarball" -C "$tmp"
  cd "${tmp}/3proxy-${THREEPROXY_VERSION}"

  info "编译中 ..."
  make -f Makefile.Linux
  make -f Makefile.Linux install

  cd /
  rm -rf "$tmp"
}

# ---------------- 写配置 ----------------
write_config() {
  mkdir -p "$CFG_DIR"
  : > "$LOG_FILE" || true
  cat > "$CFG_FILE" <<EOF
log $LOG_FILE D
rotate 30
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
auth strong
users ${USER}:CL:${PASS}
allow ${USER}
proxy -p${HTTP_PORT} -a
socks -p${SOCKS_PORT} -a
EOF
  chmod 600 "$CFG_FILE"
}

# ---------------- 服务（systemd） ----------------
write_service() {
  local bin
  bin="$(find_binary)" || die "找不到已安装的 3proxy 可执行文件。"
  info "3proxy 路径: $bin"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "系统没有 systemd，跳过服务安装。"
    warn "可手动后台运行: nohup $bin $CFG_FILE >/dev/null 2>&1 &"
    return 0
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
ExecStart=${bin} ${CFG_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now 3proxy
}

# ---------------- 防火墙放行（去重） ----------------
open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${HTTP_PORT}/tcp"  >/dev/null 2>&1 || true
    ufw allow "${SOCKS_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp"  >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${SOCKS_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${HTTP_PORT}" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "${HTTP_PORT}" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p tcp --dport "${SOCKS_PORT}" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "${SOCKS_PORT}" -j ACCEPT 2>/dev/null || true
  fi
}

# ---------------- 取公网 IP ----------------
get_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4 -fsS --max-time 5 https://ip.gs 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    ip="$(wget -qO- --timeout=5 https://ip.gs 2>/dev/null || true)"
  fi
  [ -n "$ip" ] && echo "$ip" || echo "<服务器IP>"
}

# 从配置文件解析端口（卸载时清理防火墙用）
get_port() { # $1 = proxy|socks
  [ -f "$CFG_FILE" ] || return 0
  awk -v k="$1" '$1==k { for(i=1;i<=NF;i++) if($i ~ /^-p[0-9]+$/){ sub(/^-p/,"",$i); print $i; exit } }' "$CFG_FILE"
}

# ---------------- 安装主流程 ----------------
do_install() {
  info "开始安装 3proxy（用户=${USER} HTTP=${HTTP_PORT} SOCKS=${SOCKS_PORT}）"

  if find_binary >/dev/null 2>&1; then
    info "检测到系统已存在 3proxy，跳过安装步骤。"
  elif [ -n "$PM" ] && install_from_pkg; then
    info "包管理器安装成功。"
  else
    [ -n "$PM" ] && warn "包管理器中没有 3proxy 或安装失败。"
    install_from_source
  fi

  find_binary >/dev/null 2>&1 || die "安装结束但仍找不到 3proxy 可执行文件。"

  write_config
  write_service
  open_firewall

  local ip; ip="$(get_ip)"
  echo ""
  info "安装完成 ✓"
  echo "  HTTP:   curl -x http://${USER}:${PASS}@${ip}:${HTTP_PORT} https://ip.gs"
  echo "  SOCKS5: curl --socks5-hostname ${USER}:${PASS}@${ip}:${SOCKS_PORT} https://ip.gs"
  if command -v systemctl >/dev/null 2>&1; then
    echo "  状态:   systemctl status 3proxy"
  fi
}

# ---------------- 卸载主流程 ----------------
do_uninstall() {
  info "开始卸载 3proxy ..."

  # 先从配置读端口，用于清理防火墙
  local hp sp
  hp="$(get_port proxy)"; sp="$(get_port socks)"
  hp="${hp:-$HTTP_PORT}"; sp="${sp:-$SOCKS_PORT}"

  # 停止并移除服务
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now 3proxy 2>/dev/null || true
  fi
  if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    info "已移除 systemd 服务。"
  fi

  # 清理防火墙规则
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${hp}/tcp"  >/dev/null 2>&1 || true
    ufw delete allow "${sp}/tcp"  >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${hp}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-port="${sp}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -D INPUT -p tcp --dport "${hp}" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport "${sp}" -j ACCEPT 2>/dev/null || true
  fi

  # 卸载软件包（若是包管理器安装的）
  if [ -n "$PM" ]; then
    pm_remove 3proxy 2>/dev/null || true
  fi

  # 删除源码编译产物（通常在 /usr/local/bin）
  for p in /usr/local/bin/3proxy /usr/local/3proxy/bin/3proxy; do
    [ -e "$p" ] && rm -f "$p"
  done

  # 删除配置与日志
  rm -rf "$CFG_DIR"
  rm -f "$LOG_FILE"

  echo ""
  info "卸载完成 ✓"
  warn "如当初通过源码编译，make install 可能还放置了 proxy/socks 等附带程序，"
  warn "如需彻底清理请检查 /usr/local/bin 与 /usr/local/etc。"
  warn "编译依赖（gcc/make 等）未自动移除，以免影响其它程序。"
}

# ---------------- 参数解析 ----------------
ACTION="install"
case "${1:-}" in
  uninstall|remove|-u) ACTION="uninstall"; shift ;;
  install)             shift ;;
esac

USER="${1:-admin}"
PASS="${2:-changeme}"
HTTP_PORT="${3:-8080}"
SOCKS_PORT="${4:-1080}"

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
esac