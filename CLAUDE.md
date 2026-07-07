# poly-firmware-build — build card

Builds the **TC8 (proline_exec)** kernel + DTB + Debian rootfs. Profiles
`emmc` (slotable Android image for the `boota` path) and `nfs` (TFTP
kernel + NFS rootfs).

**Boot model:** Debian ships as a **slotable Android image** booted by
NXP `boota` with the bootloader **UNLOCKED**. We DO generate AVB metadata
(`tools/avbtool ... --algorithm NONE` — unsigned but structurally valid);
`boota` rejects an image with *no* vbmeta (`INVALID_METADATA`) but forgives
the missing signature because the unit is unlocked. `build.sh` emits
`boot.img` (kernel + empty ramdisk + Debian cmdline `root=PARTLABEL=userdata`),
`dtbo.img` (DTB in an Android DTBO container), and `vbmeta.img` (hash
descriptors for boot+dtbo). Install is the browser provisioner
(`../provision-tool/`): enroll → flashos (`fastboot flash boot_a/dtbo_a/
vbmeta_a` + sparse `rootfs.simg`→`userdata`, `set_active`, `boota`).

## Build
```sh
sudo apt install -y git build-essential bison flex bc kmod \
  gcc-aarch64-linux-gnu qemu-user-static binfmt-support \
  debootstrap rsync e2fsprogs python3 zstd
./bootstrap.sh                       # fetch vanilla linux v6.6
sudo ./build.sh --profile=emmc       # → out/emmc/{Image,imx8mm-tc8.dtb,boot.img,dtbo.img,vbmeta.img,rootfs.img,rootfs.simg,version.env,SHA256SUMS}
#   --skip-rootfs / --skip-kernel / --rootfs-size=4G   (iteration)
```
TC8 Debian rootfs builder is separate → `../re/release-rootfs/`.

## Must-know (hard rules)
- Kernel **must stay < 32 MiB** — stock u-boot 2018.03 `BOOTM_LEN` cap;
  CI enforces.
- **Never hand-edit `linux-6.6/`; never disable a `.patch`** to dodge an
  apply conflict — regen from a clean tree (2026-05-19 postmortem: a
  `.patch.disabled` shipped a no-display kernel).

Related: **[FLASHING.md](FLASHING.md)** (partitions, stage-2
chainload), **[QUICKSTART.md](QUICKSTART.md)** (manual recipe),
**[NETBOOT.md](NETBOOT.md)** (TFTP/NFS). Deep detail →
**[BUILDING.md](BUILDING.md)**. Cross-repo / provenance / tc8 LXC env →
**[../re/BUILD.md](../re/BUILD.md)**.
