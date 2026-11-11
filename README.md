# onshare

**Policy-bound AI agent for tokenized stocks on Robinhood Chain — in your terminal.**

You set the rules. The agent proposes trades. A separate policy module checks every action before anything moves.

Website: [onshare.fun](https://onshare.fun) · X: [@onshareai](https://x.com/onshareai)

> **Status: MVP in development.** Market data and `--dry-run` are read-only. On-chain mode trades through an [OnshareAccount](contracts) with a limited session key; those contracts are **not audited yet**, so use a testnet, a local fork or the local stack below. On mainnet the CLI refuses on-chain commands unless you pass `--accept-unaudited`.

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

### Agent on-chain

The agent trades through an `OnshareAccount` smart account. It signs with a **session key**: a throwaway key that can only call `agentSwap`. The contract checks every trade (allowlist, max_alloc, daily_limit, drawdown, oracle slippage, feed age) and the owner can pause it at any time. The session key cannot withdraw, change the policy or call other contracts. **Never use your owner wallet key as the agent key.**

| Command | What it does |
|---|---|
| `onshare agent new` | Create a session key in `onshare.agent.key` (file mode 600, git-ignored) and print its address |
| `onshare agent show` | Print the session key's address |
| `onshare account <address>` | Read the account: owner, agent status, value, daily budget, policy, allocations |
| `onshare swap <buy\|sell> <SYM> <USD> --account <a> --adapter <b>` | One agent trade. Simulated on-chain first; asks before sending unless `--yes` |
| `onshare run --live --account <a> --adapter <b> [--every 900] [--once] [--yes]` | Agent loop: trims any stock above max_alloc, within the daily budget |

Setup:

1. The owner creates an account (see [contracts/README.md](contracts/README.md)).
2. `onshare agent new` prints the agent address. Send it a little ETH for gas.
3. The owner allowlists it: **Set agent** on [onshare.fun/dashboard.html](https://onshare.fun/dashboard.html), or `cast send <account> "setAgent(address,uint64)" <agent> <expiry>`.
4. `onshare run --live --account <account> --adapter <adapter>`

When the policy refuses a trade, the CLI says why before anything is sent:

```
$ onshare swap buy TSLA 5000 --account 0xA51c… --adapter 0x9A67… --yes
✓ price           $400.00 · chainlink
→ trade           pay 5000 USDG → TSLA
✕ policy check    DailyLimitExceeded · this trade would exceed today's daily_limit
```

#### Try it on a local chain

With [Foundry](https://book.getfoundry.sh) installed, this deploys mock tokens, feeds, a mock Uniswap router, the real adapter and an account with NVDA over its cap:

```bash
anvil &
export ONSHARE_RPC=http://127.0.0.1:8545
onshare agent new                                   # note the address
cast rpc anvil_setBalance <agent address> 0x56BC75E2D63100000 --rpc-url $ONSHARE_RPC
cd contracts && AGENT=<agent address> forge script script/LocalStack.s.sol --rpc-url $ONSHARE_RPC \
  --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 && cd ..
cat contracts/local-stack.json                      # account and adapter addresses
onshare account <account>
onshare run --live --once --account <account> --adapter <adapter>
```

The private key above is anvil's public test account. Never use it on a real network.

## Configuration

| Variable | Purpose |
|---|---|
| `ONSHARE_RPC` | RPC URL. Defaults to Robinhood Chain mainnet. The public endpoint is rate-limited; Alchemy, QuickNode and others offer free keys. |
| `ONSHARE_ACCOUNT` | Default `--account` |
| `ONSHARE_ADAPTER` | Default `--adapter` |
| `ONSHARE_AGENT_KEY` | Session key (otherwise read from `onshare.agent.key`) |
| `NO_COLOR` | Disable colored output |

## Notes

- **Market data and `--dry-run` are read-only.** They only make `eth_blockNumber` and `eth_call` requests. Only `swap` and `run --live` send transactions, and only with the session key.
- Chainlink Stock Token feeds follow US equity hours 24/5 and hold the last price when markets are closed.
- Candles are built from oracle updates (a new round on a price move or heartbeat), not from exchange trades.
- `onshare.portfolio.json` is git-ignored so your holdings stay local.

## Smart contracts

The on-chain policy lives in [`contracts/`](contracts): a smart account that lets the agent trade through an expiring session key, and reverts any trade that breaks `max_alloc`, `daily_limit`, `drawdown`, slippage or feed-age rules. The owner can pause the agent at any time. v0 is tested (55 unit, fuzz and invariant tests, plus mainnet fork tests against real Uniswap pools) but **not audited**, so use it on testnets only. See [contracts/README.md](contracts/README.md).

## Development

```bash
git clone --recurse-submodules https://github.com/onshareai/onshare
cd onshare
npm install
node bin/onshare.js help
npm test            # market data and dry-run commands against a mock RPC
npm run test:live   # on-chain commands end to end on anvil (needs Foundry)
```

One dependency: [viem](https://viem.sh), loaded only by the on-chain commands.
