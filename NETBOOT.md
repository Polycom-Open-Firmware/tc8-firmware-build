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
