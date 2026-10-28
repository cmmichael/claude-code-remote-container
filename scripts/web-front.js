#!/usr/bin/env node
// Front end for the web terminal. Listens on the public port (7681) and:
//   GET /api/sessions  -> the Remote Control server's live sessions as JSON
//   GET /api/whoami    -> who the user check sees ({auth, user}); for checking a proxy setup
//   GET /healthz       -> "ok" without a user check, for the image's health check
//   GET /              -> ttyd's page with the sessions badge (web-badge.html) added
//   anything else      -> proxied to ttyd on 127.0.0.1:$TTYD_INTERNAL_PORT,
//                         websocket upgrades included
// The sessions the Remote Control server spawns are headless (--print --sdk-url),
// so the terminal can't show them; the badge lists them with a link to
// claude.ai/code. Data comes from /proc and the session hook's stamps in
// $HOME/.claude/autoupdate-state/procs/<pid>/last-prompt|last-stop.
// Optional user check (CLAUDE_WEB_AUTH) on every request, websockets included,
// before anything reaches ttyd:
//   pomerium  verify Pomerium's signed X-Pomerium-Jwt-Assertion (ES256, keys
//             from CLAUDE_WEB_POMERIUM_JWKS_URL, aud = CLAUDE_WEB_POMERIUM_AUDIENCE)
//   header    trust an identity header (default Tailscale-User-Login) only from
//             CLAUDE_WEB_TRUSTED_PROXIES
// and the user must match CLAUDE_WEB_ALLOWED_USERS.
// No dependencies: Node's standard library only.
'use strict';
const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = +(process.env.WEB_PORT || 7681);
const TTYD_PORT = +(process.env.TTYD_INTERNAL_PORT || 7683);
const HOME = process.env.HOME || '/config';
const STATE = path.join(HOME, '.claude', 'autoupdate-state');
const VERSIONS = path.join(HOME, '.local', 'share', 'claude', 'versions') + '/';
const STALE_TURN_SECS = +(process.env.CLAUDE_UPDATE_STALE_TURN_SECS || 3600);
const CREDENTIAL = process.env.TTYD_CREDENTIAL || '';
const BADGE_FILE = process.env.WEB_BADGE_FILE || '/usr/local/share/claude-web/web-badge.html';

const log = (...a) => console.log('[web-front]', ...a);

// ---- /proc helpers -------------------------------------------------------
const read = (f) => { try { return fs.readFileSync(f, 'utf8'); } catch { return null; } };
const exe = (pid) => { try { return fs.readlinkSync(`/proc/${pid}/exe`); } catch { return ''; } };
const argv = (pid) => (read(`/proc/${pid}/cmdline`) || '').split('\0').filter(Boolean);
// Fields after "(comm)", which may itself hold spaces and parentheses.
const statFields = (pid) => {
  const s = read(`/proc/${pid}/stat`);
  return s ? s.slice(s.lastIndexOf(') ') + 2).split(' ') : null;
};
const BOOT = +(((read('/proc/stat') || '').match(/^btime (\d+)/m) || [])[1] || 0);
const HZ = 100; // USER_HZ; 100 on every Linux this image targets

function pids() {
  return fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d)).map(Number);
}
function childrenMap() {
  const kids = new Map();
  for (const p of pids()) {
    const f = statFields(p);
    if (!f) continue;
    const pp = +f[1];
    if (!kids.has(pp)) kids.set(pp, []);
    kids.get(pp).push(p);
  }
  return kids;
}
function descendants(pid, kids) {
  const out = [];
  for (const k of kids.get(pid) || []) out.push(k, ...descendants(k, kids));
  return out;
}
const num = (f) => { const v = parseInt(read(f) || '', 10); return Number.isFinite(v) ? v : 0; };

