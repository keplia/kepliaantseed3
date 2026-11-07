# Satu perintah: unduh script, lalu jalankan.
#   curl -fsSL https://raw.githubusercontent.com/keplia/kepliaantseed3/main/get.sh | sudo bash
#
# Opsi:
#   curl -fsSL .../get.sh | sudo bash -s -- --token 'cf_...' --domain example.com --name api --count 2
#
# Variabel environment yang dihormati:
#   ANTSEED_FLEET_REPO       (default: keplia/kepliaantseed3)
#   ANTSEED_FLEET_REF        (default: main)
#   ANTSEED_PORT_RANGE_LO    (default: 20000)
#   ANTSEED_PORT_RANGE_HI    (default: 40000)
#   ANTSEED_FLEET_PREFIX     (default: antseed)
#
set -Eeuo pipefail

REPO="${ANTSEED_FLEET_REPO:-keplia/kepliaantseed3}"
REF="${ANTSEED_FLEET_REF:-main}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo bash)" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

dir=/opt/antseed-fleet
mkdir -p "$dir"
for f in install.sh antseed-fleet README.md; do
  curl -fsSL "$BASE/$f" -o "$dir/$f"
done
chmod +x "$dir/install.sh" "$dir/antseed-fleet"
ln -sf "$dir/antseed-fleet" /usr/local/bin/antseed-fleet
echo "-> scripts installed in $dir (manager command: antseed-fleet)" >&2

# stdin is the curl pipe, so the installer cannot read answers from it.
# Reconnect stdin to the real terminal; if there is none, /dev/null instead of
# an empty pipe (which would look like "everyone pressed enter").
if ( exec 0<>/dev/tty ) 2>/dev/null; then
  exec bash "$dir/install.sh" "$@" </dev/tty
else
  exec bash "$dir/install.sh" "$@" </dev/null
fi
