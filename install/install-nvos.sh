#!/bin/bash
# Install a custom "nvos" (NVIDIA open kernel module) package into the Unraid
# Nvidia-Driver plugin so it is used on the next boot. Run as root ON the
# Unraid host.
#
#   install-nvos.sh [--reboot]                  (local package, else download)
#   install-nvos.sh <package.txz> [--reboot]
#   install-nvos.sh --driver 615.78.08 [--reboot]   (pick a driver version)
#
# Run straight from GitHub (no clone, no token):
#   curl -fsSL https://raw.githubusercontent.com/salty2011/unraid-nvos-driver/main/install/install-nvos.sh | bash -s -- --reboot
#
# Without a package path it looks for nvos-*-<running kernel>-1.txz in this
# script's directory and its parent (an extracted release zip). If there is
# none, it downloads the newest release package for the running kernel from
# github.com/$NVOS_REPO (default salty2011/unraid-nvos-driver), with its .md5.
#
# What it does:
#   1. verifies the package matches the running kernel and its .md5
#   2. backs up the plugin's current packages + settings.cfg to
#      /boot/config/plugins/nvidia-driver-backup-<date>/
#   3. places the package under /boot/config/plugins/nvidia-driver/packages/<kernel>/
#      (the plugin prefers a local package over a download)
#   4. sets driver_version=latest_nos and update_check=false
#   5. optionally reboots (clean array stop via powerdown)
set -euo pipefail

REBOOT=false; PKG=""; WANT_DRV=""
REPO=${NVOS_REPO:-salty2011/unraid-nvos-driver}
# Piped through bash there is no script file, so no directory to search.
HERE=""; [ -f "${BASH_SOURCE[0]:-}" ] && HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while [ $# -gt 0 ]; do
  case "$1" in
    --reboot) REBOOT=true; shift;;
    --driver) WANT_DRV="$2"; shift 2;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" 2>/dev/null || echo "see https://github.com/$REPO"; exit 0;;
    *) PKG="$1"; shift;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f /etc/unraid-version ] || { echo "this is not an Unraid host"; exit 1; }
KV=$(uname -r)                      # e.g. 6.18.47-Unraid
KDIR=${KV%%-*}                      # e.g. 6.18.47
PLUGIN=/boot/config/plugins/nvidia-driver
[ -d "$PLUGIN" ] || { echo "Nvidia-Driver plugin not installed (no $PLUGIN); install it from Community Applications first"; exit 1; }

download_pkg() {
  command -v curl >/dev/null || { echo "curl missing"; exit 1; }
  echo "looking for an nvos package for $KV in github.com/$REPO releases ..."
  URLS=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" \
    | grep -o '"browser_download_url": *"[^"]*"' | sed -E 's/.*"(https[^"]*)"$/\1/' \
    | grep -E "/nvos-[0-9.]+-$KV-1\.txz$" || true)
  [ -z "$WANT_DRV" ] || URLS=$(grep -F "/nvos-$WANT_DRV-$KV-1.txz" <<<"$URLS" || true)
  if [ -z "$URLS" ]; then
    echo "no release package for kernel $KV${WANT_DRV:+ and driver $WANT_DRV} in $REPO."
    echo "Build one with build/build-nvos.sh --kernel $KV --driver <version>, see https://github.com/$REPO"
    exit 1
  fi
  # Newest driver wins: sort on the version inside the file name.
  URL=$(sed -E 's|.*/nvos-([0-9.]+)-.*|\1 &|' <<<"$URLS" | sort -V | tail -1 | cut -d' ' -f2)
  DL=/tmp/nvos-dl; mkdir -p "$DL"
  PKG="$DL/$(basename "$URL")"
  echo "downloading $(basename "$URL") ..."
  curl -fL --retry 3 -o "$PKG" "$URL"
  curl -fsSL --retry 3 -o "$PKG.md5" "$URL.md5" || { echo "no .md5 published for $(basename "$URL"); refusing to install an unchecked download"; exit 1; }
}

