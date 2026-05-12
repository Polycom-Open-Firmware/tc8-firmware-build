#!/usr/bin/env bash
# onboard.sh — take a TC8 panel from any known stock/dev state to our
# flat-layout install. Idempotent: safe to re-run.
#
# What it does:
#   1. Drive the panel into u-boot via the brainslug (handles bootdelay=0
#      by continuously spamming ^C before SPL prints).
#   2. setenv bootdelay 3; saveenv  (defensive — easier intervention later).
#   3. Write our flat GPT (kernel/kernel_bak/dtb/dtb_bak/rootfs/data) via
#      u-boot's `gpt write mmc 1`. Stock dtbo_a/b/boot_a/b/system_a/b/
#      vendor_a/b/etc are overwritten — the dump in
#      /var/lib/vz/dump/tc8-2/ is the rollback artifact.
#   4. fastboot 0 → flash `kernel`, `dtb`, `rootfs` partitions.
#   5. Install u-boot env vars: slotbboot script, tc8_bootargs, bootcmd,
#      boot_slot=main, bootdelay=3. saveenv. reset.
#   6. Wait for ssh on the panel; light sanity check (uname + cmdline).
#
# USAGE
#   onboard.sh --brainslug http://10.99.0.35 --fastboot-host aibox \
#              --poe-port 1 --artifacts /tmp/tc8-v0.3.0
#
# artifacts/ must contain:  Image  imx8mm-tc8.dtb  rootfs.img(.zst)
#
# ENV (override defaults)
#   TC8_HOST_PASS    rooot ssh password baked into the image (default: root)
#   POE_SW_PASS      PoE switch admin password (default: $SW_PASS)
#   SW_HOST          PoE switch IP (default: 192.168.10.243)

set -euo pipefail

BRAINSLUG="${BRAINSLUG:-http://10.99.0.35}"
FASTBOOT_HOST="${FASTBOOT_HOST:-aibox}"
POE_PORT=""
ARTIFACTS=""
SLOT="${SLOT:-main}"                       # main or bak — which slot to install into
NO_REPARTITION="${NO_REPARTITION:-0}"      # 1 = skip GPT rewrite (just flash to existing kernel/dtb/rootfs partitions)
: "${TC8_HOST_PASS:=root}"
: "${SW_PASS:=${POE_SW_PASS:-}}"
: "${SW_HOST:=192.168.10.243}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --brainslug)      BRAINSLUG="$2"; shift 2;;
        --fastboot-host)  FASTBOOT_HOST="$2"; shift 2;;
        --poe-port)       POE_PORT="$2"; shift 2;;
        --artifacts)      ARTIFACTS="$2"; shift 2;;
        --slot)           SLOT="$2"; shift 2;;
        --no-repartition) NO_REPARTITION=1; shift;;
        -h|--help)        sed -n '2,40p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

