# tc8-firmware-build

Sideload mainline Linux + a Debian kiosk onto the **Polycom TC8**
video-conferencing touch panel (i.MX 8M Mini, codename LCC). Build a
reproducible image, push it to a panel, repurpose the hardware.

The build emits Debian as a **slotable Android image** plus the raw
artifacts the dev/netboot paths use:

- `boot.img` — Android boot.img: kernel + empty ramdisk + our Debian
  cmdline (`root=PARTLABEL=userdata`), with an AVB hash footer
- `dtbo.img` — `imx8mm-tc8.dtb` wrapped in an Android DTBO container
- `vbmeta.img` — AVB top-level metadata (hash descriptors for boot+dtbo)
- `rootfs.simg` — Android **sparse** rootfs, fastboot-flashed to `userdata`
- `Image` / `imx8mm-tc8.dtb` / `rootfs.img` — raw kernel, DTB, ext4 rootfs
  (for the direct-write dev path and netboot)

Two profiles share the same kernel + rootfs:

- **emmc** — the slotable Android image, flashed by the browser provisioner
- **nfs** — netboot bring-up, kernel TFTP'd, rootfs over NFS

Both boot into the same fullscreen Wayland kiosk (`cage` + `cog`). The
bundled default page is a touch-tester at `/etc/tc8-kiosk/touchtest.html`;
point `KIOSK_URL` at any URL you like.

## How the boot path actually works

