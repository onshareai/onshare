// Offline test: starts a mock Robinhood Chain RPC and runs each CLI command against it.
import http from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { price } from '../src/ui.js';
{
  const want = [[0.00000461, '$0.0₅461'], [0.004612, '$0.0₂461'], [0.01, '$0.01'], [295.28, '$295.28']];
  for (const [v, w] of want) {
    if (price(v) !== w) { console.log(`FAIL  price(${v}) = ${price(v)}, want ${w}`); process.exit(1); }
  }
  console.log('PASS  price() formats sub-cent launch-token prices');
}

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const PRICES = {
  '0x379ec4f7c378f34a1b47e4f3cbebcbac3e8e9f15': 229.58,
  '0x4a1166a659a55625345e9515b32adecea5547c38': 355.81,
  '0x6b22a786baa607d76728168703a39ea9c99f2cd0': 332.41,
};
const RID = (2n << 64n) | 500n;
const hex = (n) => BigInt(n).toString(16).padStart(64, '0');
const enc = (rid, price, ts) => '0x' + hex(rid) + hex(Math.round(price * 1e8)) + hex(ts) + hex(ts) + hex(rid);

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (d) => (body += d));
  req.on('end', () => {
    const now = Math.floor(Date.now() / 1000);
    const out = JSON.parse(body).map((call) => {
      let result;
      if (call.method === 'eth_blockNumber') result = '0x1dc9a87';
      else {
        const { to, data } = call.params[0];
        const base = PRICES[to.toLowerCase()] || 100; // feeds without a fixed test price
        if (data === '0xfeaf968c') result = enc(RID, base, now - 600);
        else {
          const i = Number(RID - BigInt('0x' + data.slice(10)));
          result = enc(RID - BigInt(i), base * (1 + Math.sin(i / 4) * 0.02), now - 600 - i * 2400);
        }
      }
      return { jsonrpc: '2.0', id: call.id, result };
    });
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(out));
  });
});

server.listen(0, async () => {
  const url = `http://127.0.0.1:${server.address().port}`;
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'onshare-'));
  const run = (args) => new Promise((done) => {
    const p = spawn(process.execPath, [path.join(root, 'bin/onshare.js'), ...args], { cwd, env: { ...process.env, ONSHARE_RPC: url, NO_COLOR: '1' } });
    let stdout = '', stderr = '';
    p.stdout.on('data', (d) => (stdout += d));
    p.stderr.on('data', (d) => (stderr += d));
    p.on('close', (status) => done({ status, stdout, stderr }));
  });
  const cases = [
    [['help'], 0, 'Usage'],
    [['markets'], 0, '$229.58'],
    [['price', 'tsla'], 0, '$355.81'],
    [['chart', 'NVDA', '--tf', '1d'], 0, 'candles'],
    [['policy', 'init'], 0, 'wrote'],
    [['policy', 'show'], 0, 'max_alloc'],
    [['check', 'buy', 'NVDA', '1000', '--hold', '12'], 0, 'approved'],
    [['check', 'buy', 'NVDA', '2000', '--hold', '12'], 2, 'rejected'],
    [['check', 'buy', 'MSFT', '1000', '--hold', '12'], 0, 'approved'],
    [['price', 'QQQ'], 0, 'Nasdaq 100 ETF'],
    [['portfolio', 'init'], 0, 'wrote'],
    [['run', '--dry-run', '--once'], 0, 'policy check'],
    [['price', 'XYZ'], 1, 'Unknown asset'],
  ];
  let failed = 0;
  for (const [args, code, expect] of cases) {
    const r = await run(args);
    const outText = r.stdout + r.stderr;
    const pass = r.status === code && outText.includes(expect);
    if (!pass) failed++;
    console.log(`${pass ? 'PASS' : 'FAIL'}  onshare ${args.join(' ')}${pass ? '' : `\n  exit ${r.status}\n${outText}`}`);
  }
  server.close();
  process.exit(failed ? 1 : 0);
});
