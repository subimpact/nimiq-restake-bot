#!/bin/bash
# v2.8 - 2026-10-26: ELECTION_FROM_EPOCH gate. Election pricing starts by itself at the first cycle of epoch N; earlier epochs keep current pricing. An explicit PRICING env still wins. 0 = gate off (default here; ImpactZero runs 1432).
# ImpactZero restake bot v2.7 - 2026-10-22 (v2.7: PRICING=current|election; election = weight min(epoch-start snapshot, current active), new/added stake earns from the next election; epoch snapshot now taken BEFORE distribution; per-epoch shadow comparison in /root/validator-restake-shadow.jsonl. DRYRUN=1 = no sends, no state writes, prints to stdout.)
# v2.5 - 2026-10-05 (v2.5: epoch-boundary stake snapshot jsonl for election-stake transparency; v2.4: sentinel falls back to LOCAL node history when public RPC blips; epoch-boundary failures were burning 1-2 cycles/min)
# Cron every 1 min. Distributes NQ08 reward balance into staker records
# (0% fee, proportional). Logs + raises flag for Hermes bridge.
#
# v2 added a HOLD SENTINEL for accidental sends (inbound to NQ08 that is NOT the
# coinbase reward address and NOT the staking contract = presumed mis-send; held +
# flagged for review; fail-closed on history outages).
# v2.1: hash-first hold-flag content (bridge dedupes on it) + fail-closed now also
# raises the alert flag so a silent skip is never invisible.
# Pure RPC — the node's imported/unlocked NQ08 wallet signs internally. No key files.
PRICING_ENV=${PRICING:-}       # an explicit PRICING env overrides the epoch gate below
PRICING=${PRICING:-current}   # current = split by live active balance (v2.5 policy)
                              # election = split by min(epoch-start snapshot, live active)
ELECTION_FROM_EPOCH=${ELECTION_FROM_EPOCH:-0}   # v2.8: election pricing from this epoch on (0 = off)
DRYRUN=${DRYRUN:-0}
if [ "$DRYRUN" = 1 ]; then
  exec 9>/tmp/validator-restake-dryrun.lock
  flock -n 9 || exit 0
  LOG=/dev/stderr; FLAG=/dev/null; HOLD_FLAG=/dev/null
  HOLD_LEDGER=/root/validator-restake-hold.ledger   # read-only in dry run
else
  exec 9>/tmp/validator-restake.lock
  flock -n 9 || exit 0
  LOG=/root/validator-restake.log
  FLAG=/root/validator-restake-flag
  HOLD_FLAG=/root/validator-restake-hold-flag
  HOLD_LEDGER=/root/validator-restake-hold.ledger
fi
SNAP_FILE=/root/validator-stake-snapshots.jsonl
SHADOW_STATE=/root/validator-restake-shadow.state.json
SHADOW_LOG=/root/validator-restake-shadow.jsonl
if [ "$DRYRUN" = 1 ]; then   # dry run never touches live state; test inputs may be injected
  SNAP_FILE=${DRY_SNAP_FILE:-$SNAP_FILE}
  SHADOW_STATE=${DRY_SHADOW_STATE:-/tmp/restake-dry-shadow.state.json}
  SHADOW_LOG=${DRY_SHADOW_LOG:-/tmp/restake-dry-shadow.jsonl}
fi
RPC='http://127.0.0.1:8648'
# How to reach the node RPC (127.0.0.1 inside the container). Default: `docker exec`.
# On busy hosts set RPC_CURL=/path/to/nimiq-curl (shipped in this repo): host curl via
# nsenter into the container's netns, no runc spawn per call, falls back to docker exec.
RPC_CURL=${RPC_CURL:-docker exec nimiq curl}
PUB_RPC='https://rpc.nimiqwatch.com'
VALIDATOR='NQ08 ACT8 T0FE PTG8 P5RL H2S3 QGXH V15R NVXY'
COINBASE='NQ81 C01N BASE 0000 0000 0000 0000 0000 0000'
CONTRACT='NQ77 0000 0000 0000 0000 0000 0000 0000 0000'
MIN_TRIGGER=2000        # Lunas (0.02 NIM) total balance to bother
RESERVE=0               # no wallet floor: tx fees are 0 on Nimiq today; the
                        # payout loop sends only computed shares, so every
                        # last luna restakes (set >0 to keep a safety floor)
# Sentinel is forward-looking only: ignore inbound txs before this block so the
# Sep 11 100k NQ27->NQ08 deposit (blk 61301883) and older history never qualify.
HOLD_SINCE=61600000
TS() { date -u +%Y-%m-%dT%H:%M:%SZ; }
[ "$DRYRUN" = 1 ] || rm -f "$FLAG"

