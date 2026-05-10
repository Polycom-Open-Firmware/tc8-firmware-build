#!/usr/bin/env bash
# build.sh — top-level pipeline: build kernel, then boot/system/dtbo/vbmeta images.
#
# DEFAULT (run after ./bootstrap.sh):
#   TC8_AVB_KEY=/path/to/key.pem ./build.sh --profile=emmc
#
# All input paths default to the submodules + linux-6.6/ from bootstrap.sh.
# Override any of them with the flags below if you want.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Defaults wired to bootstrap.sh layout
DEFAULT_LINUX="${REPO_ROOT}/linux-6.6"
DEFAULT_PATCHES="${REPO_ROOT}/kernel-patches/patches"
DEFAULT_ROOTFS_DIR="${REPO_ROOT}/rootfs"
DEFAULT_ROOTFS_TGZ="${DEFAULT_ROOTFS_DIR}/out/rootfs.tar.gz"
DEFAULT_INITRAMFS="${DEFAULT_ROOTFS_DIR}/out/initramfs.cpio.gz"

LINUX=""; PATCHES=""; ROOTFS=""; INITRAMFS=""; PROFILE=""
AVB_KEY="${TC8_AVB_KEY:-}"
# OUT defaults to $REPO_ROOT/out/<profile-name>/ once we know the profile.
# Override with --out=DIR.
OUT=""
SKIP_KERNEL=0
SKIP_ROOTFS=0
JOBS="$(nproc)"

usage() {
  cat <<EOF
build.sh — full TC8 firmware build (kernel + boot + system + dtbo + vbmeta)

USAGE
  TC8_AVB_KEY=key.pem ./build.sh --profile={nfs|emmc} [options]

REQUIRED
  --profile=NAME     nfs | emmc | path/to/custom.env
  --avb-key= or TC8_AVB_KEY in env

OPTIONS (all optional — defaults wired to submodules from ./bootstrap.sh)
  --linux=DIR        Vanilla linux-6.6 source tree    (default: ./linux-6.6)
  --patches=DIR      tc8-kernel-patches/patches       (default: ./kernel-patches/patches)
  --rootfs=PATH      rootfs tarball or directory      (default: ./rootfs/out/rootfs.tar.gz; auto-built if missing)
  --initramfs=PATH   initramfs.cpio.gz                (default: ./rootfs/out/initramfs.cpio.gz)
  --avb-key=KEY      AVB key file                     (default: \$TC8_AVB_KEY)
  --out=DIR          output dir                       (default: ./out)
  --skip-kernel      do not rebuild kernel (use existing out/kernel/Image-with-dtb)
  --skip-rootfs      do not rebuild rootfs (use existing rootfs/out/)
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
    --avb-key=*) AVB_KEY="${arg#--avb-key=}";;
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
[[ -n "$AVB_KEY" ]] || { echo "ERROR: --avb-key= or TC8_AVB_KEY required" >&2; exit 1; }
[[ -f "$AVB_KEY" ]] || { echo "ERROR: AVB key not found: $AVB_KEY" >&2; exit 1; }

# Default OUT to per-profile subdir so emmc and nfs targets coexist.
if [[ -z "$OUT" ]]; then
    profile_name="$(basename "${PROFILE%.env}")"
    OUT="$REPO_ROOT/out/$profile_name"
fi

# Build rootfs lazily if needed
if [[ $SKIP_ROOTFS -ne 1 && ! -e "$ROOTFS" ]]; then
    echo "===> [0/5] rootfs build (no $ROOTFS yet)"
    if [[ $EUID -eq 0 ]]; then
        ( cd "$DEFAULT_ROOTFS_DIR" && ./build.sh )
    else
        ( cd "$DEFAULT_ROOTFS_DIR" && sudo ./build.sh )
    fi
fi
[[ -e "$ROOTFS" ]] || { echo "ERROR: rootfs not found at $ROOTFS" >&2; exit 1; }

# Stamp version info from the three repos so the running image self-identifies.
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

mkdir -p "$OUT"
export TC8_AVB_KEY="$AVB_KEY"

KERNEL_OUT="$OUT/kernel"
KIMG="$KERNEL_OUT/Image-with-dtb"
DTB="$KERNEL_OUT/imx8mm-tc8.dtb"

if [[ $SKIP_KERNEL -ne 1 ]]; then
  echo "===> [1/5] kernel build"
  "$REPO_ROOT/kernel/build.sh" --linux="$LINUX" --patches="$PATCHES" \
    --jobs="$JOBS" --out="$KERNEL_OUT"
else
  echo "===> [1/5] kernel build SKIPPED (--skip-kernel)"
  [[ -f "$KIMG" ]] || { echo "ERROR: $KIMG missing; cannot --skip-kernel" >&2; exit 1; }
  [[ -f "$DTB"  ]] || { echo "ERROR: $DTB missing; cannot --skip-kernel"  >&2; exit 1; }
fi

echo "===> [2/5] boot.img"
boot_args=( --kernel="$KIMG" --profile="$PROFILE" --avb-key="$AVB_KEY" --out="$OUT/boot.img" )
[[ -n "$INITRAMFS" && -f "$INITRAMFS" ]] && boot_args+=( --initramfs="$INITRAMFS" )
"$REPO_ROOT/images/boot.sh" "${boot_args[@]}"

echo "===> [3/5] system.img"
"$REPO_ROOT/images/system.sh" --rootfs="$ROOTFS" --avb-key="$AVB_KEY" --out="$OUT/system.img"

echo "===> [4/5] dtbo.img"
"$REPO_ROOT/images/dtbo.sh" --dtb="$DTB" --avb-key="$AVB_KEY" --out="$OUT/dtbo.img"

echo "===> [5/5] vbmeta.img"
"$REPO_ROOT/images/vbmeta.sh" \
  --boot="$OUT/boot.img" --system="$OUT/system.img" --dtbo="$OUT/dtbo.img" \
  --avb-key="$AVB_KEY" --out="$OUT/vbmeta.img"

echo "===> SHA256SUMS"
( cd "$OUT" && sha256sum boot.img dtbo.img system.img vbmeta.img > SHA256SUMS && cat SHA256SUMS )

echo "[OK] all artifacts in $OUT"
