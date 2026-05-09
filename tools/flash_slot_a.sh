#!/usr/bin/env bash
# flash_slot_a.sh — flash canonical TC8 v0.2 firmware to slot_a from a running v0.2 on slot_b.
#
# WHAT THIS DOES
#   Pushes boot/dtbo/system/vbmeta from the WSL host to the panel (over ssh/scp),
#   sha256-verifies on the panel, then dd's each image to its slot_a partition.
#   slot_b is never touched.
#
# WHAT THIS DESTROYS
#   The Polycom stock Android currently sitting in slot_a partitions is overwritten.
#   You will NOT be able to boot back into stock from slot_a after this runs unless you
#   restore from the emmc.img backup (see RECOVERY below).
#
# RECOVERY (READ BEFORE RUNNING)
#   - slot_b stays untouched. If slot_a flash goes bad, you can still boot slot_b (the
#     v0.2 you're currently running) — that's your safety net during this operation.
#   - Full eMMC backup at aibox:/var/lib/vz/dump/tc8-backup/emmc.img is the universal
#     restore. To recover stock_a, dd the byte-ranges per
#     /home/alex/polycom_re/re/firmware/tc8-slim-v0.2/RECOVERY.md back into the
#     mmcblk2p* _a partitions from u-boot fastboot or NFS-root rescue.
#   - boota mmc1 _a is broken on mainline (see feedback_nxp_boota_quirks); to actually
#     boot into a freshly flashed slot_a, set u-boot env BOOT_A_ATTEMPTS / slot=a or use
#     `bootm` with explicit addresses. This script does NOT switch the active slot.
#
# PARTITION MAP (slot_a only — slot_b columns shown for reference, NEVER touched here)
#   boot_a    /dev/mmcblk2p3      boot_b   /dev/mmcblk2p4
#   dtbo_a    /dev/mmcblk2p1      dtbo_b   /dev/mmcblk2p2
#   system_a  /dev/mmcblk2p5      system_b /dev/mmcblk2p6
#   vbmeta_a  /dev/mmcblk2p17     vbmeta_b /dev/mmcblk2p18
#
# USAGE
#   flash_slot_a.sh --yes-destroy-stock [--host IP] [--user root] [--ssh-alias tc8] [--force-reflash]
#
# DEPENDS
#   ssh, scp, sha256sum on host; sha256sum, dd, sync on panel.

set -euo pipefail

# ---------- defaults ----------
ARTIFACT_DIR="/home/alex/polycom_re/re/firmware/tc8-slim-v0.2"
SSH_ALIAS_DEFAULT="tc8"   # used for "ssh tc8 ..." style; if --host is given it wins
PANEL_USER_DEFAULT="root"
PANEL_HOST=""             # autodetect via aibox arp if empty
SSH_ALIAS="${SSH_ALIAS_DEFAULT}"
PANEL_USER="${PANEL_USER_DEFAULT}"
CONFIRM=0
FORCE=0

# canonical artifacts (name : partition : expected-size : expected-sha256)
declare -a ARTIFACTS=(
  "boot.img:/dev/mmcblk2p3:50331648:31d5f41010bce9f69bea4954c933efa539955da2db91aadde5e68d2ec04b5522"
  "dtbo.img:/dev/mmcblk2p1:4194304:653633fad630de3c14fcece0fb5cb430bfffa517336a7768f6952cfb1a4c02e7"
  "system.img:/dev/mmcblk2p5:1879048192:84af1c66711b43cd494903427c26731a620a766774c049999568b31793480844"
  "vbmeta.img:/dev/mmcblk2p17:1048576:33022be48fbee2576e98b7debb035378acf0b7215e7c24061a337200234d2a1c"
)

# ---------- output helpers ----------
RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; CYA=$'\033[1;36m'; RST=$'\033[0m'
log()   { printf '%s[+]%s %s\n' "$CYA" "$RST" "$*"; }
ok()    { printf '%s[OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[!!]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()   { printf '%s[XX]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
flash_slot_a.sh — flash canonical TC8 v0.2 to slot_a (DESTROYS stock Android on slot_a)

USAGE
  flash_slot_a.sh --yes-destroy-stock [options]

REQUIRED
  --yes-destroy-stock     Acknowledge that slot_a stock Polycom Android will be wiped.
                          Without this flag the script aborts before doing anything.

OPTIONS
  --host IP               Panel IP (default: autodetect via 'ssh aibox ip neigh' for
                          MAC prefix 00:e0:db). Falls back to ssh alias '${SSH_ALIAS_DEFAULT}'.
  --user USER             Panel ssh user (default: ${PANEL_USER_DEFAULT})
  --ssh-alias NAME        Use this ssh config alias instead of host+user (default: ${SSH_ALIAS_DEFAULT})
  --force-reflash         Re-dd even if the slot_a partition already matches the artifact
                          sha256 (idempotency-bypass).
  -h, --help              Show this help.

ENVIRONMENT
  TC8_HOST                Same as --host
  TC8_SSH_ALIAS           Same as --ssh-alias

WHAT IT WRITES (slot_a only)
  boot.img    -> /dev/mmcblk2p3
  dtbo.img    -> /dev/mmcblk2p1
  system.img  -> /dev/mmcblk2p5
  vbmeta.img  -> /dev/mmcblk2p17

WHAT IT DOES NOT TOUCH
  slot_b: /dev/mmcblk2p{4,2,6,18}  — your running v0.2 stays intact.

RECOVERY
  - slot_b is the live fallback during the flash.
  - emmc.img backup on aibox:/var/lib/vz/dump/tc8-backup/emmc.img + RECOVERY.md
    in the firmware dir restores stock_a byte-for-byte.
EOF
}