function sessions() {
  const now = Math.floor(Date.now() / 1000);
  const server = pids().find((p) => { const a = argv(p); return a[0] === 'claude' && a[1] === 'remote-control'; });
  if (!server) return { server: { running: false }, sessions: [] };
  const kids = childrenMap();
  const list = [];
  for (const p of descendants(server, kids)) {
    const bin = exe(p);
    if (!bin.startsWith(VERSIONS)) continue;
    const a = argv(p);
    const i = a.indexOf('--session-id');
    const id = i >= 0 ? a[i + 1] : ((a.find((x) => x.startsWith('--session-id=')) || '').split('=')[1] || '');
    const f = statFields(p);
    const started = f ? BOOT + Math.floor(+f[19] / HZ) : 0;
    const lp = num(path.join(STATE, 'procs', String(p), 'last-prompt'));
    const ls = num(path.join(STATE, 'procs', String(p), 'last-stop'));
    const busy = lp > ls && now - lp < STALE_TURN_SECS;
    list.push({
      pid: p,
      id,
      url: id.startsWith('cse_') ? `https://claude.ai/code/session_${id.slice(4)}` : 'https://claude.ai/code',
      version: path.basename(bin),
      started,
      last_prompt: lp || null,
      last_stop: ls || null,
      busy,
    });
  }
  list.sort((a, b) => a.started - b.started);
  return {
    server: { running: true, pid: server, version: path.basename(exe(server)) },
    sessions: list,
    busy: list.some((s) => s.busy),
    now,
  };
}

// ---- auth (only when ttyd's own basic auth is on) -------------------------
function authorized(req) {
  if (!CREDENTIAL) return true;
  const want = Buffer.from('Basic ' + Buffer.from(CREDENTIAL).toString('base64'));
  const got = Buffer.from(req.headers.authorization || '');
  return got.length === want.length && crypto.timingSafeEqual(got, want);
}

// ---- badge injection -------------------------------------------------------
let badge = read(BADGE_FILE);
if (badge === null) log(`no badge at ${BADGE_FILE}; serving ttyd's page unchanged`);
function inject(html) {
  if (!badge) return html;
  const at = html.lastIndexOf('</body>');
  return at < 0 ? html + badge : html.slice(0, at) + badge + html.slice(at);
}

// ---- user check (CLAUDE_WEB_AUTH) -------------------------------------------
const AUTH = (process.env.CLAUDE_WEB_AUTH || 'none').toLowerCase();
const ALLOWED = (process.env.CLAUDE_WEB_ALLOWED_USERS || '')
  .split(/[\s,]+/).map((x) => x.trim().toLowerCase()).filter(Boolean);
const AUTH_HEADER = (process.env.CLAUDE_WEB_AUTH_HEADER || 'Tailscale-User-Login').toLowerCase();
const JWKS_URL = process.env.CLAUDE_WEB_POMERIUM_JWKS_URL || '';
const AUDIENCE = (process.env.CLAUDE_WEB_POMERIUM_AUDIENCE || '').toLowerCase();
const CLOCK_SKEW = 60;

if (!['none', 'pomerium', 'header'].includes(AUTH)) {
  log(`CLAUDE_WEB_AUTH=${AUTH} is not none, pomerium or header; refusing every request`);
}
if (AUTH !== 'none' && !ALLOWED.length) log('CLAUDE_WEB_ALLOWED_USERS is empty; every user will be refused');
if (AUTH === 'pomerium' && !JWKS_URL) log('CLAUDE_WEB_POMERIUM_JWKS_URL is not set; every request will be refused');
if (AUTH === 'pomerium' && !AUDIENCE) log('CLAUDE_WEB_POMERIUM_AUDIENCE is not set; tokens issued for any Pomerium route are accepted');

function allowedUser(user) {
  if (!user) return false;
  const u = user.toLowerCase();
  return ALLOWED.some((a) => a === '*' || a === u || (a.startsWith('*@') && u.endsWith(a.slice(1))));
}

// Proxies whose identity header is believed (header mode). Default: this
// container's loopback, i.e. a Tailscale Serve sidecar sharing its network.
const trusted = new net.BlockList();
for (const cidr of (process.env.CLAUDE_WEB_TRUSTED_PROXIES || '127.0.0.1/32,::1/128').split(/[\s,]+/).filter(Boolean)) {
  const [addr, bits] = cidr.split('/');
  const type = net.isIPv6(addr) ? 'ipv6' : 'ipv4';
  try { trusted.addSubnet(addr, bits ? +bits : (type === 'ipv6' ? 128 : 32), type); } catch (e) { log(`ignoring trusted proxy ${cidr}: ${e.message}`); }
}
function fromTrustedProxy(req) {
  let ip = req.socket.remoteAddress || '';
  if (ip.startsWith('::ffff:') && net.isIPv4(ip.slice(7))) ip = ip.slice(7);
  return trusted.check(ip, net.isIPv6(ip) ? 'ipv6' : 'ipv4');
}

