#!/bin/bash
# Install a custom "nvos" (NVIDIA open kernel module) package into the Unraid
# Nvidia-Driver plugin so it is used on the next boot. Run as root ON the
# Unraid host.
#
#   install-nvos.sh [--reboot]                  (finds the package next to this script)
#   install-nvos.sh <package.txz> [--reboot]
#
# Without a package path it looks for nvos-*-<running kernel>-1.txz in this
# script's directory and its parent, so it works from an extracted release zip.
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

REBOOT=false; PKG=""
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
while [ $# -gt 0 ]; do
  case "$1" in
    --reboot) REBOOT=true; shift;;
    -h|--help) sed -n '2,19p' "$0"; exit 0;;
    *) PKG="$1"; shift;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -f /etc/unraid-version ] || { echo "this is not an Unraid host"; exit 1; }
KV=$(uname -r)                      # e.g. 6.18.47-Unraid
KDIR=${KV%%-*}                      # e.g. 6.18.47
PLUGIN=/boot/config/plugins/nvidia-driver
[ -d "$PLUGIN" ] || { echo "Nvidia-Driver plugin not installed (no $PLUGIN); install it from Community Applications first"; exit 1; }

if [ -z "$PKG" ]; then
  mapfile -t FOUND < <(find "$HERE" "$(dirname "$HERE")" -maxdepth 1 -type f -name "nvos-*-$KV-1.txz" 2>/dev/null)
  case ${#FOUND[@]} in
    1) PKG=${FOUND[0]};;
    0) echo "no nvos-*-$KV-1.txz in $HERE or its parent; this release does not match the running kernel $KV"
       OTHER=$(find "$HERE" "$(dirname "$HERE")" -maxdepth 1 -type f -name "nvos-*.txz" 2>/dev/null)
       [ -z "$OTHER" ] || { echo "found packages for other kernels:"; echo "$OTHER"; }
       exit 1;;
    *) echo "several packages for $KV found; pass the one to install:"; printf '  %s\n' "${FOUND[@]}"; exit 1;;
  esac
  echo "using $PKG"
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
