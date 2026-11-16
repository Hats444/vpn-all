#!/usr/bin/env bash
# anon-status.sh — mostra IP publico, pais, DNS, VPN, kill switch, Tor e testa vazamentos.
# Retorna 1 se achar vazamento.
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
detect_env

VAZOU=0
linha() { printf '  %-16s %s\n' "$1" "$2"; }
bom()   { linha "$1" "${C_G}$2${C_0}"; }
ruim()  { linha "$1" "${C_R}$2${C_0}"; VAZOU=1; }
neutro(){ linha "$1" "${C_Y}$2${C_0}"; }

echo "anon-status · $ENV_DISTRO"

# IP e pais
json="$(public_ip_json)"
ip="$(printf '%s' "$json" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
pais="$(printf '%s' "$json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
real="$(state_get real_ip 2>/dev/null || true)"
if [[ -z "$ip" ]]; then
  neutro "IP publico" "sem resposta (kill switch sem VPN, ou sem internet)"
elif [[ -n "$real" && "$ip" == "$real" ]]; then
  ruim "IP publico" "$ip ($pais) = SEU IP REAL"
else
  bom "IP publico" "$ip (${pais:-?})"
fi
if printf '%s' "$json" | grep -q '"mullvad_exit_ip"[[:space:]]*:[[:space:]]*true'; then bom "Mullvad" "saindo por servidor Mullvad"; fi

# VPN
if have wg && wg show "$WG_IFACE" >/dev/null 2>&1; then
  hs="$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -n1)"
  if [[ -n "$hs" && "$hs" != 0 ]]; then bom "VPN" "$WG_IFACE ativa (handshake ha $(( $(date +%s) - hs ))s)"
  else ruim "VPN" "$WG_IFACE sem handshake"; fi
elif state_has vpn; then ruim "VPN" "deveria estar ativa e nao esta"
else neutro "VPN" "desligada"; fi

# Kill switch
case "$(state_get killswitch 2>/dev/null)" in
  nft) if have nft && nft list table inet anon_up >/dev/null 2>&1; then bom "Kill switch" "nftables ativo"; else ruim "Kill switch" "regras sumiram"; fi ;;
  iptables) if iptables -S ANON_UP_OUT >/dev/null 2>&1; then bom "Kill switch" "iptables ativo"; else ruim "Kill switch" "regras sumiram"; fi ;;
  *) if state_has active; then neutro "Kill switch" "nao aplicado"; else neutro "Kill switch" "desligado"; fi ;;
esac

# DNS
ns="$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
if [[ "$ns" == "127.0.0.1 " ]]; then bom "DNS" "127.0.0.1 (local -> DoH)"
elif state_has active && [[ "$ENV_OS" == linux && "$ENV_ROOT" == 1 ]]; then ruim "DNS" "${ns:-?} (deveria ser 127.0.0.1)"
else neutro "DNS" "${ns:-?}"; fi
if pid_alive dnscrypt.pid; then bom "DoH" "dnscrypt-proxy rodando ($DNS_UPSTREAM)"; elif state_has active && [[ "$ENV_OS" == linux ]]; then ruim "DoH" "dnscrypt-proxy parado"; fi

# Bloqueio de rastreadores
if [[ -f "$STATE_DIR/blocklist.hosts" ]] && pid_alive dnsmasq.pid; then
  n="$(wc -l < "$STATE_DIR/blocklist.hosts")"
  r="$(getent ahostsv4 doubleclick.net 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ "$r" == 0.0.0.0 ]]; then bom "Rastreadores" "$n dominios bloqueados (doubleclick.net -> 0.0.0.0)"
  else ruim "Rastreadores" "doubleclick.net resolveu para ${r:-nada}"; fi
fi

# IPv6
if curl -6 -fsS -m 5 https://ipv6.icanhazip.com >/dev/null 2>&1; then
  if wg show "$WG_IFACE" allowed-ips 2>/dev/null | grep -q '::/0'; then bom "IPv6" "passa pelo tunel"
  else ruim "IPv6" "saindo fora do tunel"; fi
else
  bom "IPv6" "bloqueado"
fi

# Tor
if pid_alive tor.pid; then
  if curl -fsS -m 20 --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true'; then
    bom "Tor" "ativo (SOCKS 127.0.0.1:9050)"
  else neutro "Tor" "rodando, ainda montando circuito"; fi
fi

echo
if [[ "$VAZOU" == 1 ]]; then err "achei vazamento ou falha (vermelho acima)"; exit 1; fi
ok "sem vazamento detectado nos testes de IP, DNS e IPv6"
echo "  ${C_D}lembrete: navegador, contas logadas e cookies ainda identificam voce${C_0}"
