// Terminal styling helpers (no dependencies). Respects NO_COLOR and non-TTY output.
const useColor = process.stdout.isTTY && !process.env.NO_COLOR;
const wrap = (open, close) => (s) => (useColor ? `\x1b[${open}m${s}\x1b[${close}m` : String(s));

export const c = {
  amber: (s) => (useColor ? `\x1b[38;2;255;178;36m${s}\x1b[39m` : String(s)),
  dim: wrap(2, 22),
  bold: wrap(1, 22),
  green: wrap(32, 39),
  red: wrap(31, 39),
  gray: wrap(90, 39),
};

export const sym = {
  ok: c.amber('✓'),
  bad: c.red('✕'),
  arrow: c.amber('→'),
  dot: c.amber('●'),
};

export function logo() {
  return [
    c.amber('  >  ▂▄█'),
    `  ${c.bold('onshare')} ${c.gray('· policy-bound AI agent for tokenized stocks')}`,
  ].join('\n');
}

export function usd(n) {
  return '$' + Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export function ago(sec) {
  const d = Math.max(0, Math.floor(Date.now() / 1000 - sec));
  if (d < 60) return d + 's ago';
  if (d < 3600) return Math.floor(d / 60) + 'm ago';
  if (d < 86400) return Math.floor(d / 3600) + 'h ago';
  return Math.floor(d / 86400) + 'd ago';
}

// pad that ignores ANSI escape codes
const strip = (s) => String(s).replace(/\x1b\[[0-9;]*m/g, '');
export const padEnd = (s, n) => String(s) + ' '.repeat(Math.max(0, n - strip(s).length));
export const padStart = (s, n) => ' '.repeat(Math.max(0, n - strip(s).length)) + String(s);

export function line(mark, label, detail = '') {
  return `${mark} ${padEnd(label, 16)}${c.gray(detail)}`;
}
