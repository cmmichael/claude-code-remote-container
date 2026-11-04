// The filter over `claude remote-control` output: titles recorded, repaints
// dropped. Runs the real sed from the entrypoint and the real awk file.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.join(__dirname, '..');
const sed = fs.readFileSync(path.join(root, 'scripts/entrypoint.sh'), 'utf8').match(/sed -u '([^']+)'/)[1];

function filter(output) {
  const titles = fs.mkdtempSync(path.join(os.tmpdir(), 'rc-titles-'));
  try {
    const s = spawnSync('sed', ['-u', sed], { input: output, encoding: 'utf8' });
    assert.strictEqual(s.status, 0, s.stderr);
    const a = spawnSync('awk', ['-v', `titles=${titles}`, '-f', path.join(root, 'scripts/rc-server-filter.awk')], { input: s.stdout, encoding: 'utf8' });
    assert.strictEqual(a.status, 0, a.stderr);
    const recorded = {};
    for (const f of fs.readdirSync(titles)) recorded[f] = fs.readFileSync(path.join(titles, f), 'utf8').trim();
    return { recorded, log: a.stdout };
  } finally { fs.rmSync(titles, { recursive: true, force: true }); }
}

const URL = 'https://claude.ai/code/session_01ABC?from=cli';
const ST = '\x1b\\';

test('a linked title is recorded, without what follows the link', () => {
  const { recorded } = filter(`  \x1b]8;;${URL}${ST}Tidy the compose file\x1b]8;;${ST}  connected 3s\n`);
  assert.deepStrictEqual(recorded, { '01ABC': 'Tidy the compose file' });
});

test('a link closed with BEL reads the same', () => {
  const { recorded } = filter(`\x1b]8;;${URL}\x07Tidy the compose file\x1b]8;;\x07\n`);
  assert.deepStrictEqual(recorded, { '01ABC': 'Tidy the compose file' });
});

test('an unlinked title, as earlier releases printed it, is recorded', () => {
  const { recorded } = filter(`    ${URL} Tidy the compose file\n`);
  assert.deepStrictEqual(recorded, { '01ABC': 'Tidy the compose file' });
});

test('a status is not a title, linked or not', () => {
  const { recorded } = filter(`\x1b]8;;${URL}${ST}Attached\x1b]8;;${ST}\n    ${URL} Connecting\n`);
  assert.deepStrictEqual(recorded, {});
});

test('the latest title wins', () => {
  const link = (t) => `\x1b]8;;${URL}${ST}${t}\x1b]8;;${ST}\n`;
  const { recorded } = filter(link('First') + link('Second'));
  assert.deepStrictEqual(recorded, { '01ABC': 'Second' });
});

test('a repainted line is logged once, with no tab or escape left in it', () => {
  const line = `\x1b[2K\x1b]8;;${URL}${ST}Tidy\x1b]8;;${ST}\n`;
  const { log } = filter(line + line + line);
  assert.strictEqual(log, `[rc-server] ${URL} Tidy \n`);
});
