// Unit tests for scripts/web-front.js: run with `node --test tests/`.
// Each case starts the real front end as a child process in front of a fake
// ttyd and talks to it over HTTP and websocket upgrades. No Docker needed.
'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert');
const http = require('http');
const net = require('net');
const crypto = require('crypto');
const path = require('path');
const { spawn } = require('child_process');

const FRONT = path.join(__dirname, '..', 'scripts', 'web-front.js');
const BADGE = path.join(__dirname, '..', 'scripts', 'web-badge.html');

const freePort = () => new Promise((resolve) => {
  const s = net.createServer().listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
});

// ---- fake ttyd: a page, and a websocket endpoint that answers 101 ----------
let ttyd, ttydPort;
// ---- JWKS server with a key we sign with, and a second key it doesn't know --
const signer = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const stranger = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const KID = 'test-kid-1';
let jwksServer, jwksUrl;

before(async () => {
  ttydPort = await freePort();
  ttyd = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<html><body>terminal</body></html>');
  });
  ttyd.on('upgrade', (req, sock) => {
    sock.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
    sock.end();
  });
  await new Promise((r) => ttyd.listen(ttydPort, '127.0.0.1', r));

  const jwk = { ...signer.publicKey.export({ format: 'jwk' }), kid: KID, alg: 'ES256', use: 'sig' };
  jwksServer = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ keys: [jwk] }));
  });
  const jp = await freePort();
  await new Promise((r) => jwksServer.listen(jp, '127.0.0.1', r));
  jwksUrl = `http://127.0.0.1:${jp}/.well-known/pomerium/jwks.json`;
});
after(() => { ttyd.close(); jwksServer.close(); });

// ---- start a front end with the given env; resolves once it listens --------
// WEB_PORT=0: the front end binds a free port itself and logs it, so there's
// no gap between picking a port and listening on it for another process to use.
async function front(env) {
  const child = spawn(process.execPath, [FRONT], {
    env: { PATH: process.env.PATH, HOME: '/nonexistent', WEB_PORT: '0', TTYD_INTERNAL_PORT: String(ttydPort), WEB_BADGE_FILE: BADGE, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  await new Promise((resolve, reject) => {
    const t = setTimeout(() => { child.kill(); reject(new Error(`front did not start within 15s: ${out}`)); }, 15000);
    child.stdout.on('data', (d) => { out += d; if (out.includes('user check:')) { clearTimeout(t); resolve(); } });
    child.stderr.on('data', (d) => { out += d; });
    child.on('exit', (code) => { clearTimeout(t); reject(new Error(`front exited (${code}): ${out}`)); });
  });
  const port = +out.match(/listening on :(\d+)/)[1];
  return { port, stop: () => child.kill(), log: () => out };
}

function get(port, p, headers = {}) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: p, headers }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}
// Websocket upgrade: resolves with the status line's code.
function upgrade(port, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: '/ws', headers: {
      Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64'), ...headers } });
    req.on('upgrade', (res, sock) => { sock.destroy(); resolve(101); });
    req.on('response', (res) => { res.resume(); resolve(res.statusCode); });
    req.on('error', reject);
    req.end();
  });
}

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function jwt(claims, { key = signer.privateKey, kid = KID, alg = 'ES256' } = {}) {
  const h = b64({ alg, kid, typ: 'JWT' });
  const p = b64(claims);
  const sig = crypto.sign('sha256', Buffer.from(`${h}.${p}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${h}.${p}.${sig}`;
}
const now = () => Math.floor(Date.now() / 1000);
const good = (over = {}) => ({ iss: 'term.example.com', aud: 'term.example.com', email: 'me@example.com', iat: now(), exp: now() + 300, ...over });

// ---- tests ---------------------------------------------------------------------
test('auth off: page served with the badge, websocket upgrades', async () => {
  const f = await front({});
  try {
    const r = await get(f.port, '/');
    assert.strictEqual(r.status, 200);
    assert.match(r.body, /id="cw-badge"/);
    assert.match(r.body, /terminal/);
    assert.strictEqual(await upgrade(f.port), 101);
  } finally { f.stop(); }
});

test('pomerium: valid assertion for an allowed user passes, page and websocket', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'pomerium', CLAUDE_WEB_POMERIUM_JWKS_URL: jwksUrl,
    CLAUDE_WEB_POMERIUM_AUDIENCE: 'term.example.com', CLAUDE_WEB_ALLOWED_USERS: 'me@example.com' });
  try {
    const h = { 'X-Pomerium-Jwt-Assertion': jwt(good()) };
    assert.strictEqual((await get(f.port, '/', h)).status, 200);
    const me = await get(f.port, '/api/whoami', h);
    assert.strictEqual(me.status, 200);
    assert.deepStrictEqual(JSON.parse(me.body), { auth: 'pomerium', user: 'me@example.com' });
    assert.strictEqual((await get(f.port, '/api/sessions', h)).status, 200);
    assert.strictEqual(await upgrade(f.port, h), 101);
  } finally { f.stop(); }
});

