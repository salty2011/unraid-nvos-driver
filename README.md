# unraid-nvos-driver

Build and install NVIDIA **open-kernel-module** driver packages (`nvos-*`) for
Unraid, for driver branches the Unraid Nvidia-Driver plugin does not publish
as open modules.

## Why this exists

- Blackwell GPUs (RTX 50xx, RTX PRO 6000) only work with NVIDIA's open kernel
  modules. The proprietary `nvidia-*` packages will not initialise them.
- The Unraid plugin publishes `nvos-*` packages only for the production
  branch. Feature-branch drivers (610.x) are proprietary-only there.
- NVIDIA's Vulkan AV1 encoder on Blackwell corrupts every inter frame on the
  580 to 595 branches; 610 fixes it. So a Blackwell host that needs Vulkan
  AV1 needs `nvos-610.57.04`, which nobody ships.

`build/` produces that package on any Linux box with Docker. `install/` drops
it into the plugin on the Unraid host so the plugin installs it at boot.

## Quick start: use a prebuilt package

Prebuilt packages are attached to [Releases](../../releases). The package is
tied to one exact Unraid kernel (`uname -r`); pick the release whose asset
name ends in your kernel, e.g. `nvos-610.57.04-6.18.47-Unraid-1.txz` for
Unraid 7.4.0-beta.2.

On the Unraid host, as root:

```bash
# Nvidia-Driver plugin must already be installed (Community Applications).
# For a private repo, export a GitHub token with read access first.
export GITHUB_TOKEN=ghp_...
curl -sfL -H "Authorization: Bearer $GITHUB_TOKEN" -o /tmp/install-nvos.sh \
  https://raw.githubusercontent.com/salty2011/unraid-nvos-driver/main/install/install-nvos.sh
bash /tmp/install-nvos.sh --from-release salty2011/unraid-nvos-driver v610.57.04 --reboot
```

Or copy the `.txz` and `.md5` to the host yourself and run
`install-nvos.sh /path/to/nvos-…txz --reboot`.

After the reboot:

```bash
bash verify-nvos.sh                 # driver, module license, JSON files
bash verify-nvos.sh --vulkan-test   # also proves the Vulkan ICD works in a container
```

The installer backs up the plugin's previous packages and `settings.cfg` to
`/boot/config/plugins/nvidia-driver-backup-<timestamp>/`, sets
`driver_version=latest_nos` and `update_check=false`, and moves any other
package for the same kernel out of the way. The plugin picks the highest
version present locally for the running kernel and does not download when one
exists.

## Building for a new kernel or driver

Needs a Linux host with Docker, no NVIDIA kernel modules loaded (the NVIDIA
installer refuses to build otherwise), about 6 GB RAM and 15 GB disk.
A VM is fine.

```bash
./build/build-nvos.sh --kernel 6.18.47-Unraid --driver 610.57.04
```

Roughly 25 minutes on 6 cores. Output lands in `~/nvos-build/src/out/`.
The script:

1. Finds ich777's pre-compiled Unraid kernel for that version and the matching
   `ghcr.io/ich777/unraid_kernel:gcc_X.Y.Z` image.
2. Starts that container with `DL_ON_START=false` (its auto-download keys off
   the *host's* `uname -r`, which is wrong on a build box) and prepares the
   kernel tree.
3. Runs Unraid's own `compile.sh` with `--kernel-module-type=open`, using the
   container's Slackware `makepkg`.
4. Adds the glvnd/EGL JSON files the NVIDIA installer skips in that container
   (see below), then packages.

Requirements that must exist upstream: a release for the kernel at
[ich777/unraid_kernel](https://github.com/ich777/unraid_kernel/releases) and
the driver `.run` on `us.download.nvidia.com`. Both are checked before starting.

## Things learned the hard way

- **Kernel-specific.** Every Unraid OS update changes the kernel. The plugin
  then finds no local package for the new kernel and downloads the newest
  *published* `nvos`, which may be an older driver branch. Rebuild before you
  upgrade Unraid, or right after.
- **The glvnd JSONs matter.** The build container has no libglvnd or Vulkan
  loader, so `nvidia-installer` silently omits
  `/usr/share/glvnd/egl_vendor.d/10_nvidia.json` and
  `/usr/share/egl/egl_external_platform.d/*.json`. The 610 Vulkan ICD refuses
  to initialise without them: the loader reports
  `Could not get 'vkCreateInstance' via 'vk_icdGetInstanceProcAddr' for ICD libGLX_nvidia.so.0`,
  CUDA, NVENC and `nvidia-smi` keep working, and Vulkan quietly lands on
  whatever other GPU is in the box. `container-build.sh` copies the files
  from the `.run` payload; `verify-nvos.sh` checks for them.
- **`ERROR: driverInitFileInfo ... result=11`** printed at container start is
  noise from the NVIDIA container runtime hook, seen on many Unraid hosts
  with working GPUs. Ignore it.
- **Containers created before the driver change** keep their old device
  injection. `docker restart` is not enough; recreate them
  (`docker compose up -d --force-recreate <service>`).
- **Rebooting over SSH:** Unraid 7.4 has no `/sbin/powerdown`; use
  `/usr/local/sbin/powerdown -r`, and detach it (`setsid nohup … & disown`)
  or it dies with the SSH session before doing anything.

## Layout

```
build/build-nvos.sh        host-side driver: docker container, kernel prep, build
build/container-build.sh   runs inside the ich777 container
install/install-nvos.sh    stage package into the Unraid plugin, fix settings, reboot
install/verify-nvos.sh     post-boot checks, optional container Vulkan test
```

Packages are release assets, not committed files (GitHub's 100 MB limit).
