#!/usr/bin/env bash
# build.sh — top-level pipeline: build kernel, then a flat-layout rootfs.img.
#
# SLOTABLE ANDROID MODEL (option A — keep the stock Android GPT):
# Our Linux ships as Android *slot B* alongside stock Android in slot A, booted
# by NXP `boota` (the established Android path). The DTB lives in the dtbo
# partition (Android DTBO container), NOT in boot.img's `second` — mirroring how
# stock Android pairs boot_X + dtbo_X. We emit:
#
#   out/<profile>/boot.img   Android boot.img v0 = kernel + EMPTY ramdisk +
#                            our Debian cmdline (pagesize 2048, base 0x40000000,
#                            kernel @ 0x40080000). No DTB inside.
#   out/<profile>/dtbo.img   imx8mm-tc8.dtb wrapped in an Android DTBO container
#                            (magic 0xd7b7ab1e; inner FDT @ 0x40).
#   out/<profile>/vbmeta.img AVB top-level vbmeta carrying hash descriptors for
#                            `boot` and `dtbo` (algorithm NONE = unsigned).
#
# AVB METADATA (so NXP `boota` will boot slot B): boot.img/dtbo.img each get an
# AVB hash *footer* (add_hash_footer) and vbmeta.img bundles their hash
# descriptors (make_vbmeta_image). All are produced with `--algorithm NONE` —
# i.e. UNSIGNED but structurally valid. `boota` loads vbmeta_b first; with the
# bootloader UNLOCKED it forgives the missing/mismatched signature, but the
# descriptors+footers must EXIST — an image with NO vbmeta is rejected as
# INVALID_METADATA. add_hash_footer grows each image to exactly its GPT
# partition size (boot_b=48 MiB, dtbo_b=4 MiB) with the footer at the end; the
# ANDROID!/DTBO headers stay intact at offset 0.
#
# Flash into the B-slot alongside stock Android (slot A):
#   fastboot flash boot_b   out/emmc/boot.img
#   fastboot flash dtbo_b   out/emmc/dtbo.img
#   fastboot flash vbmeta_b out/emmc/vbmeta.img
# AVB runs UNLOCKED — these images are unsigned (--algorithm NONE) by design and
# boot only because the bootloader runs unlocked.
#
# Also shipped (raw artifacts, for booti / flat-layout install per FLASHING.md):
#
#   out/<profile>/Image              raw kernel (booti reads this directly)
#   out/<profile>/imx8mm-tc8.dtb     raw device tree
#   out/<profile>/rootfs.img         plain ext4, sized for the flat-layout
#                                    `rootfs` partition (default 13 GiB)
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
DEFAULT_INITRAMFS="${DEFAULT_ROOTFS_DIR}/out/initramfs.cpio.gz"

LINUX=""; PATCHES=""; ROOTFS=""; INITRAMFS=""; PROFILE=""
# OUT defaults to $REPO_ROOT/out/<profile-name>/ once we know the profile.
# Override with --out=DIR.
OUT=""
SKIP_KERNEL=0
SKIP_ROOTFS=0
ROOTFS_IMG_SIZE=""
JOBS="$(nproc)"

usage() {
  cat <<EOF
build.sh — TC8 firmware build (kernel + DTB + rootfs.img). No AVB, no
Android A/B — produces the artifacts our flat-layout install scheme uses.

USAGE
  ./build.sh --profile={emmc|nfs} [options]

REQUIRED
  --profile=NAME     emmc | nfs | path/to/custom.env

OPTIONS (all optional — defaults wired to submodules from ./bootstrap.sh)
  --linux=DIR        Vanilla linux-6.6 source tree    (default: ./linux-6.6)
  --patches=DIR      tc8-kernel-patches/patches       (default: ./kernel-patches/patches)
  --rootfs=PATH      rootfs tarball or directory      (default: ./rootfs/out/rootfs.tar.gz; auto-built if missing)
  --initramfs=PATH   initramfs.cpio.gz                (default: ./rootfs/out/initramfs.cpio.gz)
  --rootfs-size=N    rootfs.img size in bytes         (default: 13 GiB)
  --out=DIR          output dir                       (default: ./out/<profile>)
  --skip-kernel      do not rebuild kernel (use existing out/kernel/Image)
  --skip-rootfs      do not rebuild rootfs tarball (use existing rootfs/out/)
  --jobs=N           parallelism for kernel build     (default: nproc)
  -h, --help         Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --linux=*) LINUX="${arg#--linux=}";;
    --patches=*) PATCHES="${arg#--patches=}";;
    --rootfs=*) ROOTFS="${arg#--rootfs=}";;
    --initramfs=*) INITRAMFS="${arg#--initramfs=}";;
    --profile=*) PROFILE="${arg#--profile=}";;
    --rootfs-size=*) ROOTFS_IMG_SIZE="${arg#--rootfs-size=}";;
    --out=*) OUT="${arg#--out=}";;
    --skip-kernel) SKIP_KERNEL=1;;
    --skip-rootfs) SKIP_ROOTFS=1;;
    --jobs=*) JOBS="${arg#--jobs=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

