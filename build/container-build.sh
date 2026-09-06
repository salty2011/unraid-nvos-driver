#!/bin/bash
# Runs INSIDE ghcr.io/ich777/unraid_kernel:gcc_<ver>. Builds an Unraid "nvos"
# package: NVIDIA open kernel modules + full userspace for one Unraid kernel.
# Driven by build/build-nvos.sh; can also be run by hand with:
#   docker exec -e UNAME=6.18.47-Unraid -e DRV=610.57.04 <container> bash /usr/src/container-build.sh
set -euo pipefail
export UNAME=${UNAME:?set UNAME, e.g. 6.18.47-Unraid}
export DRV=${DRV:?set DRV, e.g. 610.57.04}
export CPU_COUNT=${CPU_COUNT:-$(nproc)}
export DATA_DIR=/usr/src
cd "$DATA_DIR"

echo "=== stage 1: pre-compiled kernel $UNAME  $(date)"
if [ ! -f "linux-$UNAME.tar.xz" ]; then
  wget -q -O "linux-$UNAME.tar.xz" "https://github.com/ich777/unraid_kernel/releases/download/$UNAME/linux-$UNAME.tar.xz"
  wget -q -O "linux-$UNAME.tar.xz.sha256" "https://github.com/ich777/unraid_kernel/releases/download/$UNAME/linux-$UNAME.tar.xz.sha256"
fi
echo "$(awk '{print $1}' "linux-$UNAME.tar.xz.sha256")  linux-$UNAME.tar.xz" | sha256sum -c -
if [ ! -f "linux-$UNAME/.stage1-done" ]; then
  rm -rf "linux-$UNAME"; mkdir "linux-$UNAME"
  tar -xf "linux-$UNAME.tar.xz" -C "linux-$UNAME"
  cd "linux-$UNAME"
  grep CONFIG_CC_VERSION_TEXT .config
  rm -rf /lib/modules /lib/firmware; mkdir -p /lib/modules /lib/firmware
  make -j"$CPU_COUNT" > "$DATA_DIR/make.log" 2>&1
  make modules_install -j"$CPU_COUNT" > "$DATA_DIR/modules_install.log" 2>&1
  touch .stage1-done
  cd "$DATA_DIR"
fi
ls -la "/lib/modules/$UNAME/build" >/dev/null

echo "=== stage 2: NVIDIA $DRV open-module build  $(date)"
wget -q -O compile.sh https://raw.githubusercontent.com/unraid/unraid-nvidia-driver/master/source/compile.sh
# This container ships Slackware pkgtools; no extracted bzroot needed.
sed -i 's#${DATA_DIR}/bzroot-extracted-$UNAME/sbin/makepkg#/sbin/makepkg#' compile.sh
# The container has no libglvnd/Vulkan loader, so nvidia-installer silently
# skips the glvnd EGL vendor JSON and the EGL external-platform JSONs. The
# 610+ Vulkan ICD will not initialise without 10_nvidia.json, so copy them
# from the .run payload into the package tree right before makepkg.
python3 - <<'PY'
s = open('compile.sh').read()
hook = r'''
  # --- added by unraid-nvos-driver: JSONs nvidia-installer skips in this container ---
  ( cd ${DATA_DIR} && rm -rf nvrun-extract && ${DATA_DIR}/NVIDIA_v${1}.run --extract-only --target nvrun-extract >/dev/null 2>&1 && \
    mkdir -p /NVIDIA/usr/share/glvnd/egl_vendor.d /NVIDIA/usr/share/egl/egl_external_platform.d && \
    cp nvrun-extract/10_nvidia.json /NVIDIA/usr/share/glvnd/egl_vendor.d/ && \
    cp nvrun-extract/*_nvidia_wayland*.json nvrun-extract/15_nvidia_gbm.json nvrun-extract/20_nvidia_xcb.json nvrun-extract/20_nvidia_xlib.json /NVIDIA/usr/share/egl/egl_external_platform.d/ && \
    rm -rf nvrun-extract && echo "glvnd/EGL JSONs added" ) || { echo "ERROR: glvnd/EGL JSON copy failed"; exit 1; }
  # --- end added ---
'''
anchor = '  if [ "${2}" == "opensource" ]; then\n    PLUGIN_NAME="nvos-driver"'
assert anchor in s, 'anchor not found in compile.sh (upstream changed?)'
open('compile.sh', 'w').write(s.replace(anchor, hook + anchor, 1))
PY
# compile.sh only defines nvidia_driver(); source it, then call it.
source compile.sh "$DRV" opensource || true
nvidia_driver "$DRV" opensource

PKG="nvos-$DRV-$UNAME-1.txz"
mkdir -p "$DATA_DIR/out"
cp /tmp/nvos-driver_*/"$PKG" /tmp/nvos-driver_*/"$PKG.md5" "$DATA_DIR/out/"
rm -rf /tmp/nvos-driver_*
echo "=== done  $(date)"
ls -la "$DATA_DIR/out"
echo "md5: $(cat "$DATA_DIR/out/$PKG.md5")"
n=$(tar -tJf "$DATA_DIR/out/$PKG" | grep -c -E 'egl_vendor|egl_external')
echo "glvnd/EGL JSON entries in package: $n (expect 8)"
[ "$n" -ge 6 ] || { echo "ERROR: JSONs missing from package"; exit 1; }
modinfo "/NVIDIA/lib/modules/$UNAME/kernel/drivers/video/nvidia.ko" | grep -E '^(version|license|vermagic):'
