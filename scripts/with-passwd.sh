#!/bin/sh
# The container runs as an arbitrary uid (PUID) that has no /etc/passwd entry.
# OpenSSH refuses to run without one ("No user exists for uid ..."), so ssh,
# scp, sftp, ssh-keygen and ssh-add are symlinked here: when the uid is unknown,
# nss_wrapper supplies a passwd/group entry for this process only, then the real
# tool runs.
tool=$(basename "$0")
real="/usr/bin/$tool"
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  d="${XDG_RUNTIME_DIR:-/tmp}/nss-$(id -u)"
  mkdir -p "$d"
  echo "claude:x:$(id -u):$(id -g):claude:$HOME:/bin/bash" > "$d/passwd"
  echo "claude:x:$(id -g):" > "$d/group"
  lib=$(ls /usr/lib/*/libnss_wrapper.so 2>/dev/null | head -1)
  [ -n "$lib" ] && export LD_PRELOAD="$lib" NSS_WRAPPER_PASSWD="$d/passwd" NSS_WRAPPER_GROUP="$d/group"
fi
exec "$real" "$@"
