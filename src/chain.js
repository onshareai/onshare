// Reads Chainlink price feeds on Robinhood Chain mainnet (chain ID 4663) over JSON-RPC.
// Read-only: no keys, no transactions.

export const CHAIN_ID = 4663;
export const EXPLORER = 'https://robinhoodchain.blockscout.com';

const DEFAULT_RPCS = [
  'https://rpc.mainnet.chain.robinhood.com',
  'https://rpc.nodeflare.app/robinhood/public',
];

// Mainnet Stock Tokens with a Chainlink feed proxy (8 decimals).
// Sources: Chainlink's Robinhood Chain directory (feeds) and Robinhood's token list (tokens).
// Re-verify against docs.chain.link before adding more.
export const ASSETS = {
  NVDA: { name: 'NVIDIA', feed: '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15', token: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC' },
  TSLA: { name: 'Tesla', feed: '0x4A1166a659A55625345e9515b32adECea5547C38', token: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d' },
  AAPL: { name: 'Apple', feed: '0x6B22A786bAa607d76728168703a39Ea9C99f2cD0', token: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9' },
  MSFT: { name: 'Microsoft', feed: '0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E', token: '0xe93237C50D904957Cf27E7B1133b510C669c2e74' },
  GOOGL: { name: 'Alphabet', feed: '0xF6f373a037c30F0e5010d854385cA89185AE638b', token: '0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3' },
  AMZN: { name: 'Amazon', feed: '0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C', token: '0x12f190a9F9d7D37a250758b26824B97CE941bF54' },
  META: { name: 'Meta Platforms', feed: '0x7C38C00C30BEe9378381E7B6135d7283356D71b1', token: '0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35' },
  AMD: { name: 'AMD', feed: '0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72', token: '0x86923f96303D656E4aa86D9d42D1e57ad2023fdC' },
  TSM: { name: 'TSMC', feed: '0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F', token: '0x58FfE4a942d3885bAa22D7520691F611EF09e7AA' },
  PLTR: { name: 'Palantir', feed: '0x820ABedFF239034956B7A9d2F0a331f9F075eB4c', token: '0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A' },
  COIN: { name: 'Coinbase', feed: '0xA3a468A452940B7D6b69991207B508c609a98Ef2', token: '0x6330D8C3178a418788dF01a47479c0ce7CCF450b' },
  MSTR: { name: 'Strategy', feed: '0x396118bdFB181e6240E74D243F266B061c0edc3D', token: '0xec262a75e413fAfD0dF80480274532C79D42da09' },
  SPY: { name: 'S&P 500 ETF', feed: '0x319724394D3A0e3669269846abE664Cd621f9f6A', token: '0x117cc2133c37B721F49dE2A7a74833232B3B4C0C' },
  QQQ: { name: 'Nasdaq 100 ETF', feed: '0x80901d846d5D7B030F26B480776EE3b29374C2ae', token: '0xD5f3879160bc7c32ebb4dC785F8a4F505888de68' },
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
