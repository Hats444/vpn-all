#!/usr/bin/env bash
# anon-up.sh — liga VPN WireGuard, kill switch, DNS criptografado com bloqueio de
# rastreadores, anti-vazamento e hardening com um comando so (Linux e Termux).
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/render.sh
. "$ANON_DIR/lib/render.sh"

usage() {
  cat <<USO
uso: $(basename "$0") [opcoes]
  --tor            liga tambem o Tor (SOCKS 127.0.0.1:9050, use com torsocks)
  --no-block       nao usa as listas de bloqueio de rastreadores
  --no-killswitch  nao aplica o kill switch (nao recomendado)
  --update-lists   so baixa de novo as listas de bloqueio e recarrega o DNS
  --status         mostra o estado (o mesmo que ./anon-status.sh)
  --down           desfaz tudo (o mesmo que ./anon-down.sh)
  --dry-run        mostra o que faria, sem mudar nada
  -h, --help       esta ajuda
USO
}

OPT_TOR=""; OPT_BLOCK=""; OPT_KS=""; ONLY_LISTS=0
for a in "$@"; do
  case "$a" in
    --tor) OPT_TOR=1 ;;
    --no-block) OPT_BLOCK=0 ;;
    --no-killswitch) OPT_KS=0 ;;
    --update-lists) ONLY_LISTS=1 ;;
    --status) exec bash "$ANON_DIR/anon-status.sh" ;;
    --down) exec bash "$ANON_DIR/anon-down.sh" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "opcao desconhecida: $a" ;;
  esac
done

load_config
detect_env
[[ -n "$OPT_TOR" ]] && TOR_ENABLED="$OPT_TOR"
[[ -n "$OPT_BLOCK" ]] && BLOCK_ENABLED="$OPT_BLOCK"
[[ -n "$OPT_KS" ]] && KILLSWITCH="$OPT_KS"
maybe_elevate "$@"