We don't have Polycom's AVB signing key and we can't replace stock u-boot
(the SoC's HAB fuses pin its signature). Instead we run a chainloaded
**stage-2 U-Boot** with the bootloader **UNLOCKED**, and ship Debian as a
slotable Android image that stage-2 boots with NXP `boota` — the same path
stock Android uses.

`boota` runs AVB, so we *do* generate AVB metadata — but **unsigned**
(`avbtool --algorithm NONE`). `boota` rejects an image with *no* vbmeta
(`INVALID_METADATA`); once the metadata exists, an unlocked bootloader
forgives the missing/mismatched signature. So `boot.img` and `dtbo.img`
each carry an AVB hash footer and `vbmeta.img` bundles their descriptors —
structurally valid, cryptographically unsigned, boots only because the unit
is unlocked.

Install is the browser provisioner (`../provision-tool/`, a separate
WebUSB tool): a one-time **enroll** lands our stage-2 U-Boot, then
**flashos** does `fastboot flash boot_a / dtbo_a / vbmeta_a`, sparse-flashes
`rootfs.simg` → `userdata`, `set_active`, and reboots into Debian via
`boota`. See [FLASHING.md](FLASHING.md) for the full flow.

> A direct-write **dev/lab path** (UMS + flat GPT + `booti`, via
> `smoke/onboard.sh`) and **netboot** (TFTP+NFS) also exist — see
> [FLASHING.md](FLASHING.md#dev-path--direct-write-via-ums) and
> [NETBOOT.md](NETBOOT.md). u-boot env edits from running Linux still use
> `fw_setenv` (the rootfs ships `u-boot-tools` + `/etc/fw_env.config`).

## What you get on the panel

- 800×1280 DSI panel + backlight, etnaviv GC600/GC520 GPU acceleration
- Goodix GT9110 multi-touch (`/dev/input/event0`)
- TAS5751M class-D audio amplifier on SAI1 (`tas5751-audio` ALSA card; default volume capped at Master 80% / Speaker 75% — small panel speakers distort past that)
- RTL8363NB-VB DSA switch + FEC ethernet (`lan` interface, 1 Gbps full-duplex)
- Composite USB gadget on the data port: CDC ACM (`/dev/ttyACM0` with a root login), CDC NCM (USB Ethernet, panel at `10.55.0.1`, ssh straight off the cable), and MTP (`/data` exposed as a "Portable Device" for drag-and-drop)

## Repo layout

```
build.sh                 top-level pipeline: kernel + slot images + rootfs + SHA256SUMS
bootstrap.sh             one-shot: fetches vanilla linux-6.6
tools/                   mkbootimg.py, mkdtboimg.py, mksparse.py, avbtool (slot-image + AVB)
profiles/                emmc.env, nfs.env — per-target kernel cmdline
kernel/                  kernel/build.sh + tc8.config (config fragment)
kernel-patches/          submodule: tc8 patch series for vanilla 6.6
rootfs/                  submodule: Debian rootfs builder + chroot-setup
images/                  rootfs.sh (plain ext4) + cmdlines.sh
smoke/                   onboard.sh (dev-path direct-write) + hw-smoke-test.sh
.github/workflows/       release.yml, hw-smoke.yml
```

`kernel-patches` and `rootfs` are sibling repos under the same org; pull
with `--recurse-submodules`.

## Quick start

```bash
git clone --recurse-submodules https://github.com/Polycom-Open-Firmware/tc8-firmware-build.git
cd tc8-firmware-build
./bootstrap.sh
sudo ./build.sh --profile=emmc
# slot images + rootfs in out/emmc/{boot.img,dtbo.img,vbmeta.img,rootfs.simg,Image,imx8mm-tc8.dtb,rootfs.img}
```

Install onto a panel with the **browser provisioner** (`../provision-tool/`,
separate WebUSB tool — no host `fastboot` binary, no driver install):

1. Get the unit into the stage-2 fastboot gadget — a fresh unit takes a
   one-time serial bootstrap; an already-enrolled unit uses the 4-finger
   gesture at the boot selector.
2. Open the tool in Chrome/Edge, **enroll** (one-time: lands our stage-2
   U-Boot), then **flashos** — it `fastboot flash`es `boot_a`/`dtbo_a`/
   `vbmeta_a`, sparse-flashes `rootfs.simg` → `userdata`, `set_active`, and
   reboots into Debian via `boota`.

See [FLASHING.md](FLASHING.md) for the full provisioning flow. A
direct-write **dev/lab path** (UMS + flat GPT + `booti` via
`smoke/onboard.sh`, and the manual [QUICKSTART.md](QUICKSTART.md) recipe)
also exists for bring-up.

Default credentials baked into the image: **`root` / `root`** (works on
tty, USB CDC ACM, and ssh — change before plugging into anything you
care about). See [BUILDING.md](BUILDING.md) for credential overrides.

## Documentation

- **[FLASHING.md](FLASHING.md)** — the `boota` slot-image model, browser provisioning (enroll → flashos), and the direct-write dev path + recovery
- **[BUILDING.md](BUILDING.md)** — host setup (Ubuntu), build pipeline, iterate
- **[QUICKSTART.md](QUICKSTART.md)** — manual dev-path recipe (UMS + dd flat layout, no brainslug needed)
- **[NETBOOT.md](NETBOOT.md)** — dev path: TFTP+NFS server setup, u-boot commands for stateless boots

## Status

- Display, audio, network, USB-data CDC, NFS netboot — all verified end-to-end on hardware
- Slot-image (`boota`) provisioning via the browser tool — current install path; enroll + flashos proven on bench
- Direct-write dev path (UMS flat GPT + `booti`) — still functional for bring-up/lab use

## Hardware constraints worth knowing

- **HAB-locked BootROM** — the SoC's SRK_HASH is fused to Polycom's signing key, so stock u-boot is permanent; we can't replace it or sign for AVB. We chainload a **stage-2 U-Boot** instead and run with the bootloader **UNLOCKED**, which lets `boota` accept our **unsigned** (`--algorithm NONE`) AVB metadata.
- **`boota` requires AVB metadata to exist** — an image with no `vbmeta` is rejected as `INVALID_METADATA` even when unlocked; the unlock only forgives a missing/mismatched *signature*. So we always emit `vbmeta.img` + hash footers.
- **`Image` size is capped at ~32 MiB** by u-boot's `BOOTM_LEN`. The default `tc8.config` keeps it around 24 MiB. CI fails the release if it grows past the cap.

## License

GPL-2.0-only (matches the kernel patches it depends on).
