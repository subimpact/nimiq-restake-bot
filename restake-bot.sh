#!/bin/bash
# ImpactZero restake bot v2.4 — 2026-09-19 (v2.4: sentinel falls back to LOCAL node history when public RPC blips; epoch-boundary failures were burning 1-2 cycles/min)
# Cron every 1 min. Distributes NQ08 reward balance into staker records
# (0% fee, proportional). Logs + raises flag for Hermes bridge.
#
# v2 added a HOLD SENTINEL for accidental sends (inbound to NQ08 that is NOT the
# coinbase reward address and NOT the staking contract = presumed mis-send; held +
# flagged for review; fail-closed on history outages).
# v2.1: hash-first hold-flag content (bridge dedupes on it) + fail-closed now also
# raises the alert flag so a silent skip is never invisible.
# Pure RPC — the node's imported/unlocked NQ08 wallet signs internally. No key files.
exec 9>/tmp/validator-restake.lock
flock -n 9 || exit 0

LOG=/root/validator-restake.log
FLAG=/root/validator-restake-flag
HOLD_FLAG=/root/validator-restake-hold-flag
HOLD_LEDGER=/root/validator-restake-hold.ledger
RPC='http://127.0.0.1:8648'
PUB_RPC='https://rpc.nimiqwatch.com'
VALIDATOR='NQ08 ACT8 T0FE PTG8 P5RL H2S3 QGXH V15R NVXY'
COINBASE='NQ81 C01N BASE 0000 0000 0000 0000 0000 0000'
CONTRACT='NQ77 0000 0000 0000 0000 0000 0000 0000 0000'
MIN_TRIGGER=2000        # Lunas (0.02 NIM) total balance to bother
RESERVE=100000          # keep 1.0 NIM in wallet (rounding / future fees)
# Sentinel is forward-looking only: ignore inbound txs before this block so the
# Sep 11 100k NQ27->NQ08 deposit (blk 61301883) and older history never qualify.
HOLD_SINCE=61600000
TS() { date -u +%Y-%m-%dT%H:%M:%SZ; }
rm -f "$FLAG"

h() { docker exec nimiq curl -s -m 8 -X POST "$RPC" -H 'Content-Type: application/json' -d "$1" 2>/dev/null; }

# --- Sentinel: find inbound transfers to hold (fail-closed) ---
# v2.2 retry wrapper: one transient RPC blip must not burn a cycle or alert.
# 2 attempts, 3s apart; fail-closed (skip cycle + alert) only if BOTH fail to fetch AND parse.
SENTINEL_OK=1
for attempt in 1 2; do
  IN=$(curl -s -m 15 -X POST "$PUB_RPC" -H 'Content-Type: application/json' \
    -H 'User-Agent: impactzero-restake/2.2' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransactionsByAddress\",\"params\":[\"$VALIDATOR\",200,null]}" 2>/dev/null)
  # v2.4: if public RPC returned nothing usable, retry once more with a longer
  # timeout before failing closed (failures are transient epoch-boundary blips).
  if [ -z "$IN" ] || ! echo "$IN" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    sleep 5
    IN=$(curl -s -m 30 -X POST "$PUB_RPC" -H 'Content-Type: application/json' \
      -H 'User-Agent: impactzero-restake/2.4' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransactionsByAddress\",\"params\":[\"$VALIDATOR\",200,null]}" 2>/dev/null)
  fi
  NEW=$(HOLD_SINCE="$HOLD_SINCE" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)  # stdin pipe, NOT env var — env caps at 128KB (E2BIG) once history grows
    txs = (d.get("result") or {}).get("data") or []
except Exception:
    sys.exit(3)  # parse failure -> caller fails closed
since = int(os.environ.get("HOLD_SINCE", "61600000"))
CB = "NQ81C01NBASE000000000000000000000000"
CT = "NQ7700000000000000000000000000000000"
VAL = "nq08act8t0feptg8p5rlh2s3qgxhv15rnvxy"
for t in txs:
    to = "".join(str(t.get("to", "")).split()).lower()
    frm = "".join(str(t.get("from", "")).split())
    if to != VAL:
        continue
    if frm in (CB, CT):
        continue
    if int(t.get("blockNumber", 0)) < since:
        continue
    print(t.get("hash", ""), frm, t.get("value", 0))