# Apply defaults
: "${LINUX:=$DEFAULT_LINUX}"
: "${PATCHES:=$DEFAULT_PATCHES}"
: "${ROOTFS:=$DEFAULT_ROOTFS_TGZ}"
: "${INITRAMFS:=$DEFAULT_INITRAMFS}"

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
if [[ $SKIP_ROOTFS -ne 1 && ! -e "$ROOTFS" ]]; then
    echo "===> [0/3] rootfs tarball (no $ROOTFS yet)"
    if [[ $EUID -eq 0 ]]; then
        ( cd "$DEFAULT_ROOTFS_DIR" && ./build.sh )
    else
        ( cd "$DEFAULT_ROOTFS_DIR" && \
          sudo --preserve-env=TC8_FW_VERSION,TC8_ROOTFS_VERSION,TC8_PATCHES_VERSION,TC8_BUILD_DATE,TC8_BUILD_HOST,TC8_SSH_PUBKEY,TC8_ROOT_PASSWORD \
              ./build.sh )
    fi
fi
[[ -e "$ROOTFS" ]] || { echo "ERROR: rootfs not found at $ROOTFS" >&2; exit 1; }

mkdir -p "$OUT"

KERNEL_OUT="$OUT/kernel"
KIMG="$KERNEL_OUT/Image"
DTB="$KERNEL_OUT/imx8mm-tc8.dtb"

if [[ $SKIP_KERNEL -ne 1 ]]; then
  echo "===> [1/3] kernel"
  "$REPO_ROOT/kernel/build.sh" --linux="$LINUX" --patches="$PATCHES" \
    --jobs="$JOBS" --out="$KERNEL_OUT"
else
  echo "===> [1/3] kernel SKIPPED (--skip-kernel)"
  [[ -f "$KIMG" ]] || { echo "ERROR: $KIMG missing; cannot --skip-kernel" >&2; exit 1; }
  [[ -f "$DTB"  ]] || { echo "ERROR: $DTB missing; cannot --skip-kernel"  >&2; exit 1; }
fi

echo "===> [2/3] rootfs.img"
rootfs_args=( --rootfs="$ROOTFS" --out="$OUT/rootfs.img" )
[[ -n "$ROOTFS_IMG_SIZE" ]] && rootfs_args+=( --image-size="$ROOTFS_IMG_SIZE" )
"$REPO_ROOT/images/rootfs.sh" "${rootfs_args[@]}"

# Android sparse copy of rootfs.img for WebUSB fastboot provisioning. rootfs.img
# is sized for the whole `userdata` partition (multi-GiB) but mostly zero blocks;
# sparse encodes the zero runs as DONT_CARE chunks (no payload), so rootfs.simg
# is a small fraction of the raw size. The browser provisioner re-splits THIS
# into per-download sub-images (provision-tool/src/sparse.js) — it never handles
# the raw multi-GiB image. Round-tripped below in the verify step.
echo "===> [2.1/3] rootfs.simg (Android sparse, fastboot flash userdata)"
python3 "$REPO_ROOT/tools/mksparse.py" "$OUT/rootfs.img" "$OUT/rootfs.simg"

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

# Lift Image + DTB up to the top of out/<profile>/ so release assembly
# doesn't have to peek into out/<profile>/kernel/.
cp "$KIMG" "$OUT/Image"
cp "$DTB"  "$OUT/imx8mm-tc8.dtb"

# The PRIMARY boot artifacts: an Android boot.img v0 (kernel + EMPTY ramdisk,
# NO DTB inside) paired with a dtbo.img (DTB in an Android DTBO container). This
# is the slotable Android model — flashed to the stock `boot_b` / `dtbo_b` GPT
# partitions and booted by NXP `boota` (the established Android path) alongside
# stock Android in slot A. Geometry matches stock (pagesize 2048, base
# 0x40000000, kernel @ 0x40080000). The cmdline is our Debian kernel cmdline so
# the DSI panel + root=PARTLABEL=userdata work; it must match the stage-2
# board default `tc8_bootargs` (imx8mm_evk.c).
TC8_CMDLINE="console=tty0 console=ttymxc1,115200 earlycon=ec_imx6q,0x30890000,115200 keep_bootcon panic=10 rw rootwait fw_devlink=permissive video=DSI-1:rotate=270 fbcon=rotate:3 vt.global_cursor_default=0 root=PARTLABEL=userdata"