test('pomerium: refuses missing, forged, expired, wrong-audience, wrong-alg, unknown-kid and unlisted users', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'pomerium', CLAUDE_WEB_POMERIUM_JWKS_URL: jwksUrl,
    CLAUDE_WEB_POMERIUM_AUDIENCE: 'term.example.com', CLAUDE_WEB_ALLOWED_USERS: 'me@example.com, *@team.example.com' });
  try {
    const cases = {
      'no header': null,
      'garbage': 'not.a.jwt',
      'signed by another key': jwt(good(), { key: stranger.privateKey }),
      'expired': jwt(good({ exp: now() - 3600 })),
      'wrong audience': jwt(good({ aud: 'other.example.com' })),
      'unknown kid': jwt(good(), { kid: 'nope' }),
      'alg none': `${b64({ alg: 'none', kid: KID })}.${b64(good())}.`,
      'unlisted user': jwt(good({ email: 'intruder@example.com' })),
      'no email': jwt(good({ email: undefined })),
    };
    for (const [name, token] of Object.entries(cases)) {
      const h = token ? { 'X-Pomerium-Jwt-Assertion': token } : {};
      assert.strictEqual((await get(f.port, '/', h)).status, 403, `page: ${name}`);
      assert.strictEqual(await upgrade(f.port, h), 403, `websocket: ${name}`);
    }
    const wrongAud = await get(f.port, '/api/whoami', { 'X-Pomerium-Jwt-Assertion': jwt(good({ aud: 'other.example.com' })) });
    assert.strictEqual(wrongAud.status, 403);
    assert.match(wrongAud.body, /audience other\.example\.com is not term\.example\.com/);
    // domain wildcard
    assert.strictEqual((await get(f.port, '/', { 'X-Pomerium-Jwt-Assertion': jwt(good({ email: 'a@team.example.com' })) })).status, 200);
    assert.strictEqual((await get(f.port, '/', { 'X-Pomerium-Jwt-Assertion': jwt(good({ email: 'a@evilteam.example.com' })) })).status, 403);
    assert.match(f.log(), /refused intruder@example.com/);
  } finally { f.stop(); }
});

test('pomerium: without a JWKS URL every request is refused', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'pomerium', CLAUDE_WEB_ALLOWED_USERS: '*' });
  try {
    assert.strictEqual((await get(f.port, '/', { 'X-Pomerium-Jwt-Assertion': jwt(good()) })).status, 403);
  } finally { f.stop(); }
});

test('header: believed from a trusted proxy, for listed users only', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'header', CLAUDE_WEB_ALLOWED_USERS: 'me@github' });
  try {
    assert.strictEqual((await get(f.port, '/', { 'Tailscale-User-Login': 'me@github' })).status, 200);
    assert.strictEqual(await upgrade(f.port, { 'Tailscale-User-Login': 'me@github' }), 101);
    assert.strictEqual((await get(f.port, '/', { 'Tailscale-User-Login': 'other@github' })).status, 403);
    assert.strictEqual((await get(f.port, '/')).status, 403);
    assert.strictEqual(await upgrade(f.port), 403);
  } finally { f.stop(); }
});

