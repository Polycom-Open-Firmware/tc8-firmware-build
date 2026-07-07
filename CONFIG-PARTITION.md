# TC8 cache partition — autoconfigure + bootloader updates (v1)

How the provisioning wizard pushes device configuration and stage-2
bootloader updates to a TC8 over fastboot — no serial, no bootloader
change. The wizard writes a blob to the stock `cache` GPT partition;
boot-time services apply it before the kiosk starts. This doc is the
contract: the Linux half is implemented in this repo, and the wizard half
(build + flash the blob) implements against the format below.

## Why `cache`
- It's in the stock Android GPT — 1 GiB ext4 (was Android `/cache`), unused
  by our Debian. (Confirmed on a live v0.4.x unit: `/dev/mmcblk2p7`, clean, 95% free.)
- `fastboot flash cache <blob>` works with the existing stage-2 fastboot — no
  bootloader rebuild, no re-enroll.
- `cache` is not in the AVB-verified chain (`boot`/`dtbo`/`vbmeta`), so nothing
  needs re-signing.
- Legacy flat-layout units have no `cache`; the reader no-ops there until they're
  re-flashed to the v0.4.x stock-GPT model.

## Cache image layout

Written to the **start** of the `cache` partition. All integers
little-endian. The config blob sits at offset 0; a staged bootloader
(optional) at 1 MiB.

| offset | size | field |
|-------:|-----:|-------|
| 0  | 8  | config magic `"TC8CFGv1"` |
| 8  | 4  | config payload length `Lc` (u32) |
| 12 | 32 | sha256(config payload) |
| 44 | 20 | reserved (0) |
| 64 | `Lc` | config payload (`KEY=value\n…`) |
| **1 MiB (0x100000)** | 8 | bootloader magic `"TC8BOOT1"` |
| 1 MiB + 8 | 4 | stage-2 image length `Lb` (u32) |
| 1 MiB + 12 | 32 | sha256(stage-2 image) |
| 1 MiB + 44 | 20 | reserved (0) |
| **1 MiB + 512 (0x100200)** | `Lb` | the stage-2 image (`tc8-stage2-uboot.bin`) |

- **Config payload** — UTF-8 text, one `KEY=value` per line (LF). `#` and
  blank lines ignored. Max **1 MiB**.
- **Config-only push?** Omit everything from 1 MiB on (just the config
  blob). The bootloader-updater no-ops when there's no `TC8BOOT1` magic.
- The bootloader header lives in the **sector at 1 MiB**; the image starts
  at the **next sector** (1 MiB + 512), sector-aligned.
- The device verifies magic + sha256 before applying either half. A
  fresh or empty `cache` (no magic) or a corrupt, half-written blob is
  ignored — the unit keeps its current config and bootloader. Applied
  ONCE per unique blob (sha-gated, marker on facres); the blob is not cleared. A re-provision writes a new blob → re-applies. In sealed mode the applied /etc is persisted + restored so it survives reboots without re-running.
- Cache is 1 GiB, so even with a ~3 MiB stage-2 the composite is tiny;
  fastboot writes from offset 0, no need to write the whole partition.

## Building the cache image (wizard reference, TypeScript/JS)

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

## Config keys (the autoconfigure schema)
Status: **✅ implemented** in the v1 reader (`rootfs/etc/tc8-config/apply-config.sh`);
**▢ planned** (reserved key — document + implement incrementally).

### Identity
| key | st | effect | example |
|-----|----|--------|---------|
| `DEVICE_NAME` | ✅ | `/etc/hostname` + `hostname` | `lobby-east` |
| `LOCATION` | ▢ | inventory label (motd / a `/etc/tc8-location`) | `Bldg A / Lobby` |

### Application (device role)
The wizard's Application picker writes this; `apply-config` sets the systemd
default target accordingly and records `/etc/tc8-profile`. Baked role packages
(`poly-<device>-profile-<id>`) supply each role's apps — nothing is fetched.
| key | st | effect | example |
|-----|----|--------|---------|
| `PROFILE` | ✅ | device role. `kiosk` → `graphical.target` (fullscreen `kiosk.service`); `dev` → `multi-user.target` + tty1 autologin + ssh (no kiosk lock); `smart-speaker` (C60) → `multi-user.target`, enables the voice app service if baked, else console. Unset → `kiosk`. | `dev` |

