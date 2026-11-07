#!/usr/bin/env bash
# test-allocator.sh — offline unit test for the strict allocators.
# No root, no Cloudflare, no systemd needed. Pure bash logic test: it pulls the
# allocator functions straight out of install.sh and stubs the system layer.
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || HERE=$(dirname "${BASH_SOURCE[0]}")
SRC="$HERE/../install.sh"
[[ -f $SRC ]] || SRC="$HERE/install.sh"
[[ -f $SRC ]] || { echo "cannot find install.sh (looked at $SRC)" >&2; exit 1; }

PASS=0; FAIL=0
t_ok()   { PASS=$((PASS+1)); printf '  \033[32m✔\033[0m %s\n' "$1"; }
t_fail() { FAIL=$((FAIL+1)); printf '  \033[31m✘\033[0m %s\n' "$1"; }
t_is()   { if [[ "$2" == "$3" ]]; then t_ok "$1 ($3)"; else t_fail "$1 (expected '$3', got '$2')"; fi; }

# ---- isolated sandbox ---------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE_DIR="$TMP/state"
UNIT_DIR="$TMP/units"
PORT_REGISTRY="$STATE_DIR/ports.reserved"
PORT_HWM="$STATE_DIR/ports.hwm"
NAME_REGISTRY="$STATE_DIR/tunnels.reserved"
HOST_REGISTRY="$STATE_DIR/hosts.reserved"
PORT_RANGE_LO=20000
PORT_RANGE_HI=20060
PREFIX=antseed
ACCOUNT_ID=acct-test
mkdir -p "$STATE_DIR" "$UNIT_DIR"
: >"$PORT_REGISTRY"; : >"$NAME_REGISTRY"; : >"$HOST_REGISTRY"

