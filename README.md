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

**How it's installed and managed** — open the
[browser provisioner](https://wizard.openpolycom.cc/) in Chrome or Edge,
plug the panel into a USB port, and click through. Nothing to install, no
drivers, no command line:

- **Unlock** — first time on a fresh panel, hook up a serial adapter and
  let the wizard do the rest. Once per panel, then the adapter goes back in the drawer.
- **Install the OS** — pick a release, click flash. Keep stock Android in
  the spare slot if you want a way back.
- **Configure** — set the kiosk page, hostname, passwords, time zone, and
  certificates from a form; no shell needed.
- **Update the bootloader** — same wizard, no serial adapter.

Once unlocked, getting back into the wizard is just a four-finger tap on
the panel's boot screen. The wizard itself is open source:
[Polycom-Open-Firmware/provisioner](https://github.com/Polycom-Open-Firmware/provisioner).

**How it works** — the TC8 will only start bootloader code signed by
Polycom; that check is burned into the chip and can't be changed. So we
don't fight it: the factory bootloader runs first, exactly as shipped, and
then hands off to our own bootloader, which lives in a spare region of the
panel's built-in storage. From there, ours starts Debian the same way the
panel used to start Android — to the hardware, nothing unusual is
happening. The factory bootloader is never overwritten, so a bad flash
can't permanently brick the panel. [FLASHING.md](FLASHING.md) has the full
mechanics.

## What you get on the panel

- 800×1280 DSI panel + backlight, etnaviv GC600/GC520 GPU acceleration —
  with the kernel boot crawl and systemd status on the panel, so a failing
  boot tells you where it died
- Goodix GT9110 multi-touch (`/dev/input/event0`)
- TAS5751M class-D audio amplifier on SAI1 (`tas5751-audio` ALSA card; the
  volume range is hard-capped in the kernel so **100% is safe** — full
  scale used to brown out the panel on loud content)
- RTL8363NB-VB DSA switch + FEC ethernet (`lan` interface, 1 Gbps
  full-duplex) using the panel's **factory MAC address**, recovered from
  the stock bootloader environment — stable DHCP leases out of the box
- Composite USB gadget on the data port: CDC ACM (`/dev/ttyACM0` with a
  root login), CDC NCM (USB Ethernet, panel at `10.55.0.1`, ssh straight
  off the cable), and MTP exposing the persistent `/root` as a "Portable
  Device" for drag-and-drop
- A **sealed root filesystem**: the OS mounts read-only behind a tmpfs
  overlay, so reboots always come up pristine; `tc8-rw`/`tc8-ro` toggle a
  maintenance mode for permanent changes like `apt install`
  ([docs/RO-ROOT.md](docs/RO-ROOT.md))
- **Persistent `/root`**: root's home lives on a spare eMMC partition and
  survives reboots *and* full reinstalls ([USING.md](USING.md))

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
