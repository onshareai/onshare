// On-chain mode: read an OnshareAccount and send agent trades with a session key.
// The session key can only call agentSwap; the contract enforces every policy rule.
import fs from 'node:fs';
import readline from 'node:readline/promises';
import {
  createPublicClient, createWalletClient, http, parseAbi, defineChain, isAddress, getAddress,
  decodeErrorResult, BaseError, ContractFunctionRevertedError, formatUnits,
} from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { c, sym, usd, line } from './ui.js';
import { CHAIN_ID, EXPLORER } from './chain.js';

export const KEY_FILE = 'onshare.agent.key';
const DEFAULT_RPC = 'https://rpc.mainnet.chain.robinhood.com';
const BPS = 10_000n;

export const ACCOUNT_ABI = parseAbi([
  'function owner() view returns (address)',
  'function agent() view returns (address)',
  'function agentExpiry() view returns (uint64)',
  'function paused() view returns (bool)',
  'function agentActive() view returns (bool)',
  'function policy() view returns (uint16 maxAllocBps, uint16 dailyLimitBps, uint16 drawdownBps, uint16 maxSlippageBps, uint32 maxFeedAge)',
  'function quoteToken() view returns (address)',
  'function quoteFeed() view returns (address)',
  'function assetCount() view returns (uint256)',
  'function assetList(uint256) view returns (address)',
  'function assets(address) view returns (address feed, uint8 tokenDecimals, uint8 feedDecimals, bool listed)',
  'function adapters(address) view returns (bool)',
  'function portfolioValue() view returns (uint256)',
  'function allocationBps(address) view returns (uint256)',
  'function dailyRemaining() view returns (uint256)',
  'function dayVolume() view returns (uint256)',
  'function peakValue() view returns (uint256)',
  'function agentSwap(address adapter, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) returns (uint256)',
  'event AgentSwap(address indexed adapter, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 tradeValueUsd, uint256 portfolioValueAfter)',
  'error NotOwner()', 'error NotAgent()', 'error AgentExpired()', 'error IsPaused()', 'error Reentrancy()',
  'error AssetNotListed(address token)', 'error AdapterNotAllowed(address adapter)', 'error SameToken()', 'error ZeroAmount()',
  'error StalePrice(address feed, uint256 updatedAt)', 'error InvalidPrice(address feed)',
  'error MaxAllocExceeded(address token, uint256 allocBps, uint256 maxBps)',
  'error DailyLimitExceeded(uint256 volumeAfter, uint256 limit)',
  'error DrawdownSellOnly(uint256 value, uint256 peak)',
  'error SlippageTooHigh(uint256 minAmountOut, uint256 minAcceptable)',
  'error InsufficientOutput(uint256 received, uint256 minAmountOut)',
  'error OverSpent(uint256 spent, uint256 amountIn)', 'error TokenCallFailed(address token)',
]);
const ERC20_ABI = parseAbi(['function symbol() view returns (string)', 'function decimals() view returns (uint8)', 'function balanceOf(address) view returns (uint256)']);
const FEED_ABI = parseAbi(['function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)', 'function decimals() view returns (uint8)']);

// Plain-language explanations for policy reverts.
const WHY = {
  NotAgent: 'this key is not the account\'s agent (ask the owner to run setAgent)',
  AgentExpired: 'the session key has expired (the owner must set a new one)',
  IsPaused: 'the owner paused the agent (kill switch is on)',
  AssetNotListed: 'token is not on the account allowlist',
  AdapterNotAllowed: 'swap adapter is not allowlisted on this account',
  StalePrice: 'Chainlink price is older than the policy allows',
  InvalidPrice: 'Chainlink returned an invalid price',
  MaxAllocExceeded: 'this buy would put the stock over max_alloc',
  DailyLimitExceeded: 'this trade would exceed today\'s daily_limit',
  DrawdownSellOnly: 'portfolio is in drawdown: only sells into the quote token are allowed',
  SlippageTooHigh: 'minimum output is below the oracle slippage bound',
  InsufficientOutput: 'the pool would pay less than the oracle bound allows',
};

// ---------------------------------------------------------------- clients

