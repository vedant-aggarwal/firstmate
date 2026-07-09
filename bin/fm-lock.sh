#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# On Windows the harness is a native process that Cygwin's process table cannot
# see - the ancestry walk there dead-ends at ppid 1 - so the walk goes through
# the Windows process tree instead and the recorded holder is "win:<windows pid>".
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# shellcheck source=bin/fm-proc-lib.sh
. "$SCRIPT_DIR/fm-proc-lib.sh"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'
# The same set as a .NET regex over Windows image names, where every harness is
# "<name>.exe" and the POSIX ^pi$ anchoring does not carry over.
HARNESS_RE_WIN='claude|codex|opencode|grok|^pi\.exe$'

posix_harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(fm_proc_comm "$pid") || return 1
    args=$(fm_proc_args "$pid" 2>/dev/null || true)
    if printf '%s' "${comm##*/}" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(fm_proc_ppid "$pid") || return 1
    [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

harness_pid() {
  local win
  posix_harness_pid && return 0
  if fm_proc_is_windows && win=$(fm_proc_win_ancestor_pid "$HARNESS_RE_WIN"); then
    printf 'win:%s\n' "$win"
    return 0
  fi
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  case "$pid" in
    win:*) fm_proc_win_pid_matches "${pid#win:}" "$HARNESS_RE_WIN"; return ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(fm_proc_comm "$pid") || return 1
  printf '%s' "${comm##*/} $(fm_proc_args "$pid" 2>/dev/null || true)" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
