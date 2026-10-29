# Filters `claude remote-control` output for the container log, and records
# each session's title for the sessions badge.
#
# The server repaints its status block about once a second. A line is printed
# only when it is new or has been off the screen for over 30 s, so the log
# shows the connect, the environment link and each session that attaches, not
# the repaints.
#
# Session lines look like
#   https://claude.ai/code/session_<ID>?from=cli <title or status>
# The title is what claude.ai and the Claude app show for the session. The
# latest one (at most 200 characters) is written to $titles/<ID>, only when it
# changes; the entrypoint clears the folder at start and the server reprints
# every session as it reattaches. Status words
# (Attached, Connecting, ...) are not titles.
NF {
  if (match($0, /session_[A-Za-z0-9]+(\?from=cli)?[ \t]+/)) {
    seg = substr($0, RSTART, RLENGTH); rest = substr($0, RSTART + RLENGTH)
    match(seg, /^session_[A-Za-z0-9]+/); id = substr(seg, 9, RLENGTH - 8)
    sub(/^[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
    if (rest != "" && rest !~ /^(Attached|Detached|Connecting|Connected|Reconnecting|Disconnected|Starting|Working|Idle|Running|Waiting|Closed|Ended|Failed|Error)$/ \
        && title[id] != rest && titles != "") {
      title[id] = rest
      f = titles "/" id
      print substr(rest, 1, 200) > f
      close(f)
    }
  }
  t = systime()
  if (!($0 in seen) || t - seen[$0] > 30) { print "[rc-server] " $0; fflush() }
  seen[$0] = t
}
