# Onshare contracts

On-chain policy for the Onshare agent. An `OnshareAccount` holds tokenized stocks for one owner and lets an AI agent trade them through a limited, expiring session key. Every agent trade is checked by the contract itself, before and after it executes. If any rule fails, the whole transaction reverts.

> **Status: v0, not audited.** Use on testnets and local chains only. Do not deposit real funds until the contracts have been audited.

## What the policy enforces

| Rule | Default | What happens |
|---|---|---|
| `allowlist` | owner-defined | Only listed Stock Tokens, the quote token and allowlisted swap adapters |
| `max_alloc` | 25% | A buy that leaves one stock above 25% of the portfolio reverts |
| `daily_limit` | 10% | Agent volume per UTC day is capped at 10% of portfolio value |
| `drawdown` | 10% from peak | Below it, the agent may only sell into the quote token |
| `slippage` | 1% | Output must be within 1% of the Chainlink oracle price |
| `feed age` | 72 hours | Older prices are rejected (stock feeds pause on weekends) |
| `kill switch` | always | `pause()` stops the agent and revokes its session key |

The owner keeps full control and is never blocked by the policy: deposit, withdraw, change limits, rotate the agent key or pause at any time. The agent can only call `agentSwap`. It cannot withdraw, change settings, approve tokens or call other contracts.

Each swap is measured by real balance changes, not by what the swap venue reports. The approval to the venue is set to the exact amount and cleared after the swap.

## Contracts

| File | Purpose |
|---|---|
| `src/OnshareAccount.sol` | The policy-bound smart account |
| `src/OnshareAccountFactory.sol` | Deploys one account per owner at a predictable CREATE2 address |
| `src/interfaces/IExternal.sol` | ERC-20, Chainlink feed and swap adapter interfaces |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/onshareai/onshare
cd onshare/contracts
forge build
forge test
```

The suite has 42 tests: unit tests for every rule, fuzz tests (1,000 runs each) and invariant tests (128 runs × 64 calls) that drive the account with random trades, price moves and time jumps. Line coverage of `OnshareAccount.sol` is about 97%.

Invariants checked:

- the agent's daily volume never exceeds the daily limit
- no token approval is ever left open to a swap venue
- the agent can never change the owner, its own key, the policy or the adapter list

## Try it locally

Run a full trade on a local chain with mock tokens, feeds and a mock swap venue:

```bash
anvil &
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

The key is anvil's public test account. Never use it on a real network.

Expected output:

```
agent bought NVDA (wei): 2492500000000000000
NVDA allocation (bps):   498
daily budget left (USD): 500
oversized trade rejected: DailyLimitExceeded
```

## Deploy to a testnet

```bash
export ROBINHOOD_RPC_URL=<testnet RPC URL>
export QUOTE_TOKEN=<quote token address>
export ASSET_TOKENS=<NVDA>,<TSLA>,<AAPL>
export ASSET_FEEDS=<NVDA feed>,<TSLA feed>,<AAPL feed>
export AGENT=<agent session key address>    # optional
export ADAPTER=<swap adapter address>       # optional

cast wallet import deployer --interactive   # stores your key encrypted, never in a file
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --account deployer
```

## Not in v0

- ERC-4337 `validateUserOp` (the agent currently sends normal transactions with its session key)
- Lending module and the `health_factor` rule
- A production swap adapter for a Robinhood Chain venue
- Independent security audit

## License

MIT
