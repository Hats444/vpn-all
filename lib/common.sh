#!/usr/bin/env bash
# lib/common.sh — funcoes compartilhadas pelo anon-up, anon-down e anon-status.
# Nada aqui altera o sistema sozinho: so define funcoes e variaveis.

# ---------------------------------------------------------------- caminhos
ANON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${ANON_CONFIG:-$ANON_DIR/config.env}"
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------- log colorido
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Executa um comando, ou so mostra quando DRY_RUN=1 (modo de teste).
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '%s[dry]%s %s\n' "$C_D" "$C_0" "$*"
  else
    "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- config
# shellcheck disable=SC2034  # variaveis usadas pelos scripts que carregam este arquivo
load_config() {
  # Valores padrao: o config.env sobrescreve o que quiser.
  VPN_CONFIG_PATH=""
  WG_IFACE="anon0"
  DNS_UPSTREAM="quad9-doh-ip4-port443-filter-pri mullvad-doh"
  BLOCKLIST_URLS="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt https://big.oisd.nl"
  BLOCKLIST_MAX_AGE_H=24
  BLOCK_ENABLED=1
  TOR_ENABLED=0
  KILLSWITCH=1
  ALLOW_LAN=0
  BLOCK_IPV6=1
  MAC_RANDOMIZE=1
  DISABLE_LEAKY_SERVICES=1
  GENERIC_HOSTNAME="anon-host"
  ANDROID_PRIVATE_DNS="dns.mullvad.net"
  if [[ -f "$CONFIG_FILE" ]]; then
    check_config_perms
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  else
    warn "config.env nao encontrado em $CONFIG_FILE; usando padroes"
  fi
  [[ "$WG_IFACE" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || die "WG_IFACE invalido: $WG_IFACE"
}

# O config.env pode apontar para chaves: so aceita se ninguem alem do dono puder ler/escrever.
check_config_perms() {
  local perm
  perm="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo 600)"
  if [[ "${perm: -2}" != "00" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
      warn "config.env com permissao $perm (o certo e 600)"
    else
      warn "config.env com permissao $perm; corrigindo para 600"
      chmod 600 "$CONFIG_FILE" || die "nao consegui aplicar chmod 600 em $CONFIG_FILE"
    fi
  fi
}

# ---------------------------------------------------------------- ambiente
# shellcheck disable=SC2034  # ENV_* sao lidas pelos scripts
# Preenche: ENV_OS (linux|termux), ENV_ROOT (0|1), ENV_PKG, ENV_TUN (0|1), STATE_DIR.
detect_env() {
  if [[ -n "${TERMUX_VERSION:-}" || "${PREFIX:-}" == *com.termux* ]]; then
    ENV_OS="termux"
  else
    ENV_OS="linux"
  fi
  if [[ "${ANON_FORCE_ROOT:-0}" == 1 || "$(id -u)" == 0 ]]; then ENV_ROOT=1; else ENV_ROOT=0; fi
  if [[ -c /dev/net/tun || -c /dev/tun ]]; then ENV_TUN=1; else ENV_TUN=0; fi
  ENV_PKG=""
  if [[ "$ENV_OS" == termux ]]; then ENV_PKG="pkg"
  elif have apt-get; then ENV_PKG="apt"
  elif have pacman; then ENV_PKG="pacman"
  elif have dnf; then ENV_PKG="dnf"
  fi
  if [[ "$ENV_ROOT" == 1 && "$ENV_OS" == linux ]]; then
    STATE_DIR="${ANON_STATE_DIR:-/var/lib/anon-up}"
  else
    STATE_DIR="${ANON_STATE_DIR:-$HOME/.anon-up}"
  fi
  ENV_DISTRO="desconhecida"
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    ENV_DISTRO="$(. /etc/os-release && echo "${PRETTY_NAME:-$ID}")"
  fi
  if [[ "$ENV_OS" == termux ]]; then ENV_DISTRO="Termux ${TERMUX_VERSION:-}"; fi
}

# Reexecuta o script como root (sudo no Linux, su no Termux) quando possivel.
maybe_elevate() {
  [[ "$ENV_ROOT" == 1 || "$DRY_RUN" == 1 ]] && return 0
  local args; args="$(printf '%q ' "$@")"
  if [[ "$ENV_OS" == linux ]] && have sudo; then
    info "pedindo sudo para configurar rede e firewall"
    exec sudo -E bash "$0" "$@"
  elif [[ "$ENV_OS" == termux ]] && have su && su -c true >/dev/null 2>&1; then
    info "root detectado no Termux; reexecutando com su"
    exec su -c "PATH='$PATH' PREFIX='$PREFIX' HOME='$HOME' TERMUX_VERSION='${TERMUX_VERSION:-}' bash '$0' $args"
  fi
}

# ---------------------------------------------------------------- dependencias
# need <comando> <pacote-apt> <pacote-pacman> <pacote-pkg> [pacote-dnf]
need() {
  local cmd="$1" p_apt="$2" p_pac="$3" p_pkg="$4" p_dnf="${5:-$2}"
  have "$cmd" && return 0
  info "instalando $cmd"
  case "$ENV_PKG" in
    apt)    run apt-get install -y -qq "$p_apt" ;;
    pacman) run pacman -S --noconfirm --needed "$p_pac" ;;
    dnf)    run dnf install -y -q "$p_dnf" ;;
    pkg)    run pkg install -y "$p_pkg" ;;
    *)      die "sem gerenciador de pacotes conhecido para instalar $cmd" ;;
  esac
  [[ "$DRY_RUN" == 1 ]] || have "$cmd" || die "falhou instalar $cmd"
}

pkg_refresh() {
  case "$ENV_PKG" in
    apt) run apt-get update -qq ;;
    pkg) run pkg update -y ;;
  esac
}

# ---------------------------------------------------------------- estado
# Tudo que for alterado e anotado em STATE_DIR para o anon-down desfazer.
state_init() { run mkdir -p "$STATE_DIR"; run chmod 700 "$STATE_DIR"; }
state_set()  { [[ "$DRY_RUN" == 1 ]] || printf '%s\n' "$2" > "$STATE_DIR/$1"; }
state_get()  { [[ -f "$STATE_DIR/$1" ]] && cat "$STATE_DIR/$1"; }
state_has()  { [[ -f "$STATE_DIR/$1" ]]; }
state_del()  { [[ "$DRY_RUN" == 1 ]] || rm -f "$STATE_DIR/$1"; }

pid_alive() { local p; p="$(state_get "$1" 2>/dev/null)" && [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }

svc_active() { have systemctl && systemctl is-active --quiet "$1" 2>/dev/null; }

# ---------------------------------------------------------------- rede
public_ip_json() { curl -fsS -m 10 https://am.i.mullvad.net/json 2>/dev/null || true; }
public_ip()      { curl -fsS -m 10 https://am.i.mullvad.net/ip 2>/dev/null || curl -fsS -m 10 https://api.ipify.org 2>/dev/null || true; }

# Le "Endpoint = host:porta" do .conf do WireGuard. Saida: "host porta".
wg_endpoint() {
  local line hp host port
  line="$(grep -iE '^[[:space:]]*Endpoint[[:space:]]*=' "$1" | head -n1)" || return 1
  hp="$(printf '%s' "${line#*=}" | tr -d '[:space:]')"
  port="${hp##*:}"
  host="${hp%:*}"
  host="${host#[}"; host="${host%]}"
  [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$host" "$port"
}

resolve_ipv4() {
  if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$1"; return 0; fi
  getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'
}