// Pomerium's signing keys, fetched from the configured URL only (never from a
// URL derived from the request), cached by kid, refetched at most once a minute
// when a token names a kid we don't have.
let jwks = new Map(), jwksAt = 0, jwksFetching = null;
function fetchJwks() {
  if (jwksFetching) return jwksFetching;
  jwksFetching = new Promise((resolve) => {
    const mod = JWKS_URL.startsWith('https:') ? require('https') : http;
    const r = mod.get(JWKS_URL, { timeout: 5000 }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        try {
          if (res.statusCode !== 200) throw new Error(`HTTP ${res.statusCode}`);
          const next = new Map();
          for (const k of JSON.parse(Buffer.concat(chunks).toString('utf8')).keys || []) {
            if (k.kty === 'EC' && k.crv === 'P-256' && k.kid) next.set(k.kid, crypto.createPublicKey({ key: k, format: 'jwk' }));
          }
          jwks = next; jwksAt = Date.now();
        } catch (e) { log(`JWKS fetch from ${JWKS_URL} failed: ${e.message}`); }
        resolve();
      });
    });
    r.on('timeout', () => r.destroy(new Error('timeout')));
    r.on('error', (e) => { log(`JWKS fetch from ${JWKS_URL} failed: ${e.message}`); resolve(); });
  }).finally(() => { jwksFetching = null; });
  return jwksFetching;
}
const b64json = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));

async function pomeriumUser(req) {
  const jwt = req.headers['x-pomerium-jwt-assertion'];
  if (!jwt || !JWKS_URL) return { reason: jwt ? 'no JWKS URL configured' : 'no Pomerium assertion' };
  const parts = String(jwt).split('.');
  if (parts.length !== 3) return { reason: 'malformed assertion' };
  let header, claims;
  try { header = b64json(parts[0]); claims = b64json(parts[1]); } catch { return { reason: 'malformed assertion' }; }
  if (header.alg !== 'ES256') return { reason: `alg ${header.alg} not accepted` };
  if (!jwks.has(header.kid) && Date.now() - jwksAt > 60000) await fetchJwks();
  const key = jwks.get(header.kid);
  if (!key) return { reason: `unknown kid ${String(header.kid).slice(0, 12)}` };
  const ok = crypto.verify('sha256', Buffer.from(`${parts[0]}.${parts[1]}`), { key, dsaEncoding: 'ieee-p1363' }, Buffer.from(parts[2], 'base64url'));
  if (!ok) return { reason: 'bad signature' };
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== 'number' || claims.exp + CLOCK_SKEW < now) return { reason: 'expired assertion' };
  if (typeof claims.nbf === 'number' && claims.nbf - CLOCK_SKEW > now) return { reason: 'assertion not yet valid' };
  if (AUDIENCE) {
    const aud = [].concat(claims.aud || []).map((a) => String(a).toLowerCase());
    if (!aud.includes(AUDIENCE)) return { reason: `audience ${aud.join(',') || '(none)'} is not ${AUDIENCE}` };
  }
  return { user: claims.email || '', reason: claims.email ? '' : 'assertion has no email' };
}

async function identify(req) {
  if (AUTH === 'none') return { ok: true };
  let r;
  if (AUTH === 'pomerium') r = await pomeriumUser(req);
  else if (AUTH === 'header') {
    if (!fromTrustedProxy(req)) r = { reason: `request from ${req.socket.remoteAddress}, not a trusted proxy` };
    else r = req.headers[AUTH_HEADER] ? { user: String(req.headers[AUTH_HEADER]) } : { reason: `no ${AUTH_HEADER} header` };
  } else r = { reason: `unknown CLAUDE_WEB_AUTH=${AUTH}` };
  if (r.user && allowedUser(r.user)) return { ok: true, user: r.user };
  return { ok: false, user: r.user, reason: r.reason || `${r.user} is not in CLAUDE_WEB_ALLOWED_USERS` };
}