# ---------- arg parse ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes-destroy-stock) CONFIRM=1; shift;;
    --host) PANEL_HOST="$2"; shift 2;;
    --user) PANEL_USER="$2"; shift 2;;
    --ssh-alias) SSH_ALIAS="$2"; shift 2;;
    --force-reflash) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown arg: $1 (try --help)";;
  esac
done

# env fallbacks
[[ -z "$PANEL_HOST" && -n "${TC8_HOST:-}" ]] && PANEL_HOST="$TC8_HOST"
[[ -n "${TC8_SSH_ALIAS:-}" ]] && SSH_ALIAS="$TC8_SSH_ALIAS"

# ---------- target selection ----------
# Prefer explicit host (root@IP); else use ssh alias which already encodes user/key.
ssh_target() {
  if [[ -n "$PANEL_HOST" ]]; then
    printf '%s@%s' "$PANEL_USER" "$PANEL_HOST"
  else
    printf '%s' "$SSH_ALIAS"
  fi
}
scp_target() { ssh_target; }

panel_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$(ssh_target)" "$@"; }
panel_scp() { scp -o BatchMode=yes -o ConnectTimeout=5 "$@"; }

# ---------- big red warning ----------
big_warning() {
  cat <<EOF
${RED}========================================================================${RST}
${RED}  DESTRUCTIVE OPERATION: flashing slot_a will OVERWRITE stock Polycom${RST}
${RED}  Android partitions on /dev/mmcblk2p{1,3,5,17}.${RST}
${RED}                                                                        ${RST}
${RED}  After this runs you cannot boot stock_a unless you restore from${RST}
${RED}  the aibox emmc.img backup (see RECOVERY.md).${RST}
${RED}                                                                        ${RST}
${RED}  slot_b (your running v0.2) will NOT be touched.${RST}
${RED}========================================================================${RST}
EOF
}

countdown() {
  local n="${1:-5}"
  printf '%s' "${YEL}Proceeding in:${RST} "
  while [[ $n -gt 0 ]]; do
    printf '%d... ' "$n"
    sleep 1
    n=$((n - 1))
  done
  printf '\n'
}

# ---------- preflight ----------
preflight_confirm() {
  big_warning
  if [[ $CONFIRM -ne 1 ]]; then
    die "missing --yes-destroy-stock; refusing to flash. Re-run with that flag."
  fi
  warn "Confirmation flag present. Last chance to Ctrl-C."
  countdown 5
}

autodetect_host() {
  [[ -n "$PANEL_HOST" ]] && return 0
  # We try the ssh alias first (user has it configured per memory).
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_ALIAS" true 2>/dev/null; then
    log "ssh alias '$SSH_ALIAS' is reachable; using it."
    return 0
  fi
  warn "ssh alias '$SSH_ALIAS' unreachable; trying aibox arp scan for 00:e0:db..."
  local ip
  ip="$(ssh -o BatchMode=yes aibox "ip neigh | awk '/00:e0:db/ {print \$1; exit}'" 2>/dev/null || true)"
  [[ -z "$ip" ]] && die "could not autodetect panel IP. Pass --host explicitly."
  PANEL_HOST="$ip"
  log "autodetected panel at $PANEL_HOST"
}

verify_panel_v02() {
  log "verifying panel reachable + running v0.2..."
  local uname
  uname="$(panel_ssh 'uname -a' 2>&1)" || die "panel ssh failed: $uname"
  log "panel uname: $uname"
  # v0.2 mainline kernel is 6.x — stock is 4.9. Refuse to flash from stock.
  if echo "$uname" | grep -qE 'Linux .* 4\.9\.'; then
    die "panel appears to be running stock 4.9 kernel — refuse to flash slot_a from stock. Boot v0.2 on slot_b first."
  fi
  if ! echo "$uname" | grep -qE 'Linux .* 6\.'; then
    warn "panel kernel is not 6.x; got: $uname"
    warn "this may not be a v0.2 panel — aborting for safety."
    die "kernel sanity check failed"
  fi
  ok "panel running 6.x kernel — assumed v0.2."

  # Confirm slot_b is the active root by checking /proc/cmdline
  local cmdline
  cmdline="$(panel_ssh 'cat /proc/cmdline' 2>/dev/null || true)"
  log "panel cmdline: $cmdline"
  # Best-effort: warn if root looks like slot_a (mmcblk2p5)
  if echo "$cmdline" | grep -qE 'root=[^ ]*mmcblk2p5\b'; then
    warn "panel cmdline says root=mmcblk2p5 (slot_a). We are about to overwrite the live root!"
    die "refusing to flash slot_a while it is the active root"
  fi
}

