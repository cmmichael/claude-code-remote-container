// claude-pick-release: the claude link ends up on a release that runs.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SCRIPT = path.join(__dirname, '..', 'scripts', 'pick-release.sh');

// releases: { version: runs? }. The link starts on `linked`.
function run(releases, linked) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'pick-'));
  try {
    const versions = path.join(home, '.local/share/claude/versions');
    const bin = path.join(home, '.local/bin');
    fs.mkdirSync(versions, { recursive: true });
    fs.mkdirSync(bin, { recursive: true });
    for (const [v, ok] of Object.entries(releases)) {
      fs.writeFileSync(path.join(versions, v), `#!/bin/sh\nexit ${ok ? 0 : 1}\n`, { mode: 0o755 });
    }
    if (linked) fs.symlinkSync(path.join(versions, linked), path.join(bin, 'claude'));
    const r = spawnSync('bash', [SCRIPT], { env: { PATH: process.env.PATH, HOME: home }, encoding: 'utf8' });
    const link = linked ? path.basename(fs.readlinkSync(path.join(bin, 'claude'))) : null;
    return { status: r.status, link, out: r.stdout + r.stderr };
  } finally { fs.rmSync(home, { recursive: true, force: true }); }
}

test('a release that runs stays linked, silently', () => {
  assert.deepStrictEqual(run({ '2.1.9': true, '2.1.10': true }, '2.1.9'), { status: 0, link: '2.1.9', out: '' });
});

test('a broken release gives way to the newest that runs, by version order', () => {
  const r = run({ '2.1.9': true, '2.1.10': true, '2.1.11': false, '2.1.12': false }, '2.1.12');
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.link, '2.1.10');
  assert.match(r.out, /2\.1\.12 does not run here; using 2\.1\.10/);
});

test('with nothing that runs, the link stays and it says so', () => {
  const r = run({ '2.1.9': false, '2.1.10': false }, '2.1.10');
  assert.strictEqual(r.status, 1);
  assert.strictEqual(r.link, '2.1.10');
  assert.match(r.out, /no other installed release/);
});

test('nothing installed yet is not an error', () => {
  const r = run({}, null);
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.out, '');
});
