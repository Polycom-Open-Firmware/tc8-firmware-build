#!/usr/bin/env bash
# hw-smoke-test.sh — install a release build onto a real TC8 panel via
# onboard.sh, then run a battery of post-install checks.
#
# USAGE
#   ./scripts/hw-smoke-test.sh                       # smoke-test the latest tag
#   ./scripts/hw-smoke-test.sh --tag v0.3.0          # smoke-test a specific release
#   ./scripts/hw-smoke-test.sh --local               # smoke-test the local build in out/emmc/
#
# REQUIRED ENV (lab-specific; failing values prevent the script from running)
#   BRAINSLUG          brainslug URL, e.g. http://10.99.0.35 (default in env or via --brainslug)
#   POE_PORT           switch port number for the panel under test
#   TC8_FASTBOOT_HOST  ssh user@host with USB to the panel (default: aibox)
#   TC8_HOST_PASS      root password baked into the test image (default: root)
#   SW_PASS            PoE switch admin password

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${BRAINSLUG:=http://10.99.0.35}"
: "${POE_PORT:=}"
: "${TC8_FASTBOOT_HOST:=aibox}"
: "${TC8_HOST_PASS:=root}"
: "${SW_PASS:=${POE_SW_PASS:-}}"

MODE="release"
TAG=""
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag=*)         TAG="${1#--tag=}"; shift;;
        --tag)           TAG="$2"; shift 2;;
        --local)         MODE="local"; shift;;
        --brainslug)     BRAINSLUG="$2"; shift 2;;
        --poe-port)      POE_PORT="$2"; shift 2;;
        --keep)          KEEP=1; shift;;
        -h|--help)       sed -n '2,25p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

[[ -n "$POE_PORT" ]] || { echo "ERROR: POE_PORT env or --poe-port required" >&2; exit 1; }

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
        for f in Image imx8mm-tc8.dtb rootfs.img.zst; do
            gh release download "$TAG" --repo Polycom-Open-Firmware/tc8-firmware-build -p "$f"
        done
        # Don't pre-decompress: onboard.sh streams `zstd -dc rootfs.img.zst`
        # straight into `dd` on the staging host so the 13 GiB decompressed
        # image never has to materialize anywhere. Pre-decompressing here
        # eats /tmp on the runner.
        cd "$REPO_ROOT"
        ;;
    local)
        for f in Image imx8mm-tc8.dtb rootfs.img; do
            [[ -f "$REPO_ROOT/out/emmc/$f" ]] || {
                echo "ERROR: missing $REPO_ROOT/out/emmc/$f — build first" >&2; exit 1; }
            cp "$REPO_ROOT/out/emmc/$f" "$ASSETS/"
        done
        TAG="(local)"
        ;;
esac
ls -la "$ASSETS"

# Step 2 — onboard the panel. This handles bootdelay=0 catch, GPT rewrite,
# fastboot flash, u-boot env install, reset.
echo "[+] running onboard.sh against the panel"
BRAINSLUG="$BRAINSLUG" \
FASTBOOT_HOST="$TC8_FASTBOOT_HOST" \
SW_PASS="$SW_PASS" \
TC8_HOST_PASS="$TC8_HOST_PASS" \
    "$REPO_ROOT/smoke/onboard.sh" \
        --brainslug "$BRAINSLUG" \
        --fastboot-host "$TC8_FASTBOOT_HOST" \
        --poe-port "$POE_PORT" \
        --artifacts "$ASSETS"

# Onboard exits with the panel IP printed in its tail. Re-discover it
# from the staging host's ARP cache by probing each REACHABLE/STALE IP
# until we find one whose /proc/cmdline matches our flat layout — the
# panel's mainline kernel doesn't preserve the baked-in 00:e0:db MAC, so
# filtering by MAC prefix would miss it.
discover_ip() {
    local ips
    ips="$(ssh "$TC8_FASTBOOT_HOST" \
        "ip neigh | grep -v fe80 | awk '/REACHABLE|STALE/ && \$1 ~ /^[0-9]/ {print \$1}'" 2>/dev/null | sort -u)"
    for ip in $ips; do
        local cmdline
        cmdline="$(sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 \
            "root@$ip" 'cat /proc/cmdline 2>/dev/null' 2>/dev/null)"
        if [[ "$cmdline" == *"root=/dev/mmcblk2p5"* ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

PANEL_IP=""
for _ in $(seq 1 30); do
    PANEL_IP="$(discover_ip)"
    [[ -n "$PANEL_IP" ]] && break
    sleep 2
done
[[ -n "$PANEL_IP" ]] || { echo "ERROR: can't find panel IP after onboard" >&2; exit 2; }
echo "[+] panel @ $PANEL_IP"

REMOTE() {
    sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@$PANEL_IP" "$@"
}

# Step 3 — battery of post-install checks.
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
check rootfs_partition     "df / | awk 'NR==2{print \$1}'"                   "mmcblk2p5"
check display_card1        "ls /dev/dri/ | tr '\n' ' '"                      "card0.*card1"
check dsi_connected        "cat /sys/class/drm/card1-DSI-1/status"           "^connected$"
check audio_card           "aplay -l 2>&1 | grep tas5751"                    "tas5751-audio"
check master_capped        "amixer -c 0 sget Master | grep -oE '\\[[0-9]+%\\]' | head -1"   "\\[(7[0-9]|80)%\\]"
check speaker_capped       "amixer -c 0 sget Speaker | grep -oE '\\[[0-9]+%\\]' | head -1"  "\\[(7[0-9]|80)%\\]"
check touch_event          "ls /dev/input/event0"                            "event0"
check goodix_bound         "cat /proc/bus/input/devices | grep -c -i goodix" "^[1-9]"
check usb_gadget           "ls /sys/kernel/config/usb_gadget/g1/UDC | head -1" "UDC"
check kiosk_active         "systemctl is-active kiosk"                       "^active$"
check ssh_keys_baked       "test -f /root/.ssh/authorized_keys && echo present || echo absent" "(present|absent)"
check lan_link             "ip -br link show lan | awk '{print \$2}'"        "^UP$"
check fw_setenv_present    "command -v fw_setenv >/dev/null && echo yes"     "^yes$"
check uboot_env_readable   "fw_printenv bootcmd 2>&1 | head -1"              "bootcmd=run slotbboot"

if [[ ${#FAILS[@]} -eq 0 ]]; then
    echo
    echo "========================================="
    echo "  PASS — $TAG smoke test green on hardware"
    echo "========================================="
    exit 0
else
    echo
    echo "========================================="
    echo "  FAIL — $TAG: ${#FAILS[@]} check(s) tripped:"
    printf "    - %s\n" "${FAILS[@]}"
    echo "========================================="
    exit 1
fi
