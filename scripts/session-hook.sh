#!/bin/bash
# claude-session-hook last-prompt|last-stop
#
# UserPromptSubmit / Stop hook, installed into $HOME/.claude/settings.json by
# entrypoint.sh. It tells claude-update-watcher when a turn is in flight:
#
# - The web-terminal session (CLAUDE_WEB_INTERACTIVE, set by session.sh)
#   stamps autoupdate-state/last-prompt and last-stop, and records its
#   conversation in autoupdate-state/session-id for session.sh to resume.
# - Sessions the Remote Control server spawns are stamped per Claude process
#   in autoupdate-state/procs/<pid>/, so the watcher can tell when every
#   session under the server is idle.
#
# It must never get in Claude's way: it always exits 0 and prints nothing.
d="$HOME/.claude/autoupdate-state"
case "${1:-}" in last-prompt|last-stop) ;; *) exit 0 ;; esac
if [ -n "${CLAUDE_WEB_INTERACTIVE:-}" ]; then
  mkdir -p "$d" 2>/dev/null || exit 0
  date +%s > "$d/$1"
  jq -r '.session_id // empty' > "$d/session-id.tmp" 2>/dev/null \
    && [ -s "$d/session-id.tmp" ] && mv "$d/session-id.tmp" "$d/session-id"
  exit 0
fi
# The Claude process this hook runs for: the nearest ancestor executing a
# Claude Code release from the native installer.
pid=$PPID
while [ "${pid:-0}" -gt 1 ]; do
  case $(readlink "/proc/$pid/exe" 2>/dev/null) in "$HOME"/.local/share/claude/versions/*) break ;; esac
  pid=$(awk '{sub(/.*\) /, ""); print $2}' "/proc/$pid/stat" 2>/dev/null)  # ppid; comm may hold spaces
done
[ "${pid:-0}" -gt 1 ] && mkdir -p "$d/procs/$pid" 2>/dev/null && date +%s > "$d/procs/$pid/$1"
exit 0
