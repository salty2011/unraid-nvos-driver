#!/bin/bash
# Build an Unraid "nvos" NVIDIA driver package (open kernel modules + userspace)
# for a given Unraid kernel, on any Linux box with Docker.
#
#   ./build/build-nvos.sh --kernel 6.18.47-Unraid --driver 610.57.04
#
# Requirements on this host:
#   - docker (user in docker group or run as root)
#   - NO nvidia kernel modules loaded (nvidia-installer aborts otherwise)
#   - ~6 GB RAM, ~15 GB disk, internet access
#
# Output: <workdir>/out/nvos-<driver>-<kernel>-1.txz and .md5
# Reuses the build container and the extracted kernel tree between runs.
set -euo pipefail

KERNEL=""; DRIVER=""; GCC_TAG=""; WORKDIR="$HOME/nvos-build"; CONTAINER="nvos-build"; CPUS=""
usage() { sed -n '2,15p' "$0"; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) KERNEL="$2"; shift 2;;
    --driver) DRIVER="$2"; shift 2;;
    --gcc) GCC_TAG="$2"; shift 2;;
    --workdir) WORKDIR="$2"; shift 2;;
    --container) CONTAINER="$2"; shift 2;;
    --cpus) CPUS="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "unknown arg: $1"; usage;;
  esac
done
[ -n "$KERNEL" ] && [ -n "$DRIVER" ] || usage
case "$KERNEL" in *-Unraid) ;; *) KERNEL="$KERNEL-Unraid";; esac
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
if lsmod | grep -q '^nvidia'; then
  echo "ERROR: nvidia kernel modules are loaded on this host; nvidia-installer refuses to build here."
  echo "Use a host/VM without NVIDIA modules loaded."; exit 1
fi

# Pre-compiled kernel and its gcc come from ich777/unraid_kernel releases.
REL_JSON=$(curl -sfL "https://api.github.com/repos/ich777/unraid_kernel/releases/tags/$KERNEL" || true)
if [ -z "$REL_JSON" ]; then
  echo "ERROR: no pre-compiled kernel release for $KERNEL at https://github.com/ich777/unraid_kernel/releases"; exit 1
fi
if [ -z "$GCC_TAG" ]; then
  GCC_TAG=$(echo "$REL_JSON" | grep -o -E 'gcc_[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$GCC_TAG" ] || { echo "could not detect gcc tag from release notes; pass --gcc gcc_X.Y.Z"; exit 1; }
fi
IMAGE="ghcr.io/ich777/unraid_kernel:$GCC_TAG"
if ! curl -sfI "https://us.download.nvidia.com/XFree86/Linux-x86_64/$DRIVER/NVIDIA-Linux-x86_64-$DRIVER.run" >/dev/null; then
  echo "ERROR: NVIDIA-Linux-x86_64-$DRIVER.run not found on us.download.nvidia.com"; exit 1
fi
echo "kernel=$KERNEL driver=$DRIVER image=$IMAGE workdir=$WORKDIR"

mkdir -p "$WORKDIR/src"
cp "$HERE/container-build.sh" "$WORKDIR/src/container-build.sh"
if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker pull -q "$IMAGE"
  # DL_ON_START=false: the container keys its kernel download off the HOST uname; we drive it ourselves.
  docker run -d --name "$CONTAINER" -e DL_ON_START=false -e ENABLE_SSH=false -e UMASK=022 \
    -v "$WORKDIR/src:/usr/src" "$IMAGE" >/dev/null
else
  docker start "$CONTAINER" >/dev/null
fi
[ -n "$CPUS" ] || CPUS=$(docker exec "$CONTAINER" nproc)
LOG="$WORKDIR/build-$DRIVER-$KERNEL.log"
echo "building (log: $LOG) ..."
docker exec -e UNAME="$KERNEL" -e DRV="$DRIVER" -e CPU_COUNT="$CPUS" "$CONTAINER" \
  bash /usr/src/container-build.sh 2>&1 | tee "$LOG" | grep -E '^(===|md5|glvnd|version|license|vermagic|ERROR)'
PKG="$WORKDIR/src/out/nvos-$DRIVER-$KERNEL-1.txz"
[ -f "$PKG" ] || { echo "build failed, see $LOG"; exit 1; }
echo
echo "package: $PKG"
echo "md5:     $(cat "$PKG.md5")"
echo "Next: copy the .txz and .md5 to the Unraid host and run install/install-nvos.sh"
