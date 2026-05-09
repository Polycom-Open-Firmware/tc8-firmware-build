# FLASHING.md

How to put a built `emmc` image onto a Polycom TC8 panel via fastboot. Result: panel boots from its own eMMC into a fullscreen Wayland kiosk (cage + cog) loading the configured URL.

## Prereqs

- A built `out/emmc/` from `./build.sh --profile=emmc` — see BUILDING.md
- `fastboot` on the host (`apt install android-tools-fastboot`)
- The panel's USB data port wired to the host USB controller
- Serial console on the panel's UART (115200 8N1) so you can interrupt u-boot autoboot

## Target layout (Android A/B)

The TC8 ships with an Android A/B partition table on its 16 GB eMMC. Flash slot_b first, validate, mirror to slot_a once you trust it.

| partition       | flashed image | typical use |
|-----------------|---------------|-------------|
| `boot_a` / `boot_b`     | `boot.img`     | kernel + dtb + initramfs + cmdline |
| `dtbo_a` / `dtbo_b`     | `dtbo.img`     | DT overlay |
| `system_a` / `system_b` | `system.img`   | Debian rootfs |
| `vbmeta_a` / `vbmeta_b` | `vbmeta.img`   | AVB metadata |
| `userdata` (`mmcblk2p15`) | not touched    | shared `/data`; preserved across slot updates |

## Get into fastboot

The panel auto-boots into u-boot → kernel quickly. To intercept:

1. Power-cycle the panel (a PoE drop on the panel's port is the cleanest way; physical unplug works too).
2. Spam `Ctrl-C` + space on the serial console during u-boot's `Hit any key to stop autoboot` window.
3. At the `=>` prompt:
   ```
   => fastboot 0
   ```

The device exposes its USB gadget as Android Fastboot. Confirm from the host:

```bash
fastboot devices
# <serial>   Android Fastboot
```

For automation, a small pyserial driver that watches for the autoboot banner and writes `fastboot 0\r` is straightforward — about 30 lines.

## Flash slot_b

```bash
cd out/emmc
fastboot flash boot_b   boot.img
fastboot flash dtbo_b   dtbo.img
fastboot flash vbmeta_b vbmeta.img
fastboot flash system_b system.img    # ~1 minute
fastboot set_active b
fastboot reboot
```

Order matters: `system_b` last so the AVB chain (`vbmeta_b` → boot/dtbo/system hashes) is consistent at reboot time. After `reboot` the panel comes up on slot_b.

## Verify

If you baked your pubkey (`TC8_SSH_PUBKEY=…` or `rootfs/authorized_keys`):

```bash
ssh root@<panel-ip>

# Display
ls /dev/dri/                                  # card0 (etnaviv) + card1 (mxsfb)
cat /sys/class/drm/card1-DSI-1/status         # connected
cat /sys/class/drm/card1-DSI-1/modes          # 800x1280

# Audio
aplay -l                                      # tas5751-audio playback

# Kiosk + /data
systemctl is-active kiosk seatd               # active active
mountpoint /data && echo OK                   # /data is a mountpoint

# Browser
journalctl _COMM=cog -n 5 --no-pager          # cog: <URL> Loaded successfully.
```

The kernel cmdline does early DHCP via `IP-Config` so the panel is reachable before systemd-networkd finishes. `/data` (Android `userdata`, ext4 on `mmcblk2p15`) is mounted on demand by `kiosk.service`'s `ExecStartPre`.

If something is wrong, capture serial logs and check `dmesg | grep -iE 'lcdif|samsung-dsim|tas|panel'` — driver-bind status tells you whether a missing kernel config or DT mismatch is at fault.

## Mirror to slot_a

Once slot_b is good and you want a fallback:

```bash
fastboot flash boot_a   boot.img
fastboot flash dtbo_a   dtbo.img
fastboot flash vbmeta_a vbmeta.img
fastboot flash system_a system.img
# leave set_active=b; slot_a is the parachute
```

## Recovery

`fastboot set_active a` from u-boot fastboot mode falls back to the previous slot. If u-boot itself is intact, you can always reach fastboot via the autoboot interrupt. If you brick u-boot, NXP SDP recovery (`uuu`) over the device's USB data port is the path back — out of scope for this doc.

## End-user access

The image bakes:

- **Composite USB gadget** on the data port — plug into a host and you get both interfaces simultaneously:
  - **CDC ACM** → `/dev/ttyACM0` (Linux) / "USB Serial Device" (Windows). systemd-getty spawns a login prompt automatically.
  - **CDC NCM** → `usb0` USB-Ethernet on the host. The panel runs a tiny systemd-networkd DHCP server on `10.55.0.1/24` and leases `.2`–`.5` to the host. ssh to the panel at **`10.55.0.1`** the moment the link comes up — no manual host config required on Linux/Mac. Windows may need to allow the network in its prompt.
- **ssh** on the LAN (port 22) for hosts that share the panel's wired network.

Default credentials: **`root` / `root`**. Override at build time with `TC8_ROOT_PASSWORD=foo ./build.sh ...` or write a single line to `rootfs/root_password` (gitignored). pubkey auth (via `rootfs/authorized_keys` or `TC8_SSH_PUBKEY=`) wins when present.

The default password applies to: tty1, the panel's UART, the CDC ACM gadget, and ssh (both LAN and the USB-NCM link). *If you ship without changing it, anyone with USB or LAN access can log in as root* — change it for production.

## Configuring the kiosk URL

The kiosk reads `/etc/default/tc8-kiosk`. Variables:

```sh
KIOSK_URL=https://your-page.example.com/
COG_OPTS=--enable-media=true
```

After editing, `systemctl restart kiosk`.
