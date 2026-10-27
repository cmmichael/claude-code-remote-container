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
cd /workspace

until command -v claude >/dev/null 2>&1; do
  echo "[claude-web] waiting for Claude Code to finish installing (see the container log); Ctrl-C for a shell"
  if ! sleep 10; then
    bash -l
  fi
done

while true; do
  sid=$(cat "$STATE/session-id" 2>/dev/null || true)
  if [ -n "$sid" ]; then
    claude --resume "$sid" --remote-control "$RC_NAME" \
      || claude --continue --remote-control "$RC_NAME" \
      || claude --remote-control "$RC_NAME"
  else
    claude --continue --remote-control "$RC_NAME" || claude --remote-control "$RC_NAME"
  fi

  echo
  echo "[claude-web] claude exited. Restarting in 5s -- Ctrl-C for a shell (type 'exit' to come back)."
  if ! sleep 5; then
    bash -l
  fi
done
