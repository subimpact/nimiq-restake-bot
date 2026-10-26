# Nimiq Auto-Restake Bot

Production-proven auto-restake + watchdog toolkit for [Nimiq Albatross](https://nimiq.com) validators — the exact scripts running live on the **ImpactZero** validator ([NQ08 ACT8 T0FE PTG8 P5RL H2S3 QGXH V15R NVXY](https://nimiqwatch.com/validator/NQ08%20ACT8%20T0FE%20PTG8%20P5RL%20H2S3%20QGXH%20V15R%20NVXY)).

Runs a **0% fee**, fully transparent pool: every block reward is automatically compounded into each staker record, proportionally, every single minute. No keys on disk. No delegator action needed. Live stats are published on [nimiq.subimpact.net](https://nimiq.subimpact.net) — stake, shares, and the exact distribution formula, verifiable on-chain.

**Stake with ImpactZero** (0% commission, auto-compounding): delegate to `NQ08 ACT8 T0FE PTG8 P5RL H2S3 QGXH V15R NVXY` from Nimiq Pay or wallet.nimiq.com.

---

## What this repo contains

- **`restake-bot.sh`** — compounder: sweeps the validator reward address and re-stakes every reward to all stakers, proportional to their share, once per minute.
- **`watchdog.sh`** — resilience guard: restarts the node on panic/stall, auto-reactivates the validator on inactivity.
- **`nimiq-curl`** — optional RPC helper: runs the host `curl` inside the node container's network namespace (`nsenter -n`) instead of `docker exec nimiq curl`. A restake bot sending one tx per staker per minute otherwise makes dockerd spawn a runc process per call (we measured ~26/min, dockerd at ~60% of a core). Falls back to `docker exec` on any failure and logs it to `/root/nimiq-curl-fallback.log`. Needs root (`nsenter`) and a host `curl`.

## How restaking works

Every produced block pays one coinbase reward to the validator's **reward address**. The protocol does not split it per delegator — the bot does:

It reads the full staker ledger from the chain each cycle, computes each share, and issues `sendStakeTransaction` per staker (0% fee). Delegators see their **staked balance grow** automatically — coins stay in the staking contract until the delegator withdraws. Anyone can run this script for their own validator.

### Payout rule (`PRICING`)

Two rules are built in. Both pay every minute and stop paying a deactivated stake at once; they differ only in how stake that joins or grows mid-epoch is counted.

**`PRICING=current`** (default): split by each staker's live active balance:

```
share_i = live_i / validator_total x available
```

**`PRICING=election`**: split by the stake the protocol elected at the start of the epoch:

```
w_i     = min(stake_i in the epoch-start snapshot, live_i)
share_i = w_i / (sum(w) + validator deposit) x available
```

New or added stake earns from the next epoch, when the protocol's election counts it (validator slots are fixed at the election, so stake that arrives mid-epoch does not produce rewards until then). A staker who deactivates stops earning immediately and their share for the rest of that epoch goes to the stakers who remain. If the epoch-start snapshot is missing, the cycle is skipped and the rewards wait for the next one (fail-closed, never a guess).

Whichever rule pays, the bot computes both every cycle and writes one comparison row per epoch to `/root/validator-restake-shadow.jsonl` (totals under each rule plus every staker whose amount differs), so an operator can see the effect of a switch before making it.

**Switching at a named epoch (`ELECTION_FROM_EPOCH`)**: set it to an epoch number and the bot pays `current` until that epoch starts, then `election` from its first cycle on, with no restart or edit at the boundary. An explicit `PRICING` setting still wins. ImpactZero runs `ELECTION_FROM_EPOCH=1432`: election pricing from epoch 1432 (27 October 2026), as announced in its wallet listing.

Shares are integer-floored per staker; the unpaid remainder stays in the wallet and is swept in the next cycle.

### Safety features

- **Fail-closed sentinel** — unexpected inbound transfers to the reward address (not coinbase, not the staking contract) are held and flagged, never distributed.
- **Retry wrapper** — transient public-RPC failures are retried once before conceding a cycle (E2BIG gotcha: never pass the RPC response through an environment variable; pipe it via stdin — env caps at 128 KB once a producing validator's history grows).
- **Pay every staker** — every staker receives their proportional share each cycle, however small; only a share that integer-floor rounds to zero is skipped.
- **Reserve** — 0 by default (Nimiq tx fees are 0 today, so every last luna restakes); set `RESERVE > 0` for a wallet safety floor.
- **Lock file** — `flock` prevents overlapping cycles.
- **Epoch stake snapshot**: at the first cycle of each epoch, before any payout, the bot appends every staker's active and inactive balance to `/root/validator-stake-snapshots.jsonl`: an auditable record of stake at election time, and the input for `PRICING=election`.
- **Dry run**: `DRYRUN=1` prints what each staker would receive and sends nothing, writes no live state. Add `DRY_BAL=<luna>` to simulate a fixed reward balance (the live bot empties the wallet every minute, so a dry run usually sees nothing to pay otherwise).

## Requirements

- Nimiq node (`ghcr.io/nimiq/core-rs-albatross:latest`) with the validator imported & unlocked (null passphrase per runbook — the node signs internally; **no key files needed by the restake bot**)
- `curl`, `python3`, `flock`, cron
- Public RPC (`https://rpc.nimiqwatch.com`) or a self-hosted archive endpoint for sentinel history

## Install

```bash
# 1. Copy scripts to the node host
install -m 0755 restake-bot.sh /root/validator-restake.sh
install -m 0755 watchdog.sh /root/validator-watchdog.sh

# 2. Watchdog needs the fee+signing keys to reactivate (chmod 600, never commit)
#    Create /root/.validator-keys.conf:
#      FEE_KEY="<your fee key hex>"
#      SIGN_KEY="<your signing key hex>"

# 3. Cron (root)
crontab -l | { cat; echo "*/2 * * * * /root/validator-watchdog.sh >/dev/null 2>&1"; echo "* * * * * /root/validator-restake.sh >/dev/null 2>&1"; } | crontab -

# 4. Optional: exec-free RPC (recommended once you have many stakers)
install -m 0755 nimiq-curl /root/nimiq-curl
#    then prefix both cron commands with RPC_CURL=/root/nimiq-curl, e.g.
#    * * * * * RPC_CURL=/root/nimiq-curl /root/validator-restake.sh >/dev/null 2>&1
```

## Configuration (top of `restake-bot.sh`)

| Var | Default | Meaning |
|---|---|---|
| `RPC` | `http://127.0.0.1:8648` | local node RPC |
| `RPC_CURL` | `docker exec nimiq curl` | command used to reach `RPC`; set `/root/nimiq-curl` for the exec-free path (also read by `watchdog.sh`) |
| `PUB_RPC` | `https://rpc.nimiqwatch.com` | public RPC for history (sentinel) |
| `VALIDATOR` | ImpactZero address | your validator address |
| `COINBASE` / `CONTRACT` | protocol constants | hold-sentinel filters |
| `MIN_TRIGGER` | 2000 (0.02 NIM) | minimum wallet balance to bother |
| `RESERVE` | 0 | optional wallet safety floor (luna) |
| `HOLD_SINCE` | `61600000` | sentinel lookback start block |
| `PRICING` | `current` | payout rule: `current` (live balance) or `election` (epoch-start stake, capped at live) |
| `ELECTION_FROM_EPOCH` | `0` | switch to `election` automatically from this epoch on (`0` = off; ignored when `PRICING` is set) |
| `DRYRUN` | `0` | `1` = print shares only, no transactions, no state writes |

## Changelog / lessons learned

- **v2.8**: `ELECTION_FROM_EPOCH` gate: switch the payout rule to `election` at a named epoch, so the switch lands exactly on an epoch boundary. ImpactZero switched at epoch 1432.
- **v2.7**: payout rule is selectable: `PRICING=current` (default, unchanged behaviour) or `PRICING=election`. Both rules are computed every cycle and compared per epoch in a shadow ledger. The epoch stake snapshot is now taken before that epoch's first payout (new `lag_blocks` field). `DRYRUN=1` mode for safe testing.
- **v2.5**: epoch-boundary stake snapshot (`/root/validator-stake-snapshots.jsonl`) for an auditable record of election-time stake.
- **v2.6** — optional exec-free RPC: `RPC_CURL` setting (default `docker exec nimiq curl`, unchanged behaviour) plus the `nimiq-curl` nsenter helper. One `docker exec` per RPC call made dockerd spawn ~26 runc processes a minute on a 19-staker pool; the helper removes them without touching the node container.
- **v2.3** — sentinel reads RPC JSON via stdin, not an environment variable. Fixes `E2BIG` (exit 126) that silently halts the sentinel once a producing validator's tx history exceeds ~128 KB.
- **v2.2** — retry wrapper: 2 attempts, 3s apart before fail-closed.
- **v2.0** — hold sentinel for accidental sends.

## License

MIT — do what you like, but if this helps you run a Nimiq pool, stake at ImpactZero 😉
