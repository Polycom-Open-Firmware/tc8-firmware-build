#!/usr/bin/env bash
# hw-smoke-test.sh — flash a built release to a real TC8 panel and verify it
# boots into a working state. Returns 0 on pass, non-zero on failure with a
# summary of which check tripped.
#
# USAGE
#   ./scripts/hw-smoke-test.sh                       # smoke-test the latest tag
#   ./scripts/hw-smoke-test.sh --tag v0.1.0          # smoke-test a specific release
#   ./scripts/hw-smoke-test.sh --local               # smoke-test the local build in out/emmc/
#   ./scripts/hw-smoke-test.sh --keep                # leave panel booted after passing
#
# REQUIRED ENV (lab-specific; failing values prevent the script from running)
#   TC8_HOST_IP        ssh-able address of the panel (default: 192.168.10.229)
#   TC8_HOST_PASS      root password baked into the test image (default: root)
#   TC8_FASTBOOT_HOST  ssh user@host that can drive `fastboot` to the panel
#                      (default: aibox)
#   TC8_POE_CYCLE      shell command that hard power-cycles the panel; the
#                      script will block on it returning before polling for
#                      fastboot. Default: SW_PASS=$SW_PASS ~/polycom_re/scripts/poe_cycle.sh cycle 1
#   TC8_WATCHER_RESTART  command to (re)start the brainslug-driven watcher
#                        that catches u-boot autoboot and types `fastboot 0`
#                        (default: ssh aibox 'systemctl restart uboot-watch')
#
# This script is intentionally lab-tooling-aware: in production CI you'd
# point TC8_FASTBOOT_HOST at a self-hosted GitHub Actions runner that has
# physical USB to the panel.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Defaults — override via env or flags.
: "${TC8_HOST_IP:=192.168.10.229}"
: "${TC8_HOST_PASS:=root}"
: "${TC8_FASTBOOT_HOST:=aibox}"
: "${TC8_POE_CYCLE:=SW_PASS=${SW_PASS:-} ${REPO_ROOT}/scripts/poe_cycle.sh cycle 1}"
: "${TC8_WATCHER_RESTART:=ssh ${TC8_FASTBOOT_HOST} 'systemctl restart uboot-watch 2>/dev/null || systemd-run --unit=uboot-watch /usr/bin/python3 /tmp/uboot_watch.py'}"

MODE="release"
TAG=""
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag=*)   TAG="${1#--tag=}"; shift;;
        --tag)     TAG="$2"; shift 2;;
        --local)   MODE="local"; shift;;
        --keep)    KEEP=1; shift;;
        -h|--help) sed -n '2,30p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ASSETS="$WORK/assets"
mkdir -p "$ASSETS"

# Step 1 — fetch artifacts.
case "$MODE" in
    release)
        if [[ -z "$TAG" ]]; then
            TAG="$(gh release list --repo Polycom-Open-Firmware/tc8-firmware-build --limit 1 \
                | awk '{print $1; exit}')"
        fi
        echo "[+] using release tag $TAG"
        cd "$ASSETS"
        gh release download "$TAG" \
            --repo Polycom-Open-Firmware/tc8-firmware-build \
            --pattern 'boot-emmc.img' \
            --pattern 'dtbo.img' \
            --pattern 'vbmeta-emmc.img' \
            --pattern 'system.img.zst'
        echo "[+] decompressing system.img.zst"
        zstd -d -q system.img.zst -o system.img && rm system.img.zst
        cd "$REPO_ROOT"
        ;;
    local)
        for f in boot.img dtbo.img vbmeta.img system.img; do
            [[ -f "$REPO_ROOT/out/emmc/$f" ]] || {
                echo "ERROR: missing $REPO_ROOT/out/emmc/$f — build first" >&2; exit 1; }
            cp "$REPO_ROOT/out/emmc/$f" "$ASSETS/"
        done
        # Rename to release naming so the flash step is uniform
        mv "$ASSETS/boot.img"   "$ASSETS/boot-emmc.img"
        mv "$ASSETS/vbmeta.img" "$ASSETS/vbmeta-emmc.img"
        TAG="(local)"
        ;;
esac

ls -la "$ASSETS"

# Step 2 — drop the staged set + the brainslug-watcher into the fastboot
# driver host. Also seed /tmp/uboot_watch.py since the watcher restart
# command below assumes it lives there.
REMOTE_DIR="/tmp/tc8-smoke-$$"
echo "[+] staging artifacts on ${TC8_FASTBOOT_HOST}:${REMOTE_DIR}"
ssh "$TC8_FASTBOOT_HOST" "mkdir -p $REMOTE_DIR"
scp "$ASSETS"/{boot-emmc.img,dtbo.img,vbmeta-emmc.img,system.img} \
    "$TC8_FASTBOOT_HOST:$REMOTE_DIR/" >/dev/null
scp "$REPO_ROOT/tools/uboot_watch.py" "$TC8_FASTBOOT_HOST:/tmp/uboot_watch.py" >/dev/null

# Step 3 — get into fastboot. Use plain nohup so the runner user (no
# privileged systemd-run access) can launch the watcher.
echo "[+] arming u-boot watcher and PoE-cycling panel"
ssh -o BatchMode=yes "$TC8_FASTBOOT_HOST" 'pkill -9 -f uboot_watch.py 2>/dev/null || true; rm -f /tmp/uboot-watch.state' || true
ssh -o BatchMode=yes -f "$TC8_FASTBOOT_HOST" 'python3 /tmp/uboot_watch.py >/tmp/uboot-watch.log 2>&1' || true
sleep 2
ssh -o BatchMode=yes "$TC8_FASTBOOT_HOST" 'pgrep -af uboot_watch.py | head -1' || true
eval "$TC8_POE_CYCLE"

