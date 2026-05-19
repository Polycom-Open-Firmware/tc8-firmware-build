# tc8-firmware-build — build card

Builds the **TC8 (proline_exec)** kernel + DTB + Debian rootfs. Profiles
`emmc` (eMMC install via `smoke/onboard.sh`) and `nfs` (TFTP kernel +
NFS rootfs). No AVB — TC8 u-boot only trusts Polycom's prod key.

## Build
```sh
sudo apt install -y git build-essential bison flex bc kmod \
  gcc-aarch64-linux-gnu qemu-user-static binfmt-support \
  debootstrap rsync e2fsprogs python3 zstd
./bootstrap.sh                       # fetch vanilla linux v6.6
sudo ./build.sh --profile=emmc       # → out/emmc/{Image,imx8mm-tc8.dtb,rootfs.img,version.env,SHA256SUMS}
#   --skip-rootfs / --skip-kernel / --rootfs-size=4G   (iteration)
```
TC8 Debian rootfs builder is separate → `../re/release-rootfs/`.

## Must-know (hard rules)
- Kernel **must stay < 32 MiB** — stock u-boot 2018.03 `BOOTM_LEN` cap;
  CI enforces.
- **Never hand-edit `linux-6.6/`; never disable a `.patch`** to dodge an
  apply conflict — regen from a clean tree (2026-05-19 postmortem: a
  `.patch.disabled` shipped a no-display kernel). `bootstrap.sh` refuses
  a non-pristine tree; `build.sh` fails on dirty/off-pin submodules
  (`ALLOW_DIRTY_LINUX=1` / `ALLOW_DIRTY_SUBMODULES=1` exist — don't use
  casually).

Related: **[FLASHING.md](FLASHING.md)** (onboard.sh, partitions, stage-2
chainload), **[QUICKSTART.md](QUICKSTART.md)** (manual recipe),
**[NETBOOT.md](NETBOOT.md)** (TFTP/NFS). Deep detail →
**[BUILDING.md](BUILDING.md)**. Cross-repo / provenance / tc8 LXC env →
**[../re/BUILD.md](../re/BUILD.md)**.
