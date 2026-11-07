#!/usr/bin/env bash
# antseed-fleet - many independent Antseed gateways on one VPS.
#
# v2.0.0 - collision-proof edition:
#   * STRICT port registry: a port, once allocated, is never reused - not even
#     after an instance is removed (persisted in <state>/ports.reserved).
#   * Global lock so two installers running at the same time cannot pick the
#     same ports, tunnel names or hostnames.
#   * Tunnel names are checked against the whole Cloudflare account, not just
#     local state; a foreign tunnel with a clashing name is never hijacked -
#     a new name (<inst>-gateway-2, -3, ...) is generated instead.
#   * Hostnames are checked against live DNS before they are handed out.
#   * Scales to thousands of instances (high-water-mark port allocator).
#
#   bash install.sh          (or: curl -fsSL <get.sh> | sudo bash)
#
#  1. asks for the Cloudflare API token (never stored on disk)
#  2. lists every zone on the account and lets you pick one
#  3. asks for the name: <NAME>1.<domain>, <NAME>2.<domain>, ...  (next free N)
#  4. inspects the VPS, shows the sizing table and how many instances fit,
#     then asks how many to create
#  5. builds them one by one: system user, data dir, wallets, database, ports,
#     systemd units, Cloudflare tunnel and public hostname
#
# Non-interactive (CI, cloud-init):
#   CF_API_TOKEN=... DOMAIN=example.com NAME=api COUNT=2 bash install.sh --yes
#
# Exit codes: 0 ok, 1 usage/validation, 2 cancelled, 3 failed mid-way.

set -Eeuo pipefail

VERSION="2.0.0"
PREFIX="${ANTSEED_FLEET_PREFIX:-antseed}"
STATE_DIR="/etc/${PREFIX}-fleet"
UNIT_DIR="/etc/systemd/system"
CLI_BIN="/opt/antseed/current/bin/antseed"
CLI_NODE_PATH="/opt/antseed/node/bin"
CF_API="https://api.cloudflare.com/client/v4"
INSTALL_SH="https://antseed.com/install.sh"
LOCK_FILE="/var/lock/${PREFIX}-fleet.lock"
PORT_REGISTRY="$STATE_DIR/ports.reserved"
PORT_HWM="$STATE_DIR/ports.hwm"
NAME_REGISTRY="$STATE_DIR/tunnels.reserved"
HOST_REGISTRY="$STATE_DIR/hosts.reserved"

# Adaptive port range. Kept clear of the antseed base services (8377/8379) and
# the common daemon range, wide enough for thousands of instances.
PORT_RANGE_LO="${ANTSEED_PORT_RANGE_LO:-20000}"
PORT_RANGE_HI="${ANTSEED_PORT_RANGE_HI:-40000}"

ASSUME_YES=0
INSTANCE_NAME=""
DOMAIN=""

while (( $# )); do
  case $1 in
    --token)   CF_API_TOKEN=$2; shift 2 ;;
    --domain)  DOMAIN=$2; shift 2 ;;
    --name)    INSTANCE_NAME=$2; shift 2 ;;
    --mode)    die "--mode is no longer supported: every instance gets its own subdomain (api1.example.com)" 1 ;;
    --count)   COUNT=$2; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --version) echo "antseed-fleet $VERSION"; exit 0 ;;
    --help|-h) printf '%s\n' "usage: install.sh [--token T] [--domain D] [--name N] [--count N] [--yes]"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

MEM_PER_INSTANCE_MIB="${ANTSEED_MEM_PER_INSTANCE_MIB:-900}"
MEM_RESERVE_MIB="${ANTSEED_MEM_RESERVE_MIB:-1024}"
DISK_PER_INSTANCE_MIB="${ANTSEED_DISK_PER_INSTANCE_MIB:-400}"

# --------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
  C_D=$'\033[2m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_BOLD=''; C_0=''
fi

step() { printf '\n%s\n' "${C_B}${C_BOLD}> $*${C_0}"; }
info() { printf '%s\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '%s\n' "${C_G}[ok]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[!!]${C_0} $*" >&2; }
die() {
  local code=1
  if (( $# >= 2 )) && [[ ${!#} =~ ^[0-9]+$ ]]; then
    code=${!#}
    set -- "${@:1:$(($# - 1))}"
  fi
  printf '%s\n' "${C_R}[x] $*${C_0}" >&2
  exit "$code"
}

have_tty() { ( exec 3<>/dev/tty ) 2>/dev/null; }

interactive() {
  [[ $ASSUME_YES -eq 0 ]] || return 1
  [[ -t 1 ]] || return 1
  have_tty
}

ask() {
  local prompt=$1 default=${2:-} answer=
  if [[ $ASSUME_YES -eq 0 ]] && have_tty; then
    if [[ -n $default ]]; then
      read -r -p "$prompt [$default]: " answer </dev/tty || true
      printf '%s' "${answer:-$default}"
    else
      read -r -p "$prompt: " answer </dev/tty || true
      printf '%s' "$answer"
    fi
  else
    printf '%s' "$default"
  fi
}

ask_secret() {
  local prompt=$1 answer=
  if [[ $ASSUME_YES -eq 0 ]] && have_tty; then
    read -r -s -p "$prompt: " answer </dev/tty || true
    printf '\n' >/dev/tty
  elif [[ $ASSUME_YES -eq 0 && ! -t 0 && ! -p /dev/stdin ]]; then
    read -r answer || true
  fi
  printf '%s' "$answer"
}

confirm() {
  local q=$1 answer
  [[ $ASSUME_YES -eq 0 ]] || return 0
  have_tty || return 0
  read -r -p "$q [Y/n]: " answer </dev/tty || true
  case ${answer:-y} in [yY]|"") return 0 ;; *) return 1 ;; esac
}

trap 'die "failed at line $LINENO: $BASH_COMMAND" 3' ERR

# ---------------------------------------------------------- prerequisites

case "$(uname -s)" in
  Linux) ;;
  *) die "this script targets Linux with systemd (use WSL or a Linux VPS)" ;;