# Wait up to ~2 min for fastboot to enumerate
echo -n "[+] waiting for fastboot mode "
for _ in $(seq 1 30); do
    if ssh "$TC8_FASTBOOT_HOST" 'fastboot devices 2>/dev/null | grep -q Fastboot'; then
        echo " OK"; break
    fi
    echo -n "."; sleep 3
done
ssh "$TC8_FASTBOOT_HOST" 'fastboot devices' || {
    echo "FAIL: panel never reached fastboot" >&2; exit 2; }

# Step 4 — flash both slots so slotbboot picks up the new image.
echo "[+] flashing both slots"
ssh "$TC8_FASTBOOT_HOST" "cd $REMOTE_DIR && \
    for slot in a b; do \
        echo === flash \$slot ===; \
        fastboot flash boot_\$slot   boot-emmc.img   | tail -2; \
        fastboot flash dtbo_\$slot   dtbo.img        | tail -1; \
        fastboot flash vbmeta_\$slot vbmeta-emmc.img | tail -1; \
        fastboot flash system_\$slot system.img      | tail -2; \
    done; \
    fastboot set_active a; \
    fastboot reboot"

# Step 5 — wait for the panel to come up. DHCP may hand it a different IP
# each boot, so if TC8_HOST_IP doesn't ping, fall back to MAC discovery on
# the fastboot-driver host (which sees the panel's ARP entry).
discover_ip() {
    # Prefer the configured IP if it's responsive
    if ping -c 1 -W 2 "$TC8_HOST_IP" >/dev/null 2>&1; then
        echo "$TC8_HOST_IP"; return 0
    fi
    # Else: scrape the panel's MAC from the fastboot-host's ARP cache. The
    # MAC is stable per device; the fastboot host sees it via DHCP traffic.
    local mac="${TC8_HOST_MAC:-00:e0:db:50:87:c2}"
    local found
    found=$(ssh "$TC8_FASTBOOT_HOST" "ip neigh | awk -v m=$mac 'tolower(\$5)==tolower(m){print \$1}'" 2>/dev/null \
            | grep -E '^[0-9.]+$' | head -1)
    if [[ -n "$found" ]]; then
        echo "$found"
    fi
}

echo -n "[+] waiting for ssh "
for _ in $(seq 1 60); do
    panel_ip="$(discover_ip)"
    if [[ -n "$panel_ip" ]]; then
        sleep 5  # let sshd settle
        if sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
            "root@$panel_ip" true 2>/dev/null; then
            TC8_HOST_IP="$panel_ip"
            echo " OK ($panel_ip)"; break
        fi
    fi
    echo -n "."; sleep 3
done

REMOTE() {
    sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@$TC8_HOST_IP" "$@"
}

# Step 6 — battery of checks. Each adds to FAILS if it tripped.
echo "[+] running checks"
FAILS=()
check() {
    local name="$1" cmd="$2" expect="$3"
    local got
    got="$(REMOTE "$cmd" 2>&1 || true)"
    if [[ "$got" =~ $expect ]]; then
        printf "  ✓ %-30s %s\n" "$name" "$got"
    else
        printf "  ✗ %-30s expected /%s/ got: %s\n" "$name" "$expect" "$got"
        FAILS+=("$name")
    fi
}

check version              ". /etc/tc8-version && echo \$TC8_FW_VERSION"      "^v[0-9]"
check display_card1        "ls /dev/dri/ | tr '\n' ' '"                       "card0.*card1"
check dsi_connected        "cat /sys/class/drm/card1-DSI-1/status"            "^connected$"
check audio_card           "aplay -l 2>&1 | grep tas5751"                     "tas5751-audio"
check master_capped        "amixer -c 0 sget Master | grep -oE '\\[[0-9]+%\\]' | head -1"     "\\[(7[0-9]|80)%\\]"
check speaker_capped       "amixer -c 0 sget Speaker | grep -oE '\\[[0-9]+%\\]' | head -1"    "\\[(7[0-9]|80)%\\]"
check touch_event          "ls /dev/input/event0"                             "event0"
check goodix_bound         "cat /proc/bus/input/devices | grep -c -i goodix"  "^[1-9]"
check usb_gadget           "ls /sys/kernel/config/usb_gadget/g1/UDC | head -1" "UDC"
check kiosk_or_rickroll    "systemctl is-active kiosk tc8-rickroll | grep -m1 active" "^active$"
check ssh_keys_baked       "test -f /root/.ssh/authorized_keys && echo present || echo absent" "(present|absent)"
check lan_link             "ip -br link show lan | awk '{print \$2}'"         "^UP$"

if [[ ${#FAILS[@]} -eq 0 ]]; then
    echo
    echo "========================================="
    echo "  PASS — $TAG smoke test green on hardware"
    echo "========================================="
    if [[ $KEEP -eq 0 ]]; then
        echo "[+] cleanup: remove staged artifacts on $TC8_FASTBOOT_HOST"
        ssh "$TC8_FASTBOOT_HOST" "rm -rf $REMOTE_DIR"
    fi
    exit 0
else
    echo
    echo "========================================="
    echo "  FAIL — $TAG: ${#FAILS[@]} check(s) tripped:"
    printf "    - %s\n" "${FAILS[@]}"
    echo "========================================="
    exit 1
fi
