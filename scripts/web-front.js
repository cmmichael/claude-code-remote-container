#!/usr/bin/env node
// Front end for the web terminal. Listens on the public port (7681) and:
//   GET /api/sessions  -> the Remote Control server's live sessions as JSON
//   GET /              -> ttyd's page with the sessions badge (web-badge.html) added
//   anything else      -> proxied to ttyd on 127.0.0.1:$TTYD_INTERNAL_PORT,
//                         websocket upgrades included
// The sessions the Remote Control server spawns are headless (--print --sdk-url),
// so the terminal can't show them; the badge lists them with a link to
// claude.ai/code. Data comes from /proc and the session hook's stamps in
// $HOME/.claude/autoupdate-state/procs/<pid>/last-prompt|last-stop.
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
  const server = pids().find((p) => argv(p).join(' ') === 'claude remote-control');
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

// ---- server ----------------------------------------------------------------
const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
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
server.on('upgrade', (req, sock, head) => {
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
server.listen(PORT, '0.0.0.0', () => log(`listening on :${PORT}, terminal on 127.0.0.1:${TTYD_PORT}`));
for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => { server.close(); process.exit(0); });
