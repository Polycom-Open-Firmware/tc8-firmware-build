# Quickstart — bootstrap a fresh TC8, then provision

> **Scope: TC8 target.** The C60 boots differently (`booti`, `system_a`, SDP unlock) — see the [README](README.md) and the provisioner's C60 flow.

A fresh TC8 has only stock signed U-Boot, which won't auto-enter fastboot.
This is the **one-time serial bootstrap**: catch stock U-Boot over the UART,
force it into fastboot, then let the
[browser provisioner](https://wizard.openpolycom.cc/)
do the rest (enroll + flashos). You only need this once per unit — an
already-enrolled panel drops into fastboot with the four-finger gesture at the
boot selector, no serial.

No build is required — the provisioner ships the release artifacts. You
bring the panel, a UART probe, and a USB cable.

For the boot-path rationale (unsigned AVB, stage-2 in `boot1`, the `boota`
slot image), see [`FLASHING.md`](FLASHING.md).

## What you need

- **A TC8 panel** powered by PoE (or a TC8-compatible PoE injector).
- **A serial UART probe** on the panel's debug header — anything that
  exposes `/dev/ttyUSB*` at 115200 8N1 (an FTDI cable, a CP2102 board, a
  network-attached probe, even a Pi GPIO-UART). Wire `probe-TX → panel-RX`,
  `probe-RX → panel-TX`, `GND → GND`. Used only to catch U-Boot this once.
- **A USB cable** from your laptop to the panel's **micro-B data port** —
  the fastboot gadget (and the provisioner's WebUSB) ride this port.
- **Chrome or Edge** on the laptop (WebUSB — Firefox and Safari won't work).

## Step 1 — Catch U-Boot

The TC8 ships with `bootdelay=0`, so you can't tap a key during boot to break
into U-Boot the normal way. Send Ctrl-C continuously through the serial probe
while the panel powers up. Open your terminal program (`picocom`, `screen`,
`minicom`) on the UART:

```sh
picocom -b 115200 /dev/ttyUSB0
```

Power-cycle the panel (unplug + replug PoE) and **mash Ctrl-C continuously**
for ~10 seconds. You should land on the U-Boot prompt:

```
u-boot=>
```

> If you're using a network-attached UART probe, `smoke/catch_uboot.py`
> automates this — same flow, just Ctrl-C bursts over a WebSocket.

## Step 2 — Force fastboot

Plug the panel's micro-B data port into your laptop, then from the U-Boot
prompt drop into the fastboot gadget:

```
u-boot=> fastboot 0
```

The panel now enumerates as a fastboot device over USB. That's all the serial
console is needed for — leave the UART connected in case you want to retry,
but everything else happens in the browser.

## Step 3 — Provision from the browser

Open the
[browser provisioner](https://wizard.openpolycom.cc/)
in Chrome or Edge and:

1. **Connect device…** — pick the TC8 in the chooser.
2. **Enroll** (one-time) — lands the stage-2 U-Boot in the eMMC `boot1`
   hardware partition and sets the chainload `bootcmd` + `saveenv`. From now
   on the panel loads stage-2 on every boot and the serial cable is no longer
   needed.
3. **Flashos** — `fastboot flash`es `boot_a`/`dtbo_a`/`vbmeta_a`,
   sparse-flashes `rootfs.simg` → `userdata`, `set_active a`, and reboots into
   Debian with `boota`.

The provisioner pulls the artifacts (`boot.img`, `dtbo.img`, `vbmeta.img`,
`rootfs.simg`) from its own manifest — you don't stage anything by hand.

## What you should see

After the reboot (~30–45 s) the panel comes up into the fullscreen kiosk, and
on serial you'll see `tc8-kiosk login:`. Default login is `root` / `root`
(change it — see below).

## After the first boot

Set a real password and (optionally) drop your SSH pubkey:

```sh
ssh root@<panel-ip>     # find the IP from your DHCP server or `ip neigh`
passwd                  # change the root password
mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys   # paste your pubkey, Ctrl-D
```

Then edit `/etc/default/tc8-kiosk` to point `KIOSK_URL` at the page you want
to display and `systemctl restart kiosk`.

## Re-provisioning later

You never need the serial cable again. Enter fastboot with the **four-finger
gesture** at the boot selector, then re-run **flashos** (or the config /
bootloader-update flows) from the browser. See [`FLASHING.md`](FLASHING.md)
for the slot model, plus config and bootloader updates over the cache
partition.