esac
command -v systemctl >/dev/null || die "systemd is required"
[[ $EUID -eq 0 ]] || die "run as root (sudo bash $0)"
[[ -f /etc/os-release ]] || die "unknown distribution"
command -v curl >/dev/null || die "curl is required"

ensure_cli() {
  if [[ -x $CLI_BIN ]]; then
    ok "Antseed CLI present"
    return 0
  fi
  info "Antseed CLI not found - installing the base gateway (Node.js + CLI)"
  curl -fsSL --proto '=https' --tlsv1.2 "$INSTALL_SH" | bash -s -- --public-url "http://127.0.0.1:8379" >/tmp/antseed-base-install.log 2>&1 || {
    tail -20 /tmp/antseed-base-install.log >&2
    die "base gateway install failed (log: /tmp/antseed-base-install.log)"
  }
  [[ -x $CLI_BIN ]] || die "installer finished but $CLI_BIN is missing"
  ok "Antseed CLI installed"
}

# ---------------------------------------------------------- cloudflare

cf() {
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl -fsS -m 60 -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -m 60 -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

cfj() {
  local expr=$1
  shift || true
  node -e '
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  let j;
  try { j = JSON.parse(s); }
  catch (e) { console.error("bad JSON from Cloudflare"); process.exit(1); }
  if (j.success === false) { console.error("Cloudflare error:", JSON.stringify(j.errors)); process.exit(1); }
  const argv = process.argv.slice(2);
  const v = eval(process.argv[1]);
  process.stdout.write(v === undefined || v === null ? "" : String(v));
});' "$expr" "$@"
}

cf_verify() {
  [[ -n ${CF_API_TOKEN:-} ]] || die "no Cloudflare API token"
  local status
  status=$(cf GET /user/tokens/verify 2>/dev/null | cfj 'j.result.status' || true)
  [[ $status == active ]] || die "Cloudflare token is not active"
  local accounts
  accounts=$(cf GET /accounts | cfj '(j.result||[]).map(a => a.id + "\t" + a.name).join("\n")')
  [[ -n $accounts ]] || die "token cannot list accounts (needs Account Settings: Read)"
  ACCOUNT_ID=$(head -1 <<<"$accounts" | cut -f1)
  ACCOUNT_NAME=$(head -1 <<<"$accounts" | cut -f2)
}

list_zones() {
  cf GET "/zones?per_page=50" | cfj '(j.result||[]).map(z => z.name + "\t" + z.id + "\t" + z.status).join("\n")'
}

cf_zone_id() {
  local name=$1 z
  z=$(cf GET "/zones?name=$name" 2>/dev/null | cfj 'j.result[0]?.id || ""' || true)
  [[ -n $z ]] && { printf '%s' "$z"; return 0; }
  return 1
}

