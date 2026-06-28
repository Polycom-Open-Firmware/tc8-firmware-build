# NETBOOT.md

How to netboot the TC8 panel: u-boot pulls a kernel + dtb over **TFTP**, kernel mounts its rootfs over **NFSv3**. Result: same fullscreen Wayland kiosk (cage + cog) as the eMMC target, but nothing is written to the device's flash.

> **This is a dev / iteration path**, not the production install. The
> shipped panel boots the slotable Android image via `boota` (see
> [FLASHING.md](FLASHING.md)); netboot is for kernel/rootfs bring-up and for
> keeping fleets of panels stateless.

The examples below use the placeholder `<server-ip>` for your TFTP+NFS server. Substitute your own. The panel and the server must be on the same routable network.

## 1. Prereqs

- A built `out/nfs/` from `./build.sh --profile=nfs` — see BUILDING.md
- A server reachable from the panel that can run a TFTP daemon and an NFS server
- Serial console on the panel's UART (115200 8N1) so you can interrupt u-boot autoboot

## 2. Server setup (one-time)

```bash
sudo apt install tftpd-hpa nfs-kernel-server

# /etc/default/tftpd-hpa
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create"

sudo mkdir -p /srv/tftp/tc8 /srv/nfs/tc8

# /etc/exports — adjust the subnet to whatever your panels live on
echo "/srv/nfs/tc8 <subnet>/<mask>(rw,sync,no_subtree_check,no_root_squash)" \
    | sudo tee -a /etc/exports
sudo exportfs -ra
sudo systemctl enable --now tftpd-hpa nfs-kernel-server
```

Edit `profiles/nfs.env` (in the build repo) so the kernel cmdline points at your server's IP and exported path. Rebuild with `./build.sh --profile=nfs --skip-rootfs` after changing.

## 3. Stage the artifacts

```bash
# Kernel + dtb → TFTP root
sudo cp out/nfs/kernel/Image            /srv/tftp/tc8/Image
sudo cp out/nfs/kernel/imx8mm-tc8.dtb   /srv/tftp/tc8/imx8mm-tc8.dtb
# (Optional) the Android boot.img (unsigned AVB, --algorithm NONE) — useful if u-boot supports `bootm`/`boota` of Android boot images
sudo cp out/nfs/boot.img                /srv/tftp/tc8/boot.img

# Rootfs → NFS export
sudo rm -rf /srv/nfs/tc8/*
sudo tar -xzf rootfs/out/rootfs.tar.gz -C /srv/nfs/tc8/
```

Verify:

```bash
showmount -e localhost      # should list /srv/nfs/tc8
ls /srv/tftp/tc8/           # Image, imx8mm-tc8.dtb (and optionally boot.img)
ls /srv/nfs/tc8/            # bin boot dev etc home lib root usr var ...
```

## 4. Boot the panel

Power-cycle the panel and interrupt u-boot at the `Hit any key to stop autoboot` prompt (Ctrl-C + space on the serial console). At the `=>` prompt, substituting `<server-ip>` for your server's IP:

```sh
=> setenv autoload no
=> dhcp
=> setenv serverip <server-ip>
=> setenv bootargs "console=tty0 console=ttymxc1,115200 earlycon=ec_imx6q,0x30890000,115200 keep_bootcon panic=10 root=/dev/nfs nfsroot=<server-ip>:/srv/nfs/tc8,v3,tcp,nolock ip=:::::lan:dhcp rw rootwait fw_devlink=permissive"
=> tftpboot 0x40480000 tc8/Image
=> tftpboot 0x43000000 tc8/imx8mm-tc8.dtb
=> booti 0x40480000 - 0x43000000
```

If your u-boot supports Android boot images, you can use the Android boot.img (unsigned AVB) instead:

```sh
=> tftpboot 0x40480000 tc8/boot.img
=> bootm 0x40480000
```

The kernel will:

