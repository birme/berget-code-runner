#!/usr/bin/env node
// Formats OpenCode `run --format json` events into human-readable stdout.
// Reads JSONL from stdin, one event per line. Lines that are not valid JSON
// are printed unchanged so this stays safe if plain text gets mixed in.

const readline = require('readline');

const rl = readline.createInterface({ input: process.stdin });

function truncate(s, n) {
  if (typeof s !== 'string') return '';
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
    console.log(line);
    return;
  }

  const part = evt.part || {};
  switch (evt.type) {
    case 'step_start':
      break;

    case 'text':
      if (part.text) console.log(part.text);
      break;

    case 'reasoning':
      if (part.text) console.log(`[thinking] ${truncate(part.text, 400)}`);
      break;

    case 'tool_use': {
      const name = part.tool || 'tool';
      const state = part.state || {};
      const arg = formatToolInput(state.input);
      console.log(
        arg ? `[tool_use] ${name} — ${truncate(arg, 300)}` : `[tool_use] ${name}`
      );
      if (state.status === 'error') {
        console.log(
          `[tool_error] ${truncate(String(state.error ?? state.output ?? ''), 500)}`
        );
      } else if (state.output !== undefined && state.output !== '') {
        const out =
          typeof state.output === 'string'
            ? state.output
            : JSON.stringify(state.output);
        console.log(`[tool_result] ${truncate(out, 500)}`);
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
      console.log(`[step] ${bits.filter(Boolean).join(' ')}`);
      break;
    }

    case 'error': {
      const e = evt.error || {};
      console.log(
        `[error] ${e.name || ''} ${e.data?.message || e.message || ''}`.trimEnd()
      );
      break;
    }

    default:
      console.log(`[${evt.type || 'unknown'}]`);
  }
});
