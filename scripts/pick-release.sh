#!/bin/bash
# Keeps `claude` pointing at a release that runs here. Claude Code's updater
# moves the link to each new release, and the update watcher only keeps running
# sessions off one that fails. A session started later would still crash-loop on
# it, leaving nothing to fix the machine from. So before each start: if the
# linked release does not answer --version, link the newest other one that does.
# The updater may move the link on again; the next start checks again.
link="$HOME/.local/bin/claude"
versions="$HOME/.local/share/claude/versions"

runs() { timeout "${CLAUDE_RELEASE_CHECK_SECS:-30}" "$1" --version </dev/null >/dev/null 2>&1; }

current=$(readlink -f "$link") || exit 0
[ -e "$current" ] || [ -L "$link" ] || exit 0   # nothing installed yet
runs "$current" && exit 0

while read -r v; do
  [ "$versions/$v" = "$current" ] && continue
  if [ -x "$versions/$v" ] && runs "$versions/$v"; then
    ln -sfn "$versions/$v" "$link.new" && mv -Tf "$link.new" "$link"
    echo "[claude-web] Claude Code $(basename "$current") does not run here; using $v"
    exit 0
  fi
done < <(ls -1 "$versions" 2>/dev/null | sort -rV)

echo "[claude-web] Claude Code $(basename "$current") does not run here, and no other installed release does" >&2
exit 1
