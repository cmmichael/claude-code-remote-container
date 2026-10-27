#!/bin/bash
# Applies Claude Code auto-updates without anyone pressing "restart to update".
#
# Claude Code downloads new versions in the background but keeps running the old
# one until restarted. This loop watches for that gap and, once the interactive
# session has been idle for a while, stops it; session.sh immediately starts the
# new version on the same conversation. The Remote Control server is restarted
# the same way when it has no live sessions under it.
#
# Idle = no turn in flight (the UserPromptSubmit/Stop hooks stamp last-prompt and
# last-stop) AND nothing typed or printed in the tmux session for IDLE_SECS.
export PATH="$HOME/.local/bin:$PATH"
STATE="$HOME/.claude/autoupdate-state"
IDLE_SECS="${CLAUDE_UPDATE_IDLE_SECS:-900}"
RC_NAME="${CLAUDE_RC_NAME:-$(hostname)-web}"
RC_NAME_RE=$(printf '%s' "$RC_NAME" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
mkdir -p "$STATE"

log() { echo "[claude-update] $*"; }

latest_version() { basename "$(readlink -f "$(command -v claude)")"; }
running_version() { basename "$(readlink -f "/proc/$1/exe" 2>/dev/null)"; }

while sleep 60; do
  latest=$(latest_version) || continue
  now=$(date +%s)

  # --- interactive session (tmux "claude") ---
  pid=$(pgrep -f -o "^claude (--resume [^ ]+ |--continue )?--remote-control ${RC_NAME_RE}\$")
  if [ -n "$pid" ] && [ "$(running_version "$pid")" != "$latest" ]; then
    last_prompt=$(cat "$STATE/last-prompt" 2>/dev/null || echo 0)
    last_stop=$(cat "$STATE/last-stop" 2>/dev/null || echo 0)
    tmux_last=$(tmux display -p -t claude '#{session_activity}' 2>/dev/null || echo "$now")
    if [ "$last_stop" -ge "$last_prompt" ] \
       && [ $((now - last_stop)) -ge "$IDLE_SECS" ] \
       && [ $((now - tmux_last)) -ge "$IDLE_SECS" ]; then
      log "$(running_version "$pid") -> $latest installed; session idle $((now - tmux_last))s; restarting interactive claude (pid $pid)"
      kill -TERM "$pid"
      sleep 30
      continue
    fi
  fi

  # --- remote-control server: restart only when it has no sessions running under it ---
  rpid=$(pgrep -f -o '^claude remote-control$')
  if [ -n "$rpid" ] && [ "$(running_version "$rpid")" != "$latest" ] && [ -z "$(pgrep -P "$rpid")" ]; then
    log "$(running_version "$rpid") -> $latest installed; remote-control server idle; restarting it (pid $rpid)"
    kill -TERM "$rpid"
  fi
done