// One log line per user/reason a minute, so a reconnecting tab doesn't flood the log.
const denials = new Map();
function logDenied(req, who) {
  const k = `${who.user || '-'}|${who.reason}`;
  if (Date.now() - (denials.get(k) || 0) < 60000) return;
  denials.set(k, Date.now());
  log(`refused ${who.user || 'anonymous'} ${req.method} ${req.url.split('?')[0]}: ${who.reason}`);
}
// The reason goes in the body so a setup can be checked from the browser. It
// names the check that failed (audience, kid prefix, proxy address, user),
// never key material or configuration secrets.
const deniedBody = (who) => `Not authorized for this terminal: ${who.reason}.\nSee "Allowed users" in the README.\n`;

// ---- server ----------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  // Health check: no user, no log line, nothing about the terminal.
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
    return res.end('ok\n');
  }
  const who = await identify(req).catch((e) => ({ ok: false, reason: `check failed: ${e.message}` }));
  if (!who.ok) {
    logDenied(req, who);
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
    return res.end(deniedBody(who));
  }
  const url = req.url.split('?')[0];
  if (url === '/api/whoami') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    return res.end(JSON.stringify({ auth: AUTH, user: who.user || null }));
  }
  if (url === '/api/sessions') {
    if (!authorized(req)) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="ttyd"' });
      return res.end();
    }
    let body;
    try { body = JSON.stringify(sessions()); } catch (e) { res.writeHead(500); return res.end(String(e)); }
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    return res.end(body);
  }

  const isPage = req.method === 'GET' && (url === '/' || url === '/index.html');
  const headers = { ...req.headers };
  if (isPage) delete headers['accept-encoding']; // plain HTML so the badge can go in
  const up = http.request({ host: '127.0.0.1', port: TTYD_PORT, method: req.method, path: req.url, headers }, (ur) => {
    const ok = isPage && ur.statusCode === 200 && /text\/html/.test(ur.headers['content-type'] || '') && !ur.headers['content-encoding'];
    if (!ok) {
      res.writeHead(ur.statusCode, ur.headers);
      return ur.pipe(res);
    }
    const chunks = [];
    ur.on('data', (c) => chunks.push(c));
    ur.on('end', () => {
      const out = Buffer.from(inject(Buffer.concat(chunks).toString('utf8')));
      const h = { ...ur.headers, 'content-length': out.length, 'cache-control': 'no-store' };
      delete h['transfer-encoding'];
      res.writeHead(200, h);
      res.end(out);
    });
  });
  up.on('error', (e) => {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end(`web terminal not reachable: ${e.code || e.message}\n`);
  });
  req.pipe(up);
});

// Websocket (and any other) upgrade: replay the request to ttyd and splice the sockets.
server.on('upgrade', async (req, sock, head) => {
  sock.on('error', () => sock.destroy());
  const who = await identify(req).catch((e) => ({ ok: false, reason: `check failed: ${e.message}` }));
  if (!who.ok) {
    logDenied(req, who);
    const body = Buffer.from(deniedBody(who));
    sock.end(`HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`);
    return;
  }
  const up = net.connect(TTYD_PORT, '127.0.0.1', () => {
    let raw = `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    up.write(raw + '\r\n');
    if (head && head.length) up.write(head);
    sock.pipe(up).pipe(sock);
  });
  const close = () => { sock.destroy(); up.destroy(); };
  up.on('error', close);
  sock.on('error', close);
  up.on('close', close);
  sock.on('close', close);
});

server.keepAliveTimeout = 65000;
server.listen(PORT, '0.0.0.0', () => {
  log(`listening on :${server.address().port}, terminal on 127.0.0.1:${TTYD_PORT}`);
  log(AUTH === 'none' ? 'user check: off (CLAUDE_WEB_AUTH=none)' : `user check: ${AUTH}, allowed: ${ALLOWED.join(', ') || '(nobody)'}`);
  if (AUTH === 'pomerium' && JWKS_URL) fetchJwks();
});
for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => { server.close(); process.exit(0); });
