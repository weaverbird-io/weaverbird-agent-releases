#!/bin/sh
# weaverbird-agent's update guard: systemd runs it before every start
# (ExecStartPre, as wbsim). Installed root-owned so the agent can't change it.
#
# After an update the agent writes update-pending; the new build removes it
# once a signed heartbeat succeeds. If the new build has started 3 times, or
# 10 minutes have passed, without that, point bin/current back at the build
# before (bin/prev) and leave update-failed for the next heartbeat to report.
# Always exits 0: a missing or odd marker must never stop the agent starting.
DIR=${WEAVERBIRD_AGENT_DIR:-/var/lib/weaverbird-agent}
P="$DIR/update-pending"
[ -f "$P" ] || exit 0
MAX_STARTS=${WEAVERBIRD_GUARD_MAX_STARTS:-3}
MAX_AGE=${WEAVERBIRD_GUARD_MAX_AGE:-600}
NOW=${WEAVERBIRD_GUARD_NOW:-$(date +%s)}

version=$(sed -n 's/^version=//p' "$P" | head -n1)
prev=$(sed -n 's/^prev=//p' "$P" | head -n1)
since=$(sed -n 's/^since=//p' "$P" | head -n1)
starts=$(sed -n 's/^starts=//p' "$P" | head -n1)

case "$version" in ''|*[!0-9A-Za-z.+-]*) rm -f "$P"; exit 0 ;; esac
case "$since" in ''|*[!0-9]*) since=0 ;; esac
case "$starts" in ''|*[!0-9]*) starts=0 ;; esac
starts=$((starts + 1))

if [ "$starts" -gt "$MAX_STARTS" ] || [ $((NOW - since)) -gt "$MAX_AGE" ]; then
  # Only ever back to a build of ours in bin/.
  case "$prev" in
    "$DIR"/bin/*/weaverbird-agent) ;;
    *) prev= ;;
  esac
  if [ -n "$prev" ] && [ -x "$prev" ]; then
    ln -sfn "$prev" "$DIR/bin/.current.rollback" && mv -fT "$DIR/bin/.current.rollback" "$DIR/bin/current"
    printf '%s\n' "$version" > "$DIR/update-failed"
    echo "weaverbird-agent: $version did not come up; back to $(basename "$(dirname "$prev")")" >&2
  fi
  rm -f "$P"
  exit 0
fi

printf 'version=%s\nprev=%s\nsince=%s\nstarts=%s\n' "$version" "$prev" "$since" "$starts" > "$P.new" && mv -f "$P.new" "$P"
exit 0
