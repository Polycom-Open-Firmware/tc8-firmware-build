# TC8 bootloader update — wizard implementation guide

For the provisioner (web/native SPA). How the wizard updates a unit's **stage-2
bootloader over USB, with no serial** — by staging the new stage-2 in the `cache`
partition; the running OS flashes it on the next boot. This is the **"Update
Bootloader" step** of the Unlock / Reinstall flows (and can be standalone).

Companion: **[CONFIG-PARTITION.md](CONFIG-PARTITION.md)** — the full cache layout +
the config-key schema. This doc is the bootloader-specific slice.

---

## Summary

1. Fetch the stage-2 image `tc8-stage2-uboot.bin` (from the firmware release).
2. Build the **cache image**: config blob at offset 0, bootloader blob at 1 MiB
   (code below).
3. `fastboot flash cache <image>` (the unit is already in the stage-2 fastboot
   gadget — 4-finger gesture / fresh unit), then `fastboot reboot`.
4. **Done from the wizard's side.** The OS detects the staged stage-2 on boot and
   flashes `boot1` itself (idempotent, verified). The new bootloader is live on the
   **boot after that**.

The wizard never writes `boot1` directly — it only stages the image. No serial,
no special bootloader command.

---

## Why this works

- The stage-2 lives in the eMMC **boot1** hardware partition. A *running* Debian
  can rewrite boot1 (we do); a fastboot session generally can't target it cleanly.
  So the wizard hands the image to the OS via `cache`, and the OS does the write.
- **boot0** (stock stage-1) is never touched, so a bad write is recoverable via the
  hardware SDP / `uuu` path — the unit can't be bricked by this.
- The OS step is **idempotent + verified**: it only writes boot1 if the staged
  image's sha256 differs from what's there, refuses anything failing sha256 or the
  stage-2 signature, and reads back to confirm.

---

## Cache image layout

All integers little-endian. (Offset 0 is the existing config blob — see
CONFIG-PARTITION.md; reproduced here so this is self-contained.)

| offset | size | field |
|-------:|-----:|-------|
| 0 | 8 | config magic `"TC8CFGv1"` |
| 8 | 4 | config payload length `Lc` (u32) |
| 12 | 32 | sha256(config payload) |
| 44 | 20 | reserved (0) |
| 64 | `Lc` | config payload (`KEY=value\n…`) |
| **1 MiB (0x100000)** | 8 | bootloader magic `"TC8BOOT1"` |
| 1 MiB + 8 | 4 | stage-2 image length `Lb` (u32) |
| 1 MiB + 12 | 32 | sha256(stage-2 image) |
| 1 MiB + 44 | 20 | reserved (0) |
| **1 MiB + 512 (0x100200)** | `Lb` | the stage-2 image (`tc8-stage2-uboot.bin`) |

- The bootloader header lives in the **sector at 1 MiB**; the image starts at the
  **next sector** (1 MiB + 512), sector-aligned.
- Config-only push? Omit everything from 1 MiB on (just the config blob). The OS
  bootloader-updater no-ops when there's no `TC8BOOT1` magic.
- Cache is **1 GiB**, so a ~3 MiB image is trivial. fastboot writes from offset 0;
  you send the whole composite as one image.

---

## Building the cache image (reference, TypeScript/JS)

```ts
// configLines: e.g. ["KIOSK_URL=https://dash.local", "DEVICE_NAME=lobby"]
// stage2: Uint8Array of tc8-stage2-uboot.bin, or null for a config-only push.
async function buildCacheImage(configLines: string[], stage2: Uint8Array | null): Promise<Uint8Array> {
  const enc = new TextEncoder();

  // --- config blob @ 0 ---
  const payload = enc.encode(configLines.join("\n") + "\n");
  const cfgHdr = new Uint8Array(64);
  cfgHdr.set(enc.encode("TC8CFGv1"), 0);
  new DataView(cfgHdr.buffer).setUint32(8, payload.length, true);
  cfgHdr.set(new Uint8Array(await crypto.subtle.digest("SHA-256", payload)), 12);

  if (!stage2) {
    const blob = new Uint8Array(64 + payload.length);
    blob.set(cfgHdr, 0); blob.set(payload, 64);
    return blob;                                   // config-only
  }

  // --- bootloader: header @ 1 MiB, image @ 1 MiB + 512 ---
  const HDR_OFF = 1 << 20, IMG_OFF = HDR_OFF + 512;
  const blHdr = new Uint8Array(64);
  blHdr.set(enc.encode("TC8BOOT1"), 0);
  new DataView(blHdr.buffer).setUint32(8, stage2.length, true);
  blHdr.set(new Uint8Array(await crypto.subtle.digest("SHA-256", stage2)), 12);

  const buf = new Uint8Array(IMG_OFF + stage2.length);
  buf.set(cfgHdr, 0); buf.set(payload, 64);
  buf.set(blHdr, HDR_OFF);
  buf.set(stage2, IMG_OFF);
  return buf;                                      // fastboot flash cache <buf>
}
```

CLI equivalent (for testing): `tools/mkconfigblob.py cache.img --bootloader tc8-stage2-uboot.bin KIOSK_URL=…`

---

## Flow & UX

**Where it fits:**
- **Unlock** (first install) and **Reinstall** (update OS): include the current
  stage-2 in the cache image by default, so every install lands the matching
  bootloader. This is the **"Update Bootloader"** step — really just "include the
  stage-2 in the cache write," so it's one extra fetch + a bigger `fastboot flash
  cache`, not a separate device round-trip.
- **Reconfigure**: offer it standalone ("Update bootloader") for an in-field
  bootloader bump without reinstalling the OS.

**Timing:** the wizard's job finishes when `fastboot flash cache` + `fastboot
reboot` complete. The bootloader swaps on the unit's **first boot after that**
(the OS flashes boot1, then it's live the boot after). So after the wizard
reboots the unit, it comes up on the *old* stage-2, flashes boot1 in the
background, and the *next* power-cycle runs the new one. To make it current in
one visible step, prompt one extra reboot; otherwise it converges on its own,
since the write is idempotent.

**Failure modes:** nothing the wizard does can brick the unit — boot0 is
untouched, and the OS verifies sha256 before writing and reads back after. Show
a simple "bootloader will finish updating on the next restart" note; no warning
is needed.

---

## Artifacts

- **`tc8-stage2-uboot.bin`** — the stage-2 image. From the firmware release
  (`releases/.../tc8-stage2-uboot.bin`) or bundled with the
  [browser provisioner](https://github.com/Polycom-Open-Firmware/provisioner). Its md5 is
  in `manifest.json` (`stage2.md5`); show/track that as the bootloader version.
- The wizard already has it for **enroll** (it writes the same image to boot1 over
  serial on a virgin unit). This is the same image, delivered the no-serial way.

## On-device side (already implemented, for reference)

- `rootfs/etc/tc8-config/update-bootloader.sh` — the reader/flasher.
- `rootfs/etc/systemd/system/tc8-update-bootloader.service` — runs it at boot.
- Behaviour: validate `TC8BOOT1` blob → sha256 + `0a 00 00 14` signature → compare
  to boot1 → flash (force_ro toggle + `dd` + read-back verify) only if different.
