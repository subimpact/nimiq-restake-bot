#!/bin/bash
# Validator watchdog — ImpactZero (v1.1, 2026-09-17; keys externalized to /root/.validator-keys.conf chmod 600)
# Runs every 2 min via cron. Acts on: container down, node panics, head stall, validator inactive.
# Every action logs to /root/validator-watchdog.log and raises /root/validator-watchdog-flag for the Hermes reporter.
exec 9>/tmp/validator-watchdog.lock
flock -n 9 || exit 0

LOG=/root/validator-watchdog.log
FLAG=/root/validator-watchdog-flag
VALIDATOR="NQ08 ACT8 T0FE PTG8 P5RL H2S3 QGXH V15R NVXY"
RPC='http://127.0.0.1:8648'
# How to reach the node RPC (127.0.0.1 inside the container). Default: `docker exec`.
# On busy hosts set RPC_CURL=/path/to/nimiq-curl (shipped in this repo): host curl via
# nsenter into the container's netns, no runc spawn per call, falls back to docker exec.
RPC_CURL=${RPC_CURL:-docker exec nimiq curl}
[ -f /root/.validator-keys.conf ] && . /root/.validator-keys.conf
TS() { date -u +%Y-%m-%dT%H:%M:%SZ; }
rm -f "$FLAG"

# --- [1] container up? ---
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx nimiq; then
  echo "$(TS) CONTAINER DOWN, starting" >> "$LOG"
  docker start nimiq >> "$LOG" 2>&1
  echo "$(TS) container-down" > "$FLAG"
  exit 0
fi

# small helper: RPC ok?
rpc_ok() {
  $RPC_CURL -s -m 8 -X POST "$RPC" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getBlockNumber","params":[]}' 2>/dev/null | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["data"])' 2>/dev/null
}

# --- [2] panics in last 6 minutes? ---
P=$(docker logs --since 6m nimiq 2>/dev/null | grep -c "panicked at")
if [ "${P:-0}" -gt 0 ]; then
  echo "$(TS) $P panic(s) detected, restarting container" >> "$LOG"
  docker restart nimiq >> "$LOG" 2>&1
  echo "$(TS) panic-restart" > "$FLAG"
  exit 0
fi

# --- [3] head advancing? (two samples ~30s apart; skip if RPC not ready) ---
H1=$(rpc_ok); [ -z "$H1" ] && exit 0
sleep 30
H2=$(rpc_ok); [ -z "$H2" ] && exit 0
if [ "$H2" -le "$H1" ]; then
  echo "$(TS) head stalled ($H1 -> $H2), restarting container" >> "$LOG"
  docker restart nimiq >> "$LOG" 2>&1
  echo "$(TS) head-stall" > "$FLAG"
  exit 0
fi

# --- [4] validator inactive? (reactivate, with 10-min cooldown) ---
ST=$($RPC_CURL -s -m 8 -X POST "$RPC" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getValidatorByAddress","params":["NQ08 ACT8 T0FE PTG8 P5RL H2S3 QGXH V15R NVXY"]}' 2>/dev/null | \
  python3 -c 'import json,sys; d=json.load(sys.stdin)["result"]["data"]; print("INACTIVE" if d.get("inactivityFlag") is not None else "ACTIVE")' 2>/dev/null)
if [ "$ST" = "INACTIVE" ]; then
  if [ -f /root/.last-reactivate ] && [ $(( $(date +%s) - $(cat /root/.last-reactivate) )) -lt 600 ]; then
    echo "$(TS) INACTIVE seen, reactivation skipped (cooldown)" >> "$LOG"
    exit 0
  fi
  H=$(rpc_ok)
  [ -z "$H" ] && exit 0
  TX=$(docker exec nimiq nimiq-mktx validator reactivate "$FEE_KEY" "$VALIDATOR" "$SIGN_KEY" -f 0 -V "$H" 2>/dev/null)
  if [ -n "$TX" ]; then
    R=$($RPC_CURL -s -m 15 -X POST "$RPC" -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendRawTransaction\",\"params\":[\"$TX\"]}")
    echo "$(TS) INACTIVE -> reactivate sent at height $H: $R" >> "$LOG"
    echo "$(TS) reactivated" > "$FLAG"
    date +%s > /root/.last-reactivate
  else
    echo "$(TS) INACTIVE but mktx failed" >> "$LOG"
    echo "$(TS) reactivate-failed" > "$FLAG"
  fi
fi
exit 0
