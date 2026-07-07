# RO-ROOT — read-only rootfs with tmpfs overlay + persistent /root

Target: **v0.5.x** (v0.4.5 and earlier mount `userdata` rw directly).

## TL;DR

| | mount of `userdata` | writes | how you get there |
|---|---|---|---|
| **sealed** (default) | read-only lower + tmpfs overlay on `/` | ephemeral — evaporate on reboot | every boot, unless armed |
| **maintenance** | direct read-write, no overlay | permanent (dpkg-safe) | `tc8-rw --reboot` … `tc8-ro --reboot` |

`/root` is persistent in **both** modes (bind onto the `facres` partition —
survives reboots *and* reflashes). Everything else in sealed mode is
ephemeral by design.

## Architecture: why a minimal initramfs (option a), not systemd tmpfs units (option b)

The image boots as an Android boot.img v0 via the stage-2 U-Boot's `boota`;
there is no initrd today and `systemd.volatile=overlay` needs one. Two ways
to get an overlay:

- **(a) minimal initramfs in boot.img** — a ~1 MB gzipped cpio (static
  busybox + one auditable POSIX-sh script, `initramfs/init`) that mounts the
  real root itself and `switch_root`s.
- **(b) systemd early-boot units** overlaying `/etc`, `/var`, `/home` with
  tmpfs uppers while `/` stays ro.

We chose **(a)**:

- It seals **all of /** (option b leaves `/usr`, `/opt`, `/srv`… either
  writable or un-overlayed, and every new writer needs a new unit).
- It gives a clean **maintenance-mode switch**: the decision is made before
  any fs is mounted rw, so "direct rw, no overlay" is trivially reachable
  and dpkg-safe. With (b) there is no safe apt story at all: dpkg's db
  (`/var/lib/dpkg`) would live on a tmpfs upper while `/usr` payload landed
  on the ro-remounted lower (or vice versa) — the db and the payload tear
  apart and the dpkg state is corrupted. That hazard is structural to (b).
- systemd sees a perfectly ordinary writable `/` — no unit-ordering
  minefield around `systemd-remount-fs`, `tmpfiles`, `machine-id`, etc.
- Cost: +1 MB in boot.img (26.2 of 48 MiB used) and one more moving part at
  boot. The script is ~150 lines and fails **towards booting** (see failure
  modes).

`boota` detail that makes this safe: our v0 header keeps the stock
`ramdisk_offset` (0x01000000), which on paper overlaps the 24 MiB kernel —
but the stage-2 `boota` detects the overlap and relocates the ramdisk past
the FDT at `kernel_addr + 64 MiB` before copying
(`fb_fsl_boot.c: "ramdisk overlap detected"`), then passes it to `booti` as
`addr:size`. The kernel cmdline is unchanged from v0.4.5 (`rw ...
root=PARTLABEL=userdata`): `root=`/`rw` are parsed by the initramfs, keep
the kernel's own fallback correct if the ramdisk is ever absent, and stop
`systemd-remount-fs` from remounting the overlay ro.

## Boot flow

```
stage-2 boota ─ AVB(NONE, unlocked) ─ booti Image + initramfs + dtb
  └─ /init (busybox):
       1. mount /proc /sys /dev(devtmpfs)
       2. parse cmdline: root=PARTLABEL=… (default userdata),
          tc8.rootfs=ro|rw override, tc8.overlay_size=… (default 50%)
       3. wait ≤20 s for the PARTLABEL=userdata partition
          (PARTNAME= in /sys/class/block/*/uevent — no udev in here)
       4. mode: cmdline override, else flag file `.tc8-rootfs-rw` at the
          root of the ext4 `facres` partition (mounted ro, then umounted)
       5a. sealed:   mount userdata RO at /lower, tmpfs at /rw,
                     overlay(lower,upper,work) → /newroot,
                     layers exposed at /mnt/.tc8/{lower,rw} in the new root
       5b. maintenance: mount userdata RW at /newroot (no overlay)
       6. mkdir /newroot/{dev,proc,sys,run}, move devtmpfs,
          exec switch_root /newroot /sbin/init
  └─ systemd boots normally on a writable /
       └─ tc8-persist-root.service (before tc8-config/ssh/kiosk):
            facres → /persist (auto-mkfs.ext4 first use),
            /persist/tc8-root  → bind → /root,
            /persist/fake-hwclock.data → file-bind → /etc/fake-hwclock.data
