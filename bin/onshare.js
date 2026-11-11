#!/usr/bin/env node
// onshare — terminal CLI for the Onshare policy-bound agent on Robinhood Chain.
import fs from 'node:fs';
import { ASSETS, EXPLORER, CHAIN_ID, snapshot, rounds, candles, resolve } from '../src/chain.js';
import { DEFAULT_POLICY, POLICY_FILE, toYaml, loadPolicy, check } from '../src/policy.js';
import { c, sym, logo, usd, ago, padEnd, padStart, line } from '../src/ui.js';

const VERSION = '0.1.0';
const PORTFOLIO_FILE = 'onshare.portfolio.json';

// ---------- arg parsing ----------
const argv = process.argv.slice(2);
const flags = {};
const pos = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith('--')) {
    const [k, v] = a.slice(2).split('=');
    if (v !== undefined) flags[k] = v;
    else if (argv[i + 1] && !argv[i + 1].startsWith('--')) flags[k] = argv[++i];
    else flags[k] = true;
  } else pos.push(a);
}
const cmd = pos[0];

const HELP = `
${logo()}

${c.bold('Usage')}  onshare <command> [options]

${c.bold('Market data')} ${c.gray('(live Chainlink feeds on Robinhood Chain)')}
  markets                         Live prices for all supported Stock Tokens
  price <SYM>                     One price with feed and token addresses
  watch [SYM...]                  Live ticker, refreshes every 10s (Ctrl+C to quit)
  chart <SYM> [--tf 1h|4h|1d]     Candlestick chart from oracle rounds

${c.bold('Policy')}
  policy init                     Write ${POLICY_FILE} with safe defaults
  policy show                     Print the active policy
  check <buy|sell> <SYM> <USD>    Would the policy approve this trade?
        [--portfolio 10000] [--hold 12]   (portfolio value, current holding %)

${c.bold('Agent')}
  portfolio init                  Write an example ${PORTFOLIO_FILE}
  run --dry-run [--every 900] [--once]
                                  Run the decision loop on your portfolio file.
                                  Proposes and checks trades. Sends nothing.

${c.bold('Other')}
  version · help

${c.bold('Environment')}
  ONSHARE_RPC   Your own Robinhood Chain RPC URL (recommended for heavy use)
  NO_COLOR      Disable colors

${c.gray('Read-only. Onshare never asks for a private key. Live execution opens at limited release.')}
`;

function die(msg) {
  console.error(`${sym.bad} ${msg}`);
  process.exit(1);
}

// ---------- commands ----------
async function cmdMarkets() {
  const s = await snapshot();
  console.log(`${sym.dot} ${c.bold('Robinhood Chain')} ${c.gray(`chain ${CHAIN_ID} · block #${s.block?.toLocaleString('en-US') ?? '—'} · Chainlink`)}\n`);
  console.log(c.gray(padEnd('ASSET', 18) + padStart('PRICE', 12) + '   UPDATED'));
  for (const k of Object.keys(ASSETS)) {
    const d = s.prices[k];
    console.log(padEnd(`${c.bold(k)} ${c.gray(ASSETS[k].name)}`, 18) + padStart(d ? c.amber(usd(d.price)) : c.gray('—'), 12) + '   ' + c.gray(d ? ago(d.updatedAt) : 'no data'));
  }
  console.log(c.gray('\nFeeds follow US market hours 24/5 and hold the last price when markets are closed.'));
}

async function cmdPrice() {
  const k = resolve(pos[1]);
  const s = await snapshot([k]);
  const d = s.prices[k];
  if (!d) die('No price returned for ' + k);
  console.log(`${c.bold(k)} ${c.gray(ASSETS[k].name)}  ${c.amber(usd(d.price))}  ${c.gray('updated ' + ago(d.updatedAt))}`);
  console.log(c.gray(`feed   ${EXPLORER}/address/${ASSETS[k].feed}`));
  console.log(c.gray(`token  ${EXPLORER}/token/${ASSETS[k].token}`));
}

async function cmdWatch() {
  const list = pos.length > 1 ? pos.slice(1).map(resolve) : Object.keys(ASSETS);
  const last = {};
  console.log(`${sym.dot} watching ${list.join(', ')} ${c.gray('· every 10s · Ctrl+C to quit')}`);
  for (;;) {
    try {
      const s = await snapshot(list);
      const t = new Date().toLocaleTimeString('en-US', { hour12: false });
      const parts = list.map((k) => {
        const d = s.prices[k];
        if (!d) return `${k} ${c.gray('—')}`;
        const prev = last[k];
        last[k] = d.price;
        const p = usd(d.price);
        const colored = prev === undefined || prev === d.price ? c.amber(p) : d.price > prev ? c.green(p + ' ▲') : c.red(p + ' ▼');
        return `${c.bold(k)} ${colored}`;
      });
      console.log(`${c.gray(t)}  ${c.gray('#' + (s.block ?? '—'))}  ${parts.join('   ')}`);
    } catch (e) {
      console.log(`${sym.bad} ${c.gray(e.message)}`);
    }
    await new Promise((r) => setTimeout(r, 10000));
  }
}

async function cmdChart() {
  const k = resolve(pos[1]);
  const tfMap = { '1h': 3600e3, '4h': 4 * 3600e3, '1d': 86400e3 };
  const tf = tfMap[String(flags.tf || '4h').toLowerCase()];
  if (!tf) die('--tf must be 1h, 4h or 1d');
  process.stdout.write(c.gray(`reading oracle rounds for ${k}…\r`));
  const pts = await rounds(k, 160);
  if (process.stdout.isTTY) process.stdout.write('\r\x1b[K');
  const cs = candles(pts, tf).slice(-Math.max(8, Math.min(48, Math.floor(((process.stdout.columns || 80) - 14) / 2))));
  if (!cs.length) die('No history returned');
  const H = 14;
  let lo = Math.min(...cs.map((x) => x.l)), hi = Math.max(...cs.map((x) => x.h));
  if (hi === lo) { hi += 0.5; lo -= 0.5; }
  const row = (v) => Math.round(((hi - v) / (hi - lo)) * (H - 1));
  const grid = Array.from({ length: H }, () => Array(cs.length * 2).fill(' '));
  cs.forEach((x, i) => {
    const up = x.c > x.o, flat = x.c === x.o;
    const paint = flat ? c.gray : up ? c.green : c.red;
    const bt = row(Math.max(x.o, x.c)), bb = row(Math.min(x.o, x.c));
    for (let r = row(x.h); r <= row(x.l); r++) grid[r][i * 2] = paint(r >= bt && r <= bb ? (flat ? '━' : '█') : '│');
  });
  const last = cs[cs.length - 1];
  console.log(`${c.bold(k)} ${c.gray(ASSETS[k].name)}  ${c.amber(usd(last.c))}  ${c.gray(`${String(flags.tf || '4h')} candles · ${cs.length} · source: Chainlink rounds`)}\n`);
  grid.forEach((r, i) => {
    const label = i === 0 ? hi.toFixed(2) : i === H - 1 ? lo.toFixed(2) : i === Math.floor(H / 2) ? ((hi + lo) / 2).toFixed(2) : '';
    console.log(c.gray('│ ') + r.join('') + ' ' + c.gray(label));
  });
  const f = (t) => { const d = new Date(t); return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) + ' ' + String(d.getHours()).padStart(2, '0') + ':00'; };
  console.log(c.gray('└' + '─'.repeat(cs.length * 2 + 1)));
  console.log(c.gray('  ' + f(cs[0].t) + ' → ' + f(last.t)));
}

