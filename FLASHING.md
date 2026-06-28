# FLASHING.md

How to take a Polycom TC8 panel from stock (or a previous rev of this
sideload) onto the current build. Result: panel boots from eMMC into a
fullscreen Wayland kiosk (cage + cog) — by default a touch-tester at
`/etc/tc8-kiosk/touchtest.html`; point `KIOSK_URL` wherever you like.

## How the slot image boots

We can't sign for stock AVB (Polycom's key is fused into HAB) and we can't
replace stock u-boot. So we chainload a **stage-2 U-Boot** with the
bootloader **UNLOCKED**, and ship Debian as a **slotable Android image**
that stage-2 boots with NXP `boota` — the established Android boot path.

`build.sh` emits the slot image into `out/<profile>/`:

- **`boot.img`** — Android boot.img v0: kernel + an *empty* ramdisk + our
  Debian cmdline (`root=PARTLABEL=userdata`). No DTB inside.
- **`dtbo.img`** — `imx8mm-tc8.dtb` in an Android DTBO container.
- **`vbmeta.img`** — AVB top-level metadata carrying hash descriptors for
  `boot` and `dtbo`.

`boota` runs AVB, so the images **must** carry AVB metadata — but it is
**unsigned** (`tools/avbtool ... --algorithm NONE`). `boot.img` and
`dtbo.img` each get an AVB hash *footer* (`add_hash_footer`, which also
grows them to their exact GPT partition size) and `vbmeta.img` bundles
their descriptors. The key fact:

> `boota` rejects an image with **no** vbmeta as `INVALID_METADATA`, even
> when the bootloader is unlocked. The unlock only forgives a *missing or
> mismatched signature* — not absent metadata. So we always generate
> structurally-valid-but-unsigned AVB; it boots only because the unit is
> unlocked.

The rootfs lands in the stock `userdata` partition and is mounted via the
cmdline's `root=PARTLABEL=userdata`.

## Provisioning a panel (browser tool)

The production install path is the **browser provisioner**
(`../provision-tool/`, a separate WebUSB tool — Chrome/Edge, no host
`fastboot` binary and no driver install). It talks the fastboot protocol
directly to the stage-2 U-Boot gadget.

**Two operator entry paths into fastboot:**

- **Fresh / unprovisioned unit — one-time serial bootstrap.** A new unit
  has only stock signed U-Boot, which doesn't auto-enter fastboot. Connect
  serial, catch the stock prompt (`bootdelay=3`), `fastboot 0`, then the web
  tool **enrolls** the unit over WebUSB (lands our stage-2 U-Boot resident,
  sets the chainload `bootcmd` + `saveenv`). One time only.
- **Already-enrolled unit — 4-finger gesture.** Stage-2 loads on every
  boot; the operator does the finger-poke gesture at the boot selector to
  drop into fastboot. No serial, no host CLI.

**Then `flashos` writes the OS** (default slot `a` = replace stock
entirely; pass slot `b` to keep stock Android in A):

1. `fastboot flash boot_a` ← `boot.img`
2. `fastboot flash dtbo_a` ← `dtbo.img`
3. `fastboot flash vbmeta_a` ← `vbmeta.img`
4. sparse-flash `rootfs.simg` → `userdata` (the Android sparse protocol
   transfers ~the used data, not the full multi-GiB image)
5. `set_active a`, then reboot → stage-2 `boota` → Debian.

The browser fetches these from an artifact manifest pointing at the
`build.sh` outputs (`boot.img`, `dtbo.img`, `vbmeta.img`, `rootfs.simg`).

## Dev path — direct-write via UMS

Everything below is the **bring-up / lab path**, distinct from the
production `boota` provisioning above. Instead of the slot image it writes
a **flat GPT** and has u-boot raw-read the kernel + DTB and `booti` them
(no Android wrapper, no AVB). [QUICKSTART.md](QUICKSTART.md) is the
copy-paste recipe by hand, over a serial UART + UMS. It still works and
is handy for kernel/rootfs iteration, but a panel installed this way uses
`root=/dev/mmcblk2p5` and the `slotbboot`/`booti` env — not `boota`.

### Partition layout (flat / dev path)

This path rewrites the eMMC's GPT to a flat layout sized for 13 GB of
rootfs:

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

### ⛔ RESERVED pre-GPT region — DO NOT ALLOCATE (LBA 0x4000–0x8000)

The custom **chainloaded stage-2 u-boot** (`polycom-uboot`, the unlock
FW with the bootsel logo/gesture UX) and its BMP asset blob live in the
**unallocated gap between the env and the first GPT partition**:

