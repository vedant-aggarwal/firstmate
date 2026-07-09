#!/usr/bin/env bash
# fm-idle.sh - cache-temperature report for the fleet.
#
# Claude Code's prompt cache goes cold ~5 minutes after a session's last
# activity. Waking a COLD session re-reads its whole transcript at full
# price; waking a WARM one is nearly free. Consult this before poking
# crewmates: batch instructions to COLD sessions, prefer respawn-from-brief
# for heavy transcripts (see data/captain.md, "Cache & token hygiene").
#
# Usage: fm-idle.sh            table for every task with a state file
#        fm-idle.sh <task-id>  one line for one task
# Output columns: task-id  age  temp(WARM|COLD)  last-status-line
set -eu

FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_ROOT/state}
WARM_SECS=${FM_WARM_SECS:-300}

now=$(date +%s)

report_one() {
  local id=$1 stamp="" src="" age temp last
  # Freshest signal wins: turn-ended marker, else status-file mtime.
  for f in "$STATE/$id.turn-ended" "$STATE/$id.status"; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
    if [ -z "$stamp" ] || [ "$m" -gt "$stamp" ]; then stamp=$m; src=$f; fi
  done
  [ -n "$stamp" ] || { printf '%-28s %8s  %s\n' "$id" "-" "no state"; return; }
  age=$(( now - stamp ))
  if [ "$age" -le "$WARM_SECS" ]; then temp=WARM; else temp=COLD; fi
  if [ "$age" -ge 3600 ]; then age_h="$(( age / 3600 ))h$(( (age % 3600) / 60 ))m"
  elif [ "$age" -ge 60 ]; then age_h="$(( age / 60 ))m"
  else age_h="${age}s"; fi
  last=$(tail -n 1 "$STATE/$id.status" 2>/dev/null | cut -c1-80 || true)
  printf '%-28s %8s  %-4s  %s\n' "$id" "$age_h" "$temp" "$last"
}

if [ $# -ge 1 ]; then
  report_one "$1"
else
  printf '%-28s %8s  %-4s  %s\n' "TASK" "IDLE" "TEMP" "LAST STATUS"
  found=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    found=1
    id=$(basename "$meta" .meta)
    report_one "$id"
  done
  [ "$found" = 1 ] || echo "no tasks in $STATE"
fi