export async function clients({ needKey = false, keyFile } = {}) {
  const rpc = process.env.ONSHARE_RPC || DEFAULT_RPC;
  const probe = createPublicClient({ transport: http(rpc) });
  const chainId = await probe.getChainId();
  const chain = defineChain({
    id: chainId,
    name: chainId === CHAIN_ID ? 'Robinhood Chain' : `chain ${chainId}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const pub = createPublicClient({ chain, transport: http(rpc) });
  if (!needKey) return { pub, chain, chainId };
  const pk = loadKey(keyFile);
  const agent = privateKeyToAccount(pk);
  const wallet = createWalletClient({ account: agent, chain, transport: http(rpc) });
  return { pub, wallet, agent, chain, chainId };
}

function loadKey(keyFile) {
  let k = process.env.ONSHARE_AGENT_KEY;
  const file = keyFile || KEY_FILE;
  if (!k && fs.existsSync(file)) k = fs.readFileSync(file, 'utf8').trim();
  if (!k) throw new Error(`no agent session key. Run "onshare agent new", or set ONSHARE_AGENT_KEY.`);
  if (!/^0x[0-9a-fA-F]{64}$/.test(k)) throw new Error('agent key must be a 0x-prefixed 32-byte hex string');
  return k;
}

export function newAgentKey(force) {
  if (fs.existsSync(KEY_FILE) && !force) throw new Error(`${KEY_FILE} already exists (use --force to replace it)`);
  const pk = generatePrivateKey();
  fs.writeFileSync(KEY_FILE, pk + '\n', { mode: 0o600 });
  return privateKeyToAccount(pk).address;
}

export function agentAddress(keyFile) {
  return privateKeyToAccount(loadKey(keyFile)).address;
}

// ---------------------------------------------------------------- read

export function addr(a, name) {
  if (!a || !isAddress(String(a))) throw new Error(`${name} must be a 0x address`);
  return getAddress(String(a));
}

const read = (pub, address, functionName, args = []) => pub.readContract({ address, abi: ACCOUNT_ABI, functionName, args });

export async function readAccount(pub, account) {
  const code = await pub.getCode({ address: account });
  if (!code || code === '0x') throw new Error(`no contract at ${account} on this chain`);
  const [owner, agent, expiry, paused, active, policy, quote, n, value, remaining, dayVolume, peak] = await Promise.all([
    read(pub, account, 'owner'), read(pub, account, 'agent'), read(pub, account, 'agentExpiry'), read(pub, account, 'paused'),
    read(pub, account, 'agentActive'), read(pub, account, 'policy'), read(pub, account, 'quoteToken'), read(pub, account, 'assetCount'),
    read(pub, account, 'portfolioValue').catch(() => null), read(pub, account, 'dailyRemaining').catch(() => null),
    read(pub, account, 'dayVolume'), read(pub, account, 'peakValue'),
  ]);
  const [qSym, qDec, qBal] = await Promise.all([
    pub.readContract({ address: quote, abi: ERC20_ABI, functionName: 'symbol' }),
    pub.readContract({ address: quote, abi: ERC20_ABI, functionName: 'decimals' }),
    pub.readContract({ address: quote, abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }),
  ]);
  const assets = [];
  for (let i = 0n; i < n; i++) {
    const token = await read(pub, account, 'assetList', [i]);
    const [info, symbol, balance, alloc] = await Promise.all([
      read(pub, account, 'assets', [token]),
      pub.readContract({ address: token, abi: ERC20_ABI, functionName: 'symbol' }),
      pub.readContract({ address: token, abi: ERC20_ABI, functionName: 'balanceOf', args: [account] }),
      read(pub, account, 'allocationBps', [token]).catch(() => null),
    ]);
    const [, answer, , updatedAt] = await pub.readContract({ address: info[0], abi: FEED_ABI, functionName: 'latestRoundData' });
    assets.push({ token, symbol, feed: info[0], decimals: info[1], feedDecimals: info[2], balance, alloc, price: answer, updatedAt });
  }
  const [maxAllocBps, dailyLimitBps, drawdownBps, maxSlippageBps, maxFeedAge] = policy;
  return {
    account, owner, agent, expiry, paused, active, quote: { token: quote, symbol: qSym, decimals: qDec, balance: qBal },
    policy: { maxAllocBps, dailyLimitBps, drawdownBps, maxSlippageBps, maxFeedAge }, assets, value, remaining, dayVolume, peak,
  };
}

const usd18 = (v) => (v === null || v === undefined ? '—' : usd(Number(formatUnits(v, 18))));
const pct = (bps) => (bps === null || bps === undefined ? '—' : (Number(bps) / 100).toFixed(1) + '%');
const px = (a) => Number(a.price) / 10 ** a.feedDecimals;

export function printAccount(s, chainId) {
  const now = Math.floor(Date.now() / 1000);
  console.log(`${sym.dot} ${c.bold('Onshare account')} ${c.gray(s.account)} ${c.gray(`· chain ${chainId}`)}`);
  console.log(line(sym.ok, 'owner', s.owner));
  const agentState = s.paused ? c.red('paused (kill switch on)') : s.active ? c.green(`active · expires in ${Math.max(0, Math.round((Number(s.expiry) - now) / 3600))}h`) : c.red('no active session key');
  console.log(line(s.active ? sym.ok : sym.bad, 'agent', `${s.agent === '0x0000000000000000000000000000000000000000' ? '—' : s.agent} · ${agentState}`));
  console.log(line(sym.ok, 'value', `${usd18(s.value)} ${c.gray(`· peak ${usd18(s.peak)}`)}`));
  console.log(line(sym.ok, 'daily budget', `${usd18(s.remaining)} left ${c.gray(`· used ${usd18(s.dayVolume)} today`)}`));
  const p = s.policy;
  console.log(line(sym.ok, 'policy', `max_alloc ${pct(p.maxAllocBps)} · daily_limit ${pct(p.dailyLimitBps)} · drawdown ${pct(p.drawdownBps)} · slippage ${pct(p.maxSlippageBps)} · feed age ${Math.round(p.maxFeedAge / 3600)}h`));
  if (s.peak > 0n && s.value !== null) {
    const dd = Number((s.peak - (s.value < s.peak ? s.value : s.peak)) * 10_000n / s.peak);
    console.log(line(dd >= p.drawdownBps ? sym.bad : sym.ok, 'drawdown', `${(dd / 100).toFixed(1)}% from peak${dd >= p.drawdownBps ? c.red(' · sell-only mode') : ''}`));
  }
  console.log('');
  console.log(c.gray('  ASSET     BALANCE              PRICE        ALLOC   FEED AGE'));
  console.log(`  ${c.bold(s.quote.symbol.padEnd(9))} ${formatUnits(s.quote.balance, s.quote.decimals).padEnd(20)} ${'$1.00'.padEnd(12)} ${c.gray('quote')}`);
  for (const a of s.assets) {
    const over = a.alloc !== null && a.alloc > BigInt(p.maxAllocBps);
    const age = Math.round((now - Number(a.updatedAt)) / 60);
    console.log(`  ${c.bold(a.symbol.padEnd(9))} ${Number(formatUnits(a.balance, a.decimals)).toFixed(6).padEnd(20)} ${usd(px(a)).padEnd(12)} ${(over ? c.red : (x) => x)(pct(a.alloc).padEnd(7))} ${c.gray(age < 120 ? age + 'm' : Math.round(age / 60) + 'h')}`);
  }
}

// ---------------------------------------------------------------- trade

export function findAsset(s, symOrAddr) {
  const q = String(symOrAddr || '');
  const a = s.assets.find((x) => x.symbol.toUpperCase() === q.toUpperCase() || x.token.toLowerCase() === q.toLowerCase());
  if (!a) throw new Error(`"${q}" is not on this account's allowlist (${s.assets.map((x) => x.symbol).join(', ') || 'empty'})`);
  return a;
}

/// Build a trade worth `usdAmount` with the tightest minimum the policy accepts.
export function planTrade(s, side, asset, usdAmount) {
  const price = asset.price; // feed decimals
  const fd = 10n ** BigInt(asset.feedDecimals);
  const td = 10n ** BigInt(asset.decimals);
  const qd = 10n ** BigInt(s.quote.decimals);
  const slip = BigInt(s.policy.maxSlippageBps);
  const cents = BigInt(Math.round(usdAmount * 100));
  if (side === 'buy') {
    const amountIn = cents * qd / 100n;
    const expected = amountIn * fd * td / price / qd;
    return { tokenIn: s.quote.token, tokenOut: asset.token, amountIn, minOut: expected * (BPS - slip) / BPS + 1n, inSym: s.quote.symbol, outSym: asset.symbol, inDec: s.quote.decimals, outDec: asset.decimals };
  }
  const amountIn = cents * fd * td / price / 100n;
  const expected = amountIn * price * qd / fd / td;
  return { tokenIn: asset.token, tokenOut: s.quote.token, amountIn, minOut: expected * (BPS - slip) / BPS + 1n, inSym: asset.symbol, outSym: s.quote.symbol, inDec: asset.decimals, outDec: s.quote.decimals };
}

export function explainRevert(err) {
  if (err instanceof BaseError) {
    const rev = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (rev?.data?.errorName) return { name: rev.data.errorName, why: WHY[rev.data.errorName] || rev.data.errorName, args: rev.data.args };
    const raw = err.walk((e) => e?.data && typeof e.data === 'string' && e.data.startsWith('0x'));
    if (raw?.data) {
      try {
        const d = decodeErrorResult({ abi: ACCOUNT_ABI, data: raw.data });
        return { name: d.errorName, why: WHY[d.errorName] || d.errorName, args: d.args };
      } catch {}
    }
    return { name: 'revert', why: err.shortMessage || err.message };
  }
  return { name: 'error', why: err.message };
}

/// Simulate, then (after confirmation) send one agentSwap. Returns { sent, hash, amountOut }.
export async function executeTrade(ctx, s, adapter, t, { yes } = {}) {
  const { pub, wallet, agent, chainId } = ctx;
  const args = [adapter, t.tokenIn, t.tokenOut, t.amountIn, t.minOut];
  let sim;
  try {
    sim = await pub.simulateContract({ address: s.account, abi: ACCOUNT_ABI, functionName: 'agentSwap', args, account: agent });
  } catch (e) {
    const r = explainRevert(e);
    console.log(line(sym.bad, 'policy check', `${c.red(r.name)} · ${r.why}`));
    return { sent: false, reason: r.name };
  }
  console.log(line(sym.ok, 'policy check', `passed on-chain simulation · expect ≥ ${formatUnits(t.minOut, t.outDec)} ${t.outSym}`));
  if (!yes) {
    if (!process.stdin.isTTY) {
      console.log(line(sym.bad, 'not sent', 'no terminal to confirm; pass --yes to send without asking'));
      return { sent: false, reason: 'unconfirmed' };
    }
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const ans = (await rl.question(`  send this trade from agent ${agent.address.slice(0, 10)}…? [y/N] `)).trim().toLowerCase();
    rl.close();
    if (ans !== 'y' && ans !== 'yes') {
      console.log(line(sym.dot, 'cancelled', 'nothing sent'));
      return { sent: false, reason: 'cancelled' };
    }
  }
  const hash = await wallet.writeContract(sim.request);
  console.log(line(sym.arrow, 'sent', chainId === CHAIN_ID ? `${EXPLORER}/tx/${hash}` : hash));
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') {
    console.log(line(sym.bad, 'reverted', `in block ${receipt.blockNumber}`));
    return { sent: true, hash, failed: true };
  }
  console.log(line(sym.ok, 'executed', `block ${receipt.blockNumber} · got ${formatUnits(sim.result, t.outDec)} ${t.outSym}`));
  return { sent: true, hash, amountOut: sim.result };
}

/// Guard: refuse mainnet unless the user explicitly accepts the unaudited-contract risk.
export function mainnetGuard(chainId, flags) {
  if (chainId === CHAIN_ID && !flags['accept-unaudited']) {
    throw new Error('this is Robinhood Chain mainnet and the Onshare contracts are not audited yet. Use a testnet or local fork, or pass --accept-unaudited if you understand the risk.');
  }
}