# Se algo falhar no meio, desfaz o que ja foi feito para nao deixar a rede quebrada.
on_error() {
  local linha="$1"
  err "falhou na linha $linha; desfazendo as mudancas"
  [[ "$DRY_RUN" == 1 ]] || bash "$ANON_DIR/anon-down.sh" --quiet || true
  exit 1
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------- listas de bloqueio
build_blocklist() {
  local out="$STATE_DIR/blocklist.hosts" tmp age_h url n
  if [[ -f "$out" && "$ONLY_LISTS" == 0 ]]; then
    age_h=$(( ( $(date +%s) - $(stat -c %Y "$out") ) / 3600 ))
    if (( age_h < BLOCKLIST_MAX_AGE_H )); then ok "listas de bloqueio em dia (${age_h}h)"; return 0; fi
  fi
  info "baixando listas de bloqueio de rastreadores"
  [[ "$DRY_RUN" == 1 ]] && { run curl -fsSL "$BLOCKLIST_URLS"; return 0; }
  tmp="$(mktemp)"
  for url in $BLOCKLIST_URLS; do
    if curl -fsSL -m 60 "$url" >> "$tmp"; then ok "lista: $url"; else warn "lista falhou: $url"; fi
    echo >> "$tmp"
  done
  normalize_blocklist < "$tmp" > "$out.new"
  rm -f "$tmp"
  n="$(wc -l < "$out.new")"
  if (( n < 1000 )); then
    rm -f "$out.new"
    [[ -f "$out" ]] && { warn "listas novas vazias; mantendo as anteriores"; return 0; }
    die "nao consegui baixar nenhuma lista de bloqueio (use --no-block para seguir sem)"
  fi
  mv "$out.new" "$out"; chmod 644 "$out"
  ok "$n dominios de rastreadores bloqueados"
}

# ---------------------------------------------------------------- VPN WireGuard
setup_vpn() {
  if [[ -z "$VPN_CONFIG_PATH" && "$DRY_RUN" == 1 ]]; then
    warn "VPN_CONFIG_PATH vazio no config.env (no uso real isso para o script)"
    VPN_CONFIG_PATH="/caminho/para/provedor.conf"
  fi
  [[ -n "$VPN_CONFIG_PATH" ]] || die "defina VPN_CONFIG_PATH no config.env (arquivo .conf WireGuard do Proton VPN ou Mullvad)"
  [[ -f "$VPN_CONFIG_PATH" || "$DRY_RUN" == 1 ]] || die "arquivo da VPN nao existe: $VPN_CONFIG_PATH"
  if have wg && wg show "$WG_IFACE" >/dev/null 2>&1; then ok "VPN ja esta ativa ($WG_IFACE)"; return 0; fi
  local conf="$STATE_DIR/$WG_IFACE.conf"
  info "subindo VPN WireGuard ($WG_IFACE)"
  # o DNS do .conf e ignorado: quem resolve e o DNS local criptografado
  if [[ "$DRY_RUN" == 1 ]]; then
    run install -m 600 "$VPN_CONFIG_PATH" "$conf"
  else
    umask 077
    grep -viE '^[[:space:]]*DNS[[:space:]]*=' "$VPN_CONFIG_PATH" > "$conf"
    chmod 600 "$conf"
  fi
  run wg-quick up "$conf"
  state_set vpn "$conf"
  ok "VPN ativa"
}

# ---------------------------------------------------------------- kill switch
setup_killswitch() {
  if [[ "$KILLSWITCH" != 1 ]]; then warn "kill switch DESLIGADO (KILLSWITCH=0): se a VPN cair, seu IP real aparece"; return 0; fi
  local ep_ip="$1" ep_port="$2" f
  if have nft && [[ "$ENV_OS" == linux ]]; then
    f="$STATE_DIR/killswitch.nft"
    if [[ "$DRY_RUN" == 1 ]]; then
      render_nft "$WG_IFACE" "$ep_ip" "$ep_port" "$ALLOW_LAN" "$BLOCK_IPV6" | sed 's/^/[dry]   /'
    else
      render_nft "$WG_IFACE" "$ep_ip" "$ep_port" "$ALLOW_LAN" "$BLOCK_IPV6" > "$f"
      nft list table inet anon_up >/dev/null 2>&1 && nft delete table inet anon_up
      nft -f "$f"
    fi
    state_set killswitch nft
  elif have iptables; then
    iptables -D OUTPUT -j ANON_UP_OUT 2>/dev/null || true
    iptables -F ANON_UP_OUT 2>/dev/null || true
    iptables -X ANON_UP_OUT 2>/dev/null || true
    local l
    while IFS= read -r l; do
      # shellcheck disable=SC2086
      run $l
    done < <(render_iptables "$WG_IFACE" "$ep_ip" "$ep_port" "$ALLOW_LAN" "$BLOCK_IPV6")
    state_set killswitch iptables
  else
    die "sem nftables nem iptables: nao da para aplicar o kill switch"
  fi
  ok "kill switch ativo: sem VPN, sem internet"
}

# ---------------------------------------------------------------- IPv6
setup_ipv6() {
  [[ "$BLOCK_IPV6" == 1 ]] || return 0
  if ! state_has ipv6.bak; then
    state_set ipv6.bak "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0) $(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)"
  fi
  run sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  ok "IPv6 desligado (sem vazamento de prefixo)"
}

# ---------------------------------------------------------------- DNS
port_busy() { have ss && ss -Hlnu "sport = :$1" 2>/dev/null | grep -q "127.0.0.1:$1\|0.0.0.0:$1\|\*:$1"; }

wait_port() {
  local _i
  [[ "$DRY_RUN" == 1 ]] && return 0
  for _i in $(seq 1 30); do port_busy "$1" && return 0; sleep 0.5; done
  return 1
}

setup_dns() {
  local cache="$STATE_DIR/dnscrypt" hosts=""
  [[ "$BLOCK_ENABLED" == 1 ]] && hosts="$STATE_DIR/blocklist.hosts"
  run mkdir -p "$cache"
  if [[ "$DRY_RUN" == 1 ]]; then
    info "[dry] dnscrypt-proxy em 127.0.0.1:5353 ($DNS_UPSTREAM) e dnsmasq em 127.0.0.1:53"
  else
    render_dnscrypt "$cache" "$DNS_UPSTREAM" > "$STATE_DIR/dnscrypt-proxy.toml"
    render_dnsmasq "$hosts" "$STATE_DIR/dnsmasq.pid" > "$STATE_DIR/dnsmasq.conf"
  fi

  # outro dnsmasq do sistema ocupando a porta 53 atrapalha
  if svc_active dnsmasq; then run systemctl stop dnsmasq; state_set svc.dnsmasq 1; fi

  if pid_alive dnscrypt.pid; then ok "dnscrypt-proxy ja rodando"
  else
    info "ligando DNS criptografado (DoH)"
    if [[ "$DRY_RUN" != 1 ]]; then
      nohup dnscrypt-proxy -config "$STATE_DIR/dnscrypt-proxy.toml" > "$STATE_DIR/dnscrypt.log" 2>&1 &
      state_set dnscrypt.pid "$!"
    fi
    wait_port 5353 || die "dnscrypt-proxy nao subiu (veja $STATE_DIR/dnscrypt.log)"
  fi

  if pid_alive dnsmasq.pid; then
    run kill -HUP "$(state_get dnsmasq.pid)"; ok "dnsmasq recarregado"
  else
    run dnsmasq --conf-file="$STATE_DIR/dnsmasq.conf"
    wait_port 53 || die "dnsmasq nao subiu na porta 53"
  fi

  # resolv.conf aponta so para o DNS local
  if ! state_has resolv.bak; then
    if [[ -L /etc/resolv.conf ]]; then state_set resolv.bak "link:$(readlink /etc/resolv.conf)"
    else run cp -a /etc/resolv.conf "$STATE_DIR/resolv.conf.orig"; state_set resolv.bak "file"; fi
  fi
  if [[ -d /etc/NetworkManager/conf.d ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then run tee /etc/NetworkManager/conf.d/90-anon-up-dns.conf
    else printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/90-anon-up-dns.conf; fi
    svc_active NetworkManager && run systemctl reload NetworkManager
  fi
  if [[ "$DRY_RUN" == 1 ]]; then run tee /etc/resolv.conf
  else rm -f /etc/resolv.conf; printf '# anon-up\nnameserver 127.0.0.1\noptions edns0\n' > /etc/resolv.conf; fi
  ok "DNS: 127.0.0.1 -> bloqueio de rastreadores -> DoH ($DNS_UPSTREAM)"
}

# ---------------------------------------------------------------- hardening
setup_hardening() {
  local ifc
  if [[ "$MAC_RANDOMIZE" == 1 ]]; then
    if [[ -d /etc/NetworkManager/conf.d ]]; then
      if [[ "$DRY_RUN" == 1 ]]; then run tee /etc/NetworkManager/conf.d/91-anon-up-mac.conf
      else
        printf '[device]\nwifi.scan-rand-mac-address=yes\n\n[connection]\nwifi.cloned-mac-address=random\nethernet.cloned-mac-address=random\n' \
          > /etc/NetworkManager/conf.d/91-anon-up-mac.conf
      fi
      svc_active NetworkManager && run systemctl reload NetworkManager
      ok "MAC aleatorio configurado (vale na proxima conexao de rede)"
    else
      warn "sem NetworkManager: MAC aleatorio nao configurado (trocar o MAC agora derrubaria a rede)"
    fi
  fi
  if [[ "$DISABLE_LEAKY_SERVICES" == 1 ]]; then
    for s in avahi-daemon.socket avahi-daemon; do
      if svc_active "$s"; then run systemctl stop "$s"; state_set "svc.$s" 1; fi
    done
    if svc_active systemd-resolved && have resolvectl; then
      for ifc in /sys/class/net/*; do
        ifc="${ifc##*/}"; [[ "$ifc" == lo ]] && continue
        run resolvectl llmnr "$ifc" no 2>/dev/null || true
        run resolvectl mdns "$ifc" no 2>/dev/null || true
      done
      state_set resolved.revert 1
    fi
    ok "mDNS/LLMNR/Avahi desligados"
  fi
  if [[ -n "$GENERIC_HOSTNAME" && "$(hostname)" != "$GENERIC_HOSTNAME" ]]; then
    state_has hostname.bak || state_set hostname.bak "$(hostname)"
    if have hostnamectl; then
      run hostnamectl set-hostname "$GENERIC_HOSTNAME" 2>/dev/null || run hostname "$GENERIC_HOSTNAME"
    else
      run hostname "$GENERIC_HOSTNAME"
    fi
    if ! grep -q '# anon-up' /etc/hosts 2>/dev/null; then
      if [[ "$DRY_RUN" == 1 ]]; then run tee -a /etc/hosts
      else printf '127.0.1.1 %s # anon-up\n' "$GENERIC_HOSTNAME" >> /etc/hosts; fi
    fi
    ok "hostname generico: $GENERIC_HOSTNAME"
  fi
}

# ---------------------------------------------------------------- Tor
setup_tor() {
  [[ "$TOR_ENABLED" == 1 ]] || return 0
  if pid_alive tor.pid; then ok "Tor ja rodando"; return 0; fi
  local data="$STATE_DIR/tor"
  run mkdir -p "$data"; run chmod 700 "$data"
  if [[ "$DRY_RUN" != 1 ]]; then
    render_torrc "$data" > "$STATE_DIR/torrc"
    if [[ "$ENV_ROOT" == 1 ]] && id debian-tor >/dev/null 2>&1; then
      echo "User debian-tor" >> "$STATE_DIR/torrc"; chown -R debian-tor "$data"
    fi
  fi
  info "ligando Tor"
  run tor -f "$STATE_DIR/torrc" --RunAsDaemon 1 --PidFile "$data/tor.pid"
  if [[ "$DRY_RUN" != 1 ]]; then
    local _i; for _i in $(seq 1 20); do [[ -s "$data/tor.pid" ]] && break; sleep 0.5; done
    state_set tor.pid "$(cat "$data/tor.pid" 2>/dev/null || echo '')"
  fi
  ok "Tor: SOCKS 127.0.0.1:9050 (use: torsocks <comando>)"
  warn "VPN + Tor: o Tor sai pelo tunel da VPN. Isso esconde do provedor que voce usa Tor, mas a VPN ve que voce usa Tor."
}

# ---------------------------------------------------------------- cenarios
linux_root() {
  state_init
  pkg_refresh
  need curl curl curl curl
  need wg-quick wireguard-tools wireguard-tools wireguard-tools
  if [[ "$KILLSWITCH" == 1 ]] && ! have nft && ! have iptables; then need nft nftables nftables nftables; fi
  need dnsmasq dnsmasq-base dnsmasq dnsmasq dnsmasq
  need dnscrypt-proxy dnscrypt-proxy dnscrypt-proxy dnscrypt-proxy
  [[ "$TOR_ENABLED" == 1 ]] && need tor tor tor tor && need torsocks torsocks torsocks torsocks

  # IP real e endpoint resolvidos antes de mexer em DNS e firewall
  if ! state_has real_ip && [[ "$DRY_RUN" != 1 ]]; then state_set real_ip "$(public_ip)"; fi
  local ep="" ep_ip="" ep_port=""
  if [[ -f "$VPN_CONFIG_PATH" ]]; then
    ep="$(wg_endpoint "$VPN_CONFIG_PATH")" || die "Endpoint nao encontrado em $VPN_CONFIG_PATH"
    ep_ip="$(resolve_ipv4 "${ep% *}")"; ep_port="${ep#* }"
    [[ -n "$ep_ip" ]] || die "nao consegui resolver o endpoint ${ep% *}"
  elif [[ "$DRY_RUN" == 1 ]]; then
    ep_ip="203.0.113.10"; ep_port="51820"
  fi

  [[ "$BLOCK_ENABLED" == 1 ]] && build_blocklist
  setup_vpn
  setup_killswitch "$ep_ip" "$ep_port"
  setup_ipv6
  setup_dns
  setup_hardening
  setup_tor
  state_set active "$(date +%s)"
}

termux_guide() {
  cat <<GUIA

${C_Y}Faca no Android (o Termux sem root nao consegue fazer isso sozinho):${C_0}
  1. Configuracoes > Rede e internet > DNS privado > Nome do host: ${ANDROID_PRIVATE_DNS}
     (DNS criptografado para o celular inteiro; troque por dns.adguard-dns.com para bloquear anuncios)
  2. Instale o Proton VPN ou o DuckDuckGo VPN e conecte.
  3. Configuracoes > Rede e internet > VPN > (app da VPN) > ative
     "VPN sempre ativa" e "Bloquear conexoes sem VPN"  <- este e o kill switch
  4. Para bloquear rastreadores dos apps, use o App Tracking Protection do DuckDuckGo
     (ele ocupa o slot de VPN: nao funciona junto com outra VPN).
GUIA
}

termux_noroot() {
  state_init
  warn "Termux sem root: sem /dev/tun e sem firewall. VPN local e kill switch NAO podem ser ligados por aqui."
  if [[ "$ENV_OS" == termux ]]; then
    pkg_refresh
    need curl curl curl curl
    need tor tor tor tor
    need torsocks torsocks torsocks torsocks
    need proxychains4 proxychains-ng proxychains-ng proxychains-ng
  else
    have tor || die "sem root e sem sudo: instale o tor manualmente ou rode com sudo"
  fi
  TOR_ENABLED=1
  setup_tor
  if [[ "$DRY_RUN" != 1 ]]; then
    printf 'strict_chain\nproxy_dns\ntcp_read_time_out 15000\ntcp_connect_time_out 8000\n[ProxyList]\nsocks5 127.0.0.1 9050\n' > "$STATE_DIR/proxychains.conf"
  fi
  ok "proxychains: proxychains4 -f $STATE_DIR/proxychains.conf <comando>"
  termux_guide
  state_set active "$(date +%s)"
}

termux_root() {
  warn "Termux com root: VPN + kill switch via iptables (experimental: o roteamento do Android varia por fabricante)"
  [[ "$ENV_TUN" == 1 ]] || die "sem /dev/tun mesmo com root: use o app da VPN com 'Bloquear conexoes sem VPN'"
  state_init
  pkg_refresh
  need curl curl curl curl
  need wg-quick wireguard-tools wireguard-tools wireguard-tools
  [[ "$TOR_ENABLED" == 1 ]] && need tor tor tor tor && need torsocks torsocks torsocks torsocks
  local ep ep_ip ep_port
  ep="$(wg_endpoint "$VPN_CONFIG_PATH")" || die "Endpoint nao encontrado em $VPN_CONFIG_PATH"
  ep_ip="$(resolve_ipv4 "${ep% *}")"; ep_port="${ep#* }"
  setup_vpn
  setup_killswitch "$ep_ip" "$ep_port"
  setup_tor
  termux_guide
  state_set active "$(date +%s)"
}

# ---------------------------------------------------------------- main
info "anon-up: $ENV_DISTRO · root=$ENV_ROOT · tun=$ENV_TUN · pacotes=${ENV_PKG:-nenhum}"
[[ "$DRY_RUN" == 1 ]] && warn "modo --dry-run: nada sera alterado"

if [[ "$ONLY_LISTS" == 1 ]]; then
  [[ "$ENV_ROOT" == 1 ]] || die "--update-lists precisa de root"
  state_init; build_blocklist
  pid_alive dnsmasq.pid && run kill -HUP "$(state_get dnsmasq.pid)"
  exit 0
fi

if [[ "$ENV_OS" == linux && "$ENV_ROOT" == 1 ]]; then linux_root
elif [[ "$ENV_OS" == termux && "$ENV_ROOT" == 1 ]]; then termux_root
else termux_noroot
fi

trap - ERR
echo
if [[ "$DRY_RUN" == 1 ]]; then ok "dry-run terminado"; exit 0; fi
bash "$ANON_DIR/anon-status.sh" || warn "o teste de vazamento achou problemas (veja acima)"