### Kiosk / display
| key | st | effect | example |
|-----|----|--------|---------|
| `KIOSK_URL` | ✅ | `/etc/default/tc8-kiosk` `KIOSK_URL=` (web page **or** `rtsp://…`) | `https://dash.local` |
| `KIOSK_URL_FALLBACK` | ✅ | secondary URL if primary unreachable | `https://backup.local` |
| `COG_OPTS` | ✅ | cog browser flags | `--enable-media=true` |
| `ROTATION` | ▢ | panel orientation override (cage `-r` count) | `1` |
| `BLANK_TIMEOUT` | ▢ | screen-blank / DPMS seconds (0 = always on) | `0` |
| `BRIGHTNESS` | ▢ | backlight 0–100 | `80` |
| `RELOAD_INTERVAL` | ▢ | periodic kiosk reload / crash-watchdog (s) | `3600` |

### Network
| key | st | effect | example |
|-----|----|--------|---------|
| `NET_MODE` | ▢ | `dhcp` \| `static` (writes systemd-networkd) | `static` |
| `IP_ADDR` / `NETMASK` / `GATEWAY` | ▢ | static addressing | `192.168.1.50/24` |
| `DNS` | ▢ | resolvers (comma list) | `192.168.1.1,1.1.1.1` |
| `VLAN_ID` | ▢ | tag the `lan` port (DSA switch supports it) | `40` |
| `HTTP_PROXY` | ▢ | proxy for kiosk + updates | `http://proxy:3128` |
| `NTP_SERVER` | ✅ | `timesyncd.conf` `NTP=` | `192.168.1.1` |
| `CONFIG_TIME` | ✅ | epoch seconds — **forward-only** clock bump so an offline device (no NTP) boots with a roughly-right clock. Auto-stamped by the wizard at flash time; never moves a real/NTP-synced clock backward. Baseline (no blob) = image build date via `/etc/fake-hwclock.data`. | `1783432800` |
| `WIFI_SSID` | ✅ | configure `wlan0` with `wpa_supplicant` + DHCP via `systemd-networkd` | `Corp-Guest` |
| `WIFI_PASSWORD` | ✅ | WPA/WPA2 passphrase for `WIFI_SSID`; omit for open Wi-Fi | `s3cretwifi` |
| `WIFI_COUNTRY` | ✅ | optional regulatory country in `wpa_supplicant` config | `US` |

### Access / credentials
| key | st | effect | example |
|-----|----|--------|---------|
| `ROOT_PASSWORD` | ✅ | `chpasswd` for `root` (change the default `root/root`!) | `s3cret` |
| `KIOSK_PASSWORD` | ✅ | `chpasswd` for the `kiosk` user | `…` |
| `SSH_AUTHKEY` | ✅ | append to `/root/.ssh/authorized_keys` (fleet admin access) | `ssh-ed25519 AAAA…` |
| `SSH_ENABLE` | ▢ | enable/disable sshd | `true` |
| `SSH_PASSWORD_AUTH` | ▢ | allow/deny password login (harden) | `false` |
| `STREAM_USER` / `STREAM_PASS` | ▢ | credentials for the kiosk destination if not embedded in the URL (for example, an RTSP camera) | `admin` / `…` |

### Certificates / trust
| key | st | effect | example |
|-----|----|--------|---------|
| `CA_CERT_B64` | ✅ | base64 PEM → `/usr/local/share/ca-certificates/fleet-N.crt` + `update-ca-certificates` (trust internal HTTPS/RTSP CAs). Repeatable. | `LS0tLS1CRUdJ…` |
| `CLIENT_CERT_B64` / `CLIENT_KEY_B64` | ▢ | mTLS client cert/key to the destination | `…` |

### Time / locale / audio
| key | st | effect | example |
|-----|----|--------|---------|
| `TIMEZONE` | ✅ | `/etc/localtime` + `/etc/timezone` | `America/New_York` |
| `LOCALE` | ▢ | system locale | `en_US.UTF-8` |
| `VOLUME_MASTER` / `VOLUME_SPEAKER` | ✅ | `amixer` caps (small panel speakers distort high) | `80` / `75` |

