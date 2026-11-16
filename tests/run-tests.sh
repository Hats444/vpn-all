#!/usr/bin/env bash
# tests/run-tests.sh — testes sem mexer na rede: sintaxe, regras geradas e dry-run.
# Partes que precisam de nft/dnsmasq/root sao puladas se a ferramenta faltar.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib/common.sh
. lib/common.sh
# shellcheck source=lib/render.sh
. lib/render.sh

PASS=0; FAIL=0; SKIP=0
t_ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
t_fail() { FAIL=$((FAIL+1)); printf 'FALHA %s\n' "$1"; }
t_skip() { SKIP=$((SKIP+1)); printf 'pula %s\n' "$1"; }
check()  { local n="$1"; shift; if "$@" >/dev/null 2>&1; then t_ok "$n"; else t_fail "$n"; fi; }
SUDO=""; [[ "$(id -u)" != 0 ]] && sudo -n true 2>/dev/null && SUDO="sudo -n"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

for f in anon-up.sh anon-down.sh anon-status.sh lib/common.sh lib/render.sh; do check "bash -n $f" bash -n "$f"; done

# endpoint do WireGuard
printf '[Interface]\nPrivateKey = x\nAddress = 10.2.0.2/32\nDNS = 10.2.0.1\n[Peer]\nPublicKey = y\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.7:51820\n' > "$TMP/vpn.conf"
check "wg_endpoint le host e porta" test "$(wg_endpoint "$TMP/vpn.conf")" = "203.0.113.7 51820"
printf '[Peer]\nEndpoint=[2001:db8::1]:443\n' > "$TMP/v6.conf"
check "wg_endpoint com IPv6" test "$(wg_endpoint "$TMP/v6.conf")" = "2001:db8::1 443"
check "resolve_ipv4 devolve IP literal" test "$(resolve_ipv4 198.51.100.2)" = "198.51.100.2"

# listas de bloqueio em formatos diferentes
printf '# comentario\n0.0.0.0 ads.example.com\n127.0.0.1 track.example.net # x\n||pixel.example.org^\nplain.example.io\nlocalhost\n0.0.0.0 0.0.0.0\n!adblock comment\nADS.EXAMPLE.COM\n' > "$TMP/list.txt"
normalize_blocklist < "$TMP/list.txt" > "$TMP/out.txt"
check "normaliza hosts/adblock/dominio" diff -u <(printf '0.0.0.0 ads.example.com\n0.0.0.0 pixel.example.org\n0.0.0.0 plain.example.io\n0.0.0.0 track.example.net\n') "$TMP/out.txt"

# kill switch nftables: valida a sintaxe com nft -c (nao aplica nada)
for combo in "0 0" "1 1" "0 1"; do
  # shellcheck disable=SC2086
  set -- $combo
  render_nft anon0 203.0.113.7 51820 "$1" "$2" > "$TMP/ks.nft"
  check "nft gera regra drop por padrao (lan=$1 v6=$2)" grep -q 'policy drop' "$TMP/ks.nft"
  if have nft && { [[ "$(id -u)" == 0 ]] || [[ -n "$SUDO" ]]; }; then
    # shellcheck disable=SC2086
    check "nft -c aceita o kill switch (lan=$1 v6=$2)" $SUDO nft -c -f "$TMP/ks.nft"
  else t_skip "nft -c (sem nft ou sem root)"; fi
done
render_iptables anon0 203.0.113.7 51820 1 1 > "$TMP/ipt.txt"
check "iptables termina com DROP antes do jump" grep -q -- '-A ANON_UP_OUT -j DROP' "$TMP/ipt.txt"
check "iptables libera so o endpoint" grep -q -- '-d 203.0.113.7 -p udp --dport 51820 -j ACCEPT' "$TMP/ipt.txt"

# dnsmasq e dnscrypt
render_dnsmasq "$TMP/out.txt" "$TMP/dnsmasq.pid" > "$TMP/dnsmasq.conf"
check "dnsmasq usa so o upstream local" grep -qx 'server=127.0.0.1#5353' "$TMP/dnsmasq.conf"
check "dnsmasq ignora resolv.conf" grep -qx 'no-resolv' "$TMP/dnsmasq.conf"
if have dnsmasq; then check "dnsmasq --test aceita a config" dnsmasq --test --conf-file="$TMP/dnsmasq.conf"
else t_skip "dnsmasq --test"; fi
render_dnscrypt "$TMP/cache" "a-doh b-doh" > "$TMP/dc.toml"
check "dnscrypt lista os servidores" grep -qx "server_names = \['a-doh', 'b-doh'\]" "$TMP/dc.toml"
check "dnscrypt ouve so em 127.0.0.1:5353" grep -qx "listen_addresses = \['127.0.0.1:5353'\]" "$TMP/dc.toml"
if python3 -c 'import tomllib' 2>/dev/null; then
  check "dnscrypt toml valido" python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$TMP/dc.toml"
else t_skip "toml valido (python3 sem tomllib)"; fi

# dry-run: roda o fluxo inteiro sem tocar em nada
cp config.env "$TMP/config.env"; chmod 600 "$TMP/config.env"
ANON_CONFIG="$TMP/config.env" ANON_STATE_DIR="$TMP/state" ANON_FORCE_ROOT=1 ./anon-up.sh --dry-run --tor > "$TMP/dry.txt" 2>&1
check "dry-run linux root termina" grep -q 'dry-run terminado' "$TMP/dry.txt"
check "dry-run sobe a VPN" grep -q 'wg-quick up' "$TMP/dry.txt"
check "dry-run aplica kill switch" grep -q 'policy drop' "$TMP/dry.txt"
check "dry-run liga o Tor" grep -q 'tor -f' "$TMP/dry.txt"
check "dry-run nao criou estado" test ! -e "$TMP/state/active"
ANON_CONFIG="$TMP/config.env" ANON_STATE_DIR="$TMP/state2" TERMUX_VERSION=0.118 ./anon-up.sh --dry-run > "$TMP/termux.txt" 2>&1
check "dry-run termux sem root avisa do kill switch" grep -q 'kill switch NAO' "$TMP/termux.txt"
check "dry-run termux mostra o passo do Android" grep -q 'Bloquear conexoes sem VPN' "$TMP/termux.txt"
ANON_CONFIG="$TMP/config.env" ANON_STATE_DIR="$TMP/nada" ./anon-down.sh --dry-run > "$TMP/down.txt" 2>&1
check "down sem estado nao faz nada" grep -q 'nada para desfazer' "$TMP/down.txt"
check "opcao invalida falha" bash -c '! ./anon-up.sh --xyz'

echo
echo "passou $PASS · falhou $FAIL · pulou $SKIP"
[[ "$FAIL" == 0 ]]