[[ -n "$POE_PORT"  ]] || { echo "ERROR: --poe-port required (1 / 2 / ...)" >&2; exit 1; }
[[ -n "$ARTIFACTS" ]] || { echo "ERROR: --artifacts DIR required" >&2; exit 1; }
[[ -d "$ARTIFACTS" ]] || { echo "ERROR: $ARTIFACTS not a dir" >&2; exit 1; }
[[ "$SLOT" == "main" || "$SLOT" == "bak" ]] || { echo "ERROR: --slot must be main or bak" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve artifacts. rootfs.img may be .zst; decompress to a scratch file.
KERNEL="$ARTIFACTS/Image"
DTB="$ARTIFACTS/imx8mm-tc8.dtb"
ROOTFS="$ARTIFACTS/rootfs.img"
if [[ ! -f "$ROOTFS" && -f "${ROOTFS}.zst" ]]; then
    echo "[+] decompressing rootfs.img.zst"
    zstd -d -q "${ROOTFS}.zst" -o "$ROOTFS"
fi
for f in "$KERNEL" "$DTB" "$ROOTFS"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

# Brainslug UART helpers.
ub() {
    # send raw bytes; arg is literal $1 string
    curl -fsS -X POST --data-binary "$1" \
        -H "Content-Type: application/octet-stream" \
        "$BRAINSLUG/uart/1/write" >/dev/null
}
ub_read() {
    curl -fsS "$BRAINSLUG/uart/1/read"
}

# Drive panel into u-boot. Sends a batched-Ctrl-C burst that's already
# 1.5 KB long (every 30 ms), reads back, and detects when the panel has
# settled at the prompt: 5 consecutive reads where the tail ends in
# "u-boot=> " and no new "Trying to boot" / "SPL" / "Starting kernel"
# marker has appeared. Handles bootdelay=0 panels by being able to spam
# faster than autoboot can fire.
catch_uboot() {
    echo "[+] starting Ctrl-C spam, PoE-cycling port $POE_PORT"
    # 32 Ctrl-Cs + CRs in one body — single HTTP POST per ~30ms.
    local burst
    burst="$(printf '\x03 \r%.0s' {1..32})"
    (
        end=$((SECONDS + 120))
        while (( SECONDS < end )); do
            ub "$burst" 2>/dev/null || true
            sleep 0.03
        done
    ) &
    local spam_pid=$!

    SW_PASS="$SW_PASS" "$REPO_ROOT/smoke/poe_cycle.sh" cycle "$POE_PORT" >/dev/null

    local deadline=$((SECONDS + 150))
    local stable=0 last_tail=""
    while (( SECONDS < deadline )); do
        local chunk
        chunk="$(ub_read 2>/dev/null || true)"
        if [[ -n "$chunk" ]]; then
            # Look only at the last 200 bytes of new data — that's where a
            # fresh prompt would appear.
            last_tail="${chunk: -200}"
            if [[ "$last_tail" == *"u-boot=> "* ]]; then
                stable=$((stable + 1))
            else
                stable=0
            fi
        fi
        if (( stable >= 8 )); then
            # Prompt looks settled. Stop spamming, confirm with a fresh CR.
            kill "$spam_pid" 2>/dev/null || true
            wait "$spam_pid" 2>/dev/null || true
            sleep 0.5
            ub_read >/dev/null 2>&1 || true        # drain
            ub $'\r' 2>/dev/null || true
            sleep 0.7
            local confirm
            confirm="$(ub_read 2>/dev/null || true)"
            if [[ "$confirm" == *"u-boot=> "* ]]; then
                echo "[+] u-boot prompt caught"
                return 0
            fi
            stable=0    # false alarm; resume waiting
        fi
        sleep 0.15
    done
    kill "$spam_pid" 2>/dev/null || true
    wait "$spam_pid" 2>/dev/null || true
    echo "ERROR: never caught u-boot prompt" >&2
    echo "    last tail: ${last_tail:-(no recent data)}" >&2
    return 1
}

# Synchronously send a u-boot command, return after $1 seconds.
ub_cmd() {
    local cmd="$1"; local wait_s="${2:-1}"
    ub_read >/dev/null     # drain
    ub "${cmd}"$'\r'
    sleep "$wait_s"
    ub_read || true
}

# Write our GPT via u-boot.  IMPORTANT: this nukes the stock Polycom A/B
# layout. Run only when forensics dump exists OR you don't care.
write_gpt() {
    echo "[+] writing flat GPT"
    # uuid_disk fixed so re-runs are idempotent and partprobes see consistent ids.
    local gpt='uuid_disk=00112233-4455-6677-8899-aabbccddeeff;'
    gpt+='name=kernel,start=0x8000,size=48MiB,type=raw;'
    gpt+='name=kernel_bak,start=0x20000,size=48MiB,type=raw;'
    gpt+='name=dtb,start=0x38000,size=4MiB,type=raw;'
    gpt+='name=dtb_bak,start=0x3a000,size=4MiB,type=raw;'
    gpt+='name=rootfs,start=0x3c000,size=13GiB,type=linux;'
    gpt+='name=data,size=-,type=linux'
    ub_cmd "setenv tc8_gpt '${gpt}'" 0.5 >/dev/null
    ub_cmd "gpt write mmc 1 \"\$tc8_gpt\"" 5
}

# Install our u-boot env. tc8_bootargs takes the kernel cmdline; slotbboot
# picks kernel/dtb partition by boot_slot.
install_env() {
    local bootargs
    bootargs="$(cat "$REPO_ROOT/profiles/emmc.env" | sed -n 's/^KERNEL_CMDLINE="\(.*\)"$/\1/p')"
    # Override root= to our flat-layout rootfs partition (#5 in our GPT).
    bootargs="${bootargs//root=\/dev\/mmcblk2p6/root=\/dev\/mmcblk2p5}"
    bootargs="${bootargs//root=\/dev\/nfs nfsroot=*,nolock /}"
    [[ "$bootargs" == *"root="* ]] || bootargs="${bootargs} root=/dev/mmcblk2p5"

    # slotbboot picks {kernel,dtb} or {kernel_bak,dtb_bak} based on boot_slot env.
    local slotbboot='mmc dev 1; if test "${boot_slot}" = "bak"; then'
    slotbboot+=' mmc read 0x40000000 0x20000 0x20000;'        # kernel_bak
    slotbboot+=' mmc read 0x43400000 0x3a000 0x100;'          # dtb_bak
    slotbboot+=' else'
    slotbboot+=' mmc read 0x40000000 0x8000 0x20000;'         # kernel
    slotbboot+=' mmc read 0x43400000 0x38000 0x100;'          # dtb
    slotbboot+=' fi;'
    slotbboot+=' setenv bootargs "${tc8_bootargs}";'
    slotbboot+=' booti 0x40000000 - 0x43400000'

    echo "[+] installing u-boot env"
    ub_cmd "setenv bootdelay 3" 0.5 >/dev/null
    ub_cmd "setenv boot_slot ${SLOT}" 0.5 >/dev/null
    ub_cmd "setenv tc8_bootargs '${bootargs}'" 0.5 >/dev/null
    ub_cmd "setenv slotbboot '${slotbboot}'" 0.5 >/dev/null
    ub_cmd "setenv bootcmd 'run slotbboot'" 0.5 >/dev/null
    ub_cmd "saveenv" 3
}

run_fastboot() {
    echo "[+] entering fastboot 0"
    ub_cmd "fastboot 0" 1 >/dev/null

    echo "[+] waiting for fastboot device on $FASTBOOT_HOST"
    for _ in $(seq 1 30); do
        if ssh "$FASTBOOT_HOST" 'fastboot devices 2>/dev/null | grep -q Fastboot'; then
            ssh "$FASTBOOT_HOST" 'fastboot devices'
            break
        fi
        sleep 2
    done

    # Stage artifacts on fastboot host.
    local rd; rd="/tmp/tc8-onboard-$$"
    ssh "$FASTBOOT_HOST" "mkdir -p $rd"
    scp -q "$KERNEL" "$DTB" "$ROOTFS" "$FASTBOOT_HOST:$rd/"

    local k_part="kernel"; local d_part="dtb"
    [[ "$SLOT" == "bak" ]] && k_part="kernel_bak" d_part="dtb_bak"

    echo "[+] flashing $k_part / $d_part / rootfs"
    ssh "$FASTBOOT_HOST" "cd $rd && \
        fastboot flash $k_part   Image            | tail -1 && \
        fastboot flash $d_part   imx8mm-tc8.dtb   | tail -1 && \
        fastboot flash rootfs    rootfs.img       | tail -2"

    ssh "$FASTBOOT_HOST" "rm -rf $rd"
}

# ---- main ----
catch_uboot
if [[ "$NO_REPARTITION" -ne 1 ]]; then
    write_gpt
fi
install_env
run_fastboot

echo "[+] exiting fastboot back to u-boot, then reset"
# Exit fastboot — Ctrl-C over UART, then reset.
ub $'\x03\x03' || true
sleep 1
ub_cmd "reset" 0.5 >/dev/null

echo "[+] panel rebooting; waiting for ssh"
# Wait for a tc8 panel to reappear on the LAN.
for _ in $(seq 1 90); do
    if ssh "$FASTBOOT_HOST" "ip neigh | grep -iE '00:e0:db' | grep -v fe80 | head -1" 2>/dev/null | grep -q REACHABLE; then
        ip="$(ssh "$FASTBOOT_HOST" "ip neigh | grep -iE '00:e0:db' | grep -v fe80 | awk '{print \$1}' | head -1")"
        echo "[+] panel @ $ip; trying ssh"
        if sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR -o ConnectTimeout=5 "root@$ip" \
                'cat /etc/tc8-version; uname -a; cat /proc/cmdline' 2>/dev/null; then
            echo "[OK] onboard complete: $ip"
            exit 0
        fi
    fi
    sleep 3
done

echo "ERROR: never reached ssh on panel" >&2
exit 2
