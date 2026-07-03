# FLASHING.md

How to take a Polycom TC8 panel from stock (or a previous rev of this
sideload) onto the current build. Result: panel boots from eMMC into a
fullscreen Wayland kiosk (cage + cog) — by default a touch-tester at
`/etc/tc8-kiosk/touchtest.html`; point `KIOSK_URL` wherever you like.

## How the slot image boots

We can't sign for stock AVB (Polycom's key is fused into HAB) and we can't
replace stock u-boot. So we chainload a **stage-2 U-Boot** (resident in the
eMMC `boot1` hardware partition, out of the user area) with the bootloader
**UNLOCKED**, and ship Debian as a **slotable Android image** that stage-2
boots with NXP `boota` — the established Android boot path.

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

The production install path is the
[**browser provisioner**](https://github.com/Polycom-Open-Firmware/provisioner)
(a separate WebUSB tool — Chrome/Edge, no host
`fastboot` binary and no driver install). It talks the fastboot protocol
directly to the stage-2 U-Boot gadget.

**Two operator entry paths into fastboot:**

- **Fresh / unprovisioned unit — one-time serial bootstrap.** A new unit
  has only stock signed U-Boot, which doesn't auto-enter fastboot. Connect
  serial, catch the stock prompt (mash Ctrl-C as it powers up), `fastboot 0`,
  then the web
  tool **enrolls** the unit over WebUSB (lands our stage-2 U-Boot resident,
  sets the chainload `bootcmd` + `saveenv`). One time only — step-by-step in
  [QUICKSTART.md](QUICKSTART.md).
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

## On-eMMC layout

Install reuses the stock **A/B slot** partitions in the eMMC user area —
there's no repartitioning. `flashos` writes `boot_a`/`dtbo_a`/`vbmeta_a`
(or the `_b` slot), sparse-flashes the rootfs into `userdata`, and
`set_active`s the slot; stage-2 `boota` boots it on the next reset.

Our stage-2 U-Boot lives **outside** the user area, in an eMMC boot
hardware partition — nothing of ours sits in the user-area GPT:

- **`boot0`** — stock signed stage-1 (HAB-fused). Never touched, so a bad
  write can't brick the unit; it stays SDP/`uuu`-recoverable.
- **`boot1`** — our chainloaded stage-2 U-Boot. Stock's persisted env
  chainloads it (`mmc read` from boot1 → `go`). Keeping it in a boot HW
  partition means the whole user-area GPT belongs to the OS — no reserved
  gap the installer has to route around.

`enroll` lands stage-2 in `boot1` the first time; after that it loads on
every boot and presents the fastboot gadget + bootsel gesture UX.

## Config & bootloader updates (no serial)

Post-install, both device config and stage-2 updates go through the
**`cache` partition** — no serial, no bootloader command. The wizard does
`fastboot flash cache <blob>` and the running OS applies the staged blob on
the next boot: idempotent, sha256-verified, and `boot0` is never touched.
See [CONFIG-PARTITION.md](CONFIG-PARTITION.md) for the cache-blob layout +
config-key schema, and [BOOTLOADER-UPDATE.md](BOOTLOADER-UPDATE.md) for the
stage-2-into-`boot1` update flow.

## Recovery / unbrick

- **Bad OS slot** — flip to the other slot, or just re-run the provisioner's
  `flashos` to rewrite the active slot.
- **Bad stage-2** — re-stage it via the `cache` partition (above); the OS
  reflashes `boot1` and verifies before switching.
- **Stage-1 / total brick** (very rare — we never write `boot0`): NXP SDP
  recovery via `uuu` over USB. Out of scope here.

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
