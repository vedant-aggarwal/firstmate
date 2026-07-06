#!/usr/bin/env bash
# fm-digest.sh - generate data/DIGEST.md from the ledger + live status files.
#
# DIGEST.md is the captain's one-page read: in-flight work with the latest
# status line each, everything awaiting his review/decision/creds, active
# reminders, and what recently landed. It is GENERATED, never hand-edited -
# hand-maintained mirrors drift (the old DIGEST went stale within a day).
# Run after any ledger change, merge, or teardown; costs nothing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${FM_HOME:-$ROOT}"
BACKLOG="$HOME_DIR/data/backlog.md"
STATE="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"
OUT="$HOME_DIR/data/DIGEST.md"

[ -f "$BACKLOG" ] || { echo "no backlog at $BACKLOG" >&2; exit 1; }

section() { awk -v s="## $1" '$0==s{f=1;next} /^## /{f=0} f' "$BACKLOG"; }

{
  echo "# Fleet Digest"
  echo
  echo "GENERATED $(date '+%Y-%m-%d %H:%M') by bin/fm-digest.sh from backlog.md + state/*.status."
  echo "Do not hand-edit; rerun the script after ledger changes."
  echo
  echo "## In flight"
  found=0
  while IFS= read -r line; do
    found=1
    echo "$line"
    id=$(printf '%s' "$line" | sed -n 's/^- \[[ x]*\] *\([A-Za-z0-9_-]*\).*/\1/p')
    if [ -n "$id" ] && [ -f "$STATE/$id.status" ]; then
      echo "    latest: $(tail -1 "$STATE/$id.status")"
    fi
  done < <(section "In flight" | grep '^- ' || true)
  [ "$found" -eq 0 ] && echo "(fleet idle)"
  echo
  echo "## Needs you (review / decisions / creds)"
  section "Awaiting captain"
  echo "## Reminders"
  section "Reminders" | grep '^- \[ \]' || echo "(none)"
  echo
  qn=$(section "Queued" | grep -c '^- \[ \]' 2>/dev/null | tr -d '[:space:]')
  echo "## Queued: ${qn:-0} item(s) - see data/backlog.md"
  echo
  echo "## Recently landed"
  section "Done" | grep '^- \[x\]' | head -5
} > "$OUT"

echo "wrote $OUT"
