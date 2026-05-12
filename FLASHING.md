# FLASHING.md

How to take a Polycom TC8 panel from stock (or a previous rev of this
sideload) onto the current build. Result: panel boots from eMMC into a
fullscreen Wayland kiosk (cage + cog) loading whatever URL you've
configured.

## How the sideload boots

The TC8 ships with stock Android A/B partitions and AVB locked to
Polycom's signing key — `boota` rejects anything not signed by them, and
we don't have their key. We bypass AVB entirely by overwriting u-boot's
environment so the boot path is just raw `mmc read` + `booti`:

```
bootcmd = run slotbboot
slotbboot = mmc dev 1;
            if test "${boot_slot}" = "bak"; then
              mmc read 0x40000000 0x20000 0x20000;   # kernel_bak (raw Image)
              mmc read 0x43400000 0x3a000 0x100;     # dtb_bak    (raw DTB)
            else
              mmc read 0x40000000 0x8000  0x20000;   # kernel
              mmc read 0x43400000 0x38000 0x100;     # dtb
            fi
            setenv bootargs "${tc8_bootargs}";
            booti 0x40000000 - 0x43400000
tc8_bootargs = console=tty0 console=ttymxc1,115200 ... root=/dev/mmcblk2p5 ...
boot_slot = main
```

No Android boot.img wrapper, no dtbo overlay, no vbmeta — the kernel and DTB
sit raw at fixed LBA offsets the bootloader can find without any signature
check.

## Partition layout

We rewrite the eMMC's GPT to a flat layout sized for 13 GB of rootfs:

| # | Name        | Start LBA  | Size   | Use |
|---|-------------|-----------:|-------:|-----|
| 1 | `kernel`    | 0x8000     | 48 MiB | raw `Image` (read by slotbboot) |
| 2 | `kernel_bak`| 0x20000    | 48 MiB | rollback kernel |
| 3 | `dtb`       | 0x38000    | 4 MiB  | raw `imx8mm-tc8.dtb` |
| 4 | `dtb_bak`   | 0x3a000    | 4 MiB  | rollback DTB |
| 5 | `rootfs`    | 0x3c000    | 13 GiB | ext4 rootfs |
| 6 | `data`      | (rest)     | ~1.6 GiB | persistent `/data` |

Stock partitions (`dtbo_a/b`, `boot_a/b`, `system_a/b`, `vendor_a/b`,
`vbmeta_a/b`, …) are overwritten on first install. Recover them from
`/var/lib/vz/dump/tc8-*/` on aibox if you ever need them.

## First install on a panel

Onboarding is one command:

```bash
smoke/onboard.sh \
    --brainslug http://10.99.0.35 \
    --fastboot-host aibox \
    --poe-port 3 \
    --artifacts /tmp/tc8-v0.3.0
```

The artifacts directory must contain:
- `Image`
- `imx8mm-tc8.dtb`
- `rootfs.img` or `rootfs.img.zst`

What it does:

1. Spams Ctrl-C at the panel UART via the brainslug while the script
   PoE-cycles the panel. Catches u-boot even on stock units with
   `bootdelay=0` (no `Hit any key` window).
2. `setenv bootdelay 3; saveenv` — gives future intervention a 3-second
   window.
3. Writes the flat GPT via `gpt write mmc 1 …`.
4. `fastboot 0` over UART, then `fastboot flash kernel Image`,
   `fastboot flash dtb imx8mm-tc8.dtb`, `fastboot flash rootfs rootfs.img`.
5. Installs the u-boot env (`slotbboot`, `tc8_bootargs`, `bootcmd`,
   `boot_slot=main`).
6. `reset` → kernel comes up via `slotbboot`. Waits for ssh, prints the
   version banner.

The script is idempotent — re-running it reflashes cleanly. Pass
`--slot bak` to write to the backup slot instead of `main`.

If you just want to push a new rootfs without touching kernel/DTB,
re-run with the same artifacts but only `rootfs.img` populated — the
script skips partitions whose source isn't present.

## Updating from running Linux

Once a panel is on this firmware, you don't need to drop to u-boot for
common edits. `u-boot-tools` is in the rootfs and `/etc/fw_env.config`
points at the eMMC env block (`/dev/mmcblk2` offset `0x400000`,
64 KiB). From a root shell on the panel:

```bash
fw_printenv tc8_bootargs                          # show current cmdline
fw_setenv tc8_bootargs '<new cmdline>'            # change it
fw_setenv boot_slot bak                           # boot the rollback kernel next reset
sync && reboot
```

To push a new kernel/rootfs without touching u-boot at all:

```bash
# stage and write to the bak slot, then flip
scp Image          root@panel:/tmp/
scp imx8mm-tc8.dtb root@panel:/tmp/
ssh root@panel '
  dd if=/tmp/Image          of=/dev/disk/by-partlabel/kernel_bak conv=fsync
  dd if=/tmp/imx8mm-tc8.dtb of=/dev/disk/by-partlabel/dtb_bak    conv=fsync
  fw_setenv boot_slot bak
  sync && reboot'
```

Roll back by `fw_setenv boot_slot main && reboot`.

## Recovery / unbrick

If a slot's kernel is corrupt:

- The other slot still works. From u-boot: `setenv boot_slot bak; saveenv;
  reset` (or `main`). With `bootdelay=3` this is a 3-second window after
  power-on.
- If both slots are wedged: re-run `onboard.sh` — it catches u-boot via the
  brainslug regardless of state and re-flashes from scratch.

If u-boot itself is broken (very rare — we don't touch the bootloader
region): NXP SDP recovery via `uuu` over USB. Out of scope here.

## End-user access

The image bakes:

- **Composite USB gadget** on the data port — three interfaces:
  - **CDC ACM** → `/dev/ttyACM0` (Linux) / "USB Serial Device" (Windows).
    systemd-getty spawns a login prompt automatically.
  - **CDC NCM** → `usb0` USB-Ethernet on the host. Panel runs DHCP on
    `10.55.0.1/24` and leases the host `.2`–`.5`. ssh to `10.55.0.1` the
    moment the link comes up.
  - **MTP / Portable Device** — `/data` exposed via uMTP-Responder.
    Drag-and-drop in any native file manager.
- **ssh** on the wired LAN (port 22).

Default credentials: **`root` / `root`**. Override at build time with
`TC8_ROOT_PASSWORD=...` or `rootfs/root_password`; pubkey via
`rootfs/authorized_keys` or `TC8_SSH_PUBKEY=...`. Change them before
plugging the panel into anything you care about.

## Configuring the kiosk URL

The kiosk reads `/etc/default/tc8-kiosk`. Variables:

```sh
KIOSK_URL=https://your-page.example.com/
COG_OPTS=--enable-media=true
```

After editing, `systemctl restart kiosk`.
