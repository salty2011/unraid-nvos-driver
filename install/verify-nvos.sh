#!/bin/bash
# Post-boot check on the Unraid host. Optional: --vulkan-test runs vulkaninfo in a
# throwaway Fedora container through the NVIDIA runtime (needs Docker + internet).
set -u
VK=false; [ "${1:-}" = "--vulkan-test" ] && VK=true
ok=true
say() { printf '%-34s %s\n' "$1" "$2"; }
V=$(cat /sys/module/nvidia/version 2>/dev/null); [ -n "$V" ] && say "nvidia module" "$V" || { say "nvidia module" "NOT LOADED"; ok=false; }
L=$(modinfo nvidia 2>/dev/null | awk '/^license:/{print $2,$3}'); say "module license" "${L:-?} (open modules report 'Dual MIT/GPL')"
say "kernel" "$(uname -r)"
say "installed package" "$(ls /var/log/packages 2>/dev/null | grep -E '^(nvos|nvidia)-[0-9]' | tr '\n' ' ')"
say "nvidia-smi" "$(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>&1 | head -1)"
for f in /usr/share/glvnd/egl_vendor.d/10_nvidia.json /usr/share/egl/egl_external_platform.d/15_nvidia_gbm.json; do
  [ -f "$f" ] && say "$(basename "$f")" "present" || { say "$(basename "$f")" "MISSING (Vulkan ICD will fail on 610+)"; ok=false; }
done
say "plugin driver_version" "$(grep '^driver_version=' /boot/config/plugins/nvidia-driver/settings.cfg 2>/dev/null | cut -d= -f2)"
if $VK; then
  echo "--- Vulkan in a container (fedora:43, installs vulkan-tools; ~1 min) ---"
  docker run --rm --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all --device /dev/dri fedora:43 \
    sh -c 'dnf -y -q install vulkan-tools vulkan-loader libX11 libXext >/dev/null 2>&1; vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverVersion" | sed "s/^[ \t]*//"' 2>/dev/null \
    | grep -v driverInit || { echo "no Vulkan device reported"; ok=false; }
  echo "(expect an NVIDIA deviceName line; 'ERROR: driverInitFileInfo' lines from the runtime hook are harmless)"
fi
$ok && echo "OK" || { echo "PROBLEMS FOUND"; exit 1; }
