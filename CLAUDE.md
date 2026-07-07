# poly-firmware-build — build card

**One project, two targets.** Builds the kernel + DTB + Debian rootfs for
both Polycom panels off one shared tree (same i.MX8MM SoC):

- **`--target=tc8`** — TC8 (proline_exec). Boots as a **slotable Android
  image** via NXP `boota`; rootfs → the stock `userdata` partition as a
  sparse `rootfs.simg`.
- **`--target=c60`** — Trio C60 (kepler_proto1). Boots via `booti` from
  `boot_a`; rootfs → the stock `system_a` partition as `rootfs.img.zst`.

Shared vs per-target: the kernel is `kernel/config.base` + a per-target
`kernel/targets/<t>.frag`, patched from `kernel-patches/patches/<t>/`; each
target's facts live in `targets/<t>/target.env` and its boot recipe in
`targets/<t>/boot.sh`. The composer (`build.sh --target`) dispatches on
these — clean per-target seams, not a forced abstraction.

**Boot models (why they differ, kept separate on purpose):**
- **TC8 / boota** — `boot.img` (kernel + busybox ro-root initramfs + Debian
  cmdline `root=PARTLABEL=userdata`), `dtbo.img` (DTB in an Android DTBO
  container), `vbmeta.img` (hash descriptors, **`--algorithm NONE`** —
  unsigned but structurally valid; `boota` rejects *no* vbmeta as
  `INVALID_METADATA` but forgives the missing signature while UNLOCKED).
- **C60 / booti** — `boot.img` (kernel + **DTB in `--second`**, no
  ramdisk), `dtbo.img` (Android DTBO container), `vbmeta.img` chaining both,
  **AVB `SHA256_RSA2048`-signed** (board is HAB-open; the signature isn't
  fused-verified but stock u-boot needs a structurally-signed vbmeta with
  the dtbo descriptor).

Install is the browser provisioner (`../provisioner/`): enroll → flashos.

## Build
```sh
sudo apt install -y git build-essential bison flex bc kmod \
  gcc-aarch64-linux-gnu qemu-user-static binfmt-support \
  debootstrap rsync e2fsprogs python3 zstd
./bootstrap.sh                                 # fetch vanilla linux v6.6
sudo ./build.sh --target=tc8 --profile=emmc    # TC8: out/emmc/{Image,imx8mm-tc8.dtb,boot.img,dtbo.img,vbmeta.img,rootfs.simg,…}
sudo ./build.sh --target=c60 --profile=emmc    # C60: out/emmc/{Image,imx8mm-kepler-proto1.dtb,boot.img,dtbo.img,vbmeta.img,rootfs.img.zst,…}
#   --skip-rootfs / --skip-kernel / --rootfs-size=N   (iteration)
#   --os-profile=kiosk,dev   device-role rootfs variants (see PROFILES-PLAN.md)
```
`--target` defaults to `tc8`. The Debian rootfs builder is the `rootfs/`
submodule (poly-rootfs); it takes `--device=<t>` so the right
`poly-<device>-profile-<role>` metapackage is installed.

## Must-know (hard rules)
- **TC8 kernel must stay < 32 MiB** — stock u-boot 2018.03 `BOOTM_LEN` cap;
  CI enforces. (C60 uses its own u-boot; not bound by this.)
- **Never hand-edit `linux-6.6/`; never disable a `.patch`** to dodge an
  apply conflict — regen from a clean tree (2026-05-19 postmortem: a
  `.patch.disabled` shipped a no-display kernel). `kernel/build.sh` uses
  reset-then-apply so re-runs are idempotent.
- The **C60 boot recipe is a faithful port** of the proven c60 packer but is
  not yet silicon-verified from this converged tree — flag before shipping a
  C60 release.

Related: **[FLASHING.md](FLASHING.md)** (partitions, stage-2 chainload),
**[QUICKSTART.md](QUICKSTART.md)** (manual recipe), **[NETBOOT.md](NETBOOT.md)**
(TFTP/NFS), **[CONFIG-PARTITION.md](CONFIG-PARTITION.md)** (the `cache`-blob
config contract the wizard writes). Deep detail → **[BUILDING.md](BUILDING.md)**.
Convergence plan / milestones → **[../PROFILES-PLAN.md](../PROFILES-PLAN.md)**.
