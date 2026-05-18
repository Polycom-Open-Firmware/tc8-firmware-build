#!/usr/bin/env bash
# onboard.sh — take a TC8 panel from any known stock/dev state to our
# flat-layout install. Idempotent: safe to re-run.
#
# Strategy: configure u-boot via UART (brainslug WebSocket), then expose
# the eMMC as USB Mass Storage with u-boot's `ums` command and let the
# host repartition + write artifacts using ordinary block-device tools
# (sgdisk, dd). Stock TC8 u-boot has no `gpt` command and stock fastboot
# has no `oem partition` — UMS sidesteps both.
#
# What it does:
#   1. Drive the panel into u-boot via the brainslug (smoke/catch_uboot.py
#      now uses /uart/N/ws so this is sub-second).
#   2. Set our u-boot env (slotbboot, tc8_bootargs, bootcmd, boot_slot,
#      bootdelay=3) and saveenv — done first so it survives anything
#      that happens during UMS.
#   3. `ums 0 mmc 1` — panel exposes mmc dev 1 (eMMC user area) as USB
#      Mass Storage. The mmcblkXboot0/1 hw-partitions where u-boot itself
#      lives are NOT exposed, so u-boot is unclobberable.
#   4. On the staging host (aibox): detect the new USB disk, sgdisk a
#      flat GPT (kernel/kernel_bak/dtb/dtb_bak/rootfs/data), stream-write
#      Image / imx8mm-tc8.dtb / rootfs.img straight to the partitions.
#   5. ^C the UART to leave UMS, then `reset`.
#   6. Wait for ssh on the panel; light sanity check.
#
# USAGE
#   onboard.sh --brainslug http://10.99.0.35 --staging-host aibox \
#              --poe-port 3 --artifacts /tmp/tc8-v0.3.0
#
# artifacts/ must contain:  Image  imx8mm-tc8.dtb  rootfs.img(.zst)
#
# ENV (override defaults)
#   TC8_HOST_PASS    root ssh password baked into the image (default: root)
#   POE_SW_PASS      PoE switch admin password (default: $SW_PASS)
#   SW_HOST          PoE switch IP (default: 192.168.10.243)

set -euo pipefail

BRAINSLUG="${BRAINSLUG:-http://10.99.0.35}"
# Historical name "fastboot host" preserved as an alias so old workflow envs
# (TC8_FASTBOOT_HOST) keep working — staging-host is what it does now.
STAGING_HOST="${STAGING_HOST:-${FASTBOOT_HOST:-aibox}}"
POE_PORT=""
ARTIFACTS=""
SLOT="${SLOT:-main}"                       # main | bak — install slot
NO_REPARTITION="${NO_REPARTITION:-0}"      # 1 = skip GPT rewrite (use existing partitions of same layout)
ETHADDR="${TC8_ETHADDR:-}"                 # XX:XX:XX:XX:XX:XX — falls back to whatever
                                           # u-boot env currently has (which may
                                           # be empty on a panel we've previously
                                           # mangled, in which case Linux makes
                                           # up a random locally-administered MAC)
: "${TC8_HOST_PASS:=root}"
: "${SW_PASS:=${POE_SW_PASS:-}}"
: "${SW_HOST:=192.168.10.243}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --brainslug)      BRAINSLUG="$2"; shift 2;;
        --staging-host)   STAGING_HOST="$2"; shift 2;;
        --fastboot-host)  STAGING_HOST="$2"; shift 2;;   # legacy alias
        --poe-port)       POE_PORT="$2"; shift 2;;
        --artifacts)      ARTIFACTS="$2"; shift 2;;
        --slot)           SLOT="$2"; shift 2;;
        --no-repartition) NO_REPARTITION=1; shift;;
        --ethaddr)        ETHADDR="$2"; shift 2;;
        -h|--help)        sed -n '2,50p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

