#!/usr/bin/env bash
# flash_slot_b.sh — flash TC8 firmware to slot_b from a running v0.2 on slot_a (or NFS-root).
#
# Mirror of flash_slot_a.sh: pushes boot/dtbo/system/vbmeta from build host to the panel,
# sha256-verifies on the panel, then dd's each image to its slot_b partition.
# slot_a is never touched.
#
# PARTITION MAP (slot_b only)
#   boot_b    /dev/mmcblk2p4
#   dtbo_b    /dev/mmcblk2p2
#   system_b  /dev/mmcblk2p6
#   vbmeta_b  /dev/mmcblk2p18
#
# USAGE
#   flash_slot_b.sh --yes-destroy --artifacts DIR [--host IP] [--user root] [--ssh-alias tc8] [--force-reflash]

set -euo pipefail

# ---------- defaults ----------
ARTIFACT_DIR="${TC8_ARTIFACT_DIR:-./out}"
SSH_ALIAS_DEFAULT="tc8"
PANEL_USER_DEFAULT="root"
PANEL_HOST=""
SSH_ALIAS="${SSH_ALIAS_DEFAULT}"
PANEL_USER="${PANEL_USER_DEFAULT}"
CONFIRM=0
FORCE=0

# (name : partition : expected-size). sha256 is computed at runtime from local files
# since this slot can hold arbitrary user-built firmware.
declare -a ARTIFACTS=(
  "boot.img:/dev/mmcblk2p4:50331648"
  "dtbo.img:/dev/mmcblk2p2:4194304"
  "system.img:/dev/mmcblk2p6:1879048192"
  "vbmeta.img:/dev/mmcblk2p18:1048576"
)

RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; CYA=$'\033[1;36m'; RST=$'\033[0m'
log()   { printf '%s[+]%s %s\n' "$CYA" "$RST" "$*"; }
ok()    { printf '%s[OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s[!!]%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()   { printf '%s[XX]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
flash_slot_b.sh — flash TC8 firmware to slot_b (DESTROYS whatever currently lives on slot_b)

USAGE
  flash_slot_b.sh --yes-destroy --artifacts DIR [options]

REQUIRED
  --yes-destroy           Acknowledge slot_b will be wiped.
  --artifacts DIR         Directory containing boot.img/dtbo.img/system.img/vbmeta.img.
                          (or set TC8_ARTIFACT_DIR; default ./out)

OPTIONS
  --host IP               Panel IP (otherwise ssh alias)
  --user USER             Panel ssh user (default: root)
  --ssh-alias NAME        ssh config alias (default: tc8)
  --force-reflash         Re-dd even if partition already matches.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes-destroy) CONFIRM=1; shift;;
    --artifacts) ARTIFACT_DIR="$2"; shift 2;;
    --host) PANEL_HOST="$2"; shift 2;;
    --user) PANEL_USER="$2"; shift 2;;
    --ssh-alias) SSH_ALIAS="$2"; shift 2;;
    --force-reflash) FORCE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown arg: $1 (try --help)";;
  esac
done

[[ -z "$PANEL_HOST" && -n "${TC8_HOST:-}" ]] && PANEL_HOST="$TC8_HOST"
[[ -n "${TC8_SSH_ALIAS:-}" ]] && SSH_ALIAS="$TC8_SSH_ALIAS"

ssh_target() {
  if [[ -n "$PANEL_HOST" ]]; then printf '%s@%s' "$PANEL_USER" "$PANEL_HOST"; else printf '%s' "$SSH_ALIAS"; fi
}
panel_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$(ssh_target)" "$@"; }
panel_scp() { scp -o BatchMode=yes -o ConnectTimeout=5 "$@"; }

big_warning() {
  cat <<EOF
${RED}========================================================================${RST}
${RED}  DESTRUCTIVE OPERATION: flashing slot_b will OVERWRITE current slot_b${RST}
${RED}  contents on /dev/mmcblk2p{2,4,6,18}.${RST}
${RED}                                                                        ${RST}
${RED}  slot_a will NOT be touched.${RST}
${RED}========================================================================${RST}
EOF
}

countdown() {
  local n="${1:-5}"
  printf '%s' "${YEL}Proceeding in:${RST} "
  while [[ $n -gt 0 ]]; do printf '%d... ' "$n"; sleep 1; n=$((n-1)); done
  printf '\n'
}

