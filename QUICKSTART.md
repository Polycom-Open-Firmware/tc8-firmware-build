# Quickstart — flash a TC8 panel by hand (dev path)

A copy-paste recipe for taking a Polycom TC8 from stock (or any prior sideload
revision) to a mainline-Linux + Debian kiosk image. Friendly to first
attempts; assumes you have one TC8 panel, a USB-A-to-USB-C cable to your Linux
laptop, and a serial UART jumper.

> **This is the manual dev/lab path** — a **flat GPT** written over UMS that
> u-boot raw-reads and `booti`s (no Android wrapper, no AVB). It still works
> and needs no special tooling, but a panel installed this way runs the
> `slotbboot`/`booti` env with `root=/dev/mmcblk2p5`, **not** `boota`.
>
> The **production install** is the browser provisioner
> (`../provision-tool/`): it flashes the slotable Android image
> (`boot.img`/`dtbo.img`/`vbmeta.img` + sparse `rootfs.simg` → `userdata`)
> and boots it with `boota`. See [`FLASHING.md`](FLASHING.md#provisioning-a-panel-browser-tool).

For the long-form rationale (boot path, partition layout, why we wipe
Android), see [`FLASHING.md`](FLASHING.md).

## What you need

- **A TC8 panel** powered by PoE (or a TC8-compatible PoE injector).
- **A serial UART probe** between your laptop and the panel's debug header.
  Anything that exposes `/dev/ttyUSB*` at 115200 8N1 works — an FTDI cable,
  a CP2102 board, a network-attached UART probe (this repo's preferred probe),
  even a Pi GPIO-UART. Wire `probe-TX → panel-RX`, `probe-RX → panel-TX`,
  `GND → GND`.
- **A USB-A or USB-C cable** from your laptop to the panel's USB-C port —
  used briefly to expose the eMMC as a USB drive for partitioning.
- **A Linux host** with these packages installed:

  ```sh
  sudo apt install -y gdisk dosfstools zstd curl
  ```

- **The latest release artifacts** from
  [Polycom-Open-Firmware/tc8-firmware-build releases](https://github.com/Polycom-Open-Firmware/tc8-firmware-build/releases):

  ```sh
  TAG=v0.3.0   # or whatever's newest
  mkdir -p /tmp/tc8 && cd /tmp/tc8
  # stage2-uboot.bin + bmp_blob.bin = the fully-unlocked deliverable
  # (chainloaded stage-2 U-Boot 2024.04 + bootsel UX). Optional: omit
  # them for a plain direct-kernel install.
  for f in Image imx8mm-tc8.dtb rootfs.img.zst stage2-uboot.bin bmp_blob.bin SHA256SUMS; do
      curl -fLO "https://github.com/Polycom-Open-Firmware/tc8-firmware-build/releases/download/${TAG}/${f}"
  done
  sha256sum -c SHA256SUMS
  ```

## Step 1 — Catch u-boot

The TC8 ships with `bootdelay=0`, so you can't tap a key during boot to break
into u-boot the normal way. We send Ctrl-C continuously through the serial
probe while the panel powers up. Open your terminal program (e.g. `picocom`,
`screen`, `minicom`) on the UART:

```sh
picocom -b 115200 /dev/ttyUSB0
```

Now power-cycle the panel (unplug + replug PoE) and **mash Ctrl-C continuously**
for ~10 seconds. You should land on the u-boot prompt:

```
u-boot=>
```

> If you're using a network-attached UART probe, `smoke/catch_uboot.py`
> automates this — it's the same flow, just sending Ctrl-C bursts via a
> WebSocket.

## Step 2 — Expose the eMMC over USB

Plug the panel's USB-C port into your laptop, then from the u-boot prompt:

```
u-boot=> ums 0 mmc 1
```

The panel's eMMC now appears on your laptop as a USB drive. Find it:

```sh
lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN | grep -i 'Linux UMS'
# Example output:
# sdb   14.7G usb    Linux    UMS disk 0
```

**Triple-check** you've identified the right `/dev/sdX` — the next step is
destructive. The eMMC is 16 GiB; anything else is wrong. Set the device
once and stop typing it by hand:

```sh
EMMC=/dev/sdb   # ← edit to match what you saw above
sudo blockdev --getsize64 "$EMMC"   # should print ~15.7 GB
```

## Step 3 — Lay down the partition table

```sh
sudo sgdisk --zap-all "$EMMC"
sudo sgdisk \
    --disk-guid=00112233-4455-6677-8899-aabbccddeeff \
    -n 1:16M:+48M  -c 1:kernel      -t 1:8300 \
    -n 2:0:+48M    -c 2:kernel_bak  -t 2:8300 \
    -n 3:0:+4M     -c 3:dtb         -t 3:8300 \
    -n 4:0:+4M     -c 4:dtb_bak     -t 4:8300 \
    -n 5:0:+13G    -c 5:rootfs      -t 5:8300 \
    -n 6:0:0       -c 6:data        -t 6:8300 \
    "$EMMC"
sudo blockdev --rereadpt "$EMMC" || true
sudo udevadm settle
```

> The `1:16M` is important — the first partition must start at **16 MiB
> or later** so it doesn't overlap u-boot's environment block at byte
> offset 4 MiB. Without this margin, writing the kernel would erase the
> u-boot env and the panel would revert to the stock `boota mmc1`
> bootcmd on next reset.

You should now have `${EMMC}1`..`${EMMC}6`.

## Step 4 — Write kernel, DTB, and root filesystem

```sh
sudo dd if=/tmp/tc8/Image           of=${EMMC}1 bs=1M  conv=fsync status=progress
sudo dd if=/tmp/tc8/imx8mm-tc8.dtb  of=${EMMC}3 bs=1M  conv=fsync status=progress
zstd -dc /tmp/tc8/rootfs.img.zst | sudo dd of=${EMMC}5 bs=4M conv=fsync status=progress
```

The rootfs is ~13 GiB; expect ~5–10 minutes over USB 2.0.

When all three are done, `sync` and eject:

```sh
sudo sync
sudo eject "$EMMC" 2>/dev/null || true
```

## Step 5 — Tell u-boot how to boot

Back at the panel's u-boot prompt (Ctrl-C in the `ums` command), paste this
*one block at a time*:

```
setenv bootdelay 3
setenv boot_slot main
setenv tc8_bootargs 'console=tty0 console=ttymxc1,115200 earlycon=ec_imx6q,0x30890000,115200 keep_bootcon panic=10 rw rootwait fw_devlink=permissive video=DSI-1:rotate=270 fbcon=rotate:3 vt.global_cursor_default=0 root=/dev/mmcblk2p5'
setenv slotbboot 'mmc dev 1\; if test "${boot_slot}" = "bak"\; then mmc read 0x40000000 0x20000 0x18000\; mmc read 0x43400000 0x3a000 0x2000\; else mmc read 0x40000000 0x8000 0x18000\; mmc read 0x43400000 0x38000 0x2000\; fi\; setenv bootargs "${tc8_bootargs}"\; booti 0x40000000 - 0x43400000'
setenv bootcmd 'run slotbboot'
saveenv
reset
```

> **Why the `\;` everywhere?** u-boot's command parser splits on bare `;`
> even inside single-quoted setenv values. Escaping them keeps the
> multi-step `slotbboot` script in one env var.

The panel reboots, runs `slotbboot`, raw-loads our kernel + DTB from the
new partitions, and boots Linux. After 30–45 s you should see a kiosk
splash on screen and `tc8-kiosk login:` on serial.

## What you should see

- Serial console: `Debian GNU/Linux 12 tc8-kiosk ttymxc1 / tc8-kiosk login:`
- Default login: `root` / `root` (change immediately — see below)
- `cat /proc/cmdline` shows `root=/dev/mmcblk2p5`
- `df -h /` shows the rootfs around 13 GiB
- `cat /etc/tc8-version` shows the tag you flashed

## After the first boot

Set a real password and (optionally) drop your SSH pubkey:

```sh
ssh root@<panel-ip>     # find IP via your DHCP server or `ip neigh`
passwd                  # change root password
mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys   # paste your pubkey, Ctrl-D
```

Then edit `/etc/default/tc8-kiosk` to point at the URL you actually want to
display and `systemctl restart kiosk`.

## Updating later

You don't need to redo step 1–3 to push a new build. From a running panel:

```sh
# Stage a new kernel + DTB to the backup slot, then flip
scp Image imx8mm-tc8.dtb root@panel:/tmp/
ssh root@panel '
  dd if=/tmp/Image          of=/dev/disk/by-partlabel/kernel_bak conv=fsync
  dd if=/tmp/imx8mm-tc8.dtb of=/dev/disk/by-partlabel/dtb_bak    conv=fsync
  fw_setenv boot_slot bak
  sync && reboot'
```

If the new kernel boots cleanly, `fw_setenv boot_slot main` and copy the new
artifacts into `kernel` / `dtb` to make `main` the new normal. If it doesn't
boot, the original `main` slot still works — `fw_setenv boot_slot main &&
reboot` (from another panel, or via the recovery path below).

## Recovery

If both kernel slots are wedged and you can't reach Linux: repeat steps 1–5.
The flow is idempotent — re-running it on a panel in any state is safe and
brings it back to a known-good install.