verify_local_artifacts() {
  log "verifying local artifacts in $ARTIFACT_DIR..."
  local entry name part size sha
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name part size sha <<<"$entry"
    local p="$ARTIFACT_DIR/$name"
    [[ -f "$p" ]] || die "missing artifact: $p"
    local actual_size
    actual_size="$(stat -c%s "$p")"
    [[ "$actual_size" == "$size" ]] || die "$name size mismatch: have $actual_size want $size"
    local actual_sha
    actual_sha="$(sha256sum "$p" | awk '{print $1}')"
    [[ "$actual_sha" == "$sha" ]] || die "$name sha256 mismatch: have $actual_sha want $sha"
    ok "$name OK ($size B, sha256 ${sha:0:12}...)"
  done
}

# ---------- transfer + verify ----------
push_artifacts() {
  log "scp'ing artifacts to panel /tmp/..."
  local entry name _rest
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name _rest <<<"$entry"
    panel_scp "$ARTIFACT_DIR/$name" "$(scp_target):/tmp/$name"
    ok "pushed $name"
  done
}

panel_verify_artifacts() {
  log "sha256-verifying artifacts on panel..."
  local entry name part size sha out
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name part size sha <<<"$entry"
    out="$(panel_ssh "sha256sum /tmp/$name" | awk '{print $1}')"
    [[ "$out" == "$sha" ]] || die "panel-side sha mismatch for $name: $out != $sha"
    ok "panel /tmp/$name sha256 OK"
  done
}

# ---------- partition cross-check ----------
# read the first $size bytes of partition and sha256 them
panel_partition_sha() {
  local part="$1" size="$2"
  panel_ssh "dd if=$part bs=1M count=\$(( ($size + 1048575) / 1048576 )) iflag=fullblock status=none | head -c $size | sha256sum" \
    | awk '{print $1}'
}

already_flashed() {
  local part="$1" size="$2" sha="$3"
  local cur
  cur="$(panel_partition_sha "$part" "$size")"
  [[ "$cur" == "$sha" ]]
}

# ---------- flash ----------
flash_one() {
  local name="$1" part="$2" size="$3" sha="$4"
  log "flashing $name -> $part ..."
  if [[ $FORCE -ne 1 ]]; then
    if already_flashed "$part" "$size" "$sha"; then
      ok "$part already matches $name (sha256 ${sha:0:12}...) — skipping"
      return 0
    fi
  fi
  panel_ssh "dd if=/tmp/$name of=$part bs=1M conv=fsync status=none && sync"
  ok "dd'd $name to $part"
}

verify_flashed() {
  log "post-flash sha256 cross-check..."
  local entry name part size sha cur
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name part size sha <<<"$entry"
    cur="$(panel_partition_sha "$part" "$size")"
    if [[ "$cur" != "$sha" ]]; then
      die "$part sha256 mismatch after flash: $cur != $sha"
    fi
    ok "$part matches $name (${sha:0:12}...)"
  done
}

cleanup_panel_tmp() {
  log "cleaning up /tmp on panel..."
  panel_ssh 'rm -f /tmp/boot.img /tmp/dtbo.img /tmp/system.img /tmp/vbmeta.img' || true
}

print_next_steps() {
  cat <<EOF

${GRN}=== slot_a flash complete ===${RST}
Next steps (NOT performed by this script):
  - To boot slot_a you must change the active boot slot. boota mmc1 _a is broken on
    mainline (see feedback_nxp_boota_quirks). Likely paths:
      * From u-boot:  setenv slot a; saveenv; reset
      * Or use 'bootm' with explicit \$loadaddr against /dev/mmcblk2p3
  - Verify slot_a really boots before destroying anything else.
  - slot_b is still your safety net — leave it alone until slot_a is proven.
EOF
}

# ---------- main ----------
main() {
  preflight_confirm
  verify_local_artifacts
  autodetect_host
  log "panel target: $(ssh_target)"
  verify_panel_v02

  push_artifacts
  panel_verify_artifacts

  local entry name part size sha
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name part size sha <<<"$entry"
    flash_one "$name" "$part" "$size" "$sha"
  done
  panel_ssh 'sync; sync'

  verify_flashed
  cleanup_panel_tmp
  print_next_steps
}

main "$@"