preflight_confirm() {
  big_warning
  [[ $CONFIRM -eq 1 ]] || die "missing --yes-destroy; refusing to flash."
  warn "Confirmation flag present. Last chance to Ctrl-C."
  countdown 5
}

verify_local_artifacts() {
  log "verifying local artifacts in $ARTIFACT_DIR..."
  local entry name part size
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name part size <<<"$entry"
    local p="$ARTIFACT_DIR/$name"
    [[ -f "$p" ]] || die "missing artifact: $p"
    local actual_size
    actual_size="$(stat -c%s "$p")"
    [[ "$actual_size" == "$size" ]] || die "$name size mismatch: have $actual_size want $size"
    ok "$name OK ($actual_size B)"
  done
}

verify_panel_alive() {
  log "verifying panel reachable..."
  local uname
  uname="$(panel_ssh 'uname -a' 2>&1)" || die "panel ssh failed: $uname"
  log "panel uname: $uname"
  local cmdline
  cmdline="$(panel_ssh 'cat /proc/cmdline' 2>/dev/null || true)"
  log "panel cmdline: $cmdline"
  if echo "$cmdline" | grep -qE 'root=[^ ]*mmcblk2p6\b'; then
    die "panel cmdline says root=mmcblk2p6 (slot_b). Refusing to flash slot_b while it is the active root."
  fi
}

push_artifacts() {
  log "scp'ing artifacts to panel /tmp/..."
  local entry name _rest
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name _rest <<<"$entry"
    panel_scp "$ARTIFACT_DIR/$name" "$(ssh_target):/tmp/$name"
    ok "pushed $name"
  done
}

panel_verify_artifacts() {
  log "sha256-verifying artifacts on panel match local..."
  local entry name _rest local_sha panel_sha
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name _rest <<<"$entry"
    local_sha="$(sha256sum "$ARTIFACT_DIR/$name" | awk '{print $1}')"
    panel_sha="$(panel_ssh "sha256sum /tmp/$name" | awk '{print $1}')"
    [[ "$local_sha" == "$panel_sha" ]] || die "transfer mismatch for $name: $local_sha != $panel_sha"
    ok "$name transferred OK (${local_sha:0:12}...)"
  done
}

panel_partition_sha() {
  local part="$1" size="$2"
  panel_ssh "dd if=$part bs=1M count=\$(( ($size + 1048575) / 1048576 )) iflag=fullblock status=none | head -c $size | sha256sum" \
    | awk '{print $1}'
}

flash_one() {
  local name="$1" part="$2" size="$3"
  local local_sha
  local_sha="$(sha256sum "$ARTIFACT_DIR/$name" | awk '{print $1}')"
  log "flashing $name -> $part (sha ${local_sha:0:12}...)"
  if [[ $FORCE -ne 1 ]]; then
    local cur
    cur="$(panel_partition_sha "$part" "$size")"
    if [[ "$cur" == "$local_sha" ]]; then
      ok "$part already matches $name — skipping"
      return 0
    fi
  fi
  panel_ssh "dd if=/tmp/$name of=$part bs=1M conv=fsync status=none && sync"
  ok "dd'd $name to $part"
}

verify_flashed() {
  log "post-flash sha256 cross-check..."
  local entry name part size local_sha cur
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name part size <<<"$entry"
    local_sha="$(sha256sum "$ARTIFACT_DIR/$name" | awk '{print $1}')"
    cur="$(panel_partition_sha "$part" "$size")"
    [[ "$cur" == "$local_sha" ]] || die "$part sha256 mismatch after flash: $cur != $local_sha"
    ok "$part matches $name (${local_sha:0:12}...)"
  done
}

cleanup_panel_tmp() {
  log "cleaning up /tmp on panel..."
  panel_ssh 'rm -f /tmp/boot.img /tmp/dtbo.img /tmp/system.img /tmp/vbmeta.img' || true
}

main() {
  preflight_confirm
  verify_local_artifacts
  log "panel target: $(ssh_target)"
  verify_panel_alive
  push_artifacts
  panel_verify_artifacts
  local entry name part size
  for entry in "${ARTIFACTS[@]}"; do
    IFS=: read -r name part size <<<"$entry"
    flash_one "$name" "$part" "$size"
  done
  panel_ssh 'sync; sync'
  verify_flashed
  cleanup_panel_tmp
  ok "slot_b flash complete. slot_a untouched."
}

main "$@"
