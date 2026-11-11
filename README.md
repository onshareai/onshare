# onshare

**Policy-bound AI agent for tokenized stocks on Robinhood Chain — in your terminal.**

You set the rules. The agent proposes trades. A separate policy module checks every action before anything moves.

Website: [onshare.fun](https://onshare.fun) · X: [@onshareai](https://x.com/onshareai)

> **Status: MVP in development.** The CLI reads live market data from Robinhood Chain and runs the agent loop in `--dry-run` mode. It never sends transactions and never asks for a private key. Live execution opens at limited release.

---

## Install

Requires **Node.js 18+**.

```bash
npm install -g github:onshareai/onshare
onshare markets
```

Or run without installing:

```bash
npx github:onshareai/onshare markets
```

## Quick start

```bash
onshare markets                      # live Stock Token prices
onshare chart NVDA --tf 4h           # candlesticks in your terminal
onshare policy init                  # write onshare.policy.yaml
onshare check buy NVDA 1000 --hold 12
onshare portfolio init               # example holdings file
onshare run --dry-run                # run the agent loop, nothing is sent
```

## Commands

### Market data

Prices come straight from Chainlink price feeds on Robinhood Chain mainnet (chain ID 4663).

| Command | What it does |
|---|---|
| `onshare markets` | Live prices for all supported Stock Tokens |
| `onshare price <SYM>` | One price, plus feed and token addresses on Blockscout |
| `onshare watch [SYM...]` | Live ticker, refreshes every 10s |
| `onshare chart <SYM> [--tf 1h\|4h\|1d]` | Candlestick chart built from Chainlink oracle rounds |

Supported today: **NVDA, TSLA, AAPL**. More assets will be added once their feed addresses are verified.

### Policy

| Command | What it does |
|---|---|
| `onshare policy init` | Write `onshare.policy.yaml` with safe defaults |
| `onshare policy show` | Print the active policy |
| `onshare check <buy\|sell> <SYM> <USD> [--portfolio 10000] [--hold 12]` | Would the policy approve this trade? Exit code `0` = approved, `2` = rejected |

Default policy:

```yaml
max_alloc: 25        # % of portfolio per stock
drawdown: 10         # % from peak, then sell or hold only
health_factor: 1.5   # minimum loan health factor
daily_limit: 10      # % of portfolio traded per day
allowlist: [NVDA, TSLA, AAPL]
max_feed_age_hours: 72
```

### Agent

| Command | What it does |
|---|---|
| `onshare portfolio init` | Write an example `onshare.portfolio.json` (holdings in tokens) |
| `onshare run --dry-run [--every 900] [--once]` | Run the decision loop: read prices → evaluate → propose → policy check → simulate. Nothing is sent. |

Example cycle:

```
cycle 1 · block #31234695
✓ read            portfolio $8,799.41 · cash $2,500.00
→ propose         trim NVDA 36.5% → 25% (sell $879.94)
✓ policy check    passed
✓ simulated       sold 3.8328 NVDA @ $229.58 (dry-run, nothing sent)
✓ TSLA            16.2% ≤ 25%
✓ AAPL            18.9% ≤ 25%
```

## Configuration

| Variable | Purpose |
|---|---|
| `ONSHARE_RPC` | Your own Robinhood Chain RPC URL. The public endpoint is rate-limited; Alchemy, QuickNode and others offer free keys. |
| `NO_COLOR` | Disable colored output |

## Notes

- **Read-only.** The CLI only makes `eth_blockNumber` and `eth_call` requests.
- Chainlink Stock Token feeds follow US equity hours 24/5 and hold the last price when markets are closed.
- Candles are built from oracle updates (a new round on a price move or heartbeat), not from exchange trades.
- `onshare.portfolio.json` is git-ignored so your holdings stay local.

## Smart contracts

The on-chain policy lives in [`contracts/`](contracts): a smart account that lets the agent trade through an expiring session key, and reverts any trade that breaks `max_alloc`, `daily_limit`, `drawdown`, slippage or feed-age rules. The owner can pause the agent at any time. v0 is tested (42 tests, fuzz and invariant) but **not audited**, so use it on testnets only. See [contracts/README.md](contracts/README.md).

## Development

```bash
git clone https://github.com/onshareai/onshare
cd onshare
node bin/onshare.js help
npm test        # runs every command against a local mock RPC
```

No dependencies.