test('header: ignored from an untrusted address', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'header', CLAUDE_WEB_ALLOWED_USERS: '*', CLAUDE_WEB_TRUSTED_PROXIES: '10.0.0.0/8' });
  try {
    assert.strictEqual((await get(f.port, '/', { 'Tailscale-User-Login': 'me@github' })).status, 403);
    assert.match(f.log(), /not a trusted proxy/);
  } finally { f.stop(); }
});

test('header: custom header name', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'header', CLAUDE_WEB_AUTH_HEADER: 'X-Forwarded-Email', CLAUDE_WEB_ALLOWED_USERS: 'me@example.com' });
  try {
    assert.strictEqual((await get(f.port, '/', { 'X-Forwarded-Email': 'me@example.com' })).status, 200);
    assert.strictEqual((await get(f.port, '/', { 'Tailscale-User-Login': 'me@example.com' })).status, 403);
  } finally { f.stop(); }
});

test('an unknown mode refuses everything', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'tailscal', CLAUDE_WEB_ALLOWED_USERS: '*' });
  try {
    assert.strictEqual((await get(f.port, '/', { 'Tailscale-User-Login': 'me@github' })).status, 403);
  } finally { f.stop(); }
});

test('/healthz: 503 when the terminal is down, JSON detail with full=1', async () => {
  const dead = await freePort();   // nothing listens here
  const f = await front({ TTYD_INTERNAL_PORT: String(dead) });
  try {
    const r = await get(f.port, '/healthz');
    assert.strictEqual(r.status, 503);
    assert.match(r.body, /terminal not reachable/);
    const j = await get(f.port, '/healthz?full=1');
    assert.strictEqual(j.status, 503);
    const h = JSON.parse(j.body);
    assert.strictEqual(h.ok, false);
    assert.strictEqual(h.terminal, false);
    assert.deepStrictEqual(Object.keys(h).sort(), ['auth', 'claude_code', 'ok', 'remote_control_server', 'terminal', 'update_watcher']);
  } finally { f.stop(); }
  const up = await front({});
  try {
    const h = JSON.parse((await get(up.port, '/healthz?full=1')).body);
    assert.strictEqual(h.ok, true);
    assert.strictEqual(h.terminal, true);
    assert.strictEqual(h.auth, 'none');
  } finally { up.stop(); }
});

test('/healthz answers without a user check and logs nothing', async () => {
  const f = await front({ CLAUDE_WEB_AUTH: 'pomerium', CLAUDE_WEB_POMERIUM_JWKS_URL: jwksUrl, CLAUDE_WEB_ALLOWED_USERS: 'me@example.com' });
  try {
    const r = await get(f.port, '/healthz');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.body, 'ok\n');
    assert.strictEqual((await get(f.port, '/')).status, 403);
    assert.doesNotMatch(f.log(), /refused anonymous GET \/healthz/);
  } finally { f.stop(); }
});

// A real Remote Control server on the machine running the tests (a dev box
// that is itself one of these containers) would be found first.
function otherServerRunning() {
  const fs = require('fs');
  return fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d)).some((pid) => {
    try { const a = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0'); return a[0] === 'claude' && a[1] === 'remote-control'; } catch { return false; }
  });
}

test('the sessions list finds a Remote Control server started with flags', { skip: otherServerRunning() && 'a real Remote Control server runs on this machine' }, async () => {
  // A process whose command line is exactly `claude remote-control --name x`:
  // sh runs a script file named remote-control, with argv[0] set to claude.
  const fs = require('fs'), os = require('os');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rc-'));
  fs.writeFileSync(path.join(dir, 'remote-control'), 'sleep 30\n');
  const rc = spawn('/bin/sh', ['remote-control', '--name', 'x'], { cwd: dir, argv0: 'claude', stdio: 'ignore' });
  const f = await front({});
  try {
    await new Promise((r) => setTimeout(r, 300));
    const j = JSON.parse((await get(f.port, '/api/sessions')).body);
    assert.strictEqual(j.server.running, true);
    assert.strictEqual(j.server.pid, rc.pid);
  } finally { f.stop(); rc.kill(); fs.rmSync(dir, { recursive: true, force: true }); }
});
