// End-to-end test of the on-chain commands against a local anvil chain.
// Needs Foundry (anvil + forge). Run: npm run test:live
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const contracts = path.join(root, 'contracts');
const OWNER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'; // anvil test account #0

function haveFoundry() {
  return spawnSync('anvil', ['--version']).status === 0 && spawnSync('forge', ['--version']).status === 0;
}
if (!haveFoundry()) {
  console.log('SKIP  live tests need Foundry (anvil + forge): https://book.getfoundry.sh');
  process.exit(0);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function startAnvil(port, chainId) {
  const p = spawn('anvil', ['--port', String(port), '--chain-id', String(chainId), '--silent'], { stdio: 'ignore' });
  return p;
}
async function waitRpc(url) {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }) });
      if (r.ok) return;
    } catch {}
    await sleep(200);
  }
  throw new Error('anvil did not start');
}
async function rpc(url, method, params) {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  return (await r.json()).result;
}

const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'onshare-live-'));
function cli(args, env) {
  return new Promise((done) => {
    const p = spawn(process.execPath, [path.join(root, 'bin/onshare.js'), ...args], { cwd, env: { ...process.env, NO_COLOR: '1', ...env } });
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (out += d));
    p.stdin.end();
    p.on('close', (status) => done({ status, out }));
  });
}

let failed = 0;
function expect(name, r, status, ...needles) {
  const ok = r.status === status && needles.every((n) => r.out.includes(n));
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
  if (!ok) { failed++; console.log(`  status ${r.status} (want ${status})\n` + r.out.split('\n').map((l) => '  | ' + l).join('\n')); }
}

const PORT = 8611, URL = `http://127.0.0.1:${PORT}`;
const anvil = startAnvil(PORT, 31337);
try {
  await waitRpc(URL);
  const env = { ONSHARE_RPC: URL };

  // 1. agent key
  const k = await cli(['agent', 'new'], env);
  expect('agent new writes a session key', k, 0, 'wrote onshare.agent.key', 'agent address');
  const agent = k.out.match(/agent address\s+(0x[0-9a-fA-F]{40})/)[1];
  const mode = fs.statSync(path.join(cwd, 'onshare.agent.key')).mode & 0o777;
  expect('key file is private (600)', { status: mode === 0o600 ? 0 : 1, out: mode.toString(8) }, 0);
  await rpc(URL, 'anvil_setBalance', [agent, '0x56BC75E2D63100000']); // 100 ETH for gas

  // 2. deploy the local stack
  const dep = spawnSync('forge', ['script', 'script/LocalStack.s.sol', '--rpc-url', URL, '--broadcast', '--private-key', OWNER_KEY], { cwd: contracts, env: { ...process.env, AGENT: agent }, encoding: 'utf8' });
  if (dep.status !== 0) { console.log(dep.stdout + dep.stderr); throw new Error('deploy failed'); }
  const stack = JSON.parse(fs.readFileSync(path.join(contracts, 'local-stack.json'), 'utf8'));
  const A = ['--account', stack.account, '--adapter', stack.adapter];

  // 3. read the account
  expect('account shows state and over-cap NVDA', await cli(['account', stack.account], env), 0, 'Onshare account', 'NVDA', '37.5%', 'active');

  // 4. a trade inside every limit
  expect('swap buy TSLA $500 executes', await cli(['swap', 'buy', 'TSLA', '500', ...A, '--yes'], env), 0, 'passed on-chain simulation', 'executed');

  // 5. a trade over the daily limit is refused before anything is sent
  expect('swap over daily limit is rejected', await cli(['swap', 'buy', 'TSLA', '5000', ...A, '--yes'], env), 2, 'DailyLimitExceeded');

  // 6. a buy that breaks max_alloc
  expect('buying more NVDA breaks max_alloc', await cli(['swap', 'buy', 'NVDA', '100', ...A, '--yes'], env), 2, 'MaxAllocExceeded');

  // 7. without --yes and no terminal, nothing is sent
  expect('no confirmation, nothing sent', await cli(['swap', 'buy', 'TSLA', '10', ...A], env), 2, 'not sent');

  // 8. the agent loop trims NVDA within the remaining budget
  expect('run --live trims NVDA', await cli(['run', '--live', '--once', '--yes', ...A], env), 0, 'propose', 'trim NVDA', 'executed');

  // 9. a key that is not the agent
  const other = await cli(['swap', 'buy', 'TSLA', '10', ...A, '--yes'], { ...env, ONSHARE_AGENT_KEY: '0x' + '11'.repeat(32) });
  expect('foreign key is refused', other, 2, 'NotAgent');

  // 10. kill switch: owner pauses, agent is refused
  const pause = spawnSync('cast', ['send', stack.account, 'pause()', '--rpc-url', URL, '--private-key', OWNER_KEY], { encoding: 'utf8' });
  if (pause.status !== 0) throw new Error('pause failed: ' + pause.stderr);
  expect('paused account refuses the agent', await cli(['swap', 'buy', 'TSLA', '10', ...A, '--yes'], env), 2, 'IsPaused');
  expect('run --live holds while paused', await cli(['run', '--live', '--once', '--yes', ...A], env), 0, 'paused by the owner');

} catch (e) {
  failed++;
  console.log('FAIL  ' + e.message);
} finally {
  anvil.kill();
}

// 11. mainnet guard (anvil pretending to be chain 4663)
const PORT2 = 8612, URL2 = `http://127.0.0.1:${PORT2}`;
const anvil2 = startAnvil(PORT2, 4663);
try {
  await waitRpc(URL2);
  const r = await cli(['swap', 'buy', 'TSLA', '10', '--account', '0x' + '22'.repeat(20), '--adapter', '0x' + '33'.repeat(20), '--yes'], { ONSHARE_RPC: URL2 });
  expect('mainnet needs --accept-unaudited', r, 1, 'not audited');
} finally {
  anvil2.kill();
}

fs.rmSync(path.join(contracts, 'local-stack.json'), { force: true });
console.log(failed ? `\n${failed} failed` : '\nall live tests passed');
process.exit(failed ? 1 : 0);
