# targets/c60/boot.sh — C60 boot recipe (booti + AVB-signed slot-A set).
# Sourced by build.sh; called as `pack_boot`. Genuinely different from TC8's
# boota recipe (DTB in boot.img's --second area, AVB SHA256_RSA2048 signed not
# NONE, booti not boota) — a clean per-target recipe, not a forced abstraction.
#
# Faithful port of c60-firmware-build/bootimg/pack_boota_set.sh (what boots on
# C60 hardware). Inputs from the composer env: $OUT, $OUT/Image, $OUT/$DTB_NAME,
# geometry + AVB vars from targets/c60/target.env. Produces boot.img + dtbo.img
# + vbmeta.img and sets BOOT_SUM_FILES.
pack_boot() {
    local key="${AVB_KEY:-$OUT/avb-testkey.pem}"
    if [[ ! -f "$key" ]]; then
        echo "[+] generating AVB test key at $key (board is HAB-open; test key)"
        openssl genrsa -out "$key" 2048 2>/dev/null
    fi

    # === 1. boot.img — header v0 + DTB in --second (NOT --dtb/v2) ===
    echo "===> [boot:booti] boot.img (kernel + DTB in --second, v0)"
    rm -f "$OUT/boot.img"
    python3 "$REPO_ROOT/tools/mkbootimg.py" \
      --header_version 0 --pagesize "$BOOT_PAGESIZE" \
      --base "$BOOT_BASE" --kernel_offset "$BOOT_KERNEL_OFFSET" \
      --ramdisk_offset "$BOOT_RAMDISK_OFFSET" \
      --second_offset "$BOOT_TAGS_OFFSET" --tags_offset "$BOOT_TAGS_OFFSET" \
      --cmdline "$C60_CMDLINE" \
      --kernel "$OUT/Image" --second "$OUT/$DTB_NAME" \
      --output "$OUT/boot.img"
    [[ "$(head -c 8 "$OUT/boot.img")" == "ANDROID!" ]] || {
        echo "ERROR: boot.img magic != ANDROID!" >&2; return 1; }
    # Pad to 32 MiB content before the AVB footer (reproducible layout).
    truncate -s "$BOOT_PAD_SIZE" "$OUT/boot.img"
    python3 "$REPO_ROOT/tools/avbtool" add_hash_footer \
      --image "$OUT/boot.img" --partition_name boot \
      --partition_size "$BOOT_PARTITION_SIZE" \
      --algorithm "$AVB_ALGORITHM" --key "$key"

    # === 2. dtbo.img — Android DTBO container (magic d7b7ab1e) ===
    # booti parses the dtbo header before applying overlays; a raw 0xd00dfeed
    # FDT gets 'boota: bad dt table magic'. Built inline (per AOSP dt_table.h)
    # to match the proven byte layout exactly.
    echo "===> [boot:booti] dtbo.img (Android DTBO container + AVB)"
    rm -f "$OUT/dtbo.img"
    DTBO_OUT="$OUT/dtbo.img" DTB_IN="$OUT/$DTB_NAME" python3 - <<'PY'
import struct, os, pathlib
dtb = pathlib.Path(os.environ["DTB_IN"]).read_bytes()
fdt_size, header_size, entry_size = len(dtb), 32, 32
dt_offset  = header_size + entry_size
total_size = dt_offset + fdt_size
hdr   = struct.pack(">IIIIIIII", 0xd7b7ab1e, total_size, header_size,
                    entry_size, 1, header_size, 2048, 0)
entry = struct.pack(">IIIIIIII", fdt_size, dt_offset, 0, 0, 0, 0, 0, 0)
pathlib.Path(os.environ["DTBO_OUT"]).write_bytes(hdr + entry + dtb)
PY
    python3 "$REPO_ROOT/tools/avbtool" add_hash_footer \
      --image "$OUT/dtbo.img" --partition_name dtbo \
      --partition_size "$DTBO_PARTITION_SIZE" \
      --algorithm "$AVB_ALGORITHM" --key "$key"

    # === 3. vbmeta.img — chain BOTH boot + dtbo (mandatory) ===
    # Without the dtbo descriptor, boota emits "Can't find dtbo partition from
    # avb partition data!" and drops to fastboot.
    echo "===> [boot:booti] vbmeta.img (chain boot + dtbo, signed)"
    rm -f "$OUT/vbmeta.img"
    python3 "$REPO_ROOT/tools/avbtool" make_vbmeta_image \
      --output "$OUT/vbmeta.img" \
      --algorithm "$AVB_ALGORITHM" --key "$key" \
      --include_descriptors_from_image "$OUT/boot.img" \
      --include_descriptors_from_image "$OUT/dtbo.img"

    BOOT_SUM_FILES=( boot.img dtbo.img vbmeta.img )
}
