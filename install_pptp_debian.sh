#!/usr/bin/env bash

set -euo pipefail

# 简化版 Debian PPTP 一键安装脚本
# 默认：
#   - local-ip: 192.168.99.1
#   - range:    192.168.99.100-120
#   - dns:      1.1.1.1,8.8.8.8
#   - users:    user:123（当未传 --users）
# 参考：
#   https://github.com/Saleh7/Auto_Setup_VPN_PPTP_Server_Ubuntu-Debian/blob/master/pptp.sh
#   https://www.chiark.greenend.org.uk/~ajlanes/free/pptp-debian.html
#   https://www.ducea.com/2008/06/19/setting-up-a-pptp-vpn-server-on-debian-etch/

LOCAL_IP=""
REMOTE_RANGE="192.168.99.100-120"
DNS_LIST="1.1.1.1,8.8.8.8"
USERS_CSV=""

usage() {
  cat <<EOF
用法：
  sudo bash $0 [--local-ip 192.168.99.1] [--range 192.168.99.100-120] [--dns 1.1.1.1,8.8.8.8] [--users user:pass,user2:pass2]
说明：
  未提供 --users 时，自动创建默认账户 user:123。
EOF
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "请以 root 身份运行。示例：sudo bash $0" >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local-ip) LOCAL_IP="$2"; shift 2;;
      --range|--remote-range) REMOTE_RANGE="$2"; shift 2;;
      --dns) DNS_LIST="$2"; shift 2;;
      --users) USERS_CSV="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *) echo "未知参数：$1" >&2; usage; exit 2;;
    esac
  done
}

default_interface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

default_ipv4_of_iface() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

ensure_defaults() {
  if [[ -z "$LOCAL_IP" ]]; then
    local wan_if; wan_if=$(default_interface || true)
    if [[ -n "$wan_if" ]]; then
      LOCAL_IP=$(default_ipv4_of_iface "$wan_if" || true)
    fi
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP="192.168.99.1"
  fi
  [[ -z "$USERS_CSV" ]] && USERS_CSV="user:123"
}

backup_file() {
  local f="$1"; [[ -f "$f" ]] && cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y pptpd ppp iptables
}

write_pptpd_conf() {
  local f="/etc/pptpd.conf"
  backup_file "$f"
  sed -i '/^localip\s\|^remoteip\s/d' "$f" || true
  {
    echo "localip ${LOCAL_IP}"
    echo "remoteip ${REMOTE_RANGE}"
  } >> "$f"
}

write_pptpd_options() {
  local f="/etc/ppp/pptpd-options"
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
PPTP
  IFS=',' read -r -a dns_arr <<< "$DNS_LIST"
  for d in "${dns_arr[@]}"; do
    [[ -n "$d" ]] && echo "ms-dns $d" >> "$f"
  done
}

write_users() {
  local f="/etc/ppp/chap-secrets"
  backup_file "$f"
  touch "$f" && chmod 600 "$f"
  IFS=',' read -r -a users <<< "$USERS_CSV"
  for up in "${users[@]}"; do
    local u="${up%%:*}"; local p="${up#*:}"
    [[ -z "$u" || -z "$p" ]] && continue
    sed -i "/^\s*${u}\s\+/d" "$f" || true
    printf "%s\t*\t%s\t*\n" "$u" "$p" >> "$f"
  done
}

enable_ip_forward() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-pptp-ipforward.conf
  sysctl --system >/dev/null
}

setup_nat() {
  local wan_if; wan_if=$(default_interface || true)
  [[ -z "$wan_if" ]] && return 0
  iptables -t nat -C POSTROUTING -o "$wan_if" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$wan_if" -j MASQUERADE
  iptables -C FORWARD -i ppp+ -o "$wan_if" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ppp+ -o "$wan_if" -j ACCEPT
  iptables -C FORWARD -i "$wan_if" -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$wan_if" -o ppp+ -m state --state RELATED,ESTABLISHED -j ACCEPT
  apt-get install -y iptables-persistent >/dev/null 2>&1 || true
  command -v iptables-save >/dev/null 2>&1 && { mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4; }
}

restart_pptpd() {
  systemctl enable pptpd >/dev/null 2>&1 || true
  systemctl restart pptpd
}

main() {
  parse_args "$@"
  require_root
  ensure_defaults

  install_packages
  write_pptpd_conf
  write_pptpd_options
  write_users
  enable_ip_forward
  setup_nat
  restart_pptpd

  echo "PPTP 已配置完成"
  echo "Local IP: ${LOCAL_IP}"
  echo "Remote Range: ${REMOTE_RANGE}"
  echo "DNS: ${DNS_LIST}"
  echo "用户: ${USERS_CSV}"
  echo "如有防火墙，请放行 TCP/1723 与 GRE(47)。日志: journalctl -u pptpd -e"
}

main "$@"


