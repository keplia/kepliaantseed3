#!/usr/bin/env bash
# scale-test.sh - allocate N pairs from a huge window and verify speed/uniqueness.
# Self-contained: stubs the system layer, pulls alloc_ports out of install.sh.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRC="$HERE/../install.sh"
N=${1:-5000}

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
STATE_DIR="$TMPD/state"; UNIT_DIR="$TMPD/units"
PORT_REGISTRY="$STATE_DIR/ports.reserved"
PORT_HWM="$STATE_DIR/ports.hwm"
PORT_RANGE_LO=20000; PORT_RANGE_HI=40000
mkdir -p "$STATE_DIR" "$UNIT_DIR"; : > "$PORT_REGISTRY"

extract() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\)" { p=1 } p { print } p && /^}/ { exit }' "$2"; }
eval "$(extract alloc_ports "$SRC")"

instance_names() { true; }
baseline_ports() { echo "8379 8377"; }
port_in_registry() { grep -qx -- "$1" "$PORT_REGISTRY"; }
port_busy() { return 1; }
die() { echo "DIE: $*" >&2; exit 1; }
reserve_port() {
  local p=$1 cur=0
  echo "$p" >>"$PORT_REGISTRY"
  [[ -f $PORT_HWM ]] && cur=$(cat "$PORT_HWM" 2>/dev/null || echo 0)
  [[ $cur =~ ^[0-9]+$ ]] || cur=0
  [[ $p =~ ^[0-9]+$ ]] || return 0
  if (( p >= cur )); then echo $(( p + 1 )) >"$PORT_HWM"; fi
}

echo "allocating $N instance port-pairs from $PORT_RANGE_LO-$PORT_RANGE_HI ..."
start=$(date +%s)
: > "$TMPD/all"
for (( i = 0; i < N; i++ )); do
  read -r a b <<< "$(alloc_ports)"
  reserve_port "$a"; reserve_port "$b"
  echo "$a $b" >> "$TMPD/all"
done
end=$(date +%s)

total=$(wc -l < "$PORT_REGISTRY" | tr -d ' ')
uniq_cnt=$(sort -n "$PORT_REGISTRY" | uniq | wc -l | tr -d ' ')
dup=$(sort -n "$PORT_REGISTRY" | uniq -d | head -1)
min=$(sort -n "$PORT_REGISTRY" | head -1)
max=$(sort -n "$PORT_REGISTRY" | tail -1)
ingw=$(awk '{print $1}' "$TMPD/all" | sort -n | uniq | wc -l | tr -d ' ')
inbuyer=$(awk '{print $2}' "$TMPD/all" | sort -n | uniq | wc -l | tr -d ' ')
cross=$(comm -12 <(awk '{print $1}' "$TMPD/all" | sort -n) <(awk '{print $2}' "$TMPD/all" | sort -n) | wc -l | tr -d ' ')

echo "elapsed:            $((end - start))s"
echo "ports recorded:     $total (expected $((N*2)))"
echo "unique ports:       $uniq_cnt"
echo "range used:         $min .. $max"
echo "unique gw:          $ingw (expected $N)"
echo "unique buyer:       $inbuyer (expected $N)"
echo "gw&buyer overlap:   $cross (expected 0)"
echo "duplicates:         ${dup:-none}"
echo
if [[ $total -eq $((N*2)) && $uniq_cnt -eq $((N*2)) && $ingw -eq $N && $inbuyer -eq $N && $cross -eq 0 && -z $dup ]]; then
  echo "PASS: $N instances, zero collisions"
else
  echo "FAIL"; exit 1
fi
