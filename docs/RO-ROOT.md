# RO-ROOT — read-only rootfs with tmpfs overlay + persistent /root

> **Scope: TC8 target.** The C60 boots its rootfs directly from `system_a` (no initramfs/overlay yet) — see the [README](../README.md).

## TL;DR

| | mount of `userdata` | writes | how you get there |
|---|---|---|---|
| **sealed** (default) | read-only lower + tmpfs overlay on `/` | ephemeral — evaporate on reboot | every boot, unless armed |
| **maintenance** | direct read-write, no overlay | permanent (dpkg-safe) | `tc8-rw --reboot` … `tc8-ro --reboot` |

`/root` is persistent in **both** modes (bind onto the `facres` partition —
survives reboots *and* reflashes). Everything else in sealed mode is
ephemeral by design.

## Architecture

The overlay is set up by a **minimal initramfs inside boot.img**: a ~1 MB
gzipped cpio holding a static busybox and one auditable POSIX-sh script
(`initramfs/init`). It mounts the real root itself and `switch_root`s into
the merged tree. Properties:

- **All of `/` is sealed** — one overlay over the whole rootfs, not
  per-directory tmpfs mounts, so nothing is accidentally left writable.
- **The mode decision happens before any filesystem is mounted rw**, which
  is what makes maintenance mode dpkg-safe: in direct-rw there is no
  overlay at all, so dpkg's database and its payload land on the same
  filesystem and cannot tear apart.
- **systemd sees an ordinary writable `/`** — no special ordering around
  `systemd-remount-fs`, `tmpfiles`, or `machine-id`.
- Cost: ~1 MB in boot.img (26.2 of 48 MiB used) and one moving part at
  boot. The script is ~150 lines and fails **towards booting** (see
  failure modes).

`boota` detail that makes this safe: the v0 header keeps the stock
`ramdisk_offset` (0x01000000), which on paper overlaps the 24 MiB kernel —
the stage-2 `boota` detects the overlap and relocates the ramdisk past the
FDT at `kernel_addr + 64 MiB` before copying
(`fb_fsl_boot.c: "ramdisk overlap detected"`), then passes it to `booti` as
`addr:size`. The kernel cmdline keeps `rw ... root=PARTLABEL=userdata`:
`root=`/`rw` are parsed by the initramfs, keep the kernel's own fallback
correct if the ramdisk is ever absent, and stop `systemd-remount-fs` from
remounting the overlay ro.

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
- `kernel/targets/tc8.frag` — `CONFIG_OVERLAY_FS=y` (arm64 defconfig has
  `=m`; the rootfs ships no /lib/modules, so `=m` would silently degrade
  every boot to the direct-rw fallback).
- poly-rootfs repo — `tc8-persist-root.{sh,service}`, `tc8-rw`, `tc8-ro`,
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

- **config blob** — consumed pre-seal by the **initramfs**: a staged blob
  is applied to the real rootfs (mounted rw for seconds, chroot, full
  userland) and invalidated in place before the overlay is assembled, so
  the applied state is simply *in the filesystem*. The runtime
  tc8-config.service gates itself out on overlay boots ("the initramfs
  owns the blob") and serves direct-rw boots and no-initramfs targets
  (the C60). Invalidate-last keeps it atomic: a power cut mid-apply
  leaves the blob to re-apply next boot.
- **/data (kiosk cache, MTP export)** — `/data` on this image is
  `/dev/mmcblk2p15` = **the userdata partition itself**, i.e. the rootfs
  mounted a second time. In sealed mode that rw mount fails (superblock is
  held ro by the overlay lower) — `kiosk.service`'s ExecStartPre
  `|| true`s it and then `install -d`s the dirs, which land on the
  overlay: kiosk cache and the MTP "Panel storage" are **ephemeral** in
  sealed mode and persistent in maintenance mode. Same story
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
| overlay/tmpfs mount fails (e.g. kernel built without `OVERLAY_FS=y`) | init logs `overlay setup FAILED` and **falls back to direct-rw** — boots direct-rw, no overlay |
| ramdisk absent from boot.img | kernel falls back to cmdline `root=…` rw direct-mount — boots direct-rw, no overlay |
| `/init` crashes / rootfs partition never appears | rescue busybox shell on console (serial + panel); `exit` reboots (`panic=10` guards the no-console case) |
| facres missing | initramfs: no flag possible → always sealed. tc8-persist-root exits 0 → `/root` non-persistent. `tc8-rw` refuses with a clear error (cmdline `tc8.rootfs=rw` still available) |
| facres corrupt / not ext4 | initramfs ro-mount fails → sealed boot; then tc8-persist-root **reformats** facres (mkfs.ext4 — facres content is expendable by design) and persistence resumes empty |
| tmpfs upper fills (default 50% RAM, `tc8.overlay_size=` to tune) | writes get ENOSPC; system state on lower unharmed; reboot clears |
| maintenance flag forgotten | sticky by design; login banner + `tc8-mode` surface it; it even survives reflash (facres untouched) — run `tc8-ro` |
| power loss during maintenance apt | same risk as any rw Linux — ext4 journal replays; worst case reflash `userdata` (the sealed default makes this window rare) |

## Regression checklist

Boot plumbing:

1. Flash new `boot.img` (+`vbmeta.img`) only, keep existing rootfs: serial
   shows `boota` reporting a non-zero ramdisk (expect the
   `ramdisk overlap detected → redirect` line), kernel logs
   `Trying to unpack rootfs image as initramfs...`, then `tc8-init:` lines,
   then normal systemd boot.
2. `tc8-mode` / `findmnt /` → `overlay`; `grep tc8-overlay /proc/mounts`;
   layers visible at `/mnt/.tc8/{lower,rw}`.

Sealed-mode semantics:

3. `touch /ephemeral-test; reboot` → file gone.
4. Kiosk comes up, page loads, touch OK (`/data` dirs exist on the overlay;
   `mount | grep ' /data '` shows nothing — expected).
5. ssh in (same host keys as before), DHCP lease fresh, `journalctl` works,
   no `/var/log/journal`.
6. Wizard "Reconfigure" (cache blob): consumed on the next boot — the
   initramfs applies it to the real rootfs pre-seal and zeroes the blob
   header; `KIOSK_URL` sticks across sealed reboots because it lives
   in the real filesystem.
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