1. Run early DHCP (`ip=:::::lan:dhcp`) to bring `lan` up while u-boot's `ip` is still active
2. Mount `<server-ip>:/srv/nfs/tc8` as `/`
3. Hand off to systemd → reach `graphical.target` → start `kiosk.service`

## 5. Verify

After a few seconds the panel should be reachable. Default credentials are `root` / `root`:

```bash
ssh root@<panel-ip>

mount | grep ' / '
# <server-ip>:/srv/nfs/tc8 on / type nfs (...,vers=3,...,proto=tcp,...)

ls /dev/dri/        # card0 + card1 + renderD128
aplay -l            # tas5751-audio
pgrep -fa cog       # /usr/bin/cog ... <KIOSK_URL>
```

If `dmesg | grep -i nfs` shows `nfsroot=...` resolved and `VFS: Mounted root (nfs filesystem)`, the netboot was successful. The same kiosk URL config (`/etc/default/tc8-kiosk` / `KIOSK_URL=…`) applies as in the eMMC case.

## Persistence

Anything written to `/` persists in the NFS export — the rootfs is a real shared filesystem, not a tmpfs overlay. To start fresh, re-extract `rootfs.tar.gz` over `/srv/nfs/tc8/`.

For multiple panels sharing one NFS export, switch to a read-only export plus an overlay-fs in initramfs (out of scope here).

## Switching a deployed panel to netboot — no u-boot shell

TC8's u-boot 2018.03 ships with an **encrypted env partition** (`encryptionenabled=true` in env). `fw_setenv` from running Linux writes plaintext that u-boot rejects, and `saveenv` from the u-boot prompt may also fail without the encryption key. So you can't just edit `bootcmd` after deployment.

What you can do: the stock `bootcmd` is already a fallback chain:

```
bootcmd=run slotbboot; run mainboot; boota mmc1
```

`slotbboot` boots slot_a/b from eMMC. **If that fails, `mainboot` runs automatically** — and `mainboot` is exactly the TFTP+booti recipe (`tftp Image; tftp lcc.dtb; setenv bootargs root=/dev/nfs ...; booti`). So switching a deployed panel to netboot is a matter of making `slotbboot` fail.

The clean, reversible way:

```bash
# Get the panel into fastboot first (autoboot interrupt → 'fastboot 0',
# or use the in-Linux trick below if the panel is currently up).
fastboot erase boot_b
fastboot erase boot_a
fastboot reboot
# Both slots empty → slotbboot fails → mainboot runs → kernel TFTP'd, NFS-rooted.
```

To restore eMMC boot, re-flash both slots:

```bash
fastboot flash boot_a out/emmc/boot.img
fastboot flash boot_b out/emmc/boot.img
fastboot reboot
```

The TFTP server IP and the NFS root path used by `mainboot` are baked into u-boot's `serverip` env var and the `mainboot` macro itself. Print them with `printenv` from the u-boot shell on a sample panel to see what your fleet expects, and put your kernel + dtb at the filenames `mainboot` expects (typically `Image` and `lcc.dtb` in the TFTP root). To redirect at the network layer instead of editing the env, set DHCP option 66 (`next-server`) to your TFTP server's IP — but note that `mainboot` doesn't run `dhcp` itself, so option 66 only takes effect if `serverip` was already DHCP'd by some earlier step.

### In-Linux reboot to fastboot (no serial)

If the panel is up on Linux you can drop into fastboot without touching the serial console:

```bash
# AOSP one-shot bootloader signal in the misc partition:
ssh root@<panel> 'printf "bootonce-bootloader\0" | dd of=/dev/mmcblk2p10 conv=notrunc; reboot'
```

(`mmcblk2p10` is the `misc` partition; the `bootonce-bootloader` string is the AOSP-standard one-shot signal that u-boot's `boota` honors. Note: not every Polycom u-boot build picks this up — verify on a sample panel before relying on it across a fleet.)