[[ -n "$POE_PORT"  ]] || { echo "ERROR: --poe-port required" >&2; exit 1; }
[[ -n "$ARTIFACTS" ]] || { echo "ERROR: --artifacts DIR required" >&2; exit 1; }
[[ -d "$ARTIFACTS" ]] || { echo "ERROR: $ARTIFACTS not a dir" >&2; exit 1; }
[[ "$SLOT" == "main" || "$SLOT" == "bak" ]] || { echo "ERROR: --slot main|bak" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

KERNEL="$ARTIFACTS/Image"
DTB="$ARTIFACTS/imx8mm-tc8.dtb"
# Resolve rootfs source. Prefer streaming the .zst through `zstd -dc` straight
# to dd, so we never materialize the 14 GB decompressed file locally.
ROOTFS="$ARTIFACTS/rootfs.img"
ROOTFS_ZST="$ARTIFACTS/rootfs.img.zst"
ROOTFS_SRC_CMD=""    # set below — a shell pipeline that streams the raw image to stdout
if [[ -f "$ROOTFS" ]]; then
    ROOTFS_SRC_CMD="cat \"$ROOTFS\""
elif [[ -f "$ROOTFS_ZST" ]]; then
    ROOTFS_SRC_CMD="zstd -dc \"$ROOTFS_ZST\""
else
    echo "ERROR: need $ROOTFS or $ROOTFS_ZST" >&2; exit 1
fi
for f in "$KERNEL" "$DTB"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

# Unlock-FW stage-2 (optional). If both present, onboard installs the
# custom chainloaded U-Boot 2024.04 (bootsel logo/gesture/UMS/SDP) into
# the reserved pre-GPT gap and points stock bootcmd at it. If absent,
# onboard does a plain direct-kernel install (bootcmd='run slotbboot').
STAGE2="$ARTIFACTS/stage2-uboot.bin"     # = polycom-uboot vendored/uboot-imx/u-boot.bin
BMPBLOB="$ARTIFACTS/bmp_blob.bin"        # = polycom-uboot targets/.../logos/bmp_blob.bin
STAGE2_ENABLED=0
if [[ -f "$STAGE2" && -f "$BMPBLOB" ]]; then
    STAGE2_ENABLED=1
    echo "[+] unlock-FW stage-2 present — will install chainloaded U-Boot 2024.04"
else
    echo "[!] no stage2-uboot.bin/bmp_blob.bin in $ARTIFACTS — plain direct-kernel install (no unlock FW)"
fi

ub()      { curl -fsS -X POST --data-binary "$1" -H "Content-Type: application/octet-stream" "$BRAINSLUG/uart/1/write" >/dev/null; }
ub_read() { curl -fsS "$BRAINSLUG/uart/1/read"; }
ub_cmd()  { local cmd="$1"; local wait_s="${2:-1}"; ub_read >/dev/null; ub "${cmd}"$'\r'; sleep "$wait_s"; ub_read || true; }

catch_uboot() {
    # If a panel that already runs Linux is on the LAN, ssh-reboot it FIRST.
    # PoE-cycling the TL-SG108PE via Auto Recovery is unreliable when the
    # port was recently brought up (the switch enforces a 30 s startup
    # window before it'll trip again), and spamming Ctrl-C at a live Linux
    # shell does nothing — we'd run out of catch_uboot's timeout. A clean
    # reboot from inside the panel reliably drops us into SPL → u-boot.
    local prior_ips
    prior_ips="$(ssh "$STAGING_HOST" "ip neigh | grep -v fe80 | awk '/REACHABLE/ {print \$1}'" 2>/dev/null | sort -u)"
    for ip in $prior_ips; do
        # Only nudge panels that look like ours (root=/dev/mmcblk2p5)
        if sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 \
                "root@$ip" 'grep -q "root=/dev/mmcblk2p5" /proc/cmdline 2>/dev/null' 2>/dev/null; then
            echo "[+] panel at $ip is in Linux — issuing reboot"
            sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 \
                "root@$ip" 'systemctl reboot --no-block' 2>/dev/null || true
        fi
    done

    echo "[+] PoE-cycling port $POE_PORT"
    SW_PASS="$SW_PASS" "$REPO_ROOT/smoke/poe_cycle.sh" cycle "$POE_PORT" >/dev/null
    # $PYTHON defaults to plain `python3` (normal hosts). Override e.g.
    # PYTHON="uv run python3" in sandboxed envs that proxy python.
    ${PYTHON:-python3} "$REPO_ROOT/smoke/catch_uboot.py" --brainslug "$BRAINSLUG"
}

install_env() {
    local bootargs
    bootargs="$(sed -n 's/^KERNEL_CMDLINE="\(.*\)"$/\1/p' "$REPO_ROOT/profiles/emmc.env")"
    # Force root onto the flat-layout rootfs partition (#5).
    bootargs="${bootargs//root=\/dev\/mmcblk2p6/root=\/dev\/mmcblk2p5}"
    bootargs="${bootargs//root=\/dev\/nfs nfsroot=*,nolock /}"
    [[ "$bootargs" == *"root="* ]] || bootargs+=" root=/dev/mmcblk2p5"

    # slotbboot LBAs match write_gpt_ums layout (kernel starts at 16 MiB so it
    # doesn't trample u-boot's env block at LBA 8192):
    #   kernel       0x08000   48 MiB
    #   kernel_bak   0x20000   48 MiB
    #   dtb          0x38000    4 MiB
    #   dtb_bak      0x3a000    4 MiB
    #   rootfs       0x3c000   13 GiB
    # Semicolons escaped as `\;` so u-boot's command parser doesn't split the
    # env-var assignment mid-string. (u-boot's parser splits on bare `;`
    # even inside single-quoted setenv arguments.) booti expects: kernel
    # address, "-" for no initrd, dtb address.
    local sb='mmc dev 1\; '
    sb+='if test "${boot_slot}" = "bak"\; then '
    sb+='mmc read 0x40000000 0x20000 0x18000\; '
    sb+='mmc read 0x43400000 0x3a000 0x2000\; '
    sb+='else '
    sb+='mmc read 0x40000000 0x8000 0x18000\; '
    sb+='mmc read 0x43400000 0x38000 0x2000\; '
    sb+='fi\; '
    sb+='setenv bootargs "${tc8_bootargs}"\; '
    sb+='booti 0x40000000 - 0x43400000'

    # Restore ethaddr if the env has lost it. Polycom u-boot wipes ethaddr
    # when env is regenerated from defaults (which happens after a corrupt env
    # — e.g., if a previous reflash trampled the env block at LBA 0x2000).
    # Once set + saved, Polycom's per-boot auto-saveenv preserves it.
    if [[ -n "$ETHADDR" ]]; then
        echo "[+] setting ethaddr=$ETHADDR"
    else
        # Probe current env. Save any ethaddr we find so it survives the
        # final saveenv. If none — Linux will get a random MAC on boot.
        ub_read >/dev/null
        ub "printenv ethaddr"$'\r'
        sleep 1
        local probe_resp
        probe_resp="$(ub_read || true)"
        local existing_eth
        # grep returns 1 when env has no ethaddr (the common case after we've
        # ever stomped the env block) — `|| true` keeps pipefail from killing
        # us. Same pattern as the UMS-device wait.
        existing_eth="$({ echo "$probe_resp" | grep -oE 'ethaddr=([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1 | cut -d= -f2; } || true)"
        if [[ -n "$existing_eth" ]]; then
            ETHADDR="$existing_eth"
            echo "[+] preserving existing ethaddr=$ETHADDR"
        else
            echo "[!] no ethaddr in env and no --ethaddr passed; Linux will boot with a random MAC"
        fi
    fi

    echo "[+] installing u-boot env"
    ub_cmd "setenv bootdelay 3" 0.5 >/dev/null
    ub_cmd "setenv boot_slot ${SLOT}" 0.5 >/dev/null
    [[ -n "$ETHADDR" ]] && ub_cmd "setenv ethaddr ${ETHADDR}" 0.5 >/dev/null
    ub_cmd "setenv tc8_bootargs '${bootargs}'" 0.5 >/dev/null
    ub_cmd "setenv slotbboot '${sb}'" 0.5 >/dev/null
    # Stage-2-always-in-charge: stock bootcmd chainloads our custom
    # U-Boot 2024.04 from the reserved pre-GPT gap (LBA 0x4000). The
    # dcache-off triplet is the MMU fix (stock `go` keeps its page
    # tables). Self-persists: Polycom u-boot `saveenv`s every boot
    # (verified: 2 bare resets -> 2 autonomous stage-2 banners).
    # `slotbboot` stays defined as the RECOVERY macro — to revert to
    # direct kernel boot: `setenv bootcmd 'run slotbboot'; saveenv`.
    # Stage-2 then runs its own bootcmd (bootsel -> mmcboot).
    if [[ "$STAGE2_ENABLED" -eq 1 ]]; then
        local cl='mmc dev 1\; mmc read 0x40200000 0x4000 0x830\; '
        cl+='dcache flush\; icache off\; dcache off\; go 0x40200000'
        ub_cmd "setenv bootcmd '${cl}'" 0.5 >/dev/null
    else
        ub_cmd "setenv bootcmd 'run slotbboot'" 0.5 >/dev/null
    fi
    ub_cmd "saveenv" 3
}

UMS_DEV=""

ums_open() {
    echo "[+] enabling UMS on the panel"
    # `ums 0 mmc 1` is a blocking u-boot command — it runs until ^C. Fire and
    # forget; don't try to read a prompt back.
    ub_read >/dev/null
    ub "ums 0 mmc 1"$'\r'

    # The TC8's UMS gadget always advertises as "Linux UMS disk" — match by
    # that fingerprint rather than diffing snapshots, since a stale UMS link
    # from a previous run would defeat a naive before/after compare.
    echo "[+] waiting for USB mass storage to appear on $STAGING_HOST"
    # grep returns 1 (no match) during the wait window — `|| true` keeps
    # set -e + pipefail from killing us before USB enumeration completes.
    local name=""
    for _ in $(seq 1 30); do
        sleep 1
        name="$({ ssh "$STAGING_HOST" 'ls /dev/disk/by-id/ 2>/dev/null' | \
                  grep -E '^usb-Linux_UMS' | grep -vE -- '-part[0-9]+$' | head -1; } \
                || true)"
        [[ -n "$name" ]] && break
    done
    [[ -n "$name" ]] || { echo "ERROR: UMS device never appeared" >&2; exit 1; }

    UMS_DEV="$(ssh "$STAGING_HOST" "readlink -f /dev/disk/by-id/$name")"
    local size
    size="$(ssh "$STAGING_HOST" "blockdev --getsize64 $UMS_DEV")"
    echo "[+] UMS device: $name -> $UMS_DEV ($size bytes)"
    # Sanity guard: 16 GiB eMMC ~= 15.6 GB. Anything outside 8..32 GB
    # is suspicious — refuse rather than risk hitting the wrong disk.
    if [[ "$size" -lt 8000000000 || "$size" -gt 32000000000 ]]; then
        echo "ERROR: UMS device size $size out of expected range; refusing to write" >&2
        exit 1
    fi
}

ums_close() {
    echo "[+] flushing + closing UMS"
    ssh "$STAGING_HOST" "sync" || true
    # Ctrl-C breaks ums back to the u-boot prompt.
    ub $'\x03' || true
    sleep 2
    ub_read >/dev/null || true
}

preserve_magic_offsets() {
    # Until v0.3.1 expands the GPT to carve around them, the cert + presistdata
    # regions get wiped by our rootfs write. Dump them BEFORE zapping the GPT
    # so they're recoverable. Skipped if a previous dump exists.
    local dump_dir="/var/lib/vz/dump/tc8-magic-preflight"
    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    ssh "$STAGING_HOST" "mkdir -p $dump_dir" || return 0
    # Snapshot the env block (always nice to have) + cert + presistdata. Hex
    # offsets in decimal: env=8192, cert=11763712, presistdata=11780096; each
    # 2048 sectors except env which is 8.
    ssh "$STAGING_HOST" "
        F=$dump_dir/preflight-\${HOSTNAME:-tc}-$ts.tar
        cd $dump_dir
        dd if=$UMS_DEV bs=512 skip=8192       count=8    of=uboot-env.bin       status=none 2>/dev/null || true
        dd if=$UMS_DEV bs=512 skip=11763712   count=2048 of=cert.bin            status=none 2>/dev/null || true
        dd if=$UMS_DEV bs=512 skip=11780096   count=2048 of=presistdata.bin     status=none 2>/dev/null || true
        # Only keep the snapshot if at least one of cert/presistdata has
        # nonzero content — otherwise this panel's already been flashed and
        # the dumps would just be old rootfs garbage.
        if [ \$(stat -c%s cert.bin) -gt 0 ] && grep -qE '^subject=.*Polycom' <(openssl x509 -in cert.bin -inform PEM -noout -subject 2>/dev/null); then
            tar cf \$F uboot-env.bin cert.bin presistdata.bin 2>/dev/null
            echo \"[+] saved magic-offset preflight to \$F\"
            rm -f uboot-env.bin cert.bin presistdata.bin
        else
            rm -f uboot-env.bin cert.bin presistdata.bin
            echo '[!] no factory cert detected — skipping preflight snapshot (panel previously flashed?)'
        fi
    " || true
}

write_gpt_ums() {
    echo "[+] writing flat GPT via sgdisk on $STAGING_HOST"
    # u-boot env block at byte offset 4 MiB (LBA 0x2000, 8 sectors). If our
    # partitions start below LBA 0x4000 our writes wipe the env and the panel
    # silently reverts to stock `boota mmc1` — losing `ethaddr` etc. We start
    # the first partition at 16 MiB (= LBA 0x8000) with margin.
    #
    # WARNING — known landmines this layout currently TRAMPLES (TODO v0.3.1):
    #   - stock `cert` partition at LBA 0x00b38000 (5.6 GiB into the disk):
    #     1 MiB of per-device RSA private key.
    #   - stock `presistdata` at LBA 0x00b3c000: 36 bytes of factory device
    #     identity data.
    # The rootfs partition below spans 16 MiB to ~13 GiB and overwrites both.
    # Preserving them needs a smaller rootfs.img (~5 GiB) so partitions can
    # be carved around the magic offsets. Until then, *do not onboard a
    # factory-pristine panel without first capturing /dev/mmcblk2p9 +
    # /dev/mmcblk2p12* — those bytes are otherwise unrecoverable.
    #
    # `0x...` hex sector arguments are silently parsed as 0 by sgdisk — use
    # MiB / GiB suffixes. Start=0 = first free sector after previous.
    ssh "$STAGING_HOST" "sgdisk --zap-all $UMS_DEV >/dev/null"
    ssh "$STAGING_HOST" "sgdisk \
        --disk-guid=00112233-4455-6677-8899-aabbccddeeff \
        -n 1:16M:+48M    -c 1:kernel      -t 1:8300 \
        -n 2:0:+48M      -c 2:kernel_bak  -t 2:8300 \
        -n 3:0:+4M       -c 3:dtb         -t 3:8300 \
        -n 4:0:+4M       -c 4:dtb_bak     -t 4:8300 \
        -n 5:0:+13G      -c 5:rootfs      -t 5:8300 \
        -n 6:0:0         -c 6:data        -t 6:8300 \
        $UMS_DEV >/dev/null"
    ssh "$STAGING_HOST" "blockdev --rereadpt $UMS_DEV; udevadm settle"
}

write_partitions_ums() {
    local k_idx=1 d_idx=3
    [[ "$SLOT" == "bak" ]] && k_idx=2 d_idx=4

    # Resolve partition device names — sg disks use /dev/sdX1, mmc would use p1.
    local kpart dpart rpart
    kpart="${UMS_DEV}${k_idx}"
    dpart="${UMS_DEV}${d_idx}"
    rpart="${UMS_DEV}5"
    if [[ "$UMS_DEV" == *[0-9] ]]; then
        kpart="${UMS_DEV}p${k_idx}"
        dpart="${UMS_DEV}p${d_idx}"
        rpart="${UMS_DEV}p5"
    fi
    echo "[+] writing kernel -> $kpart, dtb -> $dpart, rootfs -> $rpart"

    # Stream from runner -> staging host -> block device. dd of= runs on the
    # staging host; the runner pipes. rootfs may be a .zst — decompressed
    # on the fly so we never need 14 GB free locally.
    cat "$KERNEL" | ssh "$STAGING_HOST" "dd of=$kpart bs=1M conv=fsync status=none"
    cat "$DTB"    | ssh "$STAGING_HOST" "dd of=$dpart bs=1M conv=fsync status=none"
    echo "[+] streaming rootfs -> $rpart (this takes a few minutes)"
    bash -c "$ROOTFS_SRC_CMD" \
        | ssh "$STAGING_HOST" "dd of=$rpart bs=4M conv=fsync status=none"
}

wait_for_ssh() {
    echo "[+] panel rebooting; waiting for ssh"
    # We can't pre-filter by MAC: mainline-Linux on the panel doesn't program
    # the baked Polycom MAC into the FEC by default, so end0/lan can get
    # random locally-administered MACs. Instead, probe every IP that ARP'd
    # recently and accept the first one whose /proc/cmdline matches the flat
    # layout (`root=/dev/mmcblk2p5`). Reachable but mismatched IPs get
    # cached so we don't keep ssh'ing them on every iteration.
    #
    # Drop strict mode for the loop body — set -e + pipefail trip on any
    # ssh/sshpass non-zero exit (timeout, refused, wrong password, no host)
    # and those are EXPECTED while the panel reboots. The function returns
    # explicit status codes.
    set +e
    local tried=""
    local found=""
    local i
    # Ping-sweep the local /24 in the background each iteration so that a
    # freshly-DHCP'd panel actually shows up in the staging host's ARP. The
    # panel ARP'ing the gateway alone doesn't bring its entry into aibox's
    # cache; we need to send it a packet.
    for i in $(seq 1 90); do
        ssh "$STAGING_HOST" 'for o in $(seq 1 254); do (ping -c1 -W1 192.168.10.$o >/dev/null 2>&1 &); done; wait' 2>/dev/null
        sleep 2
        local ips
        ips="$(ssh "$STAGING_HOST" "ip neigh | grep -v fe80 | awk '/REACHABLE|STALE/ && \$1 ~ /^[0-9]/ {print \$1}'" 2>/dev/null | sort -u)"
        for ip in $ips; do
            case " $tried " in *" $ip "*) continue;; esac

            local cmdline
            cmdline="$(sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=3 \
                "root@$ip" 'cat /proc/cmdline 2>/dev/null' 2>/dev/null)"
            if [[ "$cmdline" == *"root=/dev/mmcblk2p5"* ]]; then
                echo "[+] flat-layout panel @ $ip"
                sshpass -p "$TC8_HOST_PASS" ssh -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
                    "root@$ip" 'cat /etc/tc8-version; uname -a; cat /proc/cmdline; df / | tail -1' 2>/dev/null
                found="$ip"
                break 2
            elif [[ -n "$cmdline" ]]; then
                # Reachable as root but not our panel — never recheck.
                tried="$tried $ip"
            fi
        done
    done
    set -e
    if [[ -n "$found" ]]; then
        echo "[OK] onboard complete: $found"
        return 0
    fi
    echo "ERROR: never reached a flat-layout panel on ssh" >&2
    return 2
}

