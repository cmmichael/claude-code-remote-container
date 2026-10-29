#!/bin/bash
# Smoke test for the image: start it with a stand-in claude (no login, no
# download), check what the container provides, then stop it and check the
# clean stop.
#
#   IMAGE=claude-code-remote-container:ci tests/smoke.sh
#
# Needs docker, curl, jq and node on the host. Exits non-zero on the first
# failed check and prints the container log.
set -euo pipefail
# No `cmd | grep -q` below: grep -q exits at the first match, the writer gets
# SIGPIPE, and pipefail turns a found line into a failure. Capture, then grep.

IMAGE="${IMAGE:-claude-code-remote-container:ci}"
NAME="claude-smoke-$$"
PORT="${SMOKE_PORT:-17681}"
WORK=$(mktemp -d)
pass=0

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "----- container log -----" >&2
  docker logs "$NAME" 2>&1 | tail -60 >&2 || true
  exit 1
}
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

# --- a stand-in claude, laid out like the native installer's -------------
# It re-execs itself with argv[0] "claude", so its command line starts with
# "claude" the way the real one does and entrypoint.sh's stop logic finds it.
mkdir -p "$WORK/config/.local/share/claude/versions" "$WORK/config/.local/bin" "$WORK/workspace"
stub="$WORK/config/.local/share/claude/versions/0.0.0-stub"
cat > "$stub" <<'EOF'
#!/bin/bash
# The server runs as a script file named remote-control from its own folder,
# so its command line is exactly "claude remote-control ...", as for real.
if [ "${1:-}" = remote-control ]; then
  shift; cd /config/.local/share/claude/stub && exec -a claude /bin/bash remote-control "$@"
fi
if [ -z "${STUB_REEXEC:-}" ]; then STUB_REEXEC=1 exec -a claude /bin/bash "$0" "$@"; fi
case "${1:-}" in
  --version) echo "0.0.0-stub (Claude Code)"; exit 0 ;;
  *) trap 'exit 143' TERM ;;
esac
while :; do sleep 1; done
EOF
chmod +x "$stub"
mkdir -p "$WORK/config/.local/share/claude/stub"
cat > "$WORK/config/.local/share/claude/stub/remote-control" <<'EOF'
echo "stub remote-control server $*"
trap 'echo "stub server stopping"; exit 0' TERM
while :; do sleep 1; done
EOF
ln -s /config/.local/share/claude/versions/0.0.0-stub "$WORK/config/.local/bin/claude"

# --- start -----------------------------------------------------------------
docker run -d --name "$NAME" --init \
  --user "$(id -u):$(id -g)" \
  --health-interval 3s --health-start-period 5s \
  -e CLAUDE_RC_NAME=smoke-web \
  -v "$WORK/config:/config" -v "$WORK/workspace:/workspace" \
  -p "127.0.0.1:$PORT:7681" \
  "$IMAGE" >/dev/null || fail "container did not start"

for _ in $(seq 1 60); do
  state=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo gone)
  [ "$state" = healthy ] && break
  [ "$state" = gone ] && fail "container exited during start"
  sleep 1
done
[ "$state" = healthy ] || fail "not healthy after 60s (last: $state)"
ok "container becomes healthy"

# --- web front end -----------------------------------------------------------
page=$(curl -fsS "http://127.0.0.1:$PORT/") || fail "GET / failed"
grep -q 'id="cw-badge"' <<<"$page" || fail "terminal page has no sessions badge"
grep -q '</body>' <<<"$page" || fail "terminal page is truncated"
ok "terminal page served with the sessions badge"

json=$(curl -fsS "http://127.0.0.1:$PORT/api/sessions") || fail "GET /api/sessions failed"
jq -e 'has("server") and (.server | has("running"))' >/dev/null <<<"$json" || fail "/api/sessions: unexpected JSON: $json"
ok "/api/sessions answers JSON"

