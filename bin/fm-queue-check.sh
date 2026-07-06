#!/usr/bin/env bash
# fm-queue-check.sh - standing due-check over data/backlog.md (the ONE ledger).
#
# Scans the backlog for machine trigger tags and prints ONE line to stdout
# when something needs firstmate's attention, nothing otherwise - the
# fm-watch.sh *.check.sh contract (state/queue.check.sh is a stub that execs
# this). fm-agentd also runs it on its tick as the always-on backstop, so the
# same nudge reaches the main session even when no watcher is armed.
#
# Tags scanned:
#   due:YYYY-MM-DD     on an unchecked "- [ ]" line: fires when the date
#                      arrives, then re-fires once per day until handled
#   blocked-by:<id>    fires when <id> appears as "- [x] <id>" in the ledger
#   (since YYYY-MM-DD) on "## Awaiting captain" lines: one aggregated nag per
#                      day while any item is older than FM_NAG_DAYS (default 3)
#
# Dedupe: state/.queue-fired holds "<key> <date>" records; each key fires at
# most once per day regardless of which runner (watcher or agentd) got there
# first. The file is pruned to today's records on every run.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${FM_HOME:-$ROOT}"
BACKLOG="$HOME_DIR/data/backlog.md"
STATE="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"
FIRED="$STATE/.queue-fired"
NAG_DAYS="${FM_NAG_DAYS:-3}"

[ -f "$BACKLOG" ] || exit 0
[ -d "$STATE" ] || exit 0
TODAY=$(date +%F) || exit 0
CUTOFF=$(date -d "$NAG_DAYS days ago" +%F 2>/dev/null || echo "$TODAY")

touch "$FIRED"
grep " $TODAY\$" "$FIRED" > "$FIRED.tmp" 2>/dev/null || true
mv "$FIRED.tmp" "$FIRED"

fired_today() { grep -q "^$1 $TODAY\$" "$FIRED" 2>/dev/null; }
mark() { printf '%s %s\n' "$1" "$TODAY" >> "$FIRED"; }

out=""
add() { out="${out:+$out; }$1"; }

# 1. due: dates that have arrived (unchecked lines only)
while IFS= read -r line; do
  d=$(printf '%s' "$line" | sed -n 's/.*due:\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p')
  [ -n "$d" ] || continue
  [[ "$d" > "$TODAY" ]] && continue
  id=$(printf '%s' "$line" | sed -n 's/^- \[[ x]*\] *\([A-Za-z0-9_-]*\).*/\1/p')
  [ -n "$id" ] || id="unnamed"
  fired_today "due-$id" && continue
  add "DUE: $id (due:$d)"
  mark "due-$id"
done < <(grep -E '^- \[ \].*due:[0-9]{4}-[0-9]{2}-[0-9]{2}' "$BACKLOG" 2>/dev/null || true)

# 2. blocked-by:<id> whose blocker is now checked off
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  grep -qE "^- \[x\] $dep\b" "$BACKLOG" || continue
  fired_today "unblocked-$dep" && continue
  add "UNBLOCKED: item(s) waiting on $dep"
  mark "unblocked-$dep"
done < <(grep -E '^- \[ \]' "$BACKLOG" 2>/dev/null | grep -oE 'blocked-by:[A-Za-z0-9_-]+' | cut -d: -f2 | sort -u)

# 3. Awaiting-captain items older than NAG_DAYS: one aggregated nag per day
n=$(awk '/^## Awaiting captain/{f=1;next} /^## /{f=0} f' "$BACKLOG" 2>/dev/null \
  | sed -n 's/.*(since \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)).*/\1/p' \
  | awk -v c="$CUTOFF" '$0 <= c' | wc -l | tr -d '[:space:]')
if [ "${n:-0}" -gt 0 ] && ! fired_today awaiting-nag; then
  add "AWAITING-CAPTAIN: $n item(s) waiting >${NAG_DAYS}d - batch one nag to the captain"
  mark awaiting-nag
fi

[ -n "$out" ] && echo "queue: $out (see data/backlog.md)"
exit 0
