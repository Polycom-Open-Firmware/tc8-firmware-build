#!/usr/bin/env bash
# build.sh — top-level pipeline: build kernel, then a flat-layout rootfs.img.
#
# The TC8 boots via raw `mmc read` + `booti` (see FLASHING.md). There is no
# AVB on the data path, so we don't emit boot.img / dtbo.img / vbmeta.img
# anymore — those were never validated by the bootloader on either of the
# panels we've seen. What ships:
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

# Lift Image + DTB up to the top of out/<profile>/ so release assembly
# doesn't have to peek into out/<profile>/kernel/.
cp "$KIMG" "$OUT/Image"
cp "$DTB"  "$OUT/imx8mm-tc8.dtb"

echo "===> [3/3] SHA256SUMS + version stamp"
cat > "$OUT/version.env" <<EOF
TC8_FW_VERSION=$TC8_FW_VERSION
TC8_ROOTFS_VERSION=$TC8_ROOTFS_VERSION
TC8_PATCHES_VERSION=$TC8_PATCHES_VERSION
TC8_BUILD_DATE=$TC8_BUILD_DATE
TC8_BUILD_HOST=$TC8_BUILD_HOST
EOF
( cd "$OUT" && sha256sum Image imx8mm-tc8.dtb rootfs.img version.env > SHA256SUMS && cat SHA256SUMS )

echo "[OK] all artifacts in $OUT"