curl -fsS -o /dev/null "http://127.0.0.1:$PORT/token" || fail "GET /token (ttyd, through the proxy) failed"
health=$(curl -fsS "http://127.0.0.1:$PORT/healthz?full=1") || fail "GET /healthz failed"
jq -e '.ok and .terminal and .claude_code == "0.0.0-stub" and .remote_control_server and .update_watcher' >/dev/null <<<"$health" \
  || fail "/healthz?full=1 reports a part down: $health"
ok "ttyd reachable through the proxy; /healthz reports every part up"

node - "$PORT" <<'EOF' || fail "websocket session through the proxy failed"
const http = require('http'), crypto = require('crypto');
const port = +process.argv[2];
const req = http.request({ host: '127.0.0.1', port, path: '/ws', headers: {
  Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13',
  'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64'), 'Sec-WebSocket-Protocol': 'tty' } });
req.on('upgrade', (res, sock) => {
  const msg = Buffer.from(JSON.stringify({ AuthToken: '', columns: 80, rows: 24 }));
  const mask = crypto.randomBytes(4);
  sock.write(Buffer.concat([Buffer.from([0x81, 0x80 | msg.length]), mask, Buffer.from(msg.map((b, i) => b ^ mask[i % 4]))]));
  let n = 0;
  sock.on('data', (d) => { n += d.length; });
  setTimeout(() => { sock.destroy(); if (n > 0) process.exit(0); console.error('no terminal output'); process.exit(1); }, 2000);
});
req.on('response', (r) => { console.error('no upgrade, status', r.statusCode); process.exit(1); });
req.on('error', (e) => { console.error(e.message); process.exit(1); });
req.end();
EOF
ok "websocket terminal session streams output"

# --- inside the container ------------------------------------------------------
docker exec "$NAME" tmux has-session -t claude 2>/dev/null || fail "tmux session 'claude' is missing"
ok "tmux session running"

settings="$WORK/config/.claude/settings.json"
jq -e '.hooks.UserPromptSubmit[0].hooks[0].command == "/usr/local/bin/claude-session-hook last-prompt"
       and .hooks.Stop[0].hooks[0].command == "/usr/local/bin/claude-session-hook last-stop"
       and .autoUpdatesChannel == "stable"' "$settings" >/dev/null || fail "settings.json hooks/channel wrong: $(cat "$settings")"
ok "hooks and update channel written to settings.json"

sshcfg=$(docker exec "$NAME" ssh -G example.org 2>&1) || fail "ssh -G failed: $sshcfg"
grep -q '^user ' <<<"$sshcfg" || fail "ssh can't resolve a user for an unknown uid"
ok "ssh works for a uid without a passwd entry"

docker exec "$NAME" pgrep -f '^/bin/bash /usr/local/bin/claude-update-watcher' >/dev/null || fail "update watcher not running"
ok "update watcher running"

grep -q 'stub remote-control server --spawn=same-dir --name ' <<<"$(docker logs "$NAME" 2>&1)" \
  || fail "Remote Control server not started with --spawn=same-dir and --name"
ok "Remote Control server starts with --spawn=same-dir and keeps its own session"

if grep -q 'could not parse' <<<"$(docker logs "$NAME" 2>&1)"; then fail "entrypoint could not parse settings.json"; fi
ok "no entrypoint errors"

# --- clean stop ------------------------------------------------------------------
t0=$(date +%s)
docker stop -t 30 "$NAME" >/dev/null
dt=$(( $(date +%s) - t0 ))
code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
logs=$(docker logs "$NAME" 2>&1)
grep -q '\[claude-web\] stopping' <<<"$logs" || fail "on_stop never ran"
[ "$code" = 143 ] || fail "exit code $code after stop, expected 143"
[ "$dt" -lt 25 ] || fail "stop took ${dt}s (Docker's kill would have hit at 30s)"
if grep -q 'did not exit within' <<<"$logs"; then fail "Claude did not exit within the grace period"; fi
ok "clean stop in ${dt}s with exit 143"

echo "all $pass checks passed"
