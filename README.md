# Open Firmware for Polycom panels

![A repurposed Polycom TC8 panel running a Home Assistant dashboard as a fullscreen kiosk](docs/tc8-kiosk-dashboard.jpeg)

Poly video-conferencing rooms get decommissioned and their touch panels
usually end up as e-waste. This project gives them a second life as small
Debian Linux machines. **One repo, two targets** — both are i.MX8MM boards,
so they share one kernel tree, one Debian rootfs builder, and one composer;
only the board facts (device tree, boot recipe, partitions) differ:

| | build | boot model | rootfs lands in |
|---|---|---|---|
| **Polycom TC8** | `--target=tc8` (default) | NXP `boota` A/B slot images | `userdata` (sparse `rootfs.simg`) |
| **Polycom Trio C60** | `--target=c60` | `booti` from `boot_a` | `system_a` (`rootfs.img.zst`) |

## The Polycom TC8

The little 8-inch PoE touch panel that ships with Poly video systems. It
boots straight into a fullscreen web kiosk: point it at a dashboard, a
calendar, a camera feed, or any other page. One Ethernet cable supplies
both power (PoE) and network, the installer runs in a web browser, and the
whole stack — display, touch, audio, networking — runs on mainline Linux,
**verified on real hardware** and shipping as tagged releases.

What you get on the panel:

- 800×1280 DSI panel + backlight, etnaviv GC600/GC520 GPU acceleration —
  with the kernel boot crawl and systemd status on the panel, so a failing
  boot tells you where it died
- Goodix GT9110 multi-touch (`/dev/input/event0`)
- TAS5751M class-D audio amplifier on SAI1 (`tas5751-audio` ALSA card; the
  volume range is hard-capped in the kernel so **100% is safe** — full
  scale browns out the panel on loud content)
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

Everything boots into a fullscreen Wayland kiosk (weston + cog by
default; `KIOSK_ENGINE` selects the browser) — the stock page is a
bundled touch-tester; point `KIOSK_URL` at any page you like
([USING.md](USING.md)).

## The Polycom Trio C60

The round conference phone from the same family — touchscreen, a
mic array, a proper speaker, Wi-Fi/BT, and HDMI-in. Same SoC
as the TC8, so it runs the same Debian stack. Hardware support covers
display, touch, audio in/out, LEDs, and Wi-Fi/BT, and `--target=c60`
produces the complete `booti` image set from this repo.

**Release gate:** C60 images from this tree require boot verification on
hardware before a release ships. The C60's unlock path is different
from the TC8's — the C60 loads the project's U-Boot over USB (i.MX Serial
Download Protocol, driven by the same browser wizard via WebHID, no serial
adapter) — and its install overwrites the `system_a` slot rather than
`userdata`.

## How it's installed and managed

Open the [browser provisioner](https://wizard.openpolycom.cc/) in Chrome
or Edge, plug the device into a USB port, and click through. Nothing to
install, no drivers, no command line:

- **Unlock** — first time on a fresh unit. TC8: hook up a serial adapter
  once, then it goes back in the drawer. C60: no adapter at all — the
  wizard loads the project's bootloader over USB (WebHID SDP).
- **Install the OS** — pick a release, click flash. On the TC8 you can
  keep stock Android in the spare slot as a way back.
- **Choose an application** — what the device runs at boot: web **kiosk**
  (default), **developer** console (ssh, no kiosk lock), or — on the C60 —
  **smart speaker**. Role packages are baked into the image,
  so first boot needs no network; the picker writes `PROFILE=` in the
  config blob ([CONFIG-PARTITION.md](CONFIG-PARTITION.md)).
- **Configure** — kiosk page, hostname, Wi-Fi, passwords, time zone, and
  certificates from a form; no shell needed. The config blob is consumed
  on the next boot (applied, then invalidated — it's a message, not a
  store), and offline devices still boot with a roughly-right clock.
- **Update the bootloader** — same wizard, no serial adapter.

Once installed, getting back into the wizard is a four-finger tap during
the boot window. The wizard itself is open source:
[Polycom-Open-Firmware/provisioner](https://github.com/Polycom-Open-Firmware/provisioner).

**How it works (TC8)** — the TC8 will only start bootloader code signed by
Polycom; that check is burned into the chip and can't be changed. The
install works with it rather than against it: the factory bootloader runs
first, exactly as shipped, and then hands off to the project's bootloader,
which lives in a spare region of the panel's built-in storage. From there,
the stage-2 bootloader starts Debian the same way the panel used to start
Android — to the hardware, nothing unusual is happening. The factory
bootloader is never overwritten, so a bad flash can't permanently brick
the panel. [FLASHING.md](FLASHING.md) has the full mechanics. (The C60 is
HAB-open — the project's U-Boot is SDP-loaded and then persisted; the
wizard's C60 flow documents that path.)

## Quick start

**Just want a kiosk?** No build needed — the provisioner ships the release
artifacts. Follow [QUICKSTART.md](QUICKSTART.md).

**Build from source:**

```bash
git clone --recurse-submodules https://github.com/Polycom-Open-Firmware/poly-firmware-build.git
cd poly-firmware-build
./bootstrap.sh
sudo ./build.sh --target=tc8 --profile=emmc   # TC8 → out/emmc/ (boota set + rootfs.simg)
sudo ./build.sh --target=c60 --profile=emmc   # C60 → out/emmc/ (booti set + rootfs.img.zst)
```

See [BUILDING.md](BUILDING.md) for host setup, credential overrides
(default is **`root` / `root`** — change it), profiles, and iteration
flags.

## Documentation

Pages apply to the TC8 unless marked otherwise; each states its scope up
top.

**Install and use**

- **[QUICKSTART.md](QUICKSTART.md)** — *TC8* — fresh unit → running kiosk: serial bootstrap, then the browser provisioner
- **[FLASHING.md](FLASHING.md)** — *TC8* — the `boota` slot-image model, browser provisioning (enroll → flashos), the on-eMMC layout (A/B slots + stage-2 in `boot1`), recovery
- **[USING.md](USING.md)** — *TC8* — getting into an installed panel, kiosk URL, fleet config

**Build and develop**

- **[BUILDING.md](BUILDING.md)** — *both targets* — host setup (Ubuntu), build pipeline, `--target=`, repo layout, image-size guards
- **[RELEASING.md](RELEASING.md)** — *both targets* — the release contract: asset names the wizard depends on, manifests, gates
- **[NETBOOT.md](NETBOOT.md)** — *TC8* — TFTP and NFS development path; nothing is written to flash
- **[docs/RO-ROOT.md](docs/RO-ROOT.md)** — *TC8* — the sealed-rootfs design (read-only + overlay + maintenance mode)

**Provisioner contracts**

- **[CONFIG-PARTITION.md](CONFIG-PARTITION.md)** — *both targets* — the `cache`-partition blob: application/role (`PROFILE`), autoconfigure key schema, no-serial bootloader updates

**Extend — add apps and profiles**

Everything the devices run is a plain Debian package from the project's own
apt archive — adding an app is a metapackage away.

- **[packages](https://github.com/Polycom-Open-Firmware/packages)** `apps/` — what each application does and its config options; `DEVELOPING.md` — the add-an-app/profile cookbook: metapackage → archive → image variant → wizard entry
- **[apt](https://github.com/Polycom-Open-Firmware/apt)** — the package archive: client setup, publishing pipeline
- **[provisioner](https://github.com/Polycom-Open-Firmware/provisioner)** — the wizard: architecture, flavors, hosting

## License

GPL-2.0-only (matches the kernel patches it depends on).
