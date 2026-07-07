# Using the panel

Getting into an installed panel and changing its configuration.

## Getting in

The image bakes several ways in:

- **Composite USB gadget** on the micro-B data port — three interfaces:
  - **CDC ACM** → `/dev/ttyACM0` on Linux, "USB Serial Device" on Windows.
    systemd-getty spawns a login prompt automatically.
  - **CDC NCM** → `usb0` USB-Ethernet on the host. Panel runs DHCP on
    `10.55.0.1/24` and leases the host `.2`–`.5`. ssh to `10.55.0.1` the
    moment the link comes up.
  - **MTP / Portable Device** — the persistent `/root` ("Root home
    (persistent)") exposed by uMTP-Responder. Drag-and-drop in any native
    file manager; files land on the durable partition (see below).
- **ssh** on the wired LAN (port 22). The panel uses its factory MAC
  address, so a DHCP reservation set once stays valid forever.

Default credentials: **`root` / `root`**. Change them before plugging the
panel into anything you care about:

```sh
passwd                                             # change the root password
mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys   # paste your pubkey, Ctrl-D
```

Both of those live in `/root` — which persists (next section) — so they
survive reinstalls too. To bake different credentials into the image at
build time, see [BUILDING.md](BUILDING.md).

## The storage model: sealed system, durable home

Two rules cover almost everything:

1. **The OS is sealed.** The root filesystem mounts read-only behind a
   tmpfs overlay. Everything *looks* writable, but changes evaporate on
   reboot — a panel always comes back pristine, and yanking power can't
   corrupt the OS. `tc8-mode` shows the current state.
2. **`/root` is durable.** Root's home lives on a spare 1 GiB eMMC
   partition (`facres`) that nothing else touches: it survives reboots,
   reseals, **and full wipe-and-reinstalls** from the wizard. Keep your
   `authorized_keys`, dotfiles, notes, and scratch files there.

### Making permanent changes (installing packages)

To change the OS itself — `apt install`, editing baked config — drop into
**maintenance mode**:

```sh
tc8-rw && reboot        # next boot: rootfs direct-rw, no overlay
# … log back in (a banner reminds you writes are now permanent) …
apt update && apt install <package>
tc8-ro && reboot        # reseal; your changes are baked in
```

The flag is sticky across reboots (safe for installs that need a restart),
so remember the `tc8-ro`. Never try to write to the underlying partition
while sealed — the reboot flow exists because that's the only dpkg-safe
way. Full design and failure modes: [docs/RO-ROOT.md](docs/RO-ROOT.md).

## Entering fastboot remotely (no fingers on the panel)

The bootloader honors a saved `gesture_sel` variable, and the image ships
`/etc/fw_env-stage2.config` pointing at the stage-2 environment. To make
the *next* boot land in fastboot — once, self-disarming:

```sh
fw_setenv -c /etc/fw_env-stage2.config gesture_sel \
  "setenv gesture_sel bootsel; saveenv; fastboot usb 0"
reboot
```

The panel restores the normal boot flow and parks in fastboot on its USB
data port; flash with the wizard or plain `fastboot`, then
`fastboot reboot`. (The usual local path — four fingers on the logo during
the 3-second window — still works; the window length is tunable via the
`bootsel_win_ms` variable in the same environment.)

## Configuring the kiosk URL

The kiosk reads `/etc/default/tc8-kiosk`:

```sh
KIOSK_URL=https://your-page.example.com/
COG_OPTS=--enable-media=true
```

After editing, `systemctl restart kiosk`.

## Fleet configuration (no shell)

Hostname, kiosk URL, credentials, NTP, timezone, CA certs and more can be
pushed over fastboot by the provisioner — a config blob flashed to the
`cache` partition, applied on every boot. See
[CONFIG-PARTITION.md](CONFIG-PARTITION.md) for the key schema.