h() { $RPC_CURL -s -m 8 -X POST "$RPC" -H 'Content-Type: application/json' -d "$1" 2>/dev/null; }

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
if [ -n "$NEW" ] && [ "$DRYRUN" = 1 ]; then
  echo "DRY sentinel would hold: $NEW"
elif [ -n "$NEW" ]; then
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

# 1. Chain state first: head, validator total, staker ledger (one read, used by the
#    snapshot AND the payout so both see the same ledger).
HEAD=$(h '{"jsonrpc":"2.0","id":1,"method":"getBlockNumber","params":[]}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["data"])' 2>/dev/null)
[ -z "$HEAD" ] && exit 0
EP=$(( (HEAD - 1) / 43200 - 79 ))
if [ -z "$PRICING_ENV" ] && [ "$ELECTION_FROM_EPOCH" -gt 0 ] 2>/dev/null && [ "$EP" -ge "$ELECTION_FROM_EPOCH" ]; then
  PRICING=election   # v2.8 gate: the named switch epoch has started
fi
TOTAL=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getValidatorByAddress\",\"params\":[\"$VALIDATOR\"]}" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["result"]["data"]["balance"]))' 2>/dev/null)
[ -z "$TOTAL" ] || [ "$TOTAL" -le 0 ] && exit 0
RAW=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getStakersByValidatorAddress\",\"params\":[\"$VALIDATOR\"]}")
echo "$RAW" | python3 -c 'import json,sys; json.load(sys.stdin)["result"]["data"]' >/dev/null 2>&1 || exit 0

# 2. Epoch-boundary stake snapshot (v2.5 audit trail; v2.7 also the election weights).
# Taken BEFORE any payout of the new epoch. lag_blocks = blocks after the epoch's first
# block: stake that landed inside that lag is treated as elected (bounded by one cycle).
EP_LAST=$(tail -n 1 "$SNAP_FILE" 2>/dev/null | grep -oE '"epoch": ?[0-9]+' | grep -oE '[0-9]+' || echo 0)
[ -z "$EP_LAST" ] && EP_LAST=0
if [ "$EP" -gt "$EP_LAST" ] 2>/dev/null; then
  LAG=$(( HEAD - ((EP + 79) * 43200 + 1) ))
  SNAPROW=$(echo "$RAW" | HEAD="$HEAD" EP="$EP" TOTAL="$TOTAL" LAG="$LAG" TS_TS="$(TS)" python3 -c '
import json, os, sys
rows = json.load(sys.stdin)["result"]["data"]
out = {"epoch": int(os.environ["EP"]), "head_block": int(os.environ["HEAD"]),
       "total": int(os.environ["TOTAL"]), "ts_utc": os.environ["TS_TS"], "lag_blocks": int(os.environ["LAG"]),
       "stakers": [{"address": r["address"].replace(" ", ""), "balance": int(r["balance"]),
                    "inactive": int(r.get("inactiveBalance", 0))}
                   for r in rows]}
print(json.dumps(out))
' 2>>"$LOG")
  if [ -n "$SNAPROW" ]; then
    if [ "$DRYRUN" = 1 ]; then
      echo "DRY snapshot: would append epoch $EP head=$HEAD lag=$LAG"
      T=$(mktemp); cat "$SNAP_FILE" > "$T"; echo "$SNAPROW" >> "$T"; SNAP_FILE=$T
    else
      echo "$SNAPROW" >> "$SNAP_FILE"
      echo "$(TS) snapshot: epoch $EP head=$HEAD lag=$LAG total=$TOTAL appended (prev=$EP_LAST)" >> "$LOG"
    fi
  fi
fi

# 3. Reward balance at NQ08
BAL=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountByAddress\",\"params\":[\"$VALIDATOR\"]}" | python3 -c 'import json,sys; d=json.load(sys.stdin)["result"]["data"]; print(int(d["balance"]) if d else 0)' 2>/dev/null)
[ "$DRYRUN" = 1 ] && [ -n "${DRY_BAL:-}" ] && BAL=$DRY_BAL   # test-only fixed jar
[ -z "$BAL" ] && exit 0
[ "$BAL" -lt "$MIN_TRIGGER" ] && exit 0
AVAIL=$((BAL - RESERVE - HELD))
[ "$AVAIL" -le 0 ] && exit 0

