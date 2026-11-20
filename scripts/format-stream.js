#!/usr/bin/env node
// Formats OpenCode `run --format json` events into human-readable stdout.
// Reads JSONL from stdin, one event per line. Lines that are not valid JSON
// are printed unchanged so this stays safe if plain text gets mixed in.

const readline = require('readline');

const rl = readline.createInterface({ input: process.stdin });

// Redact secrets before anything is printed: the literal values of the runner's
// credentials (and the refreshed token file contents), plus common token shapes.
const SECRET_ENV = [
  'GIT_TOKEN',
  'GITHUB_TOKEN',
  'GH_TOKEN',
  'BERGET_API_KEY',
  'OSC_ACCESS_TOKEN',
  'GIT_TOKEN_REFRESH',
  'CONFIG_API_KEY',
];
const secrets = SECRET_ENV.map((k) => process.env[k]).filter(
  (v) => v && v.length >= 8
);
try {
  if (process.env.GIT_TOKEN_FILE) {
    const t = require('fs').readFileSync(process.env.GIT_TOKEN_FILE, 'utf8').trim();
    if (t.length >= 8) secrets.push(t);
  }
} catch {
  // no token file
}
const PATTERNS = [
  /\b(?:ghp|ghs|gho|ghu|ghr)_[A-Za-z0-9]{20,}/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}/g,
  /(Bearer\s+)[A-Za-z0-9._~+\/=-]{8,}/gi,
];

function redact(s) {
  if (typeof s !== 'string') return s;
  let out = s;
  for (const v of secrets) out = out.split(v).join('[REDACTED]');
  for (const re of PATTERNS) {
    out = out.replace(re, (m, p1) => (p1 ? `${p1}[REDACTED]` : '[REDACTED]'));
  }
  return out;
}

const log = (line) => console.log(redact(line));

function truncate(s, n) {
  if (typeof s !== 'string') return '';
  s = redact(s);
  if (s.length <= n) return s;
  return s.slice(0, n) + `… [${s.length - n} more chars]`;
}

function formatToolInput(input) {
  if (!input || typeof input !== 'object') return '';
  for (const key of ['command', 'filePath', 'path', 'pattern', 'url']) {
    if (typeof input[key] === 'string') return input[key];
  }
  try {
    return JSON.stringify(input);
  } catch {
    return '';
  }
}

rl.on('line', (raw) => {
  const line = raw.trim();
  if (!line) return;

  let evt;
  try {
    evt = JSON.parse(line);
  } catch {
    log(line);
    return;
  }

  const part = evt.part || {};
  switch (evt.type) {
    case 'step_start':
      break;

    case 'text':
      if (part.text) log(part.text);
      break;

    case 'reasoning':
      if (part.text) log(`[thinking] ${truncate(part.text, 400)}`);
      break;

    case 'tool_use': {
      const name = part.tool || 'tool';
      const state = part.state || {};
      const arg = formatToolInput(state.input);
      log(
        arg ? `[tool_use] ${name} — ${truncate(arg, 300)}` : `[tool_use] ${name}`
      );
      if (state.status === 'error') {
        log(
          `[tool_error] ${truncate(String(state.error ?? state.output ?? ''), 500)}`
        );
      } else if (state.output !== undefined && state.output !== '') {
        const out =
          typeof state.output === 'string'
            ? state.output
            : JSON.stringify(state.output);
        log(`[tool_result] ${truncate(out, 500)}`);
      }
      break;
    }

    case 'step_finish': {
      const tokens = part.tokens;
      const bits = [part.reason || ''];
      if (tokens && typeof tokens === 'object') {
        if (tokens.input !== undefined) bits.push(`in=${tokens.input}`);
        if (tokens.output !== undefined) bits.push(`out=${tokens.output}`);
      }
      if (typeof part.cost === 'number' && part.cost > 0) {
        bits.push(`$${part.cost.toFixed(4)}`);
      }
      log(`[step] ${bits.filter(Boolean).join(' ')}`);
      break;
    }

    case 'error': {
      const e = evt.error || {};
      log(
        `[error] ${e.name || ''} ${e.data?.message || e.message || ''}`.trimEnd()
      );
      break;
    }

    default:
      log(`[${evt.type || 'unknown'}]`);
  }
});
