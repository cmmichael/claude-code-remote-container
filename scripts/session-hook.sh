#!/bin/bash
# claude-session-hook last-prompt|last-stop
#
# UserPromptSubmit / Stop hook, installed into $HOME/.claude/settings.json by
# entrypoint.sh. It tells claude-update-watcher when a turn is in flight:
#
# - The web-terminal session (the claude session.sh started)
#   stamps autoupdate-state/last-prompt and last-stop, and records its
#   conversation in autoupdate-state/session-id for session.sh to resume.
# - Sessions the Remote Control server spawns are stamped per Claude process
#   in autoupdate-state/procs/<pid>/, so the watcher can tell when every
#   session under the server is idle.
#
# It must never get in Claude's way: it always exits 0 and prints nothing.
d="$HOME/.claude/autoupdate-state"
case "${1:-}" in last-prompt|last-stop) ;; *) exit 0 ;; esac
# The Claude process this hook runs for: the nearest ancestor executing a
# Claude Code release from the native installer.
ppid_of() { awk '{sub(/.*\) /, ""); print $2}' "/proc/$1/stat" 2>/dev/null; }      # after the comm, which may hold spaces
pid=$PPID
while [ "${pid:-0}" -gt 1 ]; do
  case $(readlink "/proc/$pid/exe" 2>/dev/null) in "$HOME"/.local/share/claude/versions/*) break ;; esac
  pid=$(ppid_of "$pid")
done
[ "${pid:-0}" -gt 1 ] || exit 0
# The web-terminal session is the claude that session.sh started. Everything
# under it inherits CLAUDE_WEB_INTERACTIVE, so that alone would let a
# `claude -p` that Claude runs as a tool, or one typed in the Ctrl-C shell,
# overwrite session-id with its one-off conversation, and the next restart
# would resume that.
case $(tr '\0' ' ' < "/proc/$(ppid_of "$pid")/cmdline" 2>/dev/null) in
  *claude-session*)
    mkdir -p "$d" 2>/dev/null || exit 0
    date +%s > "$d/$1"
    jq -r '.session_id // empty' > "$d/session-id.tmp" 2>/dev/null \
      && [ -s "$d/session-id.tmp" ] && mv "$d/session-id.tmp" "$d/session-id"
    exit 0 ;;
esac
[ -n "${CLAUDE_WEB_INTERACTIVE:-}" ] && exit 0      # a one-off inside the web session: neither the session nor the server's
# A session the Remote Control server spawned: stamped per process.
mkdir -p "$d/procs/$pid" 2>/dev/null && date +%s > "$d/procs/$pid/$1"
exit 0
