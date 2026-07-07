#!/usr/bin/env bash
# build.sh — top-level pipeline: build kernel + rootfs, then package the
# slotable Android image (boot.img + dtbo.img + vbmeta.img + sparse rootfs)
# booted by NXP `boota`, plus raw Image/dtb/rootfs.img for the dev paths.
#
# SLOTABLE ANDROID MODEL (keep the stock Android GPT):
# Our Linux ships as an Android slot image booted by NXP `boota` (the established
# Android path). The DTB lives in the dtbo partition (Android DTBO container),
# NOT in boot.img's `second` — mirroring how stock pairs boot_X + dtbo_X. We emit:
#
#   out/<profile>/boot.img   Android boot.img v0 = kernel + our minimal busybox
#                            initramfs (ro-root/overlay boot selector, see
#                            initramfs/init + docs/RO-ROOT.md) + our Debian
#                            cmdline (pagesize 2048, base 0x40000000, kernel
#                            @ 0x40080000). No DTB inside.
#   out/<profile>/dtbo.img   imx8mm-tc8.dtb wrapped in an Android DTBO container
#                            (magic 0xd7b7ab1e; inner FDT @ 0x40).
#   out/<profile>/vbmeta.img AVB top-level vbmeta carrying hash descriptors for
#                            `boot` and `dtbo` (algorithm NONE = unsigned).
#
# AVB METADATA (so NXP `boota` will boot the slot): boot.img/dtbo.img each get an
# AVB hash *footer* (add_hash_footer) and vbmeta.img bundles their hash
# descriptors (make_vbmeta_image). All are produced with `--algorithm NONE` —
# i.e. UNSIGNED but structurally valid. `boota` loads vbmeta_<slot> first; with the
# bootloader UNLOCKED it forgives the missing/mismatched signature, but the
# descriptors+footers must EXIST — an image with NO vbmeta is rejected as
# INVALID_METADATA. add_hash_footer grows each image to exactly its GPT
# partition size (boot 48 MiB, dtbo 4 MiB) with the footer at the end; the
# ANDROID!/DTBO headers stay intact at offset 0.
#
# Flashed by the browser provisioner. Default: slot A = REPLACE stock:
#   fastboot flash boot_a   out/emmc/boot.img
#   fastboot flash dtbo_a   out/emmc/dtbo.img
#   fastboot flash vbmeta_a out/emmc/vbmeta.img
# (use the _b slot instead to keep stock Android for dual-boot.) AVB runs
# UNLOCKED — these images are unsigned (--algorithm NONE) by design and boot
# only because the bootloader runs unlocked.
#
# Also shipped (raw artifacts, for booti / flat-layout install per FLASHING.md):
#
#   out/<profile>/Image              raw kernel (booti reads this directly)
#   out/<profile>/imx8mm-tc8.dtb     raw device tree
#   out/<profile>/rootfs.img         plain ext4, sized to exactly fill the
#                                    stock `userdata` partition (6.4 GiB)
#   out/<profile>/SHA256SUMS
#
# DEFAULT (run after ./bootstrap.sh):
#   ./build.sh --profile=emmc

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Defaults wired to bootstrap.sh layout
DEFAULT_LINUX="${REPO_ROOT}/linux-6.6"
DEFAULT_PATCHES="${REPO_ROOT}/kernel-patches/patches"
DEFAULT_ROOTFS_DIR="${REPO_ROOT}/rootfs"
DEFAULT_ROOTFS_TGZ="${DEFAULT_ROOTFS_DIR}/out/rootfs.tar.gz"

LINUX=""; PATCHES=""; ROOTFS=""; PROFILE=""
# OUT defaults to $REPO_ROOT/out/<profile-name>/ once we know the profile.
# Override with --out=DIR.
OUT=""
SKIP_KERNEL=0
SKIP_ROOTFS=0
NO_RAMDISK=0
# The stock A/B GPT's `userdata` partition = 13365248 sectors x 512 B (see
# gpt-restore/README.md). rootfs.img is flashed there and MUST NOT be bigger:
# the kernel refuses to mount an ext4 whose block count exceeds the device
# ("bad geometry"). Default = fill it exactly.
USERDATA_PARTITION_SIZE=""   # set from target.env (ROOTFS_PARTITION_SIZE)
ROOTFS_IMG_SIZE=""
JOBS="$(nproc)"