# 4. Shares. Both rules are computed every cycle; PRICING picks the one that is paid,
# the other is accumulated per epoch into the shadow ledger for comparison.
#   current : share_i = live_i * AVAIL / TOTAL                       (v2.5 policy)
#   election: share_i = w_i * AVAIL / (sum(w) + deposit), w_i = min(snapshot_i at epoch start, live_i)
#             deposit = TOTAL - sum(live) (the validator's own stake, elected like any other);
#             a staker absent from the snapshot (joined this epoch) has w = 0 until the next election.
# Integer floor on every share; the unpaid remainder stays in the wallet for the next sweep.
SHARES=$(echo "$RAW" | MODE="$PRICING" EP="$EP" AVAIL="$AVAIL" TOTAL="$TOTAL" SNAP_FILE="$SNAP_FILE" \
  SHADOW_STATE="$SHADOW_STATE" SHADOW_LOG="$SHADOW_LOG" DRYRUN="$DRYRUN" TS_TS="$(TS)" python3 -c '
import json, os, sys
E = os.environ
rows = json.load(sys.stdin)["result"]["data"]
ep, avail, total = int(E["EP"]), int(E["AVAIL"]), int(E["TOTAL"])
live = {r["address"].replace(" ", ""): int(r["balance"]) for r in rows}
order = [r["address"].replace(" ", "") for r in rows]
snap = None
try:
    for line in open(E["SNAP_FILE"]):
        line = line.strip()
        if line:
            row = json.loads(line)
            if row.get("epoch") == ep:
                snap = {s["address"]: int(s["balance"]) for s in row["stakers"]}
except OSError:
    pass
cur = {a: live[a] * avail // total for a in order}
elec = None
if snap is not None:
    w = {a: min(snap.get(a, 0), live[a]) for a in order}
    deposit = max(total - sum(live.values()), 0)
    den = sum(w.values()) + deposit
    if den > 0:
        elec = {a: w[a] * avail // den for a in order}
if E["MODE"] == "election":
    if elec is None:
        print("NOSNAP")
        sys.exit(0)
    pay, other = elec, cur
else:
    pay, other = cur, elec
for a in order:
    if pay[a] > 0:
        print(a, pay[a])
# shadow ledger: per-epoch sums of both rules, one summary row when the epoch rolls
if E["DRYRUN"] == "1" and elec is not None:
    diffs = {a: [cur[a], elec[a]] for a in order if cur[a] != elec[a]}
    print("DRY shadow", json.dumps({"epoch": ep, "avail": avail, "sum_current": sum(cur.values()),
          "sum_election": sum(elec.values()), "differs": diffs}), file=sys.stderr)
st_path, log_path = E["SHADOW_STATE"], E["SHADOW_LOG"]
try:
    st = json.load(open(st_path))
except Exception:
    st = None
if st and st.get("epoch") != ep:
    out = {"epoch": st["epoch"], "cycles": st["cycles"], "closed_ts": E["TS_TS"],
           "paid_rule": st.get("mode"), "nosnap_cycles": st.get("nosnap", 0),
           "sum_current": sum(st["cur"].values()), "sum_election": sum(st["elec"].values()),
           "per_staker": {a: {"current": st["cur"].get(a, 0), "election": st["elec"].get(a, 0)}
                          for a in sorted(set(st["cur"]) | set(st["elec"]))
                          if st["cur"].get(a, 0) != st["elec"].get(a, 0)}}
    with open(log_path, "a") as f:
        f.write(json.dumps(out) + "\n")
    st = None
if not st:
    st = {"epoch": ep, "mode": E["MODE"], "cycles": 0, "nosnap": 0, "cur": {}, "elec": {}}
st["cycles"] += 1
for a in order:
    st["cur"][a] = st["cur"].get(a, 0) + cur[a]
if elec is None:
    st["nosnap"] += 1
else:
    for a in order:
        st["elec"][a] = st["elec"].get(a, 0) + elec[a]
tmp = st_path + ".tmp"
json.dump(st, open(tmp, "w"))
os.replace(tmp, st_path)
' 2>>"$LOG")
if [ "$SHARES" = "NOSNAP" ]; then
  # election pricing without the epoch snapshot would be a guess: hold the jar (fail-closed).
  echo "$(TS) election pricing: no snapshot for epoch $EP - cycle skipped, rewards wait" >> "$LOG"
  echo "election-nosnap epoch $EP - cycle skipped, rewards held" > "$FLAG"
  exit 0
fi

# 5. Send one add-stake per staker share. Every staker with a non-zero share is paid
# every cycle; only a share that floors to 0 is skipped.
while read -r ADDR SHARE; do
  [ -z "$ADDR" ] && continue
  [ "$SHARE" -le 0 ] 2>/dev/null && continue
  if [ "$DRYRUN" = 1 ]; then
    echo "DRY would restake $SHARE lunas -> $ADDR"
    continue
  fi
  R=$(h "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendStakeTransaction\",\"params\":[\"$VALIDATOR\",\"$ADDR\",$SHARE,0,\"+0\"]}")
  echo "$(TS) restaked $SHARE lunas -> $ADDR: $R" >> "$LOG"
done <<< "$SHARES"
echo "$(TS) restake-cycle done (bal=$BAL avail=$AVAIL held=$HELD total=$TOTAL pricing=$PRICING)" >> "$LOG"
[ "$DRYRUN" = 1 ] || echo "restake-cycle" > "$FLAG"
exit 0
