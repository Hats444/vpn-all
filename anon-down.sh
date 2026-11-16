#!/usr/bin/env bash
# anon-down.sh — desfaz tudo que o anon-up fez: VPN, kill switch, DNS, IPv6,
# hostname, servicos e Tor. Segue em frente mesmo se uma etapa falhar.
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

QUIET=0
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) echo "uso: $(basename "$0") [--dry-run] [--quiet]"; exit 0 ;;
  esac
done

load_config
detect_env
maybe_elevate "$@"

[[ -d "$STATE_DIR" ]] || { [[ "$QUIET" == 1 ]] || ok "nada para desfazer"; exit 0; }
FALHAS=0
step() { "$@" || { warn "falhou: $*"; FALHAS=$((FALHAS + 1)); }; }
trap 'warn "erro inesperado na linha $LINENO; continuando"' ERR

stop_pid() {
  if pid_alive "$1"; then step run kill "$(state_get "$1")"; ok "$2 desligado"; fi
  state_del "$1"
}

stop_pid tor.pid "Tor"

# kill switch sai antes da VPN para nao ficar sem internet no meio
case "$(state_get killswitch 2>/dev/null)" in
  nft)
    if nft list table inet anon_up >/dev/null 2>&1; then step run nft delete table inet anon_up; fi
    ok "kill switch removido" ;;
  iptables)
    step run iptables -D OUTPUT -j ANON_UP_OUT
    step run iptables -F ANON_UP_OUT
    step run iptables -X ANON_UP_OUT
    if have ip6tables && ip6tables -S ANON_UP_OUT6 >/dev/null 2>&1; then
      step run ip6tables -D OUTPUT -j ANON_UP_OUT6
      step run ip6tables -F ANON_UP_OUT6
      step run ip6tables -X ANON_UP_OUT6
    fi
    ok "kill switch removido" ;;
esac
state_del killswitch

if state_has vpn; then
  if have wg && wg show "$WG_IFACE" >/dev/null 2>&1; then step run wg-quick down "$(state_get vpn)"; fi
  ok "VPN desligada"
  [[ "$DRY_RUN" == 1 ]] || rm -f "$(state_get vpn)"
  state_del vpn
fi

# DNS: volta o resolv.conf original antes de parar o resolver local
if state_has resolv.bak; then
  b="$(state_get resolv.bak)"
  if [[ "$b" == link:* ]]; then step run ln -sfn "${b#link:}" /etc/resolv.conf
  elif [[ -f "$STATE_DIR/resolv.conf.orig" ]]; then step run cp -a "$STATE_DIR/resolv.conf.orig" /etc/resolv.conf
  fi
  state_del resolv.bak; state_del resolv.conf.orig
  ok "resolv.conf restaurado"
fi
stop_pid dnsmasq.pid "dnsmasq"
stop_pid dnscrypt.pid "dnscrypt-proxy"
if state_has svc.dnsmasq; then step run systemctl start dnsmasq; state_del svc.dnsmasq; fi

nm_reload=0
for f in /etc/NetworkManager/conf.d/90-anon-up-dns.conf /etc/NetworkManager/conf.d/91-anon-up-mac.conf; do
  if [[ -f "$f" ]]; then step run rm -f "$f"; nm_reload=1; fi
done
if [[ "$nm_reload" == 1 ]] && svc_active NetworkManager; then step run systemctl reload NetworkManager; fi

if state_has ipv6.bak; then
  read -r v_all v_def < "$STATE_DIR/ipv6.bak"
  step run sysctl -q -w "net.ipv6.conf.all.disable_ipv6=${v_all:-0}" "net.ipv6.conf.default.disable_ipv6=${v_def:-0}"
  state_del ipv6.bak
  ok "IPv6 restaurado"
fi

if state_has resolved.revert && have resolvectl; then
  for ifc in /sys/class/net/*; do
    ifc="${ifc##*/}"; [[ "$ifc" == lo ]] && continue
    run resolvectl revert "$ifc" 2>/dev/null || true
  done
  state_del resolved.revert
fi
for s in avahi-daemon.socket avahi-daemon; do
  if state_has "svc.$s"; then step run systemctl start "$s"; state_del "svc.$s"; fi
done

if state_has hostname.bak; then
  h="$(state_get hostname.bak)"
  if have hostnamectl; then step run hostnamectl set-hostname "$h" 2>/dev/null || step run hostname "$h"
  else step run hostname "$h"; fi
  if grep -q '# anon-up' /etc/hosts 2>/dev/null; then step run sed -i '/# anon-up$/d' /etc/hosts; fi
  state_del hostname.bak
  ok "hostname restaurado: $h"
fi

state_del active
state_del real_ip
if [[ "$FALHAS" -gt 0 ]]; then warn "$FALHAS etapa(s) falharam; revise acima"; exit 1; fi
[[ "$QUIET" == 1 ]] || ok "tudo desfeito"