usage() {
  cat <<EOF
build.sh — TC8 firmware build. Produces the slotable Android image
(boot.img + dtbo.img + vbmeta.img, unsigned AVB --algorithm NONE, booted by
\`boota\`) + sparse rootfs.simg, plus raw Image/DTB/rootfs.img for dev paths.

USAGE
  ./build.sh --profile={emmc|nfs} [options]

REQUIRED
  --profile=NAME     emmc | nfs | path/to/custom.env

OPTIONS (all optional — defaults wired to submodules from ./bootstrap.sh)
  --linux=DIR        Vanilla linux-6.6 source tree    (default: ./linux-6.6)
  --patches=DIR      tc8-kernel-patches/patches       (default: ./kernel-patches/patches)
  --rootfs=PATH      rootfs tarball or directory      (default: ./rootfs/out/rootfs.tar.gz; auto-built if missing)
  --os-profile=LIST  device-role profile(s), comma-sep (default: kiosk).
                     Each becomes rootfs-<name>.{img,simg} built from the
                     op-tc8-profile-<name> metapackage (see
                     polycom_dev/PROFILES-PLAN.md M2). NB --profile= is the
                     BUILD target (emmc/nfs), an unfortunate legacy name.
  --rootfs-size=N    rootfs.img size in bytes         (default: 6843006976 = the userdata partition, 6.4 GiB; larger will not mount)
  --out=DIR          output dir                       (default: ./out/<profile>)
  --skip-kernel      do not rebuild kernel (use existing out/kernel/Image)
  --skip-rootfs      do not rebuild rootfs tarball (use existing rootfs/out/)
  --no-ramdisk       build boot.img with an EMPTY ramdisk (pre-v0.5 behaviour:
                     kernel mounts root=PARTLABEL=userdata rw directly; no
                     ro-root/overlay, no maintenance mode)
  --jobs=N           parallelism for kernel build     (default: nproc)
  -h, --help         Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --linux=*) LINUX="${arg#--linux=}";;
    --patches=*) PATCHES="${arg#--patches=}";;
    --rootfs=*) ROOTFS="${arg#--rootfs=}";;
    --os-profile=*) OS_PROFILES="${arg#--os-profile=}";;
    --target=*) TARGET_BOARD="${arg#--target=}";;
    --profile=*) PROFILE="${arg#--profile=}";;
    --rootfs-size=*) ROOTFS_IMG_SIZE="${arg#--rootfs-size=}";;
    --out=*) OUT="${arg#--out=}";;
    --skip-kernel) SKIP_KERNEL=1;;
    --skip-rootfs) SKIP_ROOTFS=1;;
    --no-ramdisk) NO_RAMDISK=1;;
    --jobs=*) JOBS="${arg#--jobs=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

# Apply defaults
: "${LINUX:=$DEFAULT_LINUX}"
: "${PATCHES:=$DEFAULT_PATCHES}"
: "${ROOTFS:=$DEFAULT_ROOTFS_TGZ}"

# Pre-flight: bootstrap state
if [[ ! -d "${REPO_ROOT}/kernel-patches/patches" || ! -f "${REPO_ROOT}/rootfs/build.sh" ]]; then
    echo "ERROR: submodules not populated. Run: ./bootstrap.sh" >&2
    exit 1
fi
if [[ $SKIP_KERNEL -ne 1 && ! -f "${LINUX}/Makefile" ]]; then
    echo "ERROR: linux source not found at ${LINUX}. Run: ./bootstrap.sh" >&2
    exit 1
fi

[[ -n "$PROFILE" ]] || { echo "ERROR: --profile= required" >&2; exit 1; }
: "${OS_PROFILES:=kiosk}"
# Target board (--target=tc8|c60): sources the board delta from targets/<t>/.
: "${TARGET_BOARD:=tc8}"
TENV="$REPO_ROOT/targets/$TARGET_BOARD/target.env"
[[ -f "$TENV" ]] || { echo "ERROR: unknown --target '$TARGET_BOARD' (no $TENV)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$TENV"
echo "[+] target: $TARGET_NAME  dtb=$DTB_NAME  rootfs->$ROOTFS_PARTITION (${ROOTFS_PARTITION_SIZE} B)  boot=$BOOT_MODEL"
USERDATA_PARTITION_SIZE="$ROOTFS_PARTITION_SIZE"
: "${ROOTFS_IMG_SIZE:=$ROOTFS_IMG_DEFAULT_SIZE}"

# Default OUT to per-profile subdir so emmc and nfs targets coexist.
if [[ -z "$OUT" ]]; then
    profile_name="$(basename "${PROFILE%.env}")"
    OUT="$REPO_ROOT/out/$profile_name"
fi

# Compute version refs from all 3 repos BEFORE the rootfs build, so we can
# pass them through to rootfs/build.sh which writes /etc/tc8-version.
# `git describe --dirty` produces e.g. "v0.1.0" on a clean release tag, or
# "v0.1.0-3-g1234abc-dirty" on an in-progress dev build. The upgrade script
# uses this to refuse OTA on non-release (dirty/untagged) images by default.
TC8_FW_VERSION="$(cd "$REPO_ROOT" && git describe --tags --always --dirty 2>/dev/null || echo unknown)"
TC8_ROOTFS_VERSION="$(cd "$DEFAULT_ROOTFS_DIR" && git describe --tags --always --dirty 2>/dev/null || echo unknown)"
TC8_PATCHES_VERSION="$(cd "$REPO_ROOT/kernel-patches" && git describe --tags --always --dirty 2>/dev/null || echo unknown)"
TC8_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TC8_BUILD_HOST="$(hostname)"
echo "[+] version: $TC8_FW_VERSION  rootfs=$TC8_ROOTFS_VERSION  patches=$TC8_PATCHES_VERSION"
export TC8_FW_VERSION TC8_ROOTFS_VERSION TC8_PATCHES_VERSION TC8_BUILD_DATE TC8_BUILD_HOST

# Build rootfs lazily if needed. `sudo` strips most env vars, so explicitly
# preserve the version stamps + customization knobs.
os_profile_tarballs_missing() {
    local pr
    IFS=',' read -ra _pl <<< "$OS_PROFILES"
    for pr in "${_pl[@]}"; do
        [[ -f "$DEFAULT_ROOTFS_DIR/out/rootfs-$pr.tar.gz" ]] || return 0
    done
    return 1
}
if [[ $SKIP_ROOTFS -ne 1 ]] && { [[ ! -e "$ROOTFS" ]] || os_profile_tarballs_missing; }; then
    echo "===> [0/3] rootfs tarball(s) (profiles: $OS_PROFILES)"
    if [[ $EUID -eq 0 ]]; then
        ( cd "$DEFAULT_ROOTFS_DIR" && ./build.sh --profile="$OS_PROFILES" --device="$TARGET_BOARD" )
    else
        ( cd "$DEFAULT_ROOTFS_DIR" && \
          sudo --preserve-env=TC8_FW_VERSION,TC8_ROOTFS_VERSION,TC8_PATCHES_VERSION,TC8_BUILD_DATE,TC8_BUILD_HOST,TC8_SSH_PUBKEY,TC8_ROOT_PASSWORD \
              ./build.sh --profile="$OS_PROFILES" )
    fi
fi
[[ -e "$ROOTFS" ]] || { echo "ERROR: rootfs not found at $ROOTFS" >&2; exit 1; }

mkdir -p "$OUT"

KERNEL_OUT="$OUT/kernel"
KIMG="$KERNEL_OUT/Image"
DTB="$KERNEL_OUT/$DTB_NAME"

if [[ $SKIP_KERNEL -ne 1 ]]; then
  echo "===> [1/3] kernel"
  "$REPO_ROOT/kernel/build.sh" --linux="$LINUX" --patches="$PATCHES" \
    --target="$KERNEL_TARGET" --dtb-name="$DTB_NAME" --jobs="$JOBS" --out="$KERNEL_OUT"
else
  echo "===> [1/3] kernel SKIPPED (--skip-kernel)"
  [[ -f "$KIMG" ]] || { echo "ERROR: $KIMG missing; cannot --skip-kernel" >&2; exit 1; }
  [[ -f "$DTB"  ]] || { echo "ERROR: $DTB missing; cannot --skip-kernel"  >&2; exit 1; }
fi

echo "===> [2/3] rootfs.img"
: "${ROOTFS_IMG_SIZE:=$USERDATA_PARTITION_SIZE}"
rootfs_args=( --rootfs="$ROOTFS" --out="$OUT/rootfs.img" --image-size="$ROOTFS_IMG_SIZE" )
"$REPO_ROOT/images/rootfs.sh" "${rootfs_args[@]}"

# Guard: an ext4 bigger than userdata flashes but never mounts ("bad geometry").
rootfs_sz=$(stat -c %s "$OUT/rootfs.img")
if (( rootfs_sz > USERDATA_PARTITION_SIZE )); then
  echo "ERROR: rootfs.img is $rootfs_sz B but the $ROOTFS_PARTITION partition on" \
       "$TARGET_NAME is only $ROOTFS_PARTITION_SIZE B — it would not mount." \
       "Trim the profile or use --rootfs-size=$ROOTFS_IMG_DEFAULT_SIZE or smaller." \
       "($TARGET_NAME budget is a HARD limit — the build refuses, never truncates.)" >&2
  exit 1
fi

# Rootfs delivery format is per-target (boot model): boota/TC8 flashes an
# Android sparse image over fastboot; booti/C60 streams a zstd-compressed
# ext4 image into system_a. Both start from the same raw rootfs.img above.
if [[ "$BOOT_MODEL" == booti ]]; then
  echo "===> [2.1/3] rootfs.img.zst (zstd, streamed into $ROOTFS_PARTITION)"
  zstd -19 -f -T0 -q "$OUT/rootfs.img" -o "$OUT/rootfs.img.zst"
  echo "       $(stat -c%s "$OUT/rootfs.img.zst") B compressed (from $rootfs_sz B)"
  ROOTFS_SUM_FILE="rootfs.img.zst"
else
# Android sparse copy of rootfs.img for WebUSB fastboot provisioning. rootfs.img
# is sized for the whole `userdata` partition (multi-GiB) but mostly zero blocks;
# sparse encodes the zero runs as DONT_CARE chunks (no payload), so rootfs.simg
# is a small fraction of the raw size. The browser provisioner re-splits THIS
# into per-download sub-images (provision-tool/src/sparse.js) — it never handles
# the raw multi-GiB image. Round-tripped below in the verify step.
echo "===> [2.1/3] rootfs.simg (Android sparse, fastboot flash userdata)"
python3 "$REPO_ROOT/tools/mksparse.py" "$OUT/rootfs.img" "$OUT/rootfs.simg"
ROOTFS_SUM_FILE="rootfs.simg"

# Verify the sparse image: prefer a real simg2img round-trip (byte-identical to
# the raw), else (no AOSP tools) assert the header fields + that the chunks'
# block coverage re-expands to exactly the raw size.
if command -v simg2img >/dev/null 2>&1; then
  echo "===> [2.1/3]   verify: simg2img round-trip"
  simg2img "$OUT/rootfs.simg" "$OUT/rootfs.simg.expanded"
  # rootfs.img is whole 4096-blocks; simg2img reproduces it exactly.
  if cmp -s "$OUT/rootfs.img" "$OUT/rootfs.simg.expanded"; then
    echo "       round-trip OK (simg2img output == rootfs.img)"
  else
    # mksparse pads a partial tail block; allow expansion to be a block-rounded
    # superset that matches on the raw image's length.
    raw_sz=$(stat -c %s "$OUT/rootfs.img")
    if cmp -s -n "$raw_sz" "$OUT/rootfs.img" "$OUT/rootfs.simg.expanded"; then
      echo "       round-trip OK (matches over rootfs.img length $raw_sz B)"
    else
      echo "ERROR: simg2img round-trip mismatch" >&2; exit 1
    fi
  fi
  rm -f "$OUT/rootfs.simg.expanded"
else
  echo "===> [2.1/3]   verify: header + re-expand size (no simg2img)"
  python3 "$REPO_ROOT/tools/mksparse.py" --verify "$OUT/rootfs.simg" "$OUT/rootfs.img" \
    || { echo "ERROR: rootfs.simg verify failed" >&2; exit 1; }
fi
fi   # end per-target rootfs delivery format

# Lift Image + DTB up to the top of out/<profile>/ so release assembly
# doesn't have to peek into out/<profile>/kernel/.
cp "$KIMG" "$OUT/Image"
cp "$DTB"  "$OUT/$DTB_NAME"

# Boot ramdisk: a minimal, auditable busybox initramfs (initramfs/init) that
# mounts the rootfs READ-ONLY behind a tmpfs overlay by default (ephemeral
# writes), or direct-rw when maintenance mode is armed (flag file on facres /
# tc8.rootfs=rw). Full design: docs/RO-ROOT.md. The static busybox comes out
# of the rootfs we just built (package-list.txt ships busybox-static), so no
# new host deps. --no-ramdisk reverts to the empty-ramdisk (direct rw) model.
RAMDISK_ARGS=()
if [[ $NO_RAMDISK -ne 1 && "$BOOT_MODEL" == boota ]]; then
  echo "===> [2.4/3] boot ramdisk (busybox initramfs — ro-root/overlay selector)"
  BUSYBOX="$OUT/.busybox"
  if [[ -d "$ROOTFS" ]]; then
    cp "$ROOTFS/usr/bin/busybox" "$BUSYBOX" 2>/dev/null \
      || cp "$ROOTFS/bin/busybox" "$BUSYBOX" 2>/dev/null \
      || { echo "ERROR: no usr/bin/busybox in $ROOTFS — is busybox-static in package-list.txt? (or use --no-ramdisk)" >&2; exit 1; }
  else
    tar -xOf "$ROOTFS" ./usr/bin/busybox > "$BUSYBOX" 2>/dev/null \
      || tar -xOf "$ROOTFS" ./bin/busybox > "$BUSYBOX" 2>/dev/null \
      || { echo "ERROR: no ./usr/bin/busybox in $ROOTFS — rebuild the rootfs (package-list.txt ships busybox-static) or use --no-ramdisk" >&2; exit 1; }
  fi
  python3 "$REPO_ROOT/tools/mkinitramfs.py" \
    --init "$REPO_ROOT/initramfs/init" \
    --busybox "$BUSYBOX" \
    --out "$OUT/initramfs.cpio.gz"
  rm -f "$BUSYBOX"
  RAMDISK_ARGS=( --ramdisk "$OUT/initramfs.cpio.gz" )
else
  echo "===> [2.4/3] boot ramdisk SKIPPED (--no-ramdisk: kernel mounts root rw directly)"
fi

# The PRIMARY boot artifacts: an Android boot.img v0 (kernel + the initramfs
# above, NO DTB inside) paired with a dtbo.img (DTB in an Android DTBO container). This
# is the slotable Android model — flashed to the stock `boot_a` / `dtbo_a` GPT
# partitions and booted by NXP `boota` (the established Android path) alongside
# stock Android in slot A. Geometry matches stock (pagesize 2048, base
# 0x40000000, kernel @ 0x40080000). The cmdline is our Debian kernel cmdline so
# the DSI panel + root=PARTLABEL=userdata work; it must match the stage-2
# board default `tc8_bootargs` (imx8mm_evk.c).
# root=/rw are consumed by the initramfs (which decides ro-overlay vs
# direct-rw itself); they ALSO keep the kernel's own fallback correct: if the
# ramdisk is somehow absent the kernel direct-mounts userdata rw as before.
# `rw` additionally stops systemd-remount-fs from remounting the overlay ro.
# console=tty0 LAST -> it is the primary console (/dev/console): systemd boot
# status and kernel printk land on the PANEL once fbcon binds, not serial-only.
TC8_CMDLINE="console=ttymxc1,115200 console=tty0 earlycon=ec_imx6q,0x30890000,115200 keep_bootcon panic=10 rw rootwait fw_devlink=permissive video=DSI-1:rotate=270 fbcon=rotate:3 systemd.show_status=true vt.global_cursor_default=0 root=PARTLABEL=userdata"

# NB ramdisk_offset 0x01000000 overlaps the (24 MiB) kernel on paper, but the
# stage-2 boota relocates an overlapping ramdisk past the FDT (fdt_addr =
# kernel_addr + 64 MiB) before copying — see fb_fsl_boot.c "ramdisk overlap
# detected". Kept at the stock offset so the header matches stock images.
# Extra OS-profile variants (beyond the default, which packed above as the
# compat-named rootfs.img/rootfs.simg). Each rootfs-<p>.tar.gz becomes
# rootfs-<p>.{img,simg}; header-verify only (the default did the full
# round-trip; the pipeline is identical).
EXTRA_SUM_FILES=()
IFS=',' read -ra _osp <<< "$OS_PROFILES"
for _p in "${_osp[@]}"; do
    ptgz="$DEFAULT_ROOTFS_DIR/out/rootfs-$_p.tar.gz"
    [[ "$_p" == kiosk && ! -f "$ptgz" ]] && continue   # legacy tarball-only build
    if [[ ! -f "$ptgz" ]]; then
        echo "ERROR: no tarball for os-profile '$_p' ($ptgz)" >&2; exit 1
    fi
    # default profile already packed under the plain names; also emit suffixed
    echo "===> [2.2/3] os-profile '$_p' -> rootfs-$_p.img/.simg"
    "$REPO_ROOT/images/rootfs.sh" --rootfs="$ptgz" --out="$OUT/rootfs-$_p.img" --image-size="$ROOTFS_IMG_SIZE"
    psz=$(stat -c %s "$OUT/rootfs-$_p.img")
    (( psz <= USERDATA_PARTITION_SIZE )) || { echo "ERROR: rootfs-$_p.img exceeds userdata" >&2; exit 1; }
    python3 "$REPO_ROOT/tools/mksparse.py" "$OUT/rootfs-$_p.img" "$OUT/rootfs-$_p.simg"
    EXTRA_SUM_FILES+=( "rootfs-$_p.img" "rootfs-$_p.simg" )
done

# --- boot images: per-target recipe (clean separation, dispatch on BOOT_MODEL).
# tc8 = boota A/B slot images; c60 = booti + system_a. Each targets/<t>/boot.sh
# defines pack_boot(), which produces the flashable boot artifacts + sets
# BOOT_SUM_FILES. See targets/<t>/boot.sh and PROFILES-PLAN.md (M6).
echo "===> [2.5/3] boot images (recipe: $BOOT_MODEL)"
# shellcheck disable=SC1090
. "$REPO_ROOT/targets/$TARGET_BOARD/boot.sh"
pack_boot

echo "===> [3/3] SHA256SUMS + version stamp"
cat > "$OUT/version.env" <<EOF
TC8_OS_PROFILES="$OS_PROFILES"
TC8_FW_VERSION=$TC8_FW_VERSION
TC8_ROOTFS_VERSION=$TC8_ROOTFS_VERSION
TC8_PATCHES_VERSION=$TC8_PATCHES_VERSION
TC8_BUILD_DATE=$TC8_BUILD_DATE
TC8_BUILD_HOST=$TC8_BUILD_HOST
EOF
sum_files=( Image "$DTB_NAME" "${BOOT_SUM_FILES[@]}" rootfs.img "$ROOTFS_SUM_FILE" version.env "${EXTRA_SUM_FILES[@]}" )
[[ $NO_RAMDISK -ne 1 && "$BOOT_MODEL" == boota ]] && sum_files+=( initramfs.cpio.gz )
( cd "$OUT" && sha256sum "${sum_files[@]}" > SHA256SUMS && cat SHA256SUMS )

echo "[OK] all artifacts in $OUT:"
echo "       Image            raw kernel"
echo "       imx8mm-tc8.dtb   raw device tree"
if [[ $NO_RAMDISK -ne 1 && "$BOOT_MODEL" == boota ]]; then
  echo "       initramfs.cpio.gz busybox ro-root/overlay initramfs (embedded in boot.img)"
fi
echo "       boot.img         Android boot.img v0 + AVB hash footer (NONE)   -> fastboot flash boot_a"
echo "       dtbo.img         Android DTBO + AVB hash footer (NONE)          -> fastboot flash dtbo_a"
echo "       vbmeta.img       AVB vbmeta, hash descriptors boot+dtbo (NONE)  -> fastboot flash vbmeta_a"
echo "       rootfs.img       ext4 rootfs                                   -> userdata (root=PARTLABEL=userdata)"
echo "       rootfs.simg      Android sparse rootfs (WebUSB fastboot)        -> fastboot flash userdata (resparsed in-browser)"
