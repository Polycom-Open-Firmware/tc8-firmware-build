#!/usr/bin/env bash
# fastboot_flash.sh — convenience wrapper to flash boot/dtbo/system/vbmeta to one slot via fastboot.
#
# USAGE
#   fastboot_flash.sh --slot=a|b [--images-dir=DIR] [--no-reboot]
#
# Drop the panel into u-boot fastboot first (e.g. `fastboot 0` from u-boot prompt or
# tools/uboot_watch.py interrupting boot). Then run this wrapper.

set -euo pipefail

SLOT=""
IMAGES_DIR="./out"
DO_REBOOT=1

usage() {
  cat <<EOF
fastboot_flash.sh — flash 4 partitions for one slot via fastboot

USAGE
  fastboot_flash.sh --slot=a|b [--images-dir=DIR] [--no-reboot]

OPTIONS
  --slot=a|b           Target slot (required)
  --images-dir=DIR     Directory containing boot.img dtbo.img system.img vbmeta.img (default ./out)
  --no-reboot          Skip 'fastboot reboot' at the end
  -h, --help           Show this help

NOTE
  Panel must already be in u-boot fastboot mode. From u-boot prompt:  fastboot 0
EOF
}

for arg in "$@"; do
  case "$arg" in
    --slot=*) SLOT="${arg#--slot=}";;
    --images-dir=*) IMAGES_DIR="${arg#--images-dir=}";;
    --no-reboot) DO_REBOOT=0;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg (try --help)" >&2; exit 1;;
  esac
done

[[ "$SLOT" == "a" || "$SLOT" == "b" ]] || { echo "ERROR: --slot=a or --slot=b required" >&2; exit 1; }

for f in boot.img dtbo.img system.img vbmeta.img; do
  [[ -f "$IMAGES_DIR/$f" ]] || { echo "ERROR: missing $IMAGES_DIR/$f" >&2; exit 1; }
done

command -v fastboot >/dev/null || { echo "ERROR: fastboot not in PATH (apt install fastboot or android-tools)" >&2; exit 1; }

if ! fastboot devices | grep -q .; then
  echo "ERROR: no fastboot devices detected." >&2
  echo "Hint: drop panel into u-boot fastboot first (u-boot prompt: 'fastboot 0')." >&2
  exit 1
fi

echo "[+] fastboot devices:"
fastboot devices

echo "[+] flashing slot_$SLOT from $IMAGES_DIR/"
fastboot flash "boot_$SLOT"   "$IMAGES_DIR/boot.img"
fastboot flash "dtbo_$SLOT"   "$IMAGES_DIR/dtbo.img"
fastboot flash "system_$SLOT" "$IMAGES_DIR/system.img"
fastboot flash "vbmeta_$SLOT" "$IMAGES_DIR/vbmeta.img"

if [[ $DO_REBOOT -eq 1 ]]; then
  echo "[+] fastboot reboot"
  fastboot reboot
fi

echo "[OK] slot_$SLOT flashed."
