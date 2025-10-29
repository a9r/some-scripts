#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# =============================================
# Debian PPTP 一键安装与配置脚本
# 参考：
# - https://github.com/Saleh7/Auto_Setup_VPN_PPTP_Server_Ubuntu-Debian/blob/master/pptp.sh
# - https://www.chiark.greenend.org.uk/~ajlanes/free/pptp-debian.html
# - https://www.ducea.com/2008/06/19/setting-up-a-pptp-vpn-server-on-debian-etch/
#
# 用法（以 root 执行）：
#   bash install_pptp_debian.sh \
#     --local-ip 192.168.99.1 \
#     --range 192.168.99.100-120 \
#     --dns 1.1.1.1,8.8.8.8 \
#     --users user1:pass1,user2:pass2
#
# 若未提供参数，将按默认值或自动探测；可重复执行，具备幂等性。
# =============================================

LOCAL_IP=""
REMOTE_RANGE="192.168.99.100-120"
DNS_LIST="1.1.1.1,8.8.8.8"
USERS_CSV=""

COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_RESET="\033[0m"

log() {
  echo -e "${COLOR_GREEN}[PPTP]${COLOR_RESET} $*"
}

warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*"
}

err() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "请以 root 身份运行此脚本。示例：sudo bash $0 ..."
    exit 1
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID=${ID:-}
    OS_VER=${VERSION_CODENAME:-}
  else
    OS_ID=""
    OS_VER=""
  fi
  case "$OS_ID" in
    debian|ubuntu) ;;
    *)
      warn "检测到的系统 ID: ${OS_ID:-unknown}；脚本主要面向 Debian/Ubuntu，其他发行版可能不兼容。"
      ;;
  esac
}

default_interface() {
  # 获取默认出口网卡
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

default_ipv4_of_iface() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local-ip)
        LOCAL_IP="$2"; shift 2;;
      --range|--remote-range)
        REMOTE_RANGE="$2"; shift 2;;
      --dns)
        DNS_LIST="$2"; shift 2;;
      --users)
        USERS_CSV="$2"; shift 2;;
      -h|--help)
        usage; exit 0;;
      *)
        err "未知参数：$1"; usage; exit 2;;
    esac
  done
}

usage() {
  cat <<EOF
用法：
  sudo bash $0 \\
    --local-ip 192.168.99.1 \\
    --range 192.168.99.100-120 \\
    --dns 1.1.1.1,8.8.8.8 \\
    --users user1:pass1,user2:pass2

说明：
  --local-ip   pptpd 在服务器上的 ppp 本地地址；未提供则自动探测默认网卡 IPv4。
  --range      分配给客户端的 IP 段范围，形如 192.168.99.100-120。
  --dns        分配给客户端的 DNS 列表，逗号分隔。
  --users      要创建的 VPN 账户，格式 用户名:密码，多个以逗号分隔。
EOF
}

ensure_values() {
  if [[ -z "$LOCAL_IP" ]]; then
    local wan_if
    wan_if=$(default_interface || true)
    if [[ -n "$wan_if" ]]; then
      LOCAL_IP=$(default_ipv4_of_iface "$wan_if" || true)
    fi
    if [[ -z "$LOCAL_IP" ]]; then
      warn "未能自动探测本机 IPv4，使用 192.168.99.1 作为默认 localip。"
      LOCAL_IP="192.168.99.1"
    fi
  fi

  if ! [[ "$REMOTE_RANGE" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-[0-9]{1,3}$ ]]; then
    err "--range 值无效：$REMOTE_RANGE（示例：192.168.1.100-120）"
    exit 2
  fi
}

install_packages() {
  log "安装依赖包 pptpd ppp iptables（如有必要）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y pptpd ppp iptables
}

configure_pptpd_conf() {
  local f="/etc/pptpd.conf"
  log "配置 $f ..."
  backup_file "$f"
  sed -i '/^localip\s\|^remoteip\s/d' "$f" || true
  {
    echo "localip ${LOCAL_IP}"
    echo "remoteip ${REMOTE_RANGE}"
  } >> "$f"
}

