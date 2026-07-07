# targets/tc8/boot.sh — TC8 boot recipe: Android slot images for NXP `boota`.
# Sourced by build.sh; called as `pack_boot`. Inputs (from the composer env):
#   $OUT (output dir), $OUT/Image, $OUT/$DTB_NAME, $TC8_CMDLINE, RAMDISK_ARGS,
#   geometry + partition sizes from targets/tc8/target.env. Produces:
#   boot.img (+AVB footer), dtbo.img (+AVB footer), vbmeta.img.
pack_boot() {
    echo "===> [boot:boota] boot.img (kernel + initramfs + cmdline, v0)"
    python3 "$REPO_ROOT/tools/mkbootimg.py" \
      --header_version 0 --pagesize "$BOOT_PAGESIZE" \
      --base "$BOOT_BASE" --kernel_offset "$BOOT_KERNEL_OFFSET" \
      --ramdisk_offset "$BOOT_RAMDISK_OFFSET" --tags_offset "$BOOT_TAGS_OFFSET" \
      --cmdline "$TC8_CMDLINE" --kernel "$OUT/Image" \
      "${RAMDISK_ARGS[@]}" --output "$OUT/boot.img"

    echo "===> [boot:boota] dtbo.img ($DTB_NAME in DTBO container)"
    python3 "$REPO_ROOT/tools/mkdtboimg.py" create "$OUT/dtbo.img" --dtb "$OUT/$DTB_NAME"

    echo "===> [boot:boota] AVB hash footer on boot.img (${BOOT_PARTITION_SIZE} B)"
    python3 "$REPO_ROOT/tools/avbtool" add_hash_footer \
      --image "$OUT/boot.img" --partition_name boot \
      --partition_size "$BOOT_PARTITION_SIZE" --algorithm NONE
    echo "===> [boot:boota] AVB hash footer on dtbo.img (${DTBO_PARTITION_SIZE} B)"
    python3 "$REPO_ROOT/tools/avbtool" add_hash_footer \
      --image "$OUT/dtbo.img" --partition_name dtbo \
      --partition_size "$DTBO_PARTITION_SIZE" --algorithm NONE
    echo "===> [boot:boota] vbmeta.img (hash descriptors for boot + dtbo, unsigned)"
    python3 "$REPO_ROOT/tools/avbtool" make_vbmeta_image \
      --output "$OUT/vbmeta.img" --algorithm NONE \
      --include_descriptors_from_image "$OUT/boot.img" \
      --include_descriptors_from_image "$OUT/dtbo.img"

    BOOT_SUM_FILES=( boot.img dtbo.img vbmeta.img )
}
