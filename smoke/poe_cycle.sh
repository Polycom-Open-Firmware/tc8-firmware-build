#!/usr/bin/env bash
# Hard power-cycle a TL-SG108PE PoE port via the Auto Recovery side-channel.
#
# This firmware (TL-SG108PE v5, 1.0.0 Build 20230218 Rel.51358) exposes no
# direct PoE on/off CGI. Auto Recovery is the only knob that physically
# removes power from a port.
#
# Strategy for fast, reliable cycles:
#   1. Steady state: port is configured to ping the LAN gateway (alive),
#      with break=3, interval=10, retry=1, and global recovery ENABLED.
#      Pings succeed → no cycle. Port stays up.
#   2. Cycle:        flip the ping target to a black-hole IP (240.0.0.0/4 is
#      reserved + non-routable). Switch fails the next ping, drops the port
#      for `break` seconds, then re-powers. We then revert the ping target
#      back to the gateway so steady state resumes.
#
# Trigger latency: ~10-13 s (one missed ping interval).
# Off window: 3 s (break minimum).
#
# Usage:
#   poe_cycle.sh setup <port>        # one-time: configure port + arm globally
#   poe_cycle.sh cycle <port>        # trigger a single fast cycle (auto reverts)
#   poe_cycle.sh disarm              # disable global Auto Recovery
#   poe_cycle.sh status              # dump current config + stats
#
# env:
#   SW_HOST     switch IP        (default 192.168.10.243)
#   SW_USER     admin user       (default admin)
#   SW_PASS     admin password   (REQUIRED)
#   GATEWAY     reachable host   (default 192.168.0.1) — steady-state ping target
#   BLACKHOLE   unreachable IP   (default 240.0.0.1)   — trigger ping target
#   BREAK_SEC   off-window       (default 3, 3..120)
#   INTERVAL    ping interval    (default 10, 10..120)
#   STARTUP     startup delay    (default 30, 30..600) — applies on first arm only

set -euo pipefail

SW_HOST="${SW_HOST:-192.168.10.243}"
SW_USER="${SW_USER:-admin}"
SW_PASS="${SW_PASS:?set SW_PASS}"
GATEWAY="${GATEWAY:-192.168.0.1}"
BLACKHOLE="${BLACKHOLE:-240.0.0.1}"
BREAK_SEC="${BREAK_SEC:-3}"
INTERVAL="${INTERVAL:-10}"
STARTUP="${STARTUP:-30}"

base="http://${SW_HOST}"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

login() {
  curl -s -c "$JAR" -b "$JAR" \
    --data-urlencode "username=${SW_USER}" \
    --data-urlencode "password=${SW_PASS}" \
    --data "logon=Login" \
    "${base}/logon.cgi" >/dev/null
  local code
  code=$(curl -s -b "$JAR" -o /dev/null -w '%{http_code}' "${base}/SystemInfoRpm.htm")
  [[ "$code" == "200" ]] || { echo "login failed (HTTP $code)"; exit 2; }
}

dump_state() {
  curl -s -b "$JAR" "${base}/PoeRecoveryRpm.htm" \
    | tr '\n' ' ' \
    | grep -oE 'globalRecoveryConfig = \{[^}]*\}|portRecoveryConfig =\{[^}]*\}'
}

# POST per-port config (sel_<port>=1 picks target). status: 1=Disable, 2=Enable, 7=keep.
# CGI silently drops POSTs without a matching Referer header.
apply_port() {
  local port="$1" status="$2" ip="$3" startup="$4" interval="$5" retry="$6" brk="$7"
  local args=(-s -b "$JAR" -o /dev/null
              -H "Referer: ${base}/PoeRecoveryRpm.htm"
              --data "sel_${port}=1"
              --data "name_pIp=${ip}"
              --data "name_pStartup=${startup}"
              --data "name_pInterval=${interval}"
              --data "name_pRetry=${retry}"
              --data "name_pBreak=${brk}"
              --data "name_pStatus=${status}"
              --data "applay=Apply")
  curl "${args[@]}" "${base}/poe_recovery_port_config.cgi"
}

apply_global() {
  local enable="$1"
  curl -s -b "$JAR" -o /dev/null \
    -H "Referer: ${base}/PoeRecoveryRpm.htm" \
    --data "name_globalStatus=${enable}" \
    --data "poe_auto_recovery_global_config=Apply" \
    "${base}/poe_recovery_global_config.cgi"
}

validate_port() { [[ "$1" =~ ^[1-4]$ ]] || { echo "port must be 1..4"; exit 1; }; }

cmd="${1:-}"; shift || true

case "$cmd" in
  setup)
    PORT="${1:?port required}"; validate_port "$PORT"
    echo "[*] login ${SW_HOST}"; login
    echo "[*] sanity-checking gateway ${GATEWAY} from this host"
    ping -c1 -W1 "${GATEWAY}" >/dev/null \
      || { echo "WARN: gateway ${GATEWAY} not pingable from here — switch may not reach it either"; }
    echo "[*] configuring port ${PORT}: ip=${GATEWAY} startup=${STARTUP} interval=${INTERVAL} retry=1 break=${BREAK_SEC} status=Enable"
    apply_port "${PORT}" 2 "${GATEWAY}" "${STARTUP}" "${INTERVAL}" 1 "${BREAK_SEC}"
    apply_global 1
    echo "[*] steady state armed: port ${PORT} pings ${GATEWAY} every ${INTERVAL}s; recovery global=ON."
    echo "    Use 'cycle ${PORT}' to fire one quick power-cycle."
    ;;
  cycle)
    PORT="${1:?port required}"; validate_port "$PORT"
    echo "[*] login ${SW_HOST}"; login
    echo "[*] swapping ping target to blackhole ${BLACKHOLE} on port ${PORT}"
    apply_port "${PORT}" 7 "${BLACKHOLE}" "${STARTUP}" "${INTERVAL}" 1 "${BREAK_SEC}"
    # status=7 = leave enable bit alone; we only want to flip the IP. Settings
    # take effect on the next ping cycle (~INTERVAL seconds).
    revert_in=$((INTERVAL + 5))
    echo "[*] cycle armed. Drop expected within ~${INTERVAL}s, port off ${BREAK_SEC}s."
    echo "[*] waiting ${revert_in}s before reverting target to ${GATEWAY}..."
    sleep "${revert_in}"
    apply_port "${PORT}" 7 "${GATEWAY}" "${STARTUP}" "${INTERVAL}" 1 "${BREAK_SEC}"
    echo "[*] reverted. Port pings ${GATEWAY} again — no further cycles."
    ;;
  disarm)
    echo "[*] login ${SW_HOST}"; login
    apply_global 0
    echo "[*] global Auto Recovery disabled. Per-port config left as-is."
    ;;
  status)
    login
    dump_state
    ;;
  ""|-h|--help|help)
    sed -n '2,38p' "$0"
    ;;
  *)
    echo "unknown subcommand: $cmd" >&2; exit 1
    ;;
esac
