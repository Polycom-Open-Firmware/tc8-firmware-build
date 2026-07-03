# Open Firmware for the Polycom TC8

![A repurposed Polycom TC8 panel running a Home Assistant dashboard as a fullscreen kiosk](docs/tc8-kiosk-dashboard.jpeg)

The **Polycom TC8** is the little 8-inch touch panel that ships with Poly
video-conferencing systems — and when those rooms get decommissioned, the
panels usually end up as e-waste. This project gives them a second life as
a small Debian Linux machine that boots straight into a fullscreen web
kiosk: point it at a dashboard, a calendar, a camera feed, or any other
page. One Ethernet cable supplies both power (PoE) and network, the
installer runs in a web browser, and the whole stack — display, touch,
audio, networking — runs on mainline Linux, verified on real hardware.

**How it works** — the TC8 will only start bootloader code signed by
Polycom; that check is burned into the chip and can't be changed. So we
don't fight it: the factory bootloader runs first, exactly as shipped, and
then hands off to our own bootloader, which lives in a spare region of the
panel's built-in storage. From there, ours starts Debian the same way the
panel used to start Android — to the hardware, nothing unusual is
happening. The factory bootloader is never overwritten, so a bad flash
can't permanently brick the panel. [FLASHING.md](FLASHING.md) has the full
mechanics.

**How it's installed and managed** — with the
[browser provisioner](https://wizard.openpolycom.cc/),
a point-and-click wizard that runs entirely in Chrome or Edge: nothing to
install, no drivers, no command line. It talks to the panel over a USB
cable and can:

- **Unlock** a fresh panel — one-time, and the only step that needs a
  serial cable ([QUICKSTART.md](QUICKSTART.md) walks through it)
- **Install or reinstall** the OS, with the option of keeping stock
  Android in the panel's spare boot slot
- **Configure** panels without ever opening a shell — hostname, kiosk
  page, passwords, time zone, certificates, and more
  ([CONFIG-PARTITION.md](CONFIG-PARTITION.md))
- **Update the bootloader** in the field, again with no serial cable

After the one-time unlock, everything happens with a four-finger tap on
the panel's screen and a browser tab. The wizard itself is open source:
[Polycom-Open-Firmware/provisioner](https://github.com/Polycom-Open-Firmware/provisioner).

## What you get on the panel

- 800×1280 DSI panel + backlight, etnaviv GC600/GC520 GPU acceleration
- Goodix GT9110 multi-touch (`/dev/input/event0`)
- TAS5751M class-D audio amplifier on SAI1 (`tas5751-audio` ALSA card; default volume capped at Master 80% / Speaker 75% — small panel speakers distort past that)
- RTL8363NB-VB DSA switch + FEC ethernet (`lan` interface, 1 Gbps full-duplex)
- Composite USB gadget on the data port: CDC ACM (`/dev/ttyACM0` with a root login), CDC NCM (USB Ethernet, panel at `10.55.0.1`, ssh straight off the cable), and MTP (`/data` exposed as a "Portable Device" for drag-and-drop)

Everything boots into a fullscreen Wayland kiosk (`cage` + `cog`) — by
default a bundled touch-tester; point `KIOSK_URL` at any page you like
([USING.md](USING.md)).

## Quick start

**Just want a kiosk?** No build needed — the provisioner ships the release
artifacts. Follow [QUICKSTART.md](QUICKSTART.md).

**Build from source:**

```bash
git clone --recurse-submodules https://github.com/Polycom-Open-Firmware/tc8-firmware-build.git
cd tc8-firmware-build
./bootstrap.sh
sudo ./build.sh --profile=emmc     # → out/emmc/
```

See [BUILDING.md](BUILDING.md) for host setup, credential overrides
(default is **`root` / `root`** — change it), profiles, and iteration
flags.

## Documentation

**Install and use**

- **[QUICKSTART.md](QUICKSTART.md)** — fresh unit → running kiosk: serial bootstrap, then the browser provisioner
- **[FLASHING.md](FLASHING.md)** — the `boota` slot-image model, browser provisioning (enroll → flashos), the on-eMMC layout (A/B slots + stage-2 in `boot1`), recovery
- **[USING.md](USING.md)** — getting into an installed panel, kiosk URL, fleet config

**Build and develop**

- **[BUILDING.md](BUILDING.md)** — host setup (Ubuntu), build pipeline, repo layout, image-size guard
- **[NETBOOT.md](NETBOOT.md)** — TFTP and NFS development path; nothing is written to flash

**Provisioner contracts**

- **[CONFIG-PARTITION.md](CONFIG-PARTITION.md)** — the `cache`-partition blob: autoconfigure key schema + no-serial bootloader updates

## License

GPL-2.0-only (matches the kernel patches it depends on).
