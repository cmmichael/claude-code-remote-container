#!/bin/bash
# Applies Claude Code auto-updates without anyone pressing "restart to update".
#
# Claude Code downloads new versions in the background but keeps running the old
# one until restarted. This loop watches for that gap and, once the interactive
# session has been idle for a while, stops it; session.sh immediately starts the
# new version on the same conversation. The Remote Control server is restarted
# once every session under it is idle (see below); its sessions reattach.
#
# Idle = no turn in flight (the UserPromptSubmit/Stop hooks stamp last-prompt and
# last-stop) AND nothing typed or printed in the tmux session for IDLE_SECS.
# tmux keeps the two apart: session_activity moves when a client types,
# window_activity when the pane prints (Claude's spinner prints while it works).
#
# The Remote Control server always has children: the session it creates on
# start comes back on every restart, and the server reattaches its sessions
# after one. So it is restarted when every session under it is idle (the hook
# stamps those per process in procs/<pid>), not when it has none.
export PATH="$HOME/.local/bin:$PATH"
STATE="$HOME/.claude/autoupdate-state"
IDLE_SECS="${CLAUDE_UPDATE_IDLE_SECS:-900}"
RC_NAME="${CLAUDE_RC_NAME:-$(hostname)-web}"
STALE_TURN_SECS="${CLAUDE_UPDATE_STALE_TURN_SECS:-3600}"
BOOT=$(awk '/^btime/ {print $2}' /proc/stat)
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
RC_NAME_RE=$(printf '%s' "$RC_NAME" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
mkdir -p "$STATE"

log() { echo "[claude-update] $*"; }

# Every Claude session under the Remote Control server is idle: no turn in
# flight (an interrupted turn stamps no Stop, so it stops counting after
# STALE_TURN_SECS) and no prompt, finished turn or start for IDLE_SECS.
server_idle() {  # $1 = server pid
  local kid lp ls started last now
  now=$(date +%s)
  for kid in $(pgrep -P "$1"); do
    case $(readlink "/proc/$kid/exe" 2>/dev/null) in "$HOME"/.local/share/claude/versions/*) ;; *) continue ;; esac
    lp=$(cat "$STATE/procs/$kid/last-prompt" 2>/dev/null || echo 0)
    ls=$(cat "$STATE/procs/$kid/last-stop" 2>/dev/null || echo 0)
    started=$(( BOOT + $(awk '{sub(/.*\) /, ""); print $20}' "/proc/$kid/stat" 2>/dev/null || echo 0) / HZ ))  # starttime; comm may hold spaces
    last=$lp; [ "$ls" -gt "$last" ] && last=$ls; [ "$started" -gt "$last" ] && last=$started
    if [ "$lp" -gt "$ls" ] && [ $((now - lp)) -lt "$STALE_TURN_SECS" ]; then return 1; fi
    [ $((now - last)) -ge "$IDLE_SECS" ] || return 1
  done
  return 0
}

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
    tmux_last=$(tmux display -p -t claude '#{session_activity} #{window_activity}' 2>/dev/null \
                | awk '{print ($1 > $2 ? $1 : $2)}')
    tmux_last=${tmux_last:-$now}
    # A turn is in flight when the last prompt has no Stop after it; an
    # interrupted turn never gets one, so after STALE_TURN_SECS of quiet it
    # stops counting.
    if { [ "$last_stop" -ge "$last_prompt" ] || [ $((now - tmux_last)) -ge "$STALE_TURN_SECS" ]; } \
       && [ $((now - last_stop)) -ge "$IDLE_SECS" ] \
       && [ $((now - tmux_last)) -ge "$IDLE_SECS" ]; then
      log "$(running_version "$pid") -> $latest installed; session idle $((now - tmux_last))s; restarting interactive claude (pid $pid)"
      kill -TERM "$pid"
      sleep 30
      continue
    fi
  fi

  # --- remote-control server: restart when every session under it is idle ---
  rpid=$(pgrep -f -o '^claude remote-control$')
  if [ -n "$rpid" ] && [ "$(running_version "$rpid")" != "$latest" ] && server_idle "$rpid"; then
    log "$(running_version "$rpid") -> $latest installed; remote-control server's sessions idle; restarting it (pid $rpid); they reattach"
    kill -TERM "$rpid"
  fi
  for d in "$STATE"/procs/*/; do
    [ -d "$d" ] || continue
    d=${d%/}; [ -e "/proc/${d##*/}" ] || rm -rf "$d"
  done
done
