// Policy file handling and the checks every proposed action must pass.
import fs from 'node:fs';

export const DEFAULT_POLICY = {
  max_alloc: 25,        // % of portfolio in any single stock
  drawdown: 10,         // % from peak; beyond it the agent may only sell or hold
  health_factor: 1.5,   // minimum loan health factor
  daily_limit: 10,      // % of portfolio that may trade per day
  allowlist: ['NVDA', 'TSLA', 'AAPL'],
  max_feed_age_hours: 72,
};

export const POLICY_FILE = 'onshare.policy.yaml';

export function toYaml(p) {
  return [
    '# Onshare policy. The agent may never act outside these limits.',
    `max_alloc: ${p.max_alloc}        # % of portfolio per stock`,
    `drawdown: ${p.drawdown}          # % from peak, then sell or hold only`,
    `health_factor: ${p.health_factor}    # minimum loan health factor`,
    `daily_limit: ${p.daily_limit}       # % of portfolio traded per day`,
    `allowlist: [${p.allowlist.join(', ')}]`,
    `max_feed_age_hours: ${p.max_feed_age_hours}`,
    '',
  ].join('\n');
}

// Minimal parser for the flat `key: value` format written above.
export function parseYaml(text) {
  const out = {};
  for (const raw of text.split('\n')) {
    const lineText = raw.replace(/#.*$/, '').trim();
    if (!lineText) continue;
    const i = lineText.indexOf(':');
    if (i < 0) continue;
    const key = lineText.slice(0, i).trim();
    let val = lineText.slice(i + 1).trim();
    if (val.startsWith('[') && val.endsWith(']')) {
      out[key] = val.slice(1, -1).split(',').map((v) => v.trim().toUpperCase()).filter(Boolean);
    } else if (!isNaN(Number(val))) {
      out[key] = Number(val);
    } else {
      out[key] = val;
    }
  }
  return out;
}

export function loadPolicy(file = POLICY_FILE) {
  if (!fs.existsSync(file)) return { ...DEFAULT_POLICY, _source: 'defaults' };
  const parsed = parseYaml(fs.readFileSync(file, 'utf8'));
  return { ...DEFAULT_POLICY, ...parsed, _source: file };
}

/**
 * Evaluate one proposed trade.
 * @param {object} p   policy
 * @param {object} o   { side: 'buy'|'sell', symbol, usd, portfolioUsd, holdingUsd, price, updatedAt }
 */
export function check(p, o) {
  const after = o.side === 'buy' ? o.holdingUsd + o.usd : Math.max(0, o.holdingUsd - o.usd);
  const alloc = (after / o.portfolioUsd) * 100;
  const daily = (o.usd / o.portfolioUsd) * 100;
  const ageH = (Date.now() / 1000 - o.updatedAt) / 3600;
  const results = [
    { rule: 'allowlist', pass: p.allowlist.includes(o.symbol), detail: p.allowlist.includes(o.symbol) ? o.symbol + ' allowed' : o.symbol + ' not on allowlist' },
    { rule: 'max_alloc', pass: o.side === 'sell' || alloc <= p.max_alloc, detail: `${alloc.toFixed(1)}% / ${p.max_alloc}%` },
    { rule: 'daily_limit', pass: daily <= p.daily_limit, detail: `${daily.toFixed(1)}% / ${p.daily_limit}%` },
    { rule: 'price_feed', pass: ageH <= p.max_feed_age_hours, detail: `updated ${ageH.toFixed(1)}h ago` },
  ];
  const maxUsd = o.side === 'buy'
    ? Math.max(0, Math.min(o.portfolioUsd * p.max_alloc / 100 - o.holdingUsd, o.portfolioUsd * p.daily_limit / 100))
    : Math.min(o.holdingUsd, o.portfolioUsd * p.daily_limit / 100);
  return { ok: results.every((r) => r.pass), results, alloc, daily, maxUsd };
}
