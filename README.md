# tc8-firmware-build

Reproducible firmware build for the **Polycom TC8** video-conferencing touch panel (i.MX 8M Mini, codename LCC), running mainline Linux 6.6 + a Debian-based kiosk userspace.

The build produces signed Android-style boot/system/dtbo/vbmeta images for two targets:

- **emmc** — fastboot-flashed onto the device's eMMC slot_a/slot_b
- **nfs** — TFTP'd kernel + NFS-rooted rootfs, no flash writes

Both targets boot into the same fullscreen Wayland kiosk (`cage` + `cog`) loading a configurable URL.

## What you get

- 800×1280 DSI panel + backlight, etnaviv GC600/GC520 GPU acceleration
- Goodix GT9110 multi-touch (`/dev/input/event0`)
- TAS5751M class-D audio amplifier on SAI1 (`tas5751-audio` ALSA card; default volume capped at Master 80% / Speaker 75% to stay clean — the small panel speakers distort past that without the stock biquad EQ)
- RTL8363NB-VB DSA switch + FEC ethernet (`lan` interface, 1 Gbps full-duplex)
- Composite USB gadget on the data port: CDC ACM (`/dev/ttyACM0` with a root login), CDC NCM (USB Ethernet, panel at `10.55.0.1`, ssh straight off the cable), and MTP (`/data` exposed as a "Portable Device" for drag-and-drop file access)
- AVB-signed boot chain (orange state with the development test key)

## Repo layout

```
build.sh                 top-level pipeline: kernel → boot → system → dtbo → vbmeta
bootstrap.sh             one-shot: fetches vanilla linux-6.6
profiles/                emmc.env, nfs.env — per-target kernel cmdline
kernel/                  kernel/build.sh + tc8.config (config fragment)
kernel-patches/          submodule: tc8 patch series for vanilla 6.6
rootfs/                  submodule: Debian rootfs builder + chroot-setup
images/                  boot.sh, system.sh, dtbo.sh, vbmeta.sh — image packers
vendored/avb,mkbootimg   pinned copies of avbtool and mkbootimg
```

`kernel-patches` and `rootfs` are sibling repos under the same org; pull with `--recurse-submodules`.

## Quick start

```bash
git clone --recurse-submodules https://github.com/Polycom-Open-Firmware/tc8-firmware-build.git
cd tc8-firmware-build
./bootstrap.sh
./scripts/fetch-avb-test-key.sh
sudo TC8_AVB_KEY=$PWD/testkey_rsa4096.pem ./build.sh --profile=emmc
# artifacts in out/emmc/{boot,dtbo,system,vbmeta}.img
```

Default credentials baked into the image: **`root` / `root`** (works on tty, USB CDC ACM, and ssh — change before deployment). See [BUILDING.md](BUILDING.md) for credential overrides and pubkey injection.

## Documentation

- **[BUILDING.md](BUILDING.md)** — host setup (Ubuntu), build, iterate, kernel-config notes
- **[FLASHING.md](FLASHING.md)** — fastboot flash slot_b → validate → mirror to slot_a
- **[NETBOOT.md](NETBOOT.md)** — TFTP+NFS server setup, u-boot commands, switching deployed panels to netboot

## Status

- Display, audio, network, USB-data CDC, eMMC slot boot, NFS netboot — all verified end-to-end on hardware
- AVB chain produces orange state with the development key; production deployments will want their own key + corresponding u-boot pubkey

## Hardware constraints worth knowing

- **U-Boot 2018.03 (Polycom-customized) with encrypted env** — `fw_setenv` from running Linux is not viable; the env partition is encrypted. `bootcmd` is a fixed fallback chain `run slotbboot; run mainboot; boota mmc1`, which makes "force netboot" a matter of erasing the eMMC boot slots so `slotbboot` falls through to `mainboot` (TFTP+NFS).
- **HAB-locked BootROM** — the SoC's SRK_HASH is fused to Polycom's signing key. Replacing u-boot requires either Polycom's signing key or a still-open SEC_CONFIG fuse + NXP SDP recovery (`uuu`). Out of scope for this repo.
- **`Image` size is capped at ~32 MiB** by u-boot's `BOOTM_LEN`. The default `tc8.config` keeps it around 24 MiB by disabling all non-i.MX SoC families. If you grow the kernel, validate the size before flashing.

## License

GPL-2.0-only (matches the kernel patches it depends on).
