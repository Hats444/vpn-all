#!/usr/bin/env bash
# lib/render.sh — gera os arquivos de configuracao (firewall, DNS, Tor).
# So imprime texto: quem aplica e o anon-up. Isso permite validar tudo em teste.

# Kill switch nftables: so sai trafego pela interface da VPN, loopback e o endpoint.
# render_nft <iface> <endpoint-ip> <endpoint-porta> <allow_lan 0|1> <block_ipv6 0|1>
render_nft() {
  local ifc="$1" ep="$2" port="$3" lan="$4" v6="$5"
  cat <<NFT
table inet anon_up {
  chain output {
    type filter hook output priority 0; policy drop;
    # loopback (DNS local, Tor SOCKS) sempre liberado
    oifname "lo" accept
    # tudo que passa pelo tunel da VPN pode sair
    oifname "$ifc" accept
    # so o handshake com o servidor da VPN sai pela rede fisica
    ip daddr $ep udp dport $port accept
    # DHCP para nao perder o IP da rede local
    udp sport 68 udp dport 67 accept
NFT
  if [[ "$lan" == 1 ]]; then
    cat <<'NFT'
    # ALLOW_LAN=1: impressora, NAS e roteador da rede local
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } accept
NFT
  fi
  if [[ "$v6" == 1 ]]; then
    echo '    # IPv6 bloqueado fora do tunel (evita vazar o prefixo real)'
    echo '    meta nfproto ipv6 drop'
  fi
  cat <<NFT
  }
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
    ct state established,related accept
    iifname "$ifc" ct state established,related accept
    udp sport 67 udp dport 68 accept
NFT
  if [[ "$lan" == 1 ]]; then
    echo '    ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } accept'
  fi
  cat <<'NFT'
  }
}
NFT
}

# Mesmo kill switch em iptables (fallback e Android). Imprime comandos, um por linha.
render_iptables() {
  local ifc="$1" ep="$2" port="$3" lan="$4" v6="$5"
  cat <<IPT
iptables -N ANON_UP_OUT
iptables -A ANON_UP_OUT -o lo -j ACCEPT
iptables -A ANON_UP_OUT -o $ifc -j ACCEPT
iptables -A ANON_UP_OUT -d $ep -p udp --dport $port -j ACCEPT
iptables -A ANON_UP_OUT -p udp --sport 68 --dport 67 -j ACCEPT
IPT
  if [[ "$lan" == 1 ]]; then
    for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
      echo "iptables -A ANON_UP_OUT -d $n -j ACCEPT"
    done
  fi
  echo "iptables -A ANON_UP_OUT -j DROP"
  echo "iptables -I OUTPUT 1 -j ANON_UP_OUT"
  if [[ "$v6" == 1 ]] && have ip6tables; then
    echo "ip6tables -N ANON_UP_OUT6"
    echo "ip6tables -A ANON_UP_OUT6 -o lo -j ACCEPT"
    echo "ip6tables -A ANON_UP_OUT6 -j DROP"
    echo "ip6tables -I OUTPUT 1 -j ANON_UP_OUT6"
  fi
}

# DNS local com bloqueio de rastreadores (o "App Tracking Protection" do sistema).
# render_dnsmasq <arquivo-hosts-bloqueio|""> <pidfile>
render_dnsmasq() {
  cat <<DNS
# gerado pelo anon-up
listen-address=127.0.0.1
port=53
bind-interfaces
no-resolv
no-hosts
domain-needed
bogus-priv
cache-size=10000
pid-file=$2
# upstream: dnscrypt-proxy local (DoH), nunca o DNS do provedor
server=127.0.0.1#5353
DNS
  [[ -n "$1" ]] && echo "addn-hosts=$1"
  return 0
}

# DNS criptografado (DoH) via dnscrypt-proxy, ouvindo so em 127.0.0.1:5353.
# render_dnscrypt <cache-dir> <servidores separados por espaco>
render_dnscrypt() {
  local names="" s
  for s in $2; do names+="'$s', "; done
  cat <<TOML
# gerado pelo anon-up
listen_addresses = ['127.0.0.1:5353']
server_names = [${names%, }]
ipv4_servers = true
ipv6_servers = false
doh_servers = true
dnscrypt_servers = true
require_dnssec = false
require_nolog = true
require_nofilter = false
bootstrap_resolvers = ['9.9.9.9:53', '1.1.1.1:53']
ignore_system_dns = true
netprobe_address = '9.9.9.9:53'
block_ipv6 = true
cache = true

[sources]
  [sources.public-resolvers]
    urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
    cache_file = '$1/public-resolvers.md'
    minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
    refresh_delay = 72
TOML
}

# Tor com SOCKS em 9050 e DNS em 9053 (so local).
render_torrc() {
  cat <<TOR
# gerado pelo anon-up
SocksPort 127.0.0.1:9050
DNSPort 127.0.0.1:9053
DataDirectory $1
Log notice file $1/tor.log
ClientUseIPv6 0
AvoidDiskWrites 1
TOR
}

# Junta listas (formato hosts, dominio puro ou adblock "||dominio^") em "0.0.0.0 dominio".
normalize_blocklist() {
  sed -e 's/\r$//' -e 's/#.*$//' -e 's/!.*$//' \
  | awk '
      /^\|\|[^\/]+\^/ { d=$0; sub(/^\|\|/,"",d); sub(/\^.*$/,"",d); print d; next }
      NF>=2 && ($1=="0.0.0.0" || $1=="127.0.0.1" || $1=="::") { print $2; next }
      NF==1 && $1 ~ /\./ { print $1 }
    ' \
  | tr '[:upper:]' '[:lower:]' \
  | grep -E '^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)+$' \
  | grep -vxE 'localhost|localhost\.localdomain|local|broadcasthost|ip6-localhost|ip6-loopback|0\.0\.0\.0' \
  | sort -u \
  | sed 's/^/0.0.0.0 /'
}
