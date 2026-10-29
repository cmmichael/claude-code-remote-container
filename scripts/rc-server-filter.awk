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
# latest one is written to $titles/<ID>, only when it changes. Status words
# (Attached, Connecting, ...) are not titles.
NF {
  if (match($0, /session_[A-Za-z0-9]+\?from=cli /)) {
    id = substr($0, RSTART + 8, RLENGTH - 8 - 10)
    rest = substr($0, RSTART + RLENGTH)
    sub(/^[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
    if (rest != "" && rest !~ /^(Attached|Detached|Connecting|Connected|Reconnecting|Disconnected|Starting|Working|Idle|Running|Waiting|Closed|Ended|Failed|Error)$/ \
        && title[id] != rest && titles != "") {
      title[id] = rest
      f = titles "/" id
      print rest > f
      close(f)
    }
  }
  t = systime()
  if (!($0 in seen) || t - seen[$0] > 30) { print "[rc-server] " $0; fflush() }
  seen[$0] = t
}
