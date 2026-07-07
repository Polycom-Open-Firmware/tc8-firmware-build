#!/usr/bin/env bash
# kernel/build.sh — apply tc8 patches to a vanilla linux-6.6 tree, configure, and build
# Image + dtbs, then concat Image-with-dtb.
#
# USAGE
#   kernel/build.sh --linux=DIR --patches=DIR [--config=FILE] [--jobs=N] [--out=DIR]
#
# OUTPUTS (in --out dir, default ./out/kernel)
#   Image
#   imx8mm-tc8.dtb
#   Image-with-dtb         (Image || dtb concatenated)

set -euo pipefail

LINUX=""
PATCHES=""
CONFIG=""
TARGET=""
JOBS="$(nproc)"
OUT=""
ARCH="arm64"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DTB_NAME="imx8mm-tc8.dtb"   # override with --dtb-name (per-target)

usage() {
  cat <<EOF
kernel/build.sh — patch + configure + build TC8 kernel from a vanilla 6.6 tree

USAGE
  kernel/build.sh --linux=DIR --patches=DIR [options]

REQUIRED
  --linux=DIR        Path to vanilla linux-6.6 source tree
  --patches=DIR      Path to tc8-kernel-patches/patches directory (*.patch)

OPTIONS
  --config=FILE      Kernel .config to install (default: kernel/tc8.config in this repo)
  --jobs=N           make -j (default: nproc)
  --out=DIR          Output dir for Image / dtb / Image-with-dtb (default: ./out/kernel)
  --arch=ARCH        default arm64
  --cross=PREFIX     default aarch64-linux-gnu-

ENVIRONMENT
  CROSS_COMPILE      Same as --cross
EOF
}

for arg in "$@"; do
  case "$arg" in
    --linux=*) LINUX="${arg#--linux=}";;
    --patches=*) PATCHES="${arg#--patches=}";;
    --config=*) CONFIG="${arg#--config=}";;
    --target=*) TARGET="${arg#--target=}";;
    --dtb-name=*) DTB_NAME="${arg#--dtb-name=}";;
    --jobs=*) JOBS="${arg#--jobs=}";;
    --out=*) OUT="${arg#--out=}";;
    --arch=*) ARCH="${arg#--arch=}";;
    --cross=*) CROSS="${arg#--cross=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

# Derive AFTER arg parsing so --dtb-name takes effect (was computed from
# the default up top, ignoring the override — cost the C60 DTB check).
DTB_SUBPATH="arch/arm64/boot/dts/freescale/$DTB_NAME"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -n "$LINUX"   ]] || { echo "ERROR: --linux=DIR required" >&2; exit 1; }
[[ -n "$PATCHES" ]] || { echo "ERROR: --patches=DIR required" >&2; exit 1; }
[[ -d "$LINUX/arch/arm64" ]] || { echo "ERROR: $LINUX does not look like a kernel tree" >&2; exit 1; }
[[ -d "$PATCHES" ]] || { echo "ERROR: patches dir not found: $PATCHES" >&2; exit 1; }
# Per-target patch layout (M6): if patches/<target>/ exists, apply from there
# (patches/tc8/, patches/c60/). Falls back to the flat dir for old layouts.
: "${TARGET:=tc8}"
if [[ -d "$PATCHES/$TARGET" ]]; then
  PATCHES="$PATCHES/$TARGET"
  echo "[+] per-target patches: $PATCHES"
fi
# Config sources: --target=<t> merges config.base + targets/<t>.frag (the
# converged, one-project-two-targets layout, M6). Legacy --config= (single
# monolithic file) still works and wins if given. Default target: tc8.
if [[ -z "$CONFIG" ]]; then
  : "${TARGET:=tc8}"
  CONFIG="$REPO_ROOT/kernel/config.base $REPO_ROOT/kernel/targets/$TARGET.frag"
  for f in $CONFIG; do
    [[ -f "$f" ]] || { echo "ERROR: kernel config fragment not found: $f" >&2; exit 1; }
  done
