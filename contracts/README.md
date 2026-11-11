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
| `src/adapters/UniswapV3Adapter.sol` | Swaps through Uniswap v3 (SwapRouter02) along owner-set routes |
| `src/interfaces/IExternal.sol` | ERC-20, Chainlink feed and swap adapter interfaces |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recurse-submodules https://github.com/onshareai/onshare
cd onshare/contracts
forge build
forge test
```

The suite has 55 tests plus 5 mainnet fork tests: unit tests for every rule, fuzz tests (1,000 runs each) and invariant tests (128 runs × 64 calls) that drive the account with random trades, price moves and time jumps. Line coverage of `OnshareAccount.sol` is about 97%.

Invariants checked:

- the agent's daily volume never exceeds the daily limit
- no token approval is ever left open to a swap venue
- the agent can never change the owner, its own key, the policy or the adapter list

## Uniswap v3 adapter

Uniswap holds almost all Stock Token liquidity on Robinhood Chain, so the first production venue is Uniswap v3. The adapter pulls exactly the approved amount, swaps along a route the adapter owner configured (direct pool or multi-hop), sends the output straight to the account and clears its router approval. It never holds funds between calls.

A wrong route cannot cost the account more than its oracle slippage bound: the account measures what it actually received and reverts if it is more than 1% below the Chainlink price.

Robinhood Chain mainnet (chain 4663) addresses used by the adapter and the fork tests:

| Contract | Address | Source |
|---|---|---|
| Uniswap SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` | Uniswap `sdk-core` |
| Uniswap v3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | Uniswap `sdk-core` |
| Uniswap QuoterV2 | `0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7` | Uniswap `sdk-core` |
| USDG (6 decimals) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | Paxos docs |

Always confirm addresses on the [explorer](https://robinhoodchain.blockscout.com) before deploying.

## Mainnet fork tests

`test/fork/RobinhoodFork.t.sol` runs the account and the adapter against a local fork of Robinhood Chain mainnet: real USDG, real NVDA/TSLA/AAPL Stock Tokens, real Chainlink feeds and real Uniswap v3 pools. Balances exist only inside the fork, so no real funds are used.

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path "test/fork/*" -vv
```

For each stock it finds the deepest USDG v3 pool, quotes a $100 buy and then:

- if the pool is within 1% of Chainlink, the agent buys and sells half back, and the test checks balances and approvals
- if the pool is further than 1% away, the test checks that the policy refuses the trade
- if the pair has no v3 pool (it may trade only on Uniswap v4), the test is skipped with a note

Without `ROBINHOOD_RPC_URL` the fork tests are skipped. GitHub Actions runs them on every push and on weekday mornings.

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
export UNISWAP_ROUTER=0xCaf681a66D020601342297493863E78C959E5cb2   # deploys a UniswapV3Adapter
export ROUTE_FEES=500,500,500               # v3 fee tier per asset, check the pools first

cast wallet import deployer --interactive   # stores your key encrypted, never in a file
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --account deployer
```

## Not in v0

- ERC-4337 `validateUserOp` (the agent currently sends normal transactions with its session key)
- Lending module and the `health_factor` rule
- A Uniswap v4 adapter (much of the Stock Token liquidity is on v4)
- Independent security audit

## License

MIT
