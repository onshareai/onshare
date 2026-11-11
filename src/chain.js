// Reads Chainlink price feeds on Robinhood Chain mainnet (chain ID 4663) over JSON-RPC.
// Read-only: no keys, no transactions.

export const CHAIN_ID = 4663;
export const EXPLORER = 'https://robinhoodchain.blockscout.com';

const DEFAULT_RPCS = [
  'https://rpc.mainnet.chain.robinhood.com',
  'https://rpc.nodeflare.app/robinhood/public',
];

// Verified mainnet addresses (Stock Token + Chainlink feed proxy, 8 decimals).
// Re-verify against docs.chain.link before adding more.
export const ASSETS = {
  NVDA: { name: 'NVIDIA', feed: '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15', token: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC' },
  TSLA: { name: 'Tesla', feed: '0x4A1166a659A55625345e9515b32adECea5547C38', token: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d' },
  AAPL: { name: 'Apple', feed: '0x6B22A786bAa607d76728168703a39Ea9C99f2cD0', token: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9' },
};

const LATEST_ROUND_DATA = '0xfeaf968c';
const GET_ROUND_DATA = '0x9a6fc8f5';

export function rpcList() {
  const own = process.env.ONSHARE_RPC;
  return own ? [own, ...DEFAULT_RPCS] : DEFAULT_RPCS;
}

export async function batch(calls) {
  let lastErr;
  for (const url of rpcList()) {
    try {
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), 10000);
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(calls.map(([method, params], id) => ({ jsonrpc: '2.0', id, method, params }))),
        signal: ctl.signal,
      });
      clearTimeout(t);
      const json = await res.json();
      if (!Array.isArray(json)) throw new Error('unexpected RPC response');
      const out = [];
      for (const r of json) out[r.id] = r.result;
      return out;
    } catch (e) {
      lastErr = e;
    }
  }
  throw new Error('Could not reach Robinhood Chain RPC' + (lastErr ? ` (${lastErr.message})` : '') + '. Set ONSHARE_RPC to your own endpoint.');
}

export function decodeRound(hex) {
  if (!hex || hex.length < 2 + 64 * 5) return null;
  const h = hex.slice(2);
  const roundId = BigInt('0x' + h.slice(0, 64));
  const answer = BigInt.asIntN(256, BigInt('0x' + h.slice(64, 128)));
  const updatedAt = Number(BigInt('0x' + h.slice(192, 256)));
  return { roundId, price: Number(answer) / 1e8, updatedAt };
}

export function resolve(symbol) {
  const s = String(symbol || '').toUpperCase();
  if (!ASSETS[s]) throw new Error(`Unknown asset "${symbol}". Supported: ${Object.keys(ASSETS).join(', ')}`);
  return s;
}

export async function snapshot(symbols = Object.keys(ASSETS)) {
  const calls = [['eth_blockNumber', []], ...symbols.map((s) => ['eth_call', [{ to: ASSETS[s].feed, data: LATEST_ROUND_DATA }, 'latest']])];
  const res = await batch(calls);
  const prices = {};
  symbols.forEach((s, i) => {
    const d = decodeRound(res[i + 1]);
    if (d && d.price > 0) prices[s] = d;
  });
  return { block: res[0] ? parseInt(res[0], 16) : null, prices };
}

// Past oracle rounds → [{ t (ms), p }], oldest first.
export async function rounds(symbol, n = 120) {
  const s = resolve(symbol);
  const feed = ASSETS[s].feed;
  const [lat] = await batch([['eth_call', [{ to: feed, data: LATEST_ROUND_DATA }, 'latest']]]);
  const latest = decodeRound(lat);
  if (!latest) throw new Error('No data from feed');
  const ids = [];
  for (let i = 0; i < n; i++) {
    const r = latest.roundId - BigInt(i);
    if (r > 0n) ids.push(r);
  }
  const out = [];
  for (let i = 0; i < ids.length; i += 30) {
    const chunk = ids.slice(i, i + 30);
    const res = await batch(chunk.map((r) => ['eth_call', [{ to: feed, data: GET_ROUND_DATA + r.toString(16).padStart(64, '0') }, 'latest']]));
    for (const x of res) {
      const d = decodeRound(x);
      if (d && d.price > 0 && d.updatedAt > 0) out.push({ t: d.updatedAt * 1000, p: d.price });
    }
  }
  return out.sort((a, b) => a.t - b.t);
}

export function candles(points, bucketMs) {
  const map = new Map();
  for (const pt of points) {
    const k = Math.floor(pt.t / bucketMs) * bucketMs;
    const cur = map.get(k);
    if (!cur) map.set(k, { t: k, o: pt.p, h: pt.p, l: pt.p, c: pt.p });
    else { cur.h = Math.max(cur.h, pt.p); cur.l = Math.min(cur.l, pt.p); cur.c = pt.p; }
  }
  const arr = [...map.values()].sort((a, b) => a.t - b.t);
  for (let i = 1; i < arr.length; i++) {
    const prev = arr[i - 1].c;
    arr[i].o = prev;
    arr[i].h = Math.max(arr[i].h, prev);
    arr[i].l = Math.min(arr[i].l, prev);
  }
  return arr;
}