function cmdPolicy() {
  const sub = pos[1] || 'show';
  if (sub === 'init') {
    if (fs.existsSync(POLICY_FILE) && !flags.force) die(`${POLICY_FILE} already exists (use --force to overwrite)`);
    fs.writeFileSync(POLICY_FILE, toYaml(DEFAULT_POLICY));
    console.log(`${sym.ok} wrote ${POLICY_FILE}`);
    return;
  }
  const p = loadPolicy();
  console.log(c.gray(`source: ${p._source}`));
  console.log(line(sym.ok, 'max_alloc', `${p.max_alloc}% per stock`));
  console.log(line(sym.ok, 'drawdown', `${p.drawdown}% from peak → sell or hold only`));
  console.log(line(sym.ok, 'health_factor', `≥ ${p.health_factor}`));
  console.log(line(sym.ok, 'daily_limit', `${p.daily_limit}% of portfolio per day`));
  console.log(line(sym.ok, 'allowlist', p.allowlist.join(', ')));
}

async function cmdCheck() {
  const side = String(pos[1] || '').toLowerCase();
  if (!['buy', 'sell'].includes(side)) die('usage: onshare check <buy|sell> <SYM> <USD> [--portfolio 10000] [--hold 12]');
  const k = resolve(pos[2]);
  const amount = Number(pos[3]);
  if (!(amount > 0)) die('amount must be a positive USD number');
  const portfolioUsd = Number(flags.portfolio || 10000);
  const holdingUsd = portfolioUsd * Number(flags.hold || 0) / 100;
  const p = loadPolicy();
  const s = await snapshot([k]);
  const d = s.prices[k];
  if (!d) die('No price for ' + k);
  const r = check(p, { side, symbol: k, usd: amount, portfolioUsd, holdingUsd, price: d.price, updatedAt: d.updatedAt });
  console.log(`${c.amber('$')} onshare check ${side} ${k} ${usd(amount)}`);
  console.log(line(sym.ok, 'price', `${usd(d.price)} · chainlink · ${ago(d.updatedAt)}`));
  console.log(line(sym.arrow, 'size', `${(amount / d.price).toFixed(4)} ${k}`));
  for (const x of r.results) console.log(line(x.pass ? sym.ok : sym.bad, x.rule, x.detail));
  console.log(r.ok ? line(sym.dot, c.green('approved'), 'policy would allow this trade') : line(c.red('■'), c.red('rejected'), `max allowed now ${usd(r.maxUsd)}`));
  process.exitCode = r.ok ? 0 : 2;
}

