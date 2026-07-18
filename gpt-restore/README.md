# TC8 partition-table restore

> **Scope: TC8 target** (the stock TC8 A/B GPT; the C60 keeps its own stock table).

Restores the eMMC GPT on a unit whose partition table was nuked — **over USB
fastboot, no serial, no brick risk**. Captured from a healthy unit; all four GPT
CRC32s validate.

## Files
- `gpt-primary.bin` / `gpt-backup.bin` — the canonical GPT (LBA 0..33 / last 33),
  captured from a known-good TC8.
- `make-gpt-restore.py` — builds `tc8-gpt-restore.simg` from those.
- `tc8-gpt-restore.simg` — the artifact the provisioner flashes (34 KB on-wire).

## The image
A full-disk Android **sparse** image of the 14.56 GiB user area (`mmcblk2`):

| chunk | blocks (512 B) | LBA range | contents |
|---|---|---|---|
| RAW | 34 | 0..33 | protective MBR + primary GPT |
| **DONT_CARE** | 30 535 613 | 34..30 535 646 | **untouched** — preserves the U-Boot env @ 0x400000, the raw stage-2 slot, and all partition data |
| RAW | 33 | 30 535 647..30 535 679 | backup GPT |

`blk_sz` is **512** so the 34-sector GPT lands exactly and the DONT_CARE preserves
the 4 MiB env. Writing it only rewrites the partition table; nothing else changes.

## Layout it restores (stock Android GPT, disk GUID `43263ea0-…`)
`dtbo_a/b` (4M) · `boot_a/b` (48M) · `system_a/b` (1792M) · `cache` (1G) · `facres`
(1G) · `cert` (1M) · `misc` (4M) · `metadata` (2M) · `presistdata` (1M) ·
`vendor_a/b` (512M) · `userdata` (6526M) · `fbmisc` (1M) · `vbmeta_a/b` (1M).

## How the provisioner uses it
1. **Detect** (no serial): `getvar partition-size:userdata` / `boot_a` — a nuked
   table makes these FAIL. (See provisioner `flow/partitions.ts`.)
2. **Restore**: define a whole-disk raw target at runtime
   (`fastboot_raw_partition_gpt = 0x0 0x1d1f000`, via `UCmd setenv`) → `flash gpt
   tc8-gpt-restore.simg` → `mmc rescan` → re-verify.
3. Then the normal OS install proceeds. Configure instead **refuses** if the table
   is borked (it won't touch a damaged filesystem).

## Shipping
Attach **`tc8-gpt-restore.simg`** as a release asset (alongside `rootfs.simg` etc.)
so the wizard fetches it through the Cloudflare proxy at
`/artifact/<tag>/tc8-gpt-restore.simg`. It's model-specific, not OS-version-specific,
but shipping it per-release keeps the fetch path uniform.

> Note: the captured GPT carries one unit's disk/partition GUIDs, so all restored
> units share them. Harmless for single-disk operation.