else
  # legacy single-file --config
  [[ -f "$CONFIG" ]] || { echo "ERROR: kernel config not found: $CONFIG" >&2; exit 1; }
fi
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/kernel"

mkdir -p "$OUT"
echo "[+] linux tree: $LINUX"
echo "[+] patches:    $PATCHES"
echo "[+] config:     $CONFIG"
echo "[+] out:        $OUT"
echo "[+] ARCH=$ARCH CROSS_COMPILE=$CROSS jobs=$JOBS"

cd "$LINUX"

# Apply patches idempotently — only those not already applied.
shopt -s nullglob
patch_files=("$PATCHES"/*.patch)
shopt -u nullglob

if (( ${#patch_files[@]} == 0 )); then
  echo "[!!] no .patch files found in $PATCHES — proceeding without patches"
elif git -C "$LINUX" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # RESET-THEN-APPLY. The old forward/reverse idempotency check broke as
  # soon as two patches touched the same file (reverse-check of the earlier
  # patch can never match once a later one modified the file) — it cost two
  # broken builds on 2026-07-07. Instead: revert tracked files, delete the
  # files the patches CREATE, then apply the whole series fresh. Object
  # files are untracked and survive, so rebuilds stay incremental.
  echo "[+] resetting patch state in $LINUX"
  git -C "$LINUX" checkout -- .
  for p in "${patch_files[@]}"; do
    # Delete files this patch CREATES so a re-apply doesn't "already exists".
    # `|| true`: grep exit 1 (patch creates nothing) must not trip set -e.
    for nf in $(grep -A3 "^new file mode" "$p" 2>/dev/null | sed -n 's|^+++ b/||p' || true); do
      rm -f "$LINUX/$nf"
    done
  done
  for p in "${patch_files[@]}"; do
    echo "[+] applying $(basename "$p")"
    git -C "$LINUX" apply "$p"
  done
else
  # No git tree — plain patch with the old dry-run idempotency check.
  for p in "${patch_files[@]}"; do
    if patch -p1 --dry-run -R --silent < "$p" >/dev/null 2>&1; then
      echo "[=] $(basename "$p") already applied — skipping"
    else
      echo "[+] applying $(basename "$p")"
      patch -p1 < "$p"
    fi
  done
fi

# Per-target firmware blobs for CONFIG_EXTRA_FIRMWARE (e.g. C60's BCM4356
# wifi/BT + SDMA). If targets/<target>/firmware-blobs exists, stage it into
# the tree's firmware/ before configuring. TC8 has none — no-op there.
FW_SRC="$REPO_ROOT/targets/$TARGET/firmware-blobs"
if [[ -d "$FW_SRC" ]]; then
  echo "[+] staging $TARGET firmware blobs from $FW_SRC"
  ( cd "$FW_SRC" && find . -type f ) | while read -r f; do
    mkdir -p "$(dirname "firmware/$f")"
    cp -f "$FW_SRC/$f" "firmware/$f"
  done
fi

# Install config: start from upstream arm64 defconfig, then merge our
# target config fragment(s).
make ARCH="$ARCH" CROSS_COMPILE="$CROSS" defconfig
scripts/kconfig/merge_config.sh -m .config $CONFIG   # base + target frag (unquoted: may be a list)
make ARCH="$ARCH" CROSS_COMPILE="$CROSS" olddefconfig

# Build
make -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS" Image dtbs

IMAGE_SRC="arch/$ARCH/boot/Image"
DTB_SRC="$DTB_SUBPATH"
[[ -f "$IMAGE_SRC" ]] || { echo "ERROR: $IMAGE_SRC not produced" >&2; exit 1; }
[[ -f "$DTB_SRC" ]]   || { echo "ERROR: $DTB_SRC not produced" >&2; exit 1; }

cp "$IMAGE_SRC" "$OUT/Image"
cp "$DTB_SRC"   "$OUT/$DTB_NAME"
cat "$IMAGE_SRC" "$DTB_SRC" > "$OUT/Image-with-dtb"

echo "[OK] kernel build complete:"
ls -la "$OUT/"