### Management / ops
| key | st | effect | example |
|-----|----|--------|---------|
| `LOG_FORWARD` | ▢ | remote syslog endpoint | `udp://logs:514` |
| `HEARTBEAT_URL` | ▢ | health/telemetry beacon | `https://fleet/beat` |
| `OTA_CHANNEL` / `OTA_URL` | ▢ | update channel + server | `stable` |
| `REBOOT_SCHEDULE` | ▢ | nightly reboot (kiosk hygiene), cron/timer | `04:00` |

> Multi-line or binary values (certs, keys) travel base64-encoded in the
> `*_B64` keys — this keeps the payload single-line `KEY=value`. Unknown keys
> are logged and ignored, so the wizard can send a superset safely.

## Precedence and flows
- **Precedence:** the `cache` blob is the base; a local `/data/poly-kiosk/config`
  file (existing `kiosk-config.service`) still overrides it. So a hands-on
  local edit beats the last pushed config.
- **Reconfigure** (already-unlocked unit): four-finger gesture → fastboot →
  wizard builds the blob from the form → `fastboot flash cache` →
  `fastboot reboot`.
- **Unlock or reinstall:** flash a default blob so a fresh unit boots
  configured — and include the current stage-2 by default, so every install
  lands the matching bootloader. That's one extra fetch + a bigger
  `fastboot flash cache`, not a separate device round-trip.
- **Update bootloader** (standalone): offer an in-field bootloader bump
  without reinstalling the OS.

## Bootloader update — how it lands

- The stage-2 lives in the eMMC `boot1` hardware partition. A *running*
  Debian can rewrite boot1 (we do); a fastboot session generally can't
  target it cleanly. So the wizard hands the image to the OS through `cache`,
  and the OS does the write. The wizard never writes `boot1` directly.
- On device, `tc8-update-bootloader.service` runs
  `etc/tc8-config/update-bootloader.sh` at boot: validate the `TC8BOOT1`
  blob → sha256 + `0a 00 00 14` stage-2 signature → compare to boot1 →
  flash (force_ro toggle + `dd` + read-back verify) only if different.
- **Timing:** the wizard's job finishes at `fastboot flash cache` +
  `fastboot reboot`. The unit comes up on the *old* stage-2, flashes boot1
  in the background, and the *next* power-cycle runs the new one. To make
  it current in one visible step, prompt one extra reboot; otherwise it
  converges on its own, since the write is idempotent.
- **Failure modes:** nothing the wizard does can brick the unit —
  `boot0` (stock stage-1) is never touched, so SDP and `uuu` recovery always
  works; the OS verifies sha256 before writing and reads back after. A
  "bootloader will finish updating on the next restart" note is all the
  UI needs.
- **Artifact:** `tc8-stage2-uboot.bin`, from the firmware release. Its md5
  is in `manifest.json` (`stage2.md5`); show/track that as the bootloader
  version. The wizard already has this image for **enroll** (which writes
  it to boot1 over serial on a virgin unit) — this is the same image,
  delivered the no-serial way.

## Security
The blob is **plaintext at rest** on `cache` (any root user on the device can read
it — passwords, keys). That's usually acceptable for a trusted-fleet config, and
it travels over local USB fastboot, not the network. If a deployment needs
secrets protected at rest, that's a v2 item (encrypt the payload to a device/fleet
key). Don't put anything in here you wouldn't accept on the device's disk.

## Linux side (implemented here)
- `rootfs/etc/tc8-config/apply-config.sh` — config reader (POSIX sh, busybox/coreutils only).
- `rootfs/etc/tc8-config/update-bootloader.sh` — bootloader reader/flasher.
- `rootfs/etc/systemd/system/tc8-config.service` — oneshot, `Before=kiosk-config.service kiosk.service`.
- `rootfs/etc/systemd/system/tc8-update-bootloader.service` — runs the flasher at boot.
- Enabled in `rootfs/chroot-setup.sh`. To add a `▢` key: extend the reader's
  `case`, flip it to ✅ here.