write_stage2_ums() {
    # Raw-dd the unlock-FW stage-2 into the RESERVED pre-GPT gap (bytes
    # 8-16 MiB, untouched by the flat GPT whose first partition is at
    # 16 MiB). u-boot.bin -> LBA 0x4000 (16384); BMP blob -> LBA 0x5000
    # (20480). Stock bootcmd (install_env) chainloads `mmc read ...
    # 0x4000 0x830; go`. UMS is still open so $UMS_DEV is the whole eMMC.
    local s2sz s2nb blsz blnb rb
    s2sz=$(stat -c%s "$STAGE2"); s2nb=$(( (s2sz+511)/512 ))
    blsz=$(stat -c%s "$BMPBLOB"); blnb=$(( (blsz+511)/512 ))
    echo "[+] stage-2 u-boot.bin ($s2sz B) -> $UMS_DEV LBA 0x4000"
    cat "$STAGE2"  | ssh "$STAGING_HOST" "dd of=$UMS_DEV bs=512 seek=16384 conv=fsync status=none"
    echo "[+] bmp blob ($blsz B) -> $UMS_DEV LBA 0x5000"
    cat "$BMPBLOB" | ssh "$STAGING_HOST" "dd of=$UMS_DEV bs=512 seek=20480 conv=fsync status=none"
    ssh "$STAGING_HOST" "sync"
    rb=$(ssh "$STAGING_HOST" "dd if=$UMS_DEV bs=512 skip=16384 count=$s2nb 2>/dev/null | head -c $s2sz | md5sum | cut -d' ' -f1")
    [[ "$rb" == "$(md5sum "$STAGE2" | cut -d' ' -f1)" ]] || { echo "ERROR: stage-2 readback mismatch" >&2; exit 1; }
    rb=$(ssh "$STAGING_HOST" "dd if=$UMS_DEV bs=512 skip=20480 count=$blnb 2>/dev/null | head -c $blsz | md5sum | cut -d' ' -f1")
    [[ "$rb" == "$(md5sum "$BMPBLOB" | cut -d' ' -f1)" ]] || { echo "ERROR: bmp blob readback mismatch" >&2; exit 1; }
    echo "[+] unlock-FW stage-2 + blob verified in the reserved gap"
}

# ---- main ----
catch_uboot
install_env
ums_open
if [[ "$NO_REPARTITION" -ne 1 ]]; then
    preserve_magic_offsets
    write_gpt_ums
fi
write_partitions_ums
[[ "$STAGE2_ENABLED" -eq 1 ]] && write_stage2_ums
ums_close

echo "[+] reset"
ub_cmd "reset" 0.5 >/dev/null
wait_for_ssh
