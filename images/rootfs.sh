#!/usr/bin/env bash
# images/rootfs.sh — build a plain ext4 rootfs.img from a rootfs tarball or
# directory. No AVB footer: the production path sparses this into rootfs.simg
# and fastboot-flashes it to the stock `userdata` partition.
#
# USAGE
#   images/rootfs.sh --rootfs=PATH [--out=FILE] [--image-size=BYTES]
#
# --rootfs may be a .tar / .tar.gz / .tar.xz / .tar.zst, or a directory.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ROOTFS=""
OUT=""
# Default size: the stock A/B GPT's `userdata` partition — 13365248 sectors
# x 512 B (see gpt-restore/README.md). The image MUST NOT exceed it: the
# kernel refuses to mount an ext4 bigger than its partition ("bad geometry").
# Anything from ~1 GiB (just the base Debian) up to this cap works; pick
# smaller for faster fastboot pushes.
IMAGE_SIZE="6843006976"
LABEL="poly-rootfs"

usage() {
  cat <<EOF
images/rootfs.sh — build plain ext4 rootfs.img (no AVB)

USAGE
  images/rootfs.sh --rootfs=PATH [options]

REQUIRED
  --rootfs=PATH        Tarball (.tar[.gz|.xz|.zst]) or directory containing rootfs

OPTIONS
  --out=FILE           Output (default: ./out/rootfs.img)
  --image-size=N       ext4 image size in bytes (default $IMAGE_SIZE)
  --label=NAME         ext4 volume label (default $LABEL)
  -h, --help           Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --rootfs=*) ROOTFS="${arg#--rootfs=}";;
    --out=*) OUT="${arg#--out=}";;
    --image-size=*) IMAGE_SIZE="${arg#--image-size=}";;
    --label=*) LABEL="${arg#--label=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

[[ -n "$ROOTFS"  ]] || { echo "ERROR: --rootfs= required" >&2; exit 1; }
[[ -e "$ROOTFS"  ]] || { echo "ERROR: rootfs not found: $ROOTFS" >&2; exit 1; }
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/rootfs.img"

command -v mkfs.ext4 >/dev/null || { echo "ERROR: mkfs.ext4 not in PATH" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

WORK=""
ROOTFS_DIR=""
cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -d "$ROOTFS" ]]; then
  ROOTFS_DIR="$ROOTFS"
else
  WORK="$(mktemp -d -t poly-rootfs.XXXXXX)"
  ROOTFS_DIR="$WORK/rootfs"
  mkdir -p "$ROOTFS_DIR"
  echo "[+] extracting $ROOTFS -> $ROOTFS_DIR"
  case "$ROOTFS" in
    *.tar.gz|*.tgz)   tar -xzf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar.xz)         tar -xJf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar.zst)        tar --zstd -xf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar.bz2)        tar -xjf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar)            tar -xf  "$ROOTFS" -C "$ROOTFS_DIR";;
    *) echo "ERROR: unrecognized rootfs format: $ROOTFS" >&2; exit 1;;
  esac
fi

echo "[+] truncating image to $IMAGE_SIZE bytes -> $OUT"
truncate -s "$IMAGE_SIZE" "$OUT"

echo "[+] mkfs.ext4 -d $ROOTFS_DIR -L $LABEL"
mkfs.ext4 -F -L "$LABEL" -d "$ROOTFS_DIR" -T default "$OUT"

ls -la "$OUT"
echo "[OK] $OUT"