if [ -z "$PKG" ]; then
  FOUND=()
  [ -z "$HERE" ] || mapfile -t FOUND < <(find "$HERE" "$(dirname "$HERE")" -maxdepth 1 -type f -name "nvos-${WANT_DRV:-*}-$KV-1.txz" 2>/dev/null)
  case ${#FOUND[@]} in
    1) PKG=${FOUND[0]}; echo "using $PKG";;
    0) download_pkg;;
    *) echo "several packages for $KV found; pass the one to install:"; printf '  %s\n' "${FOUND[@]}"; exit 1;;
  esac
fi

[ -f "$PKG" ] || { echo "package file $PKG missing"; exit 1; }
BASE=$(basename "$PKG")
case "$BASE" in
  nvos-*-"$KV"-1.txz) ;;
  nvidia-*) echo "$BASE is a PROPRIETARY-module package; Blackwell GPUs need nvos-*"; exit 1;;
  *) echo "$BASE does not match running kernel $KV (expected nvos-<driver>-$KV-1.txz)"; exit 1;;
esac
DRV=$(echo "$BASE" | sed -E 's/^nvos-([0-9.]+)-.*/\1/')
if [ -f "$PKG.md5" ]; then
  echo "$(awk '{print $1}' "$PKG.md5")  $PKG" | md5sum -c - || exit 1
else
  echo "WARNING: no $BASE.md5 next to the package; skipping checksum"
fi

# Sanity: the package must carry open modules for this exact kernel.
# (List once into a variable: with pipefail, `tar | grep -q` fails on SIGPIPE.)
LIST=$(tar -tJf "$PKG")
grep -q "lib/modules/$KV/kernel/drivers/video/nvidia.ko" <<<"$LIST" || { echo "package has no nvidia.ko for $KV"; exit 1; }
grep -q "usr/share/glvnd/egl_vendor.d/10_nvidia.json" <<<"$LIST" || echo "WARNING: package lacks 10_nvidia.json; Vulkan on 610+ will not initialise in containers"

TS=$(date +%Y%m%d-%H%M%S); BK="$PLUGIN-backup-$TS"
mkdir -p "$BK" "$PLUGIN/packages/$KDIR"
cp "$PLUGIN/settings.cfg" "$BK/settings.cfg" 2>/dev/null || true
# Anything else in the kernel dir goes to the backup: the plugin picks the highest
# version by name, and a stray proprietary package would win the sort.
find "$PLUGIN/packages/$KDIR" -maxdepth 1 -type f ! -name "$BASE" ! -name "$BASE.md5" -exec mv {} "$BK/" \; 2>/dev/null || true
cp "$PKG" "$PLUGIN/packages/$KDIR/$BASE"
[ -f "$PKG.md5" ] && cp "$PKG.md5" "$PLUGIN/packages/$KDIR/$BASE.md5" || md5sum "$PLUGIN/packages/$KDIR/$BASE" | awk '{print $1}' > "$PLUGIN/packages/$KDIR/$BASE.md5"
echo "$(awk '{print $1}' "$PLUGIN/packages/$KDIR/$BASE.md5")  $PLUGIN/packages/$KDIR/$BASE" | md5sum -c -

CFG="$PLUGIN/settings.cfg"; touch "$CFG"
grep -q '^driver_version=' "$CFG" && sed -i 's/^driver_version=.*/driver_version=latest_nos/' "$CFG" || echo 'driver_version=latest_nos' >> "$CFG"
grep -q '^update_check=' "$CFG" && sed -i 's/^update_check=.*/update_check=false/' "$CFG" || echo 'update_check=false' >> "$CFG"

echo
echo "Staged nvos $DRV for kernel $KV:"
ls -la "$PLUGIN/packages/$KDIR/"
grep -E '^(driver_version|update_check)=' "$CFG"
echo "backup: $BK"
echo "currently running: $(cat /sys/module/nvidia/version 2>/dev/null || echo 'no nvidia module loaded')"
echo
echo "NOTE: the package is kernel-specific. After an Unraid OS update the plugin will"
echo "      download the newest PUBLISHED nvos (which may be older); rebuild and re-run this."
if $REBOOT; then
  echo "rebooting (clean array stop) ..."
  PD=$(command -v powerdown || echo /usr/local/sbin/powerdown)
  [ -x "$PD" ] || PD=/sbin/reboot
  setsid nohup "$PD" -r </dev/null >/dev/null 2>&1 & disown
else
  echo "Reboot to activate: /usr/local/sbin/powerdown -r"
fi