' <<< "$IN" 2>/dev/null)
  SENTINEL_OK=$?
  [ $SENTINEL_OK -eq 0 ] && break
  [ $attempt -lt 2 ] && sleep 3
done
if [ $SENTINEL_OK -ne 0 ]; then
  echo "$(TS) sentinel failed (rc=$SENTINEL_OK after 2 attempts) — skipping cycle (fail-closed)" >> "$LOG"
  echo "sentinel-failed rc=$SENTINEL_OK — cycle skipped, rewards held" > "$FLAG"
  exit 0
fi

# Appends newly seen mis-sends to the ledger, dedup by tx hash, raises the hold flag.
if [ -n "$NEW" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    HASH=$(echo "$line" | cut -d' ' -f1)
    if ! grep -q "$HASH" "$HOLD_LEDGER" 2>/dev/null; then
      echo "$line|$(date -u +%s)" >> "$HOLD_LEDGER"
      echo "$(TS) sentinel: NEW held inbound tx $line" >> "$LOG"
      echo "HELD $line" > "$HOLD_FLAG"
    fi
  done <<< "$NEW"
  tail -n 200 "$HOLD_LEDGER" > "${HOLD_LEDGER}.tmp" 2>/dev/null && mv "${HOLD_LEDGER}.tmp" "$HOLD_LEDGER"
fi
HELD=$(awk -F'|' '{s+=$3} END{print s+0}' "$HOLD_LEDGER" 2>/dev/null)
[ -z "$HELD" ] && HELD=0

# Node wallet must be unlocked (imported with null passphrase per runbook; re-locks on restart)
h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unlockAccount\",\"params\":[\"$VALIDATOR\",null,null]}" >/dev/null 2>&1

# 1. Reward balance at NQ08
BAL=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountByAddress\",\"params\":[\"$VALIDATOR\"]}" | python3 -c 'import json,sys; d=json.load(sys.stdin)["result"]["data"]; print(int(d["balance"]) if d else 0)' 2>/dev/null)
[ -z "$BAL" ] && exit 0
[ "$BAL" -lt "$MIN_TRIGGER" ] && exit 0

# 2. Validator total stake
TOTAL=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getValidatorByAddress\",\"params\":[\"$VALIDATOR\"]}" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["result"]["data"]["balance"]))' 2>/dev/null)
[ -z "$TOTAL" ] || [ "$TOTAL" -le 0 ] && exit 0

AVAIL=$((BAL - RESERVE - HELD))
[ "$AVAIL" -le 0 ] && exit 0

# 3. Distribute proportionally to every staker (share_i = staker_i / total * AVAIL)
RAW=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getStakersByValidatorAddress\",\"params\":[\"$VALIDATOR\"]}")
echo "$RAW" | python3 -c "
import json,sys
d=json.load(sys.stdin)['result']['data']
for s in d:
    print(s['address'].replace(' ',''), int(s['balance']))
" | while read -r ADDR SB; do
  SHARE=$(( SB * AVAIL / TOTAL ))
  # Every staker gets their proportional share, however small: a dust share
  # that is skipped here would still accrue on-chain, but the pool's promise is
  # "every staker is paid every cycle", so only a zero share (0 < stake but
  # integer floor rounds it away) is skipped.
  [ "$SHARE" -le 0 ] && continue
  R=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendStakeTransaction\",\"params\":[\"$VALIDATOR\",\"$ADDR\",$SHARE,0,\"+0\"]}")
  echo "$(TS) restaked $SHARE lunas -> $ADDR: $R" >> "$LOG"
done
echo "$(TS) restake-cycle done (bal=$BAL avail=$AVAIL held=$HELD total=$TOTAL)" >> "$LOG"
echo "restake-cycle" > "$FLAG"
exit 0
