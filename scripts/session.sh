#!/bin/bash
# Runs inside the persistent tmux session "claude", which the ttyd web terminal
# attaches to.
#
# Every launch resumes THIS session's conversation (its id is recorded by the
# UserPromptSubmit/Stop hooks that entrypoint.sh installs), falling back to the
# most recent conversation in /workspace, then to a fresh one. Transcripts live
# in $HOME/.claude on the config volume, so they survive container restarts.
#
# claude-update-watcher sends this claude process SIGTERM when a newer Claude
# Code version is installed and the session is idle; the loop below then starts
# the new version on the same conversation.
export PATH="$HOME/.local/bin:$PATH"
export CLAUDE_WEB_INTERACTIVE=1
STATE="$HOME/.claude/autoupdate-state"
RC_NAME="${CLAUDE_RC_NAME:-$(hostname)-web}"
cd /workspace || echo "[claude-web] /workspace is missing; staying in $PWD" >&2

until command -v claude >/dev/null 2>&1; do
  echo "[claude-web] waiting for Claude Code to finish installing (see the container log); Ctrl-C for a shell"
  if ! sleep 10; then
    bash -l
  fi
done

# Run one claude; succeed unless it failed by itself right away (a resume of a
# conversation that no longer exists, say). A claude stopped by a signal (the
# update watcher's SIGTERM, a container stop) or one that ran for a while
# counts as done, so the loop comes back to the same conversation by id rather
# than falling through to --continue, which opens whichever conversation in
# /workspace is newest.
try() {
  local t0 rc
  t0=$(date +%s)
  claude "$@" --remote-control "$RC_NAME"
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -gt 128 ] || [ $(( $(date +%s) - t0 )) -ge 30 ]
}

while true; do
  sid=$(cat "$STATE/session-id" 2>/dev/null || true)
  if [ -n "$sid" ]; then
    try --resume "$sid" || try --continue || try
  else
    try --continue || try
  fi

  # entrypoint.sh's on_stop marks a container stop; don't start Claude again.
  [ -e "$STATE/stopping" ] && exit 0
  echo
  echo "[claude-web] claude exited. Restarting in 5s -- Ctrl-C for a shell (type 'exit' to come back)."
  if ! sleep 5; then
    bash -l
  fi
  [ -e "$STATE/stopping" ] && exit 0
done