function cmdPortfolio() {
  if (pos[1] !== 'init') die('usage: onshare portfolio init');
  if (fs.existsSync(PORTFOLIO_FILE) && !flags.force) die(`${PORTFOLIO_FILE} already exists (use --force to overwrite)`);
  const example = { note: 'Example holdings in tokens. Used by `onshare run --dry-run` only.', cash_usdg: 2500, holdings: { NVDA: 14, TSLA: 4, AAPL: 5 } };
  fs.writeFileSync(PORTFOLIO_FILE, JSON.stringify(example, null, 2) + '\n');
  console.log(`${sym.ok} wrote ${PORTFOLIO_FILE} ${c.gray('(edit it to match your holdings)')}`);
}

async function cmdRun() {
  if (!flags['dry-run']) {
    console.log(`${sym.bad} Live execution opens at limited release. Running in ${c.bold('--dry-run')} mode instead.\n`);
  }
  if (!fs.existsSync(PORTFOLIO_FILE)) die(`no ${PORTFOLIO_FILE} found. Run: onshare portfolio init`);
  const pf = JSON.parse(fs.readFileSync(PORTFOLIO_FILE, 'utf8'));
  const p = loadPolicy();
  const every = Math.max(10, Number(flags.every || 900));
  let tradedToday = 0, day = new Date().toDateString(), n = 0;
  console.log(`${c.amber('$')} onshare run --dry-run ${c.gray(`· policy: ${p._source} · every ${every}s`)}`);
  console.log(line(sym.ok, 'policy loaded', `max_alloc=${p.max_alloc}% daily_limit=${p.daily_limit}%`));
  for (;;) {
    n++;
    if (new Date().toDateString() !== day) { day = new Date().toDateString(); tradedToday = 0; }
    try {
      const syms = Object.keys(pf.holdings).filter((k) => ASSETS[k]);
      const s = await snapshot(syms);
      const value = (k) => (s.prices[k] ? pf.holdings[k] * s.prices[k].price : 0);
      const total = pf.cash_usdg + syms.reduce((a, k) => a + value(k), 0);
      console.log(`\n${c.gray(`cycle ${n} · block #${s.block ?? '—'} · ${new Date().toLocaleTimeString('en-US', { hour12: false })}`)}`);
      console.log(line(sym.ok, 'read', `portfolio ${usd(total)} · cash ${usd(pf.cash_usdg)}`));
      let acted = false;
      for (const k of syms) {
        const d = s.prices[k];
        if (!d) { console.log(line(sym.bad, k, 'no price, skipped')); continue; }
        const alloc = (value(k) / total) * 100;
        if (alloc <= p.max_alloc) { console.log(line(sym.ok, k, `${alloc.toFixed(1)}% ≤ ${p.max_alloc}%`)); continue; }
        const excess = value(k) - (total * p.max_alloc) / 100;
        const room = Math.max(0, (total * p.daily_limit) / 100 - tradedToday);
        const sell = Math.min(excess, room);
        console.log(line(sym.arrow, 'propose', `trim ${k} ${alloc.toFixed(1)}% → ${p.max_alloc}% (sell ${usd(sell)})`));
        const r = check(p, { side: 'sell', symbol: k, usd: sell, portfolioUsd: total, holdingUsd: value(k), price: d.price, updatedAt: d.updatedAt });
        const dailyOk = tradedToday + sell <= (total * p.daily_limit) / 100 + 1e-9;
        if (sell <= 0 || !dailyOk) { console.log(line(sym.bad, 'policy check', 'daily limit reached, hold')); continue; }
        if (!r.ok) { console.log(line(sym.bad, 'policy check', r.results.filter((x) => !x.pass).map((x) => x.rule).join(', '))); continue; }
        console.log(line(sym.ok, 'policy check', 'passed'));
        pf.holdings[k] -= sell / d.price;
        pf.cash_usdg += sell;
        tradedToday += sell;
        acted = true;
        console.log(line(sym.ok, 'simulated', `sold ${(sell / d.price).toFixed(4)} ${k} @ ${usd(d.price)} ${c.gray('(dry-run, nothing sent)')}`));
      }
      if (!acted) console.log(line(sym.dot, 'hold', 'portfolio within policy'));
    } catch (e) {
      console.log(line(sym.bad, 'error', e.message));
    }
    if (flags.once) break;
    console.log(c.gray(`next cycle in ${every}s · Ctrl+C to stop`));
    await new Promise((r) => setTimeout(r, every * 1000));
  }
}

// ---------- dispatch ----------
const routes = {
  markets: cmdMarkets, price: cmdPrice, watch: cmdWatch, chart: cmdChart,
  policy: cmdPolicy, check: cmdCheck, portfolio: cmdPortfolio, run: cmdRun,
  version: () => console.log(VERSION), '--version': () => console.log(VERSION), '-v': () => console.log(VERSION),
  help: () => console.log(HELP), '--help': () => console.log(HELP), '-h': () => console.log(HELP),
};

const fn = routes[cmd] || (cmd ? null : routes.help);
if (!fn) die(`unknown command "${cmd}". Run: onshare help`);
Promise.resolve(fn()).catch((e) => die(e.message));
