# Building the image

Build the sideloaded Linux image for a Polycom panel from a fresh
checkout. **One repo, two targets** — `--target=` picks the board:

- `--target=tc8` (default) — the TC8 panel: `boota` slot image
  (`boot.img` + `dtbo.img` + `vbmeta.img`, unsigned AVB) + sparse
  `rootfs.simg` for `userdata`.
- `--target=c60` — the Trio C60: `booti` image set (`boot.img` with the
  DTB in its `second` area, Android-DTBO `dtbo.img`, **signed** vbmeta) +
  `rootfs.img.zst` for `system_a`. The 1.75 GiB `system_a` partition is
  the hard ceiling; the default image size is a headroom-safe 1.6 GiB,
  and the builder refuses to emit an oversized image rather than
  truncate it.

A target is `targets/<t>/target.env` (board facts: DTB, partitions, boot
geometry) + `targets/<t>/boot.sh` (the boot-image recipe) — the kernel is
`kernel/config.base` merged with `kernel/targets/<t>.frag`, patched from
`kernel-patches/patches/<t>/`, and the rootfs builder gets `--device=<t>`
so the right `poly-<device>-profile-<role>` package lands. Everything
below applies to both targets unless it names one; the worked examples
use the TC8. Two profiles share the same kernel + rootfs:

- `emmc` — the slotable Android image (`boot.img` + `dtbo.img` +
  `vbmeta.img` + sparse `rootfs.simg`), booted by `boota` and installed by
  the browser provisioner
- `nfs` — netboot bring-up, kernel TFTP'd, rootfs over NFS

`build.sh` produces both the Android slot image (`boot.img`/`dtbo.img`/
`vbmeta.img` + `rootfs.simg`) and the raw `Image` / `imx8mm-tc8.dtb` /
`rootfs.img` used by netboot. The slot image carries **unsigned** AVB
metadata (`tools/avbtool ... --algorithm NONE`) and boots because the unit
is unlocked — [FLASHING.md](FLASHING.md) has the whole story.

## 1. Install prerequisites

On a fresh Ubuntu 22.04+ host:

```bash
sudo apt update
sudo apt install -y \
    git build-essential bison flex bc kmod \
    gcc-aarch64-linux-gnu \
    qemu-user-static binfmt-support \
    debootstrap rsync \
    e2fsprogs python3 \
    zstd
```

`binfmt-support` registers `/proc/sys/fs/binfmt_misc/qemu-aarch64` so
`debootstrap --second-stage` can run arm64 binaries inside the chroot.
Verify:

```bash
ls /proc/sys/fs/binfmt_misc/qemu-aarch64    # should exist
```

## 2. Clone

```bash
git clone --recurse-submodules https://github.com/Polycom-Open-Firmware/poly-firmware-build.git
cd poly-firmware-build
./bootstrap.sh                              # downloads vanilla linux-6.6
```

## 3. (Optional) Bake credentials

Default credentials are **`root` / `root`**, working on tty, USB CDC ACM,
and ssh. To change:

```bash
echo 'mySecret' > root_password         # gitignored
# or: export TC8_ROOT_PASSWORD=mySecret
```

To pre-authorize an SSH pubkey for `root`:

```bash
cat ~/.ssh/id_ed25519.pub > authorized_keys     # gitignored
# or: export TC8_SSH_PUBKEY=~/.ssh/id_ed25519.pub
```

SSH host keys are generated at image build time (`ssh-keygen -A` in the
build chroot) and are never committed.

## 4. Build

```bash
sudo ./build.sh --profile=emmc
```

`sudo` is needed for the chroot bind-mounts and `debootstrap`. First
invocation builds rootfs (~10 min) + kernel (~3 min) + `rootfs.img`
(~30 s). Subsequent invocations cache.

Outputs:

```
out/emmc/boot.img               # Android boot.img v0 + AVB hash footer (NONE) -> fastboot flash boot_a
out/emmc/dtbo.img               # DTB in Android DTBO container + AVB footer    -> fastboot flash dtbo_a
out/emmc/vbmeta.img             # AVB vbmeta, hash descriptors boot+dtbo (NONE) -> fastboot flash vbmeta_a
out/emmc/rootfs.simg            # Android sparse rootfs                         -> fastboot flash userdata
out/emmc/Image                  # raw kernel (netboot)
out/emmc/imx8mm-tc8.dtb         # raw device tree (netboot)
out/emmc/rootfs.img             # 6.4 GiB ext4, sized to the userdata partition (sparse on disk; ~2 GiB used)
out/emmc/initramfs.cpio.gz      # busybox ro-root initramfs (emitted by default; embedded in boot.img)
out/emmc/version.env            # TC8_FW_VERSION, build host, etc.
out/emmc/SHA256SUMS
out/emmc/kernel/Image           # intermediate (= out/emmc/Image)
```

## 5. Install

See [FLASHING.md](FLASHING.md). The production path is the
[**browser provisioner**](https://wizard.openpolycom.cc/): get the unit into the stage-2
fastboot gadget (one-time serial bootstrap on a fresh unit, or the four-finger
gesture once enrolled), then `flashos` writes `boot_a`/`dtbo_a`/`vbmeta_a` +
sparse `rootfs.simg` → `userdata`, `set_active`, and reboots with `boota`.

[QUICKSTART.md](QUICKSTART.md) is the step-by-step fresh-unit serial bootstrap;
[NETBOOT.md](NETBOOT.md) covers the TFTP and NFS development path.

## 6. Iterate

```bash
./build.sh --profile=emmc --skip-rootfs                 # keep rootfs tarball, rebuild kernel + repack
./build.sh --profile=emmc --skip-kernel --skip-rootfs   # only re-pack from existing artifacts
./build.sh --profile=emmc --rootfs-size=4G              # smaller rootfs image (faster fastboot push)
./build.sh --profile=emmc --os-profile=kiosk,bare       # device-ROLE variants (see below)

```

Tweaking `kernel/config.base` or `kernel/targets/tc8.frag` doesn't
trigger a rootfs rebuild.

## Repo layout

```
build.sh                 top-level pipeline: kernel + slot images + rootfs + SHA256SUMS
bootstrap.sh             one-shot: fetches vanilla linux-6.6
tools/                   mkbootimg.py, mkdtboimg.py, mksparse.py, avbtool (slot-image + AVB)
profiles/                emmc.env, nfs.env — per-target kernel cmdline
kernel/                  kernel/build.sh + config.base + targets/<t>.frag (shared config + per-target fragment)
kernel-patches/          submodule: tc8 patch series for vanilla 6.6
rootfs/                  submodule: Debian rootfs builder + chroot-setup
images/                  rootfs.sh (plain ext4)
smoke/                   catch_uboot.py, uboot_watch.py, poe_cycle.sh, orient.html (serial-bootstrap / bring-up helpers)
.github/workflows/       release.yml
```

`kernel-patches` and `rootfs` are sibling repos under the same org; pull
with `--recurse-submodules`.

## Image-size guard

The kernel `Image` must stay under u-boot 2018.03's 32 MiB `BOOTM_LEN`
cap on this device. CI fails the release build if it grows past that.
~24 MiB is fine.

`rootfs.img` is capped at the `userdata` partition (6,843,006,976 bytes) —
the kernel refuses to mount an ext4 bigger than its partition, so `build.sh`
errors out rather than emit an image that flashes but never boots.

If the Image grows past the cap, add SoC families to `kernel/config.base`'s
`# CONFIG_ARCH_… is not set` block to drop them.

## What's forced built-in

The rootfs ships **no `/lib/modules/`**, so any driver in this list
staying `=m` won't load:

- `DRM=y`, `DRM_KMS_HELPER=y`, `DRM_ETNAVIV=y`, `DRM_PANEL_POLY_LCC=y`
- `DRM_MXSFB=y`, `DRM_IMX_LCDIF=y`, `DRM_SAMSUNG_DSIM=y` — i.MX 8M Mini DSI is the **Samsung DSIM** IP, not NWL
- `PHY_MIXEL_MIPI_DPHY=y` — DSIM's phy supplier
- `BACKLIGHT_CLASS_DEVICE=y`, `BACKLIGHT_PWM=y`, `PWM_IMX27=y`
- `SND_SOC_FSL_SAI=y`, `IMX_SDMA=y`, `SND_SOC_TAS571X=y`
- `NET_DSA_REALTEK_RTL8365MB=y`, `NET_DSA_TAG_RTL8_4=y`
- `USB_LIBCOMPOSITE=y`, `USB_F_ACM=y`, `USB_CONFIGFS=y` — USB-data console gadget
- `IP_PNP=y`, `IP_PNP_DHCP=y`, `NFS_FS=y`, `ROOT_NFS=y` — netboot
- `FRAMEBUFFER_CONSOLE_ROTATION=y` — so `fbcon=rotate:N` in cmdline takes effect

If you change the config, verify by reading `/proc/config.gz` on the
running device after reflashing — `kconfig` silently demotes `=y` to `=m`
if a hard dependency is `=m`.

---

## Appendix — building inside an unprivileged LXC

If you must build inside a Proxmox LXC (instead of a real host), you'll
hit problems systemd-tmpfiles can't fix without `CAP_MKNOD`. Two
workarounds:

### Recreate `/dev` char devices at boot

systemd-tmpfiles can't `mknod` in unpriv LXCs and silently leaves
`/dev/null`, `/dev/zero`, etc. as empty regular files. debootstrap
stage 2 fails when that happens. Fix with a oneshot service:

```bash
sudo tee /usr/local/sbin/tc8-fix-devs <<'EOF'
#!/bin/sh
for n in null:1:3 zero:1:5 random:1:8 urandom:1:9 tty:5:0 full:1:7; do
    name=${n%%:*}; mm=${n#*:}; major=${mm%:*}; minor=${mm#*:}
    [ -c /dev/$name ] || { rm -f /dev/$name; mknod -m 666 /dev/$name c $major $minor; }
done
EOF
sudo chmod +x /usr/local/sbin/tc8-fix-devs

sudo tee /etc/systemd/system/tc8-fix-devs.service <<'EOF'
[Unit]
Description=Recreate /dev char devices in unpriv LXC
DefaultDependencies=no
After=local-fs-pre.target
Before=sysinit.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tc8-fix-devs
RemainAfterExit=yes
[Install]
WantedBy=sysinit.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now tc8-fix-devs.service
```

### `rm -rf rootfs/work` may print "Operation not permitted" warnings

The chroot's `/proc` bind-mount can't be lazily unmounted in an
unprivileged LXC. Harmless; output artifacts are unaffected.

### `sudo` won't show progress in some pct-exec setups

If you run the build with `pct exec`, redirect the build to a logfile
and `tail -f` it:

```bash
pct exec <ctid> -- bash -c '
    /usr/local/sbin/tc8-fix-devs
    cd poly-firmware-build
    ./build.sh --profile=emmc 2>&1 | tee /root/build.log
'
```

A native-host build is otherwise straightforward and recommended.

## Device-role profiles (`--os-profile=`)

Not to be confused with `--profile=emmc|nfs` (the *build target*): an
**OS profile** is the device's role — what it boots into. Each profile is
the board-agnostic metapackage `poly-app-<name>` from the
[OpenPolycom apt archive](https://github.com/Polycom-Open-Firmware/apt)
(the per-board `poly-<device>-profile-<name>` is the fallback),
installed into an isolated copy of the shared debootstrap base and packed
as `rootfs-<name>.{img,simg}` (`TC8_OS_PROFILES` lands in `version.env`,
`TC8_PROFILE` in the image's `/etc/tc8-version`). The default profile is
`kiosk`; plain `rootfs.{img,simg}` always alias it so existing tooling and
the provisioner keep working. The special profile `bare` is the untouched
base. Developer cookbook (creating profiles/apps): `DEVELOPING.md` in the
[`packages` repo](https://github.com/Polycom-Open-Firmware/packages/blob/main/DEVELOPING.md).