# ---- system-layer stubs -------------------------------------------------
die()  { echo "DIE: $*" >&2; exit 9; }
ok()   { :; }
warn() { :; }
info() { :; }
port_busy() { return 1; }                    # nothing listening in the sandbox
baseline_ports() { echo "8379 8377"; }       # the base antseed services
state_file() { echo "$STATE_DIR/$1.env"; }
instance_exists() { [[ -f $(state_file "$1") ]]; }
instance_names() {
  local f
  for f in "$STATE_DIR"/*.env; do [[ -e $f ]] || continue; basename "$f" .env; done | sort -V
}
existing_instances() {
  local n
  while read -r n; do [[ -n $n ]] || continue; ( . "$(state_file "$n")"; echo "$INSTANCE $HOST" ); done <<<"$(instance_names)"
}
port_in_registry() { grep -qx -- "$1" "$PORT_REGISTRY" 2>/dev/null; }
name_in_registry() { grep -qix -- "$1" "$NAME_REGISTRY" 2>/dev/null; }
host_in_registry() { grep -qix -- "$1" "$HOST_REGISTRY" 2>/dev/null; }
reserve_port() {
  local p=$1 cur=0
  echo "$p" >>"$PORT_REGISTRY"
  [[ -f $PORT_HWM ]] && cur=$(cat "$PORT_HWM" 2>/dev/null || echo 0)
  [[ $cur =~ ^[0-9]+$ ]] || cur=0
  [[ $p =~ ^[0-9]+$ ]] || return 0
  if (( p >= cur )); then echo $(( p + 1 )) >"$PORT_HWM"; fi
}
reserve_name() { echo "$1" >>"$NAME_REGISTRY"; }
reserve_host() { echo "$1" >>"$HOST_REGISTRY"; }
host_for() { printf '%s%d.%s' "$1" "$2" "$3"; }
host_taken_by_other() { printf '%s' "${FAKE_DNS_TAKEN:-}"; }
# Cloudflare stubs
cf_tunnel_names() { [[ -n ${FAKE_TUNNELS:-} ]] && printf '%s\n' $FAKE_TUNNELS || true; }
cf() { printf '{"result":{"name":"%s"}}' "${OWN_TUNNEL_NAME:-}"; }
cfj() {
  local e=$1; shift
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch(e){process.exit(1)}const v=eval(process.argv[1]);process.stdout.write(v==null?"":String(v))})' "$e" 2>/dev/null || true
}

# ---- pull the real functions out of install.sh --------------------------
extract() { # extract <func> <file>
  local fn=$1 file=$2
  awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\)" { p=1 }
    p { print }
    p && /^}/ { exit }
  ' "$file"
}
for fn in alloc_ports alloc_tunnel_name alloc_host next_host_num; do
  eval "$(extract "$fn" "$SRC")"
done

# =========================================================== tests

echo "== alloc_ports: sequential, never reuse =="
read -r gw1 b1 <<<"$(alloc_ports)"; reserve_port "$gw1"; reserve_port "$b1"
read -r gw2 b2 <<<"$(alloc_ports)"; reserve_port "$gw2"; reserve_port "$b2"
read -r gw3 b3 <<<"$(alloc_ports)"; reserve_port "$gw3"; reserve_port "$b3"
t_is "first gw"     "$gw1" "20000"
t_is "first buyer"  "$b1" "20001"
t_is "second gw"    "$gw2" "20002"
t_is "second buyer" "$b2" "20003"
t_is "third gw"     "$gw3" "20004"
[[ $gw1 != "$gw2" && $gw2 != "$gw3" && $b1 != "$gw2" && $b2 != "$gw3" ]] \
  && t_ok "no overlap between allocations" || t_fail "overlap detected"

echo "== alloc_ports: registry survives a removed instance =="
rm -f "$STATE_DIR"/*.env         # simulate 'remove' (state gone, registry kept)
read -r gw4 b4 <<<"$(alloc_ports)"
[[ $gw4 -gt "$gw3" ]] && t_ok "removed instance's port stays reserved (got $gw4)" || t_fail "reused removed port ($gw4 <= $gw3)"
reserve_port "$gw4"; reserve_port "$b4"

echo "== alloc_ports: exhaust the window =="
SPAN=$(( PORT_RANGE_HI - PORT_RANGE_LO + 1 ))
i=0; last=""
while :; do
  if out=$(alloc_ports 2>/dev/null); then
    read -r a b <<<"$out"; reserve_port "$a"; reserve_port "$b"; last=$b; i=$((i+1))
  else
    break
  fi
  (( i > SPAN )) && { t_fail "allocator never reports exhaustion"; break; }
done
total=$(wc -l <"$PORT_REGISTRY" | tr -d ' ')
# 2 ports per allocation, so an odd leftover port (61 -> 60 used, 1 stranded) is
# expected: the allocator must stop when fewer than 2 free ports remain.
if (( total <= SPAN && total >= SPAN - 2 )); then
  t_ok "exhaustion stops at $total of $SPAN ports ($i allocations)"
else
  t_fail "exhaustion behaviour wrong ($total of $SPAN, $i allocations)"
fi
[[ $last -le $PORT_RANGE_HI ]] && t_ok "never allocated outside the range" || t_fail "allocated outside range ($last)"
# every reserved port is unique
dup=$(sort -n "$PORT_REGISTRY" | uniq -d | head -1)
[[ -z $dup ]] && t_ok "registry has no duplicate ports" || t_fail "duplicate reserved port $dup"

echo "== alloc_tunnel_name: foreign tunnel is never hijacked =="
: >"$NAME_REGISTRY"; rm -f "$STATE_DIR"/*.env
FAKE_TUNNELS="antseed1-gateway antseed2-gateway-x"
OWN_TUNNEL_NAME=""
tn=$(alloc_tunnel_name antseed1)
t_is "foreign antseed1-gateway -> new name" "$tn" "antseed1-gateway-2"
reserve_name "$tn"

echo "== alloc_tunnel_name: own tunnel is reused =="
cat >"$STATE_DIR/antseed9.env" <<EOF
INSTANCE=antseed9
TUNNEL_ID=tid-9
TUNNEL_NAME=antseed9-gateway
EOF
FAKE_TUNNELS="antseed9-gateway antseed1-gateway"
OWN_TUNNEL_NAME="antseed9-gateway"     # what Cloudflare reports for tid-9
tn=$(alloc_tunnel_name antseed9)
t_is "own tunnel kept" "$tn" "antseed9-gateway"
OWN_TUNNEL_NAME=""

echo "== alloc_tunnel_name: reserved name forces a new suffix =="
rm -f "$STATE_DIR"/*.env
FAKE_TUNNELS=""
reserve_name "antseed5-gateway"
tn=$(alloc_tunnel_name antseed5)
t_is "reserved name -> new suffix" "$tn" "antseed5-gateway-2"

echo "== alloc_host: skips reserved and DNS-taken hosts =="
: >"$HOST_REGISTRY"; rm -f "$STATE_DIR"/*.env
cat >"$STATE_DIR/antseed1.env" <<EOF
INSTANCE=antseed1
HOST=api1.example.com
EOF
ZONE_ID=zone-test
FAKE_DNS_TAKEN=""
h=$(alloc_host api example.com); t_is "next after local api1" "$h" "api2.example.com"
reserve_host "api2.example.com"
FAKE_DNS_TAKEN=""
h=$(alloc_host api example.com); t_is "skips registry" "$h" "api3.example.com"
reserve_host "api3.example.com"
# everything above api3 is DNS-taken -> the allocator must jump past them
FAKE_DNS_TAKEN="tid.cfargotunnel.com"
FAKE_DNS_MODE=jump
# patch host_taken_by_other to only mark api4 as taken so the loop terminates
host_taken_by_other() {
  local h=$1
  case $h in
    api4.example.com) printf 'tid.cfargotunnel.com' ;;
    *) printf '' ;;
  esac
}
h=$(alloc_host api example.com); t_is "skips DNS-taken api4" "$h" "api5.example.com"
FAKE_DNS_TAKEN=""

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