| LBA | Bytes | Contents |
|----:|------:|----------|
| 0x0–0x2000 | 0–4 MiB | HAB-signed SPL/ATF/OPTEE/u-boot — UUU only |
| 0x2000 | 0x400000 | u-boot env (4 KiB) |
| 0x2008–0x4000 | 0x401000– | free (optional redundant env) |
| **0x4000** | **0x800000** | **stage-2 `u-boot.bin`** (chainload: `mmc read … 0x4000 0x830`) |
| **0x5000** | **0xA00000** | **bootsel BMP blob** (slots 0x5000/0x5200/0x5400/0x5600) |
| 0x5800–0x8000 | | free headroom |
| 0x8000+ | | flat GPT (`kernel` …) |

**Contract — the flat-GPT generator MUST keep the first partition at
`Start LBA ≥ 0x8000` and MUST NOT create or let the rootfs/installer
reclaim anything in `0x4000–0x8000`.** Earlier the stage-2 lived in
`kernel_bak` (LBA 0x20000) — that is the *load-bearing rollback-kernel
partition* (`slotbboot` raw-reads + `booti`s it on `boot_slot=bak`), so
it was never safe; this reserved gap is the on-eMMC contract.

### First install (dev path)

The flat-layout install is done by hand over UMS —
[QUICKSTART.md](QUICKSTART.md) is the full copy-paste recipe (catch
u-boot → `ums 0 mmc 1` → `sgdisk` a flat GPT → `dd` kernel/DTB/rootfs →
set the `slotbboot`/`bootcmd` env → `reset`).

The artifacts you write are:
- `Image`
- `imx8mm-tc8.dtb`
- `rootfs.img` or `rootfs.img.zst`

For the **fully-unlocked deliverable** (chainloaded stage-2 U-Boot
2024.04 with the bootsel logo/gesture/UMS UX), also stage:
- `stage2-uboot.bin` — `polycom-uboot` `vendored/uboot-imx/u-boot.bin`
  (built `scripts/build.sh tc8-proline_exec`)
- `bmp_blob.bin` — `polycom-uboot`
  `targets/tc8-proline_exec/logos/bmp_blob.bin`

These go into the reserved pre-GPT gap (LBA 0x4000/0x5000) with stock
`bootcmd` pointed at the chainload; without them it's a plain
direct-kernel install. Verified end-to-end on TC1 2026-05-18
(catch→env→UMS GPT/kernel/dtb/rootfs→stage-2 md5-verified→reboot→Debian
on the LAN, `root=/dev/mmcblk2p5`).

The host you run UMS against needs `gdisk`, `util-linux` (provides
`blockdev`, `udevadm`), `zstd`, and `dd`, plus root or passwordless sudo
to write the block device.

How the flow works:

1. Catch u-boot. Stock units ship `bootdelay=0` (no `Hit any key`
   window), so you mash Ctrl-C through power-on — see QUICKSTART.
2. Install our u-boot env vars (`slotbboot`, `tc8_bootargs`, `bootcmd`,
   `boot_slot=main`, `bootdelay=3`) and `saveenv`. Done first so the env
   survives anything that happens during the disk-write phase.
3. `ums 0 mmc 1` over UART — the panel exposes the eMMC user area as a
   USB Mass Storage gadget on the host. u-boot itself lives on the
   eMMC's boot HW partitions, which `ums` does *not* expose, so the
   bootloader is unclobberable.
4. From the host: `sgdisk` a flat GPT
   (kernel/kernel_bak/dtb/dtb_bak/rootfs/data) and stream-write `Image` /
   `imx8mm-tc8.dtb` / `rootfs.img.zst` straight into the right partitions
   with `dd conv=fsync` (pipe the rootfs through `zstd -dc` so the 14 GiB
   decompressed image never has to land on disk).
5. Ctrl-C the UART to leave `ums`, then `reset`.
6. The panel reboots, `slotbboot` raw-reads our kernel + DTB from their
   partitions, and Linux comes up with `root=/dev/mmcblk2p5`.

Why UMS instead of fastboot: stock TC8 u-boot has neither `gpt write` nor
fastboot's `oem partition`, so neither can install a fresh partition
table. UMS sidesteps both by handing the eMMC to the host and letting
ordinary block-device tools (`sgdisk`, `dd`) do the work.

To push only a new rootfs without touching kernel/DTB, write just the
`rootfs` partition and leave the others alone.

### Updating from running Linux (dev path)

Once a panel is on the flat-layout firmware, you don't need to drop to u-boot for
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

### Recovery / unbrick (dev path)

If a slot's kernel is corrupt:

- The other slot still works. From u-boot: `setenv boot_slot bak; saveenv;
  reset` (or `main`). With `bootdelay=3` this is a 3-second window after
  power-on.
- If both slots are wedged: redo the [QUICKSTART.md](QUICKSTART.md)
  dev-path install from scratch — catching u-boot over UART works
  regardless of slot state and re-flashes the eMMC over UMS.

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
