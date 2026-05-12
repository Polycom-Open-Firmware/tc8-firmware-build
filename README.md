# tc8-firmware-build

Sideload mainline Linux + a Debian kiosk onto the **Polycom TC8**
video-conferencing touch panel (i.MX 8M Mini, codename LCC). Build a
reproducible image, push it to a panel, repurpose the hardware.

The build produces three artifacts:

- `Image` — raw mainline Linux 6.6 kernel
- `imx8mm-tc8.dtb` — raw device tree for the LCC board
- `rootfs.img` — plain ext4 rootfs

Two profiles share the same kernel + rootfs:

- **emmc** — installed onto eMMC via `smoke/onboard.sh`
- **nfs** — netboot bring-up, kernel TFTP'd, rootfs over NFS

Both boot into the same fullscreen Wayland kiosk (`cage` + `cog`) loading
a configurable URL.

## How the boot path actually works

The TC8's stock u-boot has Polycom's signing key locked into AVB. We
can't sign anything it will accept, and we can't replace u-boot (the
SoC's HAB fuses point at Polycom's key too). So we don't try.

What we do instead: overwrite u-boot's *environment* — the `bootcmd`
script, the cmdline — and have it raw-read our kernel and DTB from fixed
eMMC offsets and `booti` directly. No Android boot.img wrapper, no dtbo
overlay, no vbmeta — AVB never executes. The rootfs is plain ext4
mounted by the kernel via `root=/dev/mmcblk2p5`.

See [FLASHING.md](FLASHING.md) for the full recipe and [the partition
table](FLASHING.md#partition-layout). u-boot env edits happen from
running Linux via `fw_setenv` (the rootfs ships `u-boot-tools` and the
right `/etc/fw_env.config`).

## What you get on the panel

- 800×1280 DSI panel + backlight, etnaviv GC600/GC520 GPU acceleration
- Goodix GT9110 multi-touch (`/dev/input/event0`)
- TAS5751M class-D audio amplifier on SAI1 (`tas5751-audio` ALSA card; default volume capped at Master 80% / Speaker 75% — small panel speakers distort past that)
- RTL8363NB-VB DSA switch + FEC ethernet (`lan` interface, 1 Gbps full-duplex)
- Composite USB gadget on the data port: CDC ACM (`/dev/ttyACM0` with a root login), CDC NCM (USB Ethernet, panel at `10.55.0.1`, ssh straight off the cable), and MTP (`/data` exposed as a "Portable Device" for drag-and-drop)

## Repo layout

```
build.sh                 top-level pipeline: kernel + rootfs.img + SHA256SUMS
bootstrap.sh             one-shot: fetches vanilla linux-6.6
profiles/                emmc.env, nfs.env — per-target kernel cmdline
kernel/                  kernel/build.sh + tc8.config (config fragment)
kernel-patches/          submodule: tc8 patch series for vanilla 6.6
rootfs/                  submodule: Debian rootfs builder + chroot-setup
images/                  rootfs.sh (plain ext4) + cmdlines.sh
smoke/                   onboard.sh + hw-smoke-test.sh + test fixtures
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
# artifacts in out/emmc/{Image,imx8mm-tc8.dtb,rootfs.img}
```

Install onto a panel:

```bash
smoke/onboard.sh --brainslug http://10.99.0.35 \
                 --fastboot-host aibox \
                 --poe-port 3 \
                 --artifacts out/emmc
```

Default credentials baked into the image: **`root` / `root`** (works on
tty, USB CDC ACM, and ssh — change before plugging into anything you
care about). See [BUILDING.md](BUILDING.md) for credential overrides.

## Documentation

- **[BUILDING.md](BUILDING.md)** — host setup (Ubuntu), build pipeline, iterate
- **[FLASHING.md](FLASHING.md)** — `onboard.sh`, partition layout, fw_setenv from running Linux, recovery
- **[NETBOOT.md](NETBOOT.md)** — TFTP+NFS server setup, u-boot commands for dev-mode boots

## Status

- Display, audio, network, USB-data CDC, eMMC install, NFS netboot — all verified end-to-end on hardware
- Two panel u-boot variants seen in the wild ("class A" with Polycom's `slotbboot` + `boota` fallback; "class B" with `boota mmc1` only). Both work — see [FLASHING.md](FLASHING.md#first-install-on-a-panel).

## Hardware constraints worth knowing

- **U-Boot 2018.03 (Polycom-customized)** — we don't replace it; we just rewrite its environment. AVB sits unused. `bootcmd` becomes `run slotbboot`, our env script.
- **HAB-locked BootROM** — the SoC's SRK_HASH is fused to Polycom's signing key, so the bootloader is permanent. Doesn't matter for us; u-boot env is mutable.
- **`Image` size is capped at ~32 MiB** by u-boot's `BOOTM_LEN`. The default `tc8.config` keeps it around 24 MiB. CI fails the release if it grows past the cap.

## License

GPL-2.0-only (matches the kernel patches it depends on).
