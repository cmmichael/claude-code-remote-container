#!/bin/bash
# Keeps Claude Code available three ways:
#   1. A persistent interactive session in tmux ("claude"), served as a web
#      terminal by ttyd on :7681. It resumes the last conversation and has
#      Remote Control on, so it also shows up in claude.ai/code and the Claude app.
#   2. A Claude Code Remote Control server, so new sessions can be started from
#      claude.ai/code and the Claude app.
#   3. claude-update-watcher, which applies Claude Code's background auto-updates
#      by restarting idle sessions onto the new version.
#
# First start: open the web terminal (or `docker exec -it <container> claude`),
# /login with a claude.ai account (Remote Control needs one; API keys don't work
# for it) and accept the /workspace trust prompt. The loops pick it up afterwards.
set -u

export PATH="$HOME/.local/bin:$PATH"
STATE="$HOME/.claude/autoupdate-state"
mkdir -p "$STATE"
cd /workspace

if [ ! -w "$HOME" ]; then
  echo "[claude-web] $HOME is not writable by uid $(id -u); fix ownership of the config volume" >&2
fi

# Install Claude Code in the background so the web terminal comes up even when
# the install cannot run yet (no network on first start, say). The session
# loop waits for the binary, and the terminal gives a shell meanwhile.
loops=()   # background loops that on_stop ends
if ! command -v claude >/dev/null 2>&1; then
  (
    until command -v claude >/dev/null 2>&1; do
      echo "[claude-web] claude binary not found -- installing to $HOME/.local/bin"
      curl -fsSL https://claude.ai/install.sh | bash && break
      echo "[claude-web] install failed, retrying in 60s"
      sleep 60
    done
  ) &
  loops+=($!)
fi

# Hooks that tell the update watcher when a turn is in flight and which
# conversation the web session is on. Merged into the user settings once;
# gated on CLAUDE_WEB_INTERACTIVE so Remote Control sessions started from the
# app don't touch the state files.
settings="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -s "$settings" ] || echo '{}' > "$settings"
if ! grep -q 'autoupdate-state' "$settings"; then
  hook() {
    printf '[ -n "$CLAUDE_WEB_INTERACTIVE" ] || exit 0; d="$HOME/.claude/autoupdate-state"; mkdir -p "$d"; date +%%s > "$d/%s"; jq -r ".session_id // empty" > "$d/session-id.tmp" && [ -s "$d/session-id.tmp" ] && mv "$d/session-id.tmp" "$d/session-id"; exit 0' "$1"
  }
  tmp=$(mktemp)
  if jq --arg p "$(hook last-prompt)" --arg s "$(hook last-stop)" '
      .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{hooks: [{type: "command", command: $p, timeout: 10}]}])
    | .hooks.Stop             = ((.hooks.Stop             // []) + [{hooks: [{type: "command", command: $s, timeout: 10}]}])
    ' "$settings" > "$tmp"; then
    cat "$tmp" > "$settings"
    echo "[claude-web] installed auto-update hooks into $settings"
  else
    echo "[claude-web] could not parse $settings; auto-update hooks not installed" >&2
  fi
  rm -f "$tmp"
fi

# Start the interactive session now so it runs before anyone opens the web
# terminal. ttyd's "new-session -A" recreates it if it ever goes away.
tmux new-session -d -s claude -x 200 -y 50 /usr/local/bin/claude-session 2>/dev/null || true

# --index serves the newer web client built in the Dockerfile (OSC 52 clipboard).
# macOptionClickForcesSelection lets Option+drag select text on macOS while tmux
# and Claude Code hold the mouse; Windows/Linux use Shift+drag.
ttyd_args=(--writable --port 7681 --interface 0.0.0.0 -t "titleFixed=${CLAUDE_WEB_TITLE:-claude}" -t fontSize=14
  -t macOptionClickForcesSelection=true)
[ -f /usr/share/ttyd/index.html ] && ttyd_args+=(--index /usr/share/ttyd/index.html)
if [ -n "${TTYD_CREDENTIAL:-}" ]; then
  ttyd_args+=(--credential "$TTYD_CREDENTIAL")
fi
(
  while true; do
    ttyd "${ttyd_args[@]}" tmux new-session -A -s claude /usr/local/bin/claude-session
    echo "[claude-web] ttyd exited -- restarting in 5s"
    sleep 5
  done
) &
loops+=($!)

if [ "${CLAUDE_AUTO_UPDATE_RESTART:-true}" = "true" ]; then
  /usr/local/bin/claude-update-watcher &
  loops+=($!)
fi

if [ "${CLAUDE_REMOTE_CONTROL_SERVER:-true}" = "true" ]; then
  (
    while true; do
      claude remote-control || true
      echo "[claude-web] remote-control exited -- restarting in 30s (log in via the web terminal if this repeats)"
      sleep 30
    done
  ) &
  loops+=($!)
fi

# Stop cleanly. `docker stop` signals only this script (through tini). Without
# this, every Claude process would be SIGKILLed when the stop timeout ran out:
# mid tool call, with its Remote Control session left dangling. Stop the loops
# first so nothing restarts, give every Claude process a SIGTERM and up to
# STOP_GRACE_SECS to exit, then take tmux down. docker-compose.yml allows 30s.
STOP_GRACE_SECS="${CLAUDE_STOP_GRACE_SECS:-20}"
# Interactive sessions run as "claude ..."; sessions the Remote Control server
# spawns run as the versioned binary's full path.
CLAUDE_PROC_RE="^(claude|$HOME/\.local/share/claude/versions/[^ ]+)( |\$)"
on_stop() {
  trap '' TERM INT
  echo "[claude-web] stopping: asking Claude to exit (up to ${STOP_GRACE_SECS}s)"
  kill "${loops[@]}" 2>/dev/null
  pkill -x ttyd 2>/dev/null
  local pids i
  pids=$(pgrep -f "$CLAUDE_PROC_RE")
  [ -n "$pids" ] && kill -TERM $pids 2>/dev/null
  for ((i = 0; i < STOP_GRACE_SECS * 2; i++)); do
    pgrep -f "$CLAUDE_PROC_RE" >/dev/null || break
    sleep 0.5
  done
  pgrep -f "$CLAUDE_PROC_RE" >/dev/null && echo "[claude-web] Claude did not exit within ${STOP_GRACE_SECS}s; stopping anyway"
  tmux kill-server 2>/dev/null
  exit 143
}
trap on_stop TERM INT

# wait returns early when a trapped signal arrives, so the trap runs at once.
while true; do wait; sleep 1; done