configure_pptpd_options() {
  local f="/etc/ppp/pptpd-options"
  log "配置 $f ..."
  backup_file "$f"
  cat > "$f" <<PPTP
name pptp-server

refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2

require-mppe-128
mppe-stateful

proxyarp
nodefaultroute
lock
nobsdcomp
noipx
mtu 1490
mru 1490

# DNS servers for clients
PPTP
  IFS=',' read -r -a dns_arr <<< "$DNS_LIST"
  for d in "${dns_arr[@]}"; do
    [[ -n "$d" ]] && echo "ms-dns $d" >> "$f"
  done
}

configure_users() {
  if [[ -z "$USERS_CSV" ]]; then
    warn "未提供 --users，自动创建默认账户 user:123。"
    USERS_CSV="user:123"
  fi
  local f="/etc/ppp/chap-secrets"
  log "写入用户到 $f ..."
  backup_file "$f"
  touch "$f" && chmod 600 "$f"
  IFS=',' read -r -a users <<< "$USERS_CSV"
  for up in "${users[@]}"; do
    local u p
    u="${up%%:*}"; p="${up#*:}"
    if [[ -z "$u" || -z "$p" || "$u" == "$p" && -z "$u" ]]; then
      warn "忽略无效用户定义：$up"
      continue
    fi
    # 移除同名旧行
    sed -i "/^\s*${u}\s\+/d" "$f" || true
    printf "%s\t*\t%s\t*\n" "$u" "$p" >> "$f"
  done
}

enable_ip_forward() {
  log "启用 IPv4 转发..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-pptp-ipforward.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

setup_nat_firewall() {
  local wan_if
  wan_if=$(default_interface || true)
  if [[ -z "$wan_if" ]]; then
    warn "未能自动识别默认出口网卡，跳过 NAT 规则添加。可手动添加后运行：iptables-save > /etc/iptables/rules.v4"
    return 0
  fi

  log "配置 iptables NAT 转发规则（出口网卡：$wan_if）..."
  # 基本规则（幂等处理：如果存在先删除后添加）
  iptables -t nat -C POSTROUTING -o "$wan_if" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$wan_if" -j MASQUERADE

  iptables -C FORWARD -i ppp+ -o "$wan_if" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i ppp+ -o "$wan_if" -j ACCEPT

  iptables -C FORWARD -i "$wan_if" -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$wan_if" -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT

  # 持久化规则
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y iptables-persistent >/dev/null 2>&1 || true
  if command -v iptables-save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
  fi
}

restart_service() {
  log "启用并重启 pptpd 服务..."
  systemctl enable pptpd >/dev/null 2>&1 || true
  systemctl restart pptpd
  sleep 1
  systemctl --no-pager --full status pptpd | sed -n '1,15p' || true
}

summary_msg() {
  cat <<EOF
================ 配置完成 ================
Local IP (pptpd):    $LOCAL_IP
Client IP Range:     $REMOTE_RANGE
DNS for clients:     $DNS_LIST

建议：
1) 若服务器启用了 UFW/Firewalld，请放行 TCP/1723 和 GRE（协议 47）。
2) 客户端创建 "PPTP" 连接，验证方式 MS-CHAPv2，数据加密 MPPE-128。
3) 如需调整：/etc/pptpd.conf, /etc/ppp/pptpd-options, /etc/ppp/chap-secrets。
4) 查看日志：journalctl -u pptpd -e 或 tail -f /var/log/syslog。
=========================================
EOF
}

main() {
  parse_args "$@"
  require_root
  detect_os
  ensure_values

  log "参数：local-ip=${LOCAL_IP} range=${REMOTE_RANGE} dns=${DNS_LIST} users=${USERS_CSV:-<none>}"

  install_packages
  configure_pptpd_conf
  configure_pptpd_options
  configure_users
  enable_ip_forward
  setup_nat_firewall
  restart_service
  summary_msg
}

main "$@"