echo "===> [2.5/3] Android boot.img (boot_b) — kernel + empty ramdisk + cmdline, AVB-free v0"
python3 "$REPO_ROOT/tools/mkbootimg.py" \
  --header_version 0 --pagesize 2048 \
  --base 0x40000000 --kernel_offset 0x00080000 \
  --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
  --cmdline "$TC8_CMDLINE" \
  --kernel "$OUT/Image" \
  --output "$OUT/boot.img"

echo "===> [2.5/3] Android dtbo.img (dtbo_b) — imx8mm-tc8.dtb in DTBO container"
python3 "$REPO_ROOT/tools/mkdtboimg.py" create "$OUT/dtbo.img" \
  --dtb "$OUT/imx8mm-tc8.dtb"

# AVB metadata for the slot-B Android images. NXP `boota` loads vbmeta_b first
# and refuses an image with NO vbmeta (INVALID_METADATA) even when UNLOCKED — it
# only forgives signature/hash *mismatches*, not absent metadata. So we add an
# AVB hash footer to boot.img + dtbo.img and emit a top-level vbmeta.img
# bundling both hash descriptors. All use `--algorithm NONE`: unsigned but
# structurally valid (boots only because the bootloader runs unlocked).
#
# add_hash_footer grows each image to EXACTLY its GPT partition size with the
# footer at the tail (boot_b=98304 sectors=50331648 B=48 MiB; dtbo_b=8192
# sectors=4194304 B=4 MiB). The ANDROID!/DTBO magic stays at offset 0, so the
# images remain valid Android containers. NONE needs no external crypto — pure
# python3 stdlib (hashlib SHA256 for the descriptor, no signing).
BOOT_PARTITION_SIZE=50331648   # boot_b  = 98304 sectors (48 MiB)
DTBO_PARTITION_SIZE=4194304    # dtbo_b  = 8192  sectors (4 MiB)

echo "===> [2.6/3] AVB hash footer on boot.img (partition boot, ${BOOT_PARTITION_SIZE} B)"
python3 "$REPO_ROOT/tools/avbtool" add_hash_footer \
  --image "$OUT/boot.img" --partition_name boot \
  --partition_size "$BOOT_PARTITION_SIZE" --algorithm NONE

echo "===> [2.6/3] AVB hash footer on dtbo.img (partition dtbo, ${DTBO_PARTITION_SIZE} B)"
python3 "$REPO_ROOT/tools/avbtool" add_hash_footer \
  --image "$OUT/dtbo.img" --partition_name dtbo \
  --partition_size "$DTBO_PARTITION_SIZE" --algorithm NONE

echo "===> [2.6/3] AVB vbmeta.img (vbmeta_b) — hash descriptors for boot + dtbo, unsigned"
python3 "$REPO_ROOT/tools/avbtool" make_vbmeta_image \
  --output "$OUT/vbmeta.img" --algorithm NONE \
  --include_descriptors_from_image "$OUT/boot.img" \
  --include_descriptors_from_image "$OUT/dtbo.img"

echo "===> [3/3] SHA256SUMS + version stamp"
cat > "$OUT/version.env" <<EOF
TC8_FW_VERSION=$TC8_FW_VERSION
TC8_ROOTFS_VERSION=$TC8_ROOTFS_VERSION
TC8_PATCHES_VERSION=$TC8_PATCHES_VERSION
TC8_BUILD_DATE=$TC8_BUILD_DATE
TC8_BUILD_HOST=$TC8_BUILD_HOST
EOF
( cd "$OUT" && sha256sum Image imx8mm-tc8.dtb boot.img dtbo.img vbmeta.img rootfs.img rootfs.simg version.env > SHA256SUMS && cat SHA256SUMS )

echo "[OK] all artifacts in $OUT:"
echo "       Image            raw kernel"
echo "       imx8mm-tc8.dtb   raw device tree"
echo "       boot.img         Android boot.img v0 + AVB hash footer (NONE)   -> fastboot flash boot_b"
echo "       dtbo.img         Android DTBO + AVB hash footer (NONE)          -> fastboot flash dtbo_b"
echo "       vbmeta.img       AVB vbmeta, hash descriptors boot+dtbo (NONE)  -> fastboot flash vbmeta_b"
echo "       rootfs.img       ext4 rootfs                                   -> userdata (root=PARTLABEL=userdata)"
echo "       rootfs.simg      Android sparse rootfs (WebUSB fastboot)        -> fastboot flash userdata (resparsed in-browser)"