```

Pieces:

- `initramfs/init` — the boot selector (this repo, packed at build time).
- `tools/mkinitramfs.py` — deterministic gzipped-newc-cpio writer (stdlib
  python3, same style as mkbootimg.py). busybox is pulled out of the rootfs
  tarball (`package-list.txt` ships `busybox-static`) — no new host deps.
- `build.sh [2.4/3]` — builds `out/<profile>/initramfs.cpio.gz` and feeds
  `mkbootimg --ramdisk`. `--no-ramdisk` reproduces the pre-v0.5 empty-ramdisk
  boot.img (kernel direct-mounts userdata rw).
- `kernel/tc8.config` — `CONFIG_OVERLAY_FS=y` (arm64 defconfig has `=m`;
  we ship no /lib/modules, so `=m` would silently degrade every boot to
  the direct-rw fallback).
- tc8-rootfs repo — `tc8-persist-root.{sh,service}`, `tc8-rw`, `tc8-ro`,
  `tc8-mode`, `etc/profile.d/tc8-mode.sh` (maintenance-mode login banner).

## How to make persistent changes (apt install etc.)

```sh
tc8-rw --reboot          # arm maintenance mode + reboot
# … panel comes back; login banner + tc8-mode confirm DIRECT-RW …
apt update
apt install <package>
apt clean && rm -rf /var/lib/apt/lists/*    # optional: keep the image lean
tc8-ro --reboot          # reseal + reboot
```

- The flag (`/persist/.tc8-rootfs-rw`) is **sticky**: it survives reboots
  (multi-reboot maintenance sessions work, e.g. a package wanting a
  restart) and even reflashes — `tc8-ro` is an explicit step. `tc8-mode`
  shows current + next-boot mode; every interactive login warns while
  unsealed.
- `apt` in **sealed** mode is not dangerous — db and payload both land in
  the tmpfs upper and evaporate *together* (coherent, just pointless, and
  `apt update` alone can eat ~200 MB of tmpfs).
- **Never** write to the lower fs during a sealed boot (e.g. remounting
  `/mnt/.tc8/lower` rw, or `mount /dev/mmcblk2p15` somewhere and writing).
  Files already copied-up to tmpfs shadow the lower; dpkg state would tear
  between layers. Always use the reboot flow.
- What changed this boot: `find /mnt/.tc8/rw/upper`.
- Bench override without the flag: bake/`fastboot boot` a boot.img whose
  cmdline appends `tc8.rootfs=rw` (or `=ro` to force-seal — the cmdline
  beats the flag).

## Persistent /root (facres)

`tc8-persist-root.service` runs in **both** modes, so `/root` behaves
identically either way: facres (1 GiB, untouched by the provisioner's
flashos) is mounted rw at `/persist`, seeded once from the baked `/root`,
and bind-mounted onto `/root`. `tc8-config`'s `SSH_AUTHKEY` runs after it,
so wizard-pushed keys persist. The saved fake-hwclock timestamp also lives
there (file-bind), otherwise every sealed boot would start at image build
time and TLS would fail until NTP; the unit's ExecStop saves the clock
through the bind at shutdown.

`tc8-rw`/`tc8-ro` keep their mode flag at the facres fs root, next to
`tc8-root/`. The initramfs only ever mounts facres **ro** to read the flag.

## Interactions audited

- **tc8-config.service** — applies the cache-partition blob **once per unique blob** (sha-gated; on unchanged sealed reboots it silently restores a persisted /etc snapshot from facres rather than re-applying)
  (it already re-runs; under the overlay its `/etc` writes are ephemeral, so
  each boot = pristine baked `/etc` + blob, fully deterministic). Ordering
  unchanged: after tc8-persist-root, before networkd/kiosk. In maintenance
  mode its writes stick — harmless, it's idempotent.
- **/data (kiosk cache, MTP export)** — `/data` on this image is
  `/dev/mmcblk2p15` = **the userdata partition itself**, i.e. the rootfs
  mounted a second time. In sealed mode that rw mount fails (superblock is
  held ro by the overlay lower) — `kiosk.service`'s ExecStartPre already
  `|| true`s it and then `install -d`s the dirs, which now land on the
  overlay: kiosk cache and the MTP "Panel storage" become **ephemeral** in
  sealed mode, and work exactly as before in maintenance mode. Same story
  for `kiosk-config.service`'s optional `/data/poly-kiosk/config` override
  (use the cache-blob config path instead, or maintenance mode).
- **alsa** — `alsa-restore` reads the baked safe-volume state from the ro
  lower every boot; runtime mixer changes evaporate (the shutdown store
  writes the upper). Volumes are re-assertable per boot via the config
  blob's `VOLUME_*` keys.
- **ssh** — host keys are baked at build (lower), stable across reboots.
- **DHCP** — `wipe-networkd-leases` + leases under `/var/lib` on the upper:
  fresh DHCPDISCOVER every boot, as designed.
- **journald** — `Storage=volatile` + `/var/log` tmpfs via fstab, unchanged;
  no `/var/log/journal` is created anywhere.