zone_root() {
  local host=$1
  host=${host#*.}
  while [[ $host == *.* ]]; do
    if cf_zone_id "$host" >/dev/null 2>&1; then printf '%s' "$host"; return 0; fi
    host=${host#*.}
  done
  return 1
}

# ------------------------------------------------------------- resources

mem_total_mib() { awk '/MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo; }
mem_avail_mib() { awk '/MemAvailable/ { printf "%d", $2 / 1024 }' /proc/meminfo; }
disk_avail_mib() { df -Pm /var/lib | awk 'NR == 2 { print $4 }'; }

print_sizing_table() {
  local fits=$1 mine=$(( ($3 + 512) / 1024 )) t rec row total fit
  printf '    %-9s %-16s %-9s %s\n' "RAM VPS" "BUDGET" "FITS" "MARK"
  printf '    %-9s %-16s %-9s %s\n' "--------" "----------------" "---------" "----"
  for t in 1024 2048 3072 4096 6144 8192 12288 16384 24576 32768 49152 65536; do
    rec=$(($2 > 0 ? (t - MEM_RESERVE_MIB) / $2 : 0))
    (( rec < 1 )) && rec=1
    if (( t % 1024 == 0 )); then
      printf -v total '%d GB' $((t / 1024))
    else
      printf -v total '%.1f GB' "$(awk -v m="$t" 'BEGIN { print m / 1024 }')"
    fi
    fit=""
    (( t / 1024 == mine )) && fit="  <- this VPS"
    printf '    %-9s %-16s %-9s%s\n' "$total" "$2 MiB" "$rec" "$fit"
  done
  printf '    %-9s %-16s %-9s%s\n' "now" "free RAM" "$fits" "  <- can be created right now"
}

recommend_count() {
  local avail by_mem by_disk
  avail=$(mem_avail_mib)
  by_mem=$(( (avail - MEM_RESERVE_MIB) / MEM_PER_INSTANCE_MIB ))
  (( by_mem < 0 )) && by_mem=0
  by_disk=$(( $(disk_avail_mib) / DISK_PER_INSTANCE_MIB ))
  echo "$by_mem $by_disk $avail"
}

# ------------------------------------------------------------- naming

sanitize_name() {
  local n
  n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
  printf '%s' "$n"
}

host_for() { printf '%s%d.%s' "$1" "$2" "$3"; }

next_host_num() {
  local name=$1 max=0 host
  for host in $(existing_instances | awk '{ print $2 }'); do
    if [[ $host =~ ^${name}([0-9]+)\. ]]; then
      (( BASH_REMATCH[1] > max )) && max=${BASH_REMATCH[1]}
    fi
  done
  echo $((max + 1))
}

host_taken_by_other() {
  local rec
  rec=$(cf GET "/zones/$ZONE_ID/dns_records?name=$1" 2>/dev/null |
    cfj '(j.result[0] && j.result[0].content) || ""' || true)
  printf '%s' "$rec"
}

assert_tunnel_owner() {
  local owner remote
  remote=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$2" 2>/dev/null |
    cfj 'j.result?.name || ""' || true)
  [[ -n $remote ]] || die "tunnel $2 does not exist" 3
  for owner in $(instance_names); do
    [[ $owner == "$1" ]] && continue
    local other
    other=$(sed -n 's/^TUNNEL_ID=//p' "$(state_file "$owner")" 2>/dev/null || true)
    [[ $other == "$2" ]] && die "tunnel $2 already belongs to $owner - refusing to share it" 3
  done
  [[ $remote == "$1-gateway" || $remote == "$1-gateway-"* ]] ||
    die "tunnel $2 is named '$remote', not '$1-gateway*' - refusing to reuse it" 3
}

# ---------------------------------------------------------- strict registries

acquire_lock() {
  install -d -m 755 "$STATE_DIR"
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  if ! flock -w 120 9; then
    die "another antseed-fleet run is holding the lock ($LOCK_FILE) - try again in a moment" 3
  fi
}

registry_touch() {
  install -d -m 700 "$STATE_DIR"
  touch "$PORT_REGISTRY" "$NAME_REGISTRY" "$HOST_REGISTRY"
  chmod 600 "$PORT_REGISTRY" "$NAME_REGISTRY" "$HOST_REGISTRY" 2>/dev/null || true
}

reserve_port() {
  local p=$1 cur=0
  echo "$p" >>"$PORT_REGISTRY"
  # keep the O(1) high-water mark in sync: highest port ever reserved + 1.
  [[ -f $PORT_HWM ]] && cur=$(cat "$PORT_HWM" 2>/dev/null || echo 0)
  [[ $cur =~ ^[0-9]+$ ]] || cur=0
  [[ $p =~ ^[0-9]+$ ]] || return 0
  if (( p >= cur )); then
    echo $(( p + 1 )) >"$PORT_HWM"
  fi
}
reserve_name() { echo "$1" >>"$NAME_REGISTRY"; }
reserve_host() { echo "$1" >>"$HOST_REGISTRY"; }

port_in_registry() { grep -qx -- "$1" "$PORT_REGISTRY" 2>/dev/null; }
name_in_registry() { grep -qix -- "$1" "$NAME_REGISTRY" 2>/dev/null; }
host_in_registry() { grep -qix -- "$1" "$HOST_REGISTRY" 2>/dev/null; }

# ------------------------------------------------------------- instances

state_file() { echo "$STATE_DIR/$1.env"; }

instance_names() {
  local f
  for f in "$STATE_DIR"/*.env; do
    [[ -e $f ]] || continue
    basename "$f" .env
  done | sort -V
}

existing_instances() {
  local n
  while read -r n; do
    [[ -n $n ]] || continue
    ( . "$(state_file "$n")"; echo "$INSTANCE $HOST" )
  done <<<"$(instance_names)"
}

instance_exists() { [[ -f $(state_file "$1") ]]; }

load_instance() {
  local f
  [[ -n ${1:-} ]] || die "instance name required"
  f=$(state_file "$1")
  [[ -f $f ]] || die "instance '$1' not found (see: antseed-fleet list)"
  . "$f"
}

as_instance() {
  local user=$1 home=$2
  shift 2
  runuser -u "$user" -- env HOME="$home" PATH="$CLI_NODE_PATH:/usr/bin:/bin" "$CLI_BIN" "$@"
}

# ---- port probing -------------------------------------------------------
port_busy() {
  local p=$1
  if ss -Htanu 2>/dev/null | awk -v p="$p" '
      { n = split($4, a, /[:.]/); if (a[n] == p) { f = 1; exit }
        n = split($5, b, /[:.]/); if (b[n] == p) { f = 1; exit } }
      END { exit f ? 0 : 1 }'; then return 0; fi
  local hex
  hex=$(printf '%04X' "$p")
  if grep -qiE ":$hex[[:space:]]" /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null; then
    return 0
  fi
  if grep -rqsE -- "--port[= ][\"']?$p([\"' ]|$)" "$UNIT_DIR" 2>/dev/null; then return 0; fi
  if grep -qE "[[:space:]]${p}/" /etc/services 2>/dev/null; then return 0; fi
  return 1
}

baseline_ports() {
  local unit="$UNIT_DIR/antseed-buyer.service" bport=""
  [[ -f $unit ]] || return 0
  bport=$(sed -n 's/.*buyer start --port \([0-9][0-9]*\).*/\1/p' "$unit" | head -1)
  echo "8379 ${bport:-8377}"
}

# Strict allocator. Never reuses a port that is listening, reserved by the
# registry, used by another unit, or listed in /etc/services.
#
# Scalability: the registry is append-only and ports are handed out in
# increasing order, so everything below the high-water mark is taken and the
# next candidate is simply the HWM (cached in ports.hwm -> O(1) per call).
# Live sockets are read once from /proc/net into a string, so probing a
# candidate costs no subprocess. A full wrap-around scan is only needed once
# the HWM reaches the end of the window.
alloc_ports() {
  local gw="" buyer=""
  local max_tries=$(( PORT_RANGE_HI - PORT_RANGE_LO + 1 ))
  local base_live; base_live=" $(baseline_ports) "

  # preload live ports once (pure bash)
  local live_ports=" "
  local _f _line _local _hexport _dec _first
  for _f in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
    [[ -r $_f ]] || continue
    _first=1
    while IFS= read -r _line; do
      if (( _first )); then _first=0; continue; fi
      _local=${_line#*: }
      _local=${_local%% *}
      _hexport=${_local##*:}
      [[ $_hexport =~ ^[0-9A-Fa-f]{1,4}$ ]] || continue
      _dec=$(( 16#$_hexport ))
      live_ports+="$_dec "
    done <"$_f"
  done

  live_free() {
    local p=$1
    (( p < PORT_RANGE_LO || p > PORT_RANGE_HI )) && return 1
    [[ $base_live == *" $p "* ]] && return 1
    [[ $live_ports == *" $p "* ]] && return 1
    return 0
  }

  # high-water mark
  local hw=""
  [[ -f $PORT_HWM ]] && hw=$(cat "$PORT_HWM" 2>/dev/null || true)
  if ! [[ $hw =~ ^[0-9]+$ ]]; then
    local reserved
    reserved=$(instance_names | while read -r n; do
      local f="$STATE_DIR/$n.env"
      [[ -f $f ]] && ( . "$f"; echo "$GW_PORT"; echo "$BUYER_PORT" )
    done)
    hw=$PORT_RANGE_LO
    {
      cat "$PORT_REGISTRY" 2>/dev/null || true
      echo "$reserved"
      baseline_ports
    } | tr -s '[:space:]' '\n' | awk 'NF' | sort -n | tail -1 |
      { read -r last; [[ -n ${last:-} ]] && hw=$(( last + 1 )); }
    [[ $hw =~ ^[0-9]+$ ]] || hw=$PORT_RANGE_LO
    echo "$hw" >"$PORT_HWM" 2>/dev/null || true
  fi
  (( hw < PORT_RANGE_LO )) && hw=$PORT_RANGE_LO

  if (( hw <= PORT_RANGE_HI )); then
    local p=$hw i
    for (( i = 0; i < max_tries; i++ )); do
      if (( p > PORT_RANGE_HI )); then p=$PORT_RANGE_LO; fi
      if (( p >= hw )); then
        if [[ -z $gw ]]; then
          live_free "$p" && gw=$p
        elif [[ -z $buyer ]]; then
          (( p != gw )) && live_free "$p" && buyer=$p
        fi
      else
        break
      fi
      [[ -n $gw && -n $buyer ]] && break
      p=$((p + 1))
    done
    if [[ -n $gw && -n $buyer ]]; then
      printf '%s %s\n' "$gw" "$buyer"
      return 0
    fi
  fi

  # exact scan (window nearly full): build a busy-set once, walk the window
  gw=""; buyer=""
  declare -A busy=()
  local port
  {
    cat "$PORT_REGISTRY" 2>/dev/null || true
    instance_names | while read -r n; do
      local f="$STATE_DIR/$n.env"
      [[ -f $f ]] && ( . "$f"; echo "$GW_PORT"; echo "$BUYER_PORT" )
    done
    tr ' ' '\n' <<<"$base_live"
  } | tr -s '[:space:]' '\n' | awk 'NF' >"$STATE_DIR/.busy.$$"
  while IFS= read -r port; do busy[$port]=1; done <"$STATE_DIR/.busy.$$"
  rm -f "$STATE_DIR/.busy.$$"

  port=$PORT_RANGE_LO
  local i
  for (( i = 0; i < max_tries; i++ )); do
    if [[ -z ${busy[$port]:-} ]] && live_free "$port"; then
      if [[ -z $gw ]]; then
        gw=$port
      elif (( port != gw )); then
        buyer=$port
        break
      fi
    fi
    port=$((port + 1))
    (( port > PORT_RANGE_HI )) && port=$PORT_RANGE_LO
  done

  [[ -n $gw && -n $buyer ]] || die "no free ports in $PORT_RANGE_LO-$PORT_RANGE_HI - widen ANTSEED_PORT_RANGE_*" 3
  printf '%s %s\n' "$gw" "$buyer"
}

wait_port() {
  local port=$1 tries=${2:-60} i
  for (( i = 0; i < tries; i++ )); do
    port_busy "$port" && return 0
    sleep 1
  done
  return 1
}

# ---- tunnel name allocator ----------------------------------------------
cf_tunnel_names() {
  cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?is_deleted=false&per_page=200" 2>/dev/null |
    cfj '(j.result||[]).map(t => t.name).join("\n")' || true
}

alloc_tunnel_name() {
  local inst=$1
  local all_tunnels
  all_tunnels=$(cf_tunnel_names)

  local own_id=""
  if instance_exists "$inst"; then
    own_id=$(sed -n 's/^TUNNEL_ID=//p' "$(state_file "$inst")" | head -1)
  fi

  local candidate="$inst-gateway" n=2
  while (:); do
    local taken=0
    if [[ -n $own_id ]]; then
      local owner_name
      owner_name=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$own_id" 2>/dev/null |
        cfj 'j.result?.name || ""' || true)
      [[ $owner_name == "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    fi
    grep -qxF -- "$candidate" <<<"$all_tunnels" && taken=1
    if name_in_registry "$candidate" && (( taken == 0 )); then
      local st="$STATE_DIR/$inst.env"
      if [[ -f $st ]]; then
        local rn; rn=$(sed -n 's/^TUNNEL_NAME=//p' "$st" | head -1)
        [[ $rn == "$candidate" ]] || taken=1
      else
        taken=1
      fi
    fi
    (( taken == 0 )) && { printf '%s' "$candidate"; return 0; }
    candidate="$inst-gateway-$n"; n=$((n + 1))
    (( n > 9999 )) && die "cannot find a free tunnel name for $inst (checked 9999 variants)" 3
  done
}

# ---- host allocator -----------------------------------------------------
alloc_host() {
  local name=$1 domain=$2
  local n; n=$(next_host_num "$name")
  local guard=0
  while (:); do
    local h; h=$(host_for "$name" "$n" "$domain")
    local taken=0
    host_in_registry "$h" && taken=1
    if (( taken == 0 )) && [[ -n ${ZONE_ID:-} ]]; then
      local router; router=$(host_taken_by_other "$h" || true)
      [[ -n $router ]] && taken=1
    fi
    (( taken == 0 )) && { printf '%s' "$h"; return 0; }
    n=$((n + 1)); guard=$((guard + 1))
    (( guard > 100000 )) && die "cannot find a free host number for $name.$domain" 3
  done
}

write_units() {
  local name=$1 user=$2 home=$3 gw=$4 buyer=$5

  cat >"$UNIT_DIR/$name-buyer.service" <<UNIT
[Unit]
Description=Antseed buyer ($name)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$CLI_BIN buyer start --port $buyer
Environment=ANTSEED_SUPERVISED=1
Environment=MALLOC_ARENA_MAX=2
Environment=MALLOC_MMAP_THRESHOLD_=131072
Environment=MALLOC_TRIM_THRESHOLD_=131072
User=$user
Group=$user
Environment=HOME=$home
Environment=PATH=$CLI_NODE_PATH:/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=5
TimeoutStopSec=90
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$home
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT

  cat >"$UNIT_DIR/$name-gateway.service" <<UNIT
[Unit]
Description=Antseed API-key gateway ($name)
After=network-online.target $name-buyer.service
Wants=network-online.target $name-buyer.service

[Service]
EnvironmentFile=/etc/$name/gateway.env
ExecStart=$CLI_BIN tunnel start --no-buyer --provider cloudflare --buyer-port $buyer --gateway-port $gw
User=$user
Group=$user
Environment=HOME=$home
Environment=PATH=$CLI_NODE_PATH:/usr/local/bin:/usr/bin:/bin
Restart=always
RestartSec=5
TimeoutStopSec=90
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$home
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
}

create_one() {
  local inst=$1 host=$2 zone_id=$3 domain=$4
  local user=$inst home gw_port buyer_port tunnel_id tunnel_name

  home="/var/lib/$user"
  info "creating $inst for $host"

  if ! id "$user" >/dev/null 2>&1; then
    useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin "$user"
    ok "system user $user ($home)"
  else
    ok "system user $user already exists"
  fi
  install -d -o "$user" -g "$user" -m 700 "$home"

  read -r gw_port buyer_port <<<"$(alloc_ports)"
  reserve_port "$gw_port"
  reserve_port "$buyer_port"
  ok "ports gateway=$gw_port buyer=$buyer_port (reserved strictly)"

  tunnel_name=$(alloc_tunnel_name "$inst")
  reserve_name "$tunnel_name"
  tunnel_id=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$tunnel_name&is_deleted=false" 2>/dev/null |
    cfj 'j.result[0]?.id || ""' || true)
  if [[ -n $tunnel_id ]]; then
    assert_tunnel_owner "$inst" "$tunnel_id"
    ok "reusing tunnel $tunnel_name ($tunnel_id)"
  else
    tunnel_id=$(cf POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
      "{\"name\":\"$tunnel_name\",\"config_src\":\"cloudflare\"}" | cfj 'j.result.id')
    ok "tunnel $tunnel_name ($tunnel_id)"
  fi

  cf PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" \
    "{\"config\":{\"ingress\":[{\"hostname\":\"$host\",\"service\":\"http://localhost:$gw_port\"},{\"service\":\"http_status:404\"}]}}" \
    >/dev/null
  ok "ingress $host -> http://localhost:$gw_port"

  local dns_name=$host dns_ok=1 dns_body rec_id
  [[ $host == *".$domain" ]] && dns_name=${host%".$domain"}
  rec_id=$(cf GET "/zones/$zone_id/dns_records?name=$host" | cfj 'j.result[0]?.id || ""')
  dns_body="{\"type\":\"CNAME\",\"name\":\"$dns_name\",\"content\":\"$tunnel_id.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}"
  if [[ -n $rec_id ]]; then
    cf PUT "/zones/$zone_id/dns_records/$rec_id" "$dns_body" >/dev/null &&
      ok "DNS $host updated (CNAME -> tunnel)" || { warn "DNS update failed for $host"; dns_ok=0; }
  else
    cf POST "/zones/$zone_id/dns_records" "$dns_body" >/dev/null &&
      ok "DNS $host created (CNAME -> tunnel)" || { warn "DNS create failed for $host"; dns_ok=0; }
  fi
  (( dns_ok )) || die "cannot point $host at the tunnel" 3
  reserve_host "$host"

  local tunnel_token
  tunnel_token=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$tunnel_id/token" | cfj 'j.result')
  install -d -m 755 "/etc/$inst"
  (
    umask 077
    printf 'CLOUDFLARED_TUNNEL_TOKEN=%s\n' "$tunnel_token" >"/etc/$inst/gateway.env"
    printf 'ANTSEED_TUNNEL_PUBLIC_URL=https://%s\n' "$host" >>"/etc/$inst/gateway.env"
    printf 'ANTSEED_TRUST_CLOUDFLARE_HEADERS=1\n' >>"/etc/$inst/gateway.env"
  )
  chmod 600 "/etc/$inst/gateway.env"
  ok "env /etc/$inst/gateway.env (0600)"

  write_units "$inst" "$user" "$home" "$gw_port" "$buyer_port"
  systemctl daemon-reload
  ok "units $inst-buyer, $inst-gateway"

  systemctl enable --now "$inst-buyer.service" >/dev/null 2>&1
  if ! wait_port "$buyer_port" 60; then
    die "buyer did not open port $buyer_port (journalctl -u $inst-buyer)" 3
  fi
  if journalctl -u "$inst-buyer" --no-pager -n 60 2>/dev/null | grep -q 'already in use; reusing existing local proxy'; then
    die "port $buyer_port is owned by another process" 3
  fi
  ok "buyer listening on $buyer_port"

  local key_json key wallet
  key_json=$(as_instance "$user" "$home" gateway key create --label admin --json)
  key=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).apiKey)' "$key_json")
  wallet=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).identityAddress || "")' "$key_json")
  ok "API key created (label: admin)"

  systemctl enable --now "$inst-gateway.service" >/dev/null 2>&1
  wait_port "$gw_port" 90 || die "gateway did not open port $gw_port" 3
  ok "gateway listening on $gw_port"

  install -d -m 700 "$STATE_DIR"
  (
    umask 077
    {
      echo "INSTANCE=$inst"
      echo "USER=$user"
      echo "HOME_DIR=$home"
      echo "HOST=$host"
      echo "MODE=sub"
      echo "DOMAIN=$domain"
      echo "GW_PORT=$gw_port"
      echo "BUYER_PORT=$buyer_port"
      echo "TUNNEL_ID=$tunnel_id"
      echo "TUNNEL_NAME=$tunnel_name"
      echo "ZONE_ID=$zone_id"
      echo "API_KEY=$key"
      echo "WALLET=$wallet"
      echo "CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$(state_file "$inst")"
  )

  local i up=0 code tag body tagline="x-antseed-gateway-tag: "
  for (( i = 0; i < 30; i++ )); do
    body=$(curl -sS -m 20 -D - -o /dev/null "https://$host/v1/models" \
      -H "Authorization: Bearer $key" 2>/dev/null || true)
    code=$(head -1 <<<"$body" | awk '{ print $2 }')
    tag=$(grep -i "^$tagline" <<<"$body" | tr -d '\r' | awk -F': ' '{ print $2 }')
    [[ -n $tag ]] && { up=1; break; }
    sleep 2
  done

  if [[ $code == 200 && -n $tag ]]; then
    ok "https://$host/v1/models -> 200"
  elif [[ $code == 200 ]]; then
    warn "https://$host/v1/models -> 200 but no gateway tag (answered by a proxy?)"
  else
    warn "https://$host/v1/models -> ${code:-no response}"
    warn "the tunnel config did not take effect - check: antseed-fleet status $inst"
  fi
  (( up )) || warn "tunnel still connecting"

  local link
  link=$(as_instance "$user" "$home" gateway console-link 2>/dev/null | grep -oE 'https://[^ ]+' | head -1 || true)

  printf '%s\n' "${C_G}${C_BOLD}  $inst is up${C_0}"
  printf '    %-10s %s\n' "Base URL" "https://$host/v1"
  printf '    %-10s %s\n' "Console" "https://$host/console"
  printf '    %-10s %s\n' "API key" "$key"
  printf '    %-10s %s\n' "Wallet" "${wallet:-(see console)}"
  printf '    %-10s %s\n' "Ports" "gw=$gw_port buyer=$buyer_port"
  printf '    %-10s %s\n' "Tunnel" "$tunnel_name"
  printf '    %-10s %s\n' "Setup" "${link:-(run: antseed-fleet link $inst)}"
  printf '%s\n' "${C_D}    The API key is shown once. Store it now.${C_0}"
}

# ============================================================ main flow

step "Antseed fleet installer $VERSION"

# ---------------------------------------------------------- 1/5 token

step "1/5 - Cloudflare API token"
if [[ -z ${CF_API_TOKEN:-} ]]; then
  cat <<'TXT' >&2

  Create a scoped Cloudflare API token:
    https://dash.cloudflare.com/profile/api-tokens
    (Create Token -> Create Custom Token)

    Account | Cloudflare Tunnel | Edit
    Account | Account Settings  | Read
    Zone    | DNS               | Edit
    Zone    | Zone              | Read

    Account Resources: your account
    Zone Resources:    your zone
TXT
  if [[ $ASSUME_YES -eq 0 ]] && ! have_tty; then
    die "no terminal to type into. Run it in an interactive shell, or pass the value:
  curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed3/main/get.sh |
    sudo bash -s -- --token cf_xxx --domain example.com --name api" 1
  fi
  while [[ -z ${CF_API_TOKEN:-} ]]; do
    CF_API_TOKEN=$(ask_secret "  Paste the Cloudflare API token")
    [[ -n $CF_API_TOKEN ]] || warn "token is empty - paste the cfut_... / cf_... value"
  done
fi
export CF_API_TOKEN

info "checking the token"
cf_verify
ok "account: $ACCOUNT_NAME"

# ---------------------------------------------------------- 2/5 domain

step "2/5 - Domain"
ZONES=$(list_zones)
[[ -n $ZONES ]] || die "this token cannot see any zone - check Zone | Zone | Read for your zone" 1

mapfile -t ZONE_NAMES < <(cut -f1 <<<"$ZONES")
mapfile -t ZONE_IDS < <(cut -f2 <<<"$ZONES")
mapfile -t ZONE_STATUS < <(cut -f3 <<<"$ZONES")

zone_id_for() {
  local i
  for i in "${!ZONE_NAMES[@]}"; do
    [[ ${ZONE_NAMES[$i]} == "$1" ]] && { printf '%s' "${ZONE_IDS[$i]}"; return 0; }
  done
  return 1
}

if [[ -z $DOMAIN ]]; then
  def=1
  first_host=$(existing_instances | awk 'NR==1 { print $2 }')
  if [[ -n $first_host ]]; then
    root=$(zone_root "$first_host" || true)
    for i in "${!ZONE_NAMES[@]}"; do [[ ${ZONE_NAMES[$i]} == "$root" ]] && { def=$((i + 1)); break; }; done
  fi

  printf '    %-4s %-34s %s\n' "#" "DOMAIN" "STATUS"
  for i in "${!ZONE_NAMES[@]}"; do
    printf '    %-4s %-34s %s\n' "$((i + 1))" "${ZONE_NAMES[$i]}" "${ZONE_STATUS[$i]}"
  done
  echo
  printf '%s\n' "${C_D}    Type a number, or a zone that is not in the list.${C_0}"

  if [[ $ASSUME_YES -eq 0 ]] && ! have_tty; then
    die "no terminal to ask for the domain. Pass --domain example.com" 1
  fi
  pick=${DOMAIN_PICK:-}
  while [[ -z $DOMAIN ]]; do
    pick=$(ask "  Which domain" "${pick:-$def}")
    if [[ $pick =~ ^[0-9]+$ ]]; then
      if (( pick >= 1 && pick <= ${#ZONE_NAMES[@]} )); then
        DOMAIN=${ZONE_NAMES[$((pick - 1))]}
      else
        warn "no domain number $pick - pick 1..${#ZONE_NAMES[@]}"
        pick=""
      fi
    else
      DOMAIN=$(printf '%s' "$pick" | tr '[:upper:]' '[:lower:]')
      [[ $DOMAIN == *.* ]] || { warn "'$DOMAIN' does not look like a domain"; DOMAIN=""; }
    fi
  done
fi

DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN#https://}
DOMAIN=${DOMAIN%%/*}
if ! zone_id_for "$DOMAIN" >/dev/null; then
  trimmed=${DOMAIN#*.}
  if zone_id_for "$trimmed" >/dev/null; then
    warn "using the zone $trimmed instead of $DOMAIN"
    DOMAIN=$trimmed
  fi
fi
ZONE_ID=$(zone_id_for "$DOMAIN") || die "zone '$DOMAIN' not found on this Cloudflare account (the token sees: ${ZONE_NAMES[*]})" 1
ok "domain: $DOMAIN   (zone $ZONE_ID)"

# ---------------------------------------------------------- 3/5 name

step "3/5 - Name"
san_name() {
  local n
  n=$(sanitize_name "$1")
  [[ -n $n ]] || return 1
  [[ $n =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  [[ $n == *.* ]] && return 1
  printf '%s' "$n"
}

same_name_used() {
  local name=$1 n=0 h
  for h in $(existing_instances | awk '{ print $2 }'); do
    if [[ $h =~ ^${name}[0-9]+\. ]]; then n=$((n + 1)); fi
  done
  echo "$n"
}

if [[ -z $INSTANCE_NAME ]]; then
  if [[ $ASSUME_YES -eq 0 ]] && ! have_tty; then
    die "no terminal to ask for the name. Pass --name api" 1
  fi
  guess="api"
  for h in $(existing_instances | awk '{ print $2 }'); do
    if [[ $h =~ ^([a-z0-9-]+)[0-9]+\. ]]; then guess=${BASH_REMATCH[1]}; break; fi
  done
  INSTANCE_NAME=$(ask "  Name for the instances (letters, digits, dash)" "$guess")
fi
INSTANCE_NAME=$(san_name "$INSTANCE_NAME") || die "invalid name - use letters, digits and dashes, e.g. api or gateway" 1

prio=""
[[ $INSTANCE_NAME =~ ^(buyer|gateway|tunnel|cloudflared|antseed|console|admin|root|system)$ ]] &&
  prio="  (this name is used by the base service on ports 8377/8379; instances still use $INSTANCE_NAME 1, $INSTANCE_NAME 2, ...)"

echo
printf '    %-14s %s\n' "Domain" "$DOMAIN"
printf '    %-14s %s\n' "Name" "$INSTANCE_NAME"
printf '    %-14s %s\n' "1st host" "https://$(host_for "$INSTANCE_NAME" 1 "$DOMAIN")"
printf '    %-14s %s\n' "then" "https://$(host_for "$INSTANCE_NAME" 2 "$DOMAIN"), https://$(host_for "$INSTANCE_NAME" 3 "$DOMAIN"), ..."
[[ -n $prio ]] && printf '%s\n' "${C_D}   $prio${C_0}"

# ---------------------------------------------------------- 4/5 how many

step "4/5 - This VPS and how many"
ensure_cli
read -r rec by_disk avail <<<"$(recommend_count)"
used=$(existing_instances | wc -l)
cpu_model=$(awk -F': ' '/model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
mem_total=$(mem_total_mib)
disk_free=$(disk_avail_mib)
already=$(same_name_used "$INSTANCE_NAME")

printf '    %-24s %s\n' "CPUs" "$(nproc)${cpu_model:+ x $cpu_model}"
printf '    %-24s %s MiB (%s GB)\n' "RAM total" "$mem_total" "$(awk -v m="$mem_total" 'BEGIN { printf "%.1f", m / 1024 }')"
printf '    %-24s %s MiB\n' "RAM available" "$avail"
printf '    %-24s %s MiB (%s GB)\n' "Disk free" "$disk_free" "$(awk -v m="$disk_free" 'BEGIN { printf "%.0f", m / 1024 }')"
printf '    %-24s %s\n' "Instances already here" "$used"
printf '    %-24s %s MiB per instance\n' "Memory budget" "$MEM_PER_INSTANCE_MIB"
echo
print_sizing_table "$rec" "$MEM_PER_INSTANCE_MIB" "$mem_total"
echo

if (( rec == 0 )); then
  warn "no room for another instance right now"
  count=0
else
  ok "recommended now: ${C_BOLD}$rec${C_0} more instance(s)   (disk allows $by_disk)"
  count=${COUNT:-}
  if [[ -z $count ]]; then
    while true; do
      count=$(ask "  How many instances do you want" "$rec")
      [[ $count =~ ^[0-9]+$ ]] || {
        warn "enter a number"
        if [[ ${COUNT:-} != "" ]]; then die "COUNT must be numeric" 1; fi
        continue
      }
      (( count > rec )) && {
        warn "$count is above the recommendation ($rec) - the VPS may run out of memory"
        confirm "  Continue anyway?" || { count=""; continue; }
      }
      (( count > 0 )) && break
      interactive || { count=0; break; }
    done
  fi
fi

(( count > 0 )) || { warn "nothing to do"; exit 0; }

# ---------------------------------------------------------- 5/5 create

acquire_lock
registry_touch

hosts=()
names=()
for (( i = 0; i < count; i++ )); do
  h=$(alloc_host "$INSTANCE_NAME" "$DOMAIN")
  hosts+=("$h")
  reserve_host "$h"
done

idx=1
for (( i = 0; i < count; i++ )); do
  while instance_exists "${PREFIX}${idx}"; do idx=$((idx + 1)); done
  names+=("${PREFIX}${idx}")
  idx=$((idx + 1))
done

step "5/5 - Creating $count instance(s)"
printf '    %-14s %s\n' "INSTANCE" "PUBLIC URL"
for i in "${!hosts[@]}"; do
  printf '    %-14s https://%s/v1\n' "${names[$i]}" "${hosts[$i]}"
done
echo
confirm "  Proceed?" || { warn "cancelled"; exit 2; }

created=0
for i in "${!hosts[@]}"; do
  create_one "${names[$i]}" "${hosts[$i]}" "$ZONE_ID" "$DOMAIN" ||
    die "failed while creating ${hosts[$i]} (instances created so far: $created)" 3
  created=$((created + 1))
  echo
done

step "Done - $created instance(s) created"
printf '    %-12s %s\n' "NAME" "BASE URL"
existing_instances | while read -r n h; do printf '    %-12s https://%s/v1\n' "$n" "$h"; done
echo
info "manage with: antseed-fleet list | status | link NAME | logs NAME -f | remove NAME"
info "API keys are shown once above - save them now"
info "run 'antseed-fleet check --domain $DOMAIN --name $INSTANCE_NAME' next time to preview allocations"
