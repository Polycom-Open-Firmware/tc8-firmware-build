# targets/c60/boot.sh — C60 boot recipe. GENUINELY different from TC8's, so a
# clean per-target recipe (not a forced shared abstraction). Interface contract
# (same as tc8/boot.sh): pack_boot() produces the target's flashable boot
# artifacts into $OUT and sets BOOT_SUM_FILES.
#
# C60 boot model (from c60-firmware-build, the reference impl):
#   - boot.img = Android boot.img v0, kernel + DTB in the `--second` area
#     (TC8 keeps the DTB in a separate dtbo; C60 carries it in boot.img).
#   - dtbo.img = Android DTBO image.
#   - vbmeta.img = chained vbmeta over boot.img + dtbo.img, AVB-SIGNED
#     (TC8 uses --algorithm NONE / unsigned; C60 signs — needs the AVB key).
#   - u-boot `mmc read boot_a` then `booti` (TC8 uses NXP `boota`).
#   - rootfs → system_a as rootfs.img.zst (zstd ext4), NOT a sparse .simg to
#     userdata; the 1.6 GiB system_a budget is enforced by the composer.
#   Reference tooling: c60-firmware-build/images/pack_boota_set.sh + its AVB key.
#
# STATUS: design stub. Folding the real packing here is the M6 C60 boot step,
# gated on: (1) the C60 kernel building from the shared kernel-patches (C60 DTS
# + drivers not yet folded — active in the c60-kernel-patches session), and
# (2) porting pack_boota_set.sh + AVB key handling into the shared composer.
# Until then --target=c60 through this composer is not buildable end-to-end.
pack_boot() {
    echo "===> [boot:booti] C60 boot recipe not yet folded into the shared composer" >&2
    echo "     Needs: shared C60 kernel patches + pack_boota_set.sh + AVB key." >&2
    echo "     Reference: c60-firmware-build/images/pack_boota_set.sh. (M6 TODO.)" >&2
    return 1
}