- **dev paths** — the `nfs` profile and the `booti`/onboard.sh path don't
  carry the initramfs; they keep their existing rw behaviour
  (`profiles/emmc.env` `KERNEL_CMDLINE` untouched).

## Failure modes

| failure | behaviour |
|---|---|
| overlay/tmpfs mount fails (e.g. kernel built without `OVERLAY_FS=y`) | init logs `overlay setup FAILED` and **falls back to direct-rw** — boots like v0.4.5 |
| ramdisk absent from boot.img | kernel falls back to cmdline `root=…` rw direct-mount — boots like v0.4.5 |
| `/init` crashes / rootfs partition never appears | rescue busybox shell on console (serial + panel); `exit` reboots (`panic=10` guards the no-console case) |
| facres missing | initramfs: no flag possible → always sealed. tc8-persist-root exits 0 → `/root` non-persistent. `tc8-rw` refuses with a clear error (cmdline `tc8.rootfs=rw` still available) |
| facres corrupt / not ext4 | initramfs ro-mount fails → sealed boot; then tc8-persist-root **reformats** facres (mkfs.ext4, prior-art behaviour — facres content is expendable by design) and persistence resumes empty |
| tmpfs upper fills (default 50% RAM, `tc8.overlay_size=` to tune) | writes get ENOSPC; system state on lower unharmed; reboot clears |
| maintenance flag forgotten | sticky by design; login banner + `tc8-mode` surface it; it even survives reflash (facres untouched) — run `tc8-ro` |
| power loss during maintenance apt | same risk as any rw Linux — ext4 journal replays; worst case reflash `userdata` (the sealed default makes this window rare) |

## Bench test checklist — HARDWARE-VERIFIED 2026-07-06

> Run on the bench unit, fully remotely (stage-2 env fastboot one-shot +
> `fastboot` from the rig host): `boota` boots the non-empty v0 ramdisk;
> sealed boot = `/` overlay over ro `userdata` (`/mnt/.tc8/lower` ext4 ro);
> a file written to `/etc` in sealed mode vanished on reboot; `tc8-rw` →
> maintenance (direct-rw ext4, banner) → `apt install sl` → `tc8-ro` →
> resealed, and the package persisted through the sealed boots. Persistent
> `/root` marker survived throughout (including, separately, a full
> userdata reflash). All services (gadget, MTP, persist-root, kiosk) active
> in both modes. Original checklist below for regression reference.

Boot plumbing (the one truly new mechanism — **verify first**):

1. Flash new `boot.img` (+`vbmeta.img`) only, keep existing rootfs: serial
   shows `boota` reporting a non-zero ramdisk (expect the
   `ramdisk overlap detected → redirect` line), kernel logs
   `Trying to unpack rootfs image as initramfs...`, then `tc8-init:` lines,
   then normal systemd boot. **This is the go/no-go for the whole design**
   (boota+booti passing a v0 ramdisk has never been exercised on TC8).
2. `tc8-mode` / `findmnt /` → `overlay`; `grep tc8-overlay /proc/mounts`;
   layers visible at `/mnt/.tc8/{lower,rw}`.

Sealed-mode semantics:

3. `touch /ephemeral-test; reboot` → file gone.
4. Kiosk comes up, page loads, touch OK (`/data` dirs exist on the overlay;
   `mount | grep ' /data '` shows nothing — expected).
5. ssh in (same host keys as before), DHCP lease fresh, `journalctl` works,
   no `/var/log/journal`.
6. Wizard "Reconfigure" (cache blob): applies on next boot and **every**
   boot; `KIOSK_URL` sticks across reboots (because reapplied, not stored).
7. `date` sane on boot before NTP (fake-hwclock via facres); advance clock,
   clean reboot, still sane.

Persistence:

8. `echo hi > /root/marker; reboot` → present. Reflash rootfs (`flashos`)
   → still present. `.ssh/authorized_keys` from a config blob survives too.
9. First-boot-ever path: wipe facres (`dd if=/dev/zero of=/dev/disk/by-partlabel/facres bs=1M count=8`),
   reboot → sealed boot fine, facres auto-mkfs'd, `/root` reseeded.

Maintenance mode:

10. `tc8-rw --reboot` → banner + `tc8-mode` say direct-rw; `findmnt /` →
    ext4 rw. `apt update && apt install sl` works.
11. Reboot *without* `tc8-ro` → still direct-rw (sticky flag).
12. `tc8-ro --reboot` → sealed again; `sl` still installed (it hit the
    lower); `/ephemeral-test` still absent.
13. `tc8.rootfs=ro` cmdline test (optional): flag set but forced sealed.

Regression sweep: cold boot (power pull, not just `reboot`), both slots if
B is populated, USB gadget console/MTP, audio safe-volume, panel rotation.
