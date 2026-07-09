#!/usr/bin/env bash
# Portable process introspection.
#
# Every firstmate script that asks "what is this pid, who is its parent, is it
# still the same process" used to call `ps -o <field>=`. Cygwin's ps (the ps a
# Git Bash firstmate actually runs, `ps (cygwin) 3.4.9`) has no -o option at
# all, so all of those calls returned empty and every caller silently took its
# "cannot determine" branch: the watcher was never recognized as healthy, the
# session lock could never be acquired, and harness detection fell through to
# unknown.
#
# So each accessor here tries `ps -o` once, and otherwise reads /proc, which
# Cygwin does provide (cmdline, ppid, exename, stat).
#
# A Windows harness is a further problem, not solved by /proc: claude.exe is a
# native Windows process, invisible to Cygwin's process table, so a Cygwin
# ancestry walk dead-ends at ppid 1 before reaching it. fm_proc_win_ancestor_pid
# walks the *Windows* process tree instead, via PowerShell. Pids it returns are
# Windows pids and are NOT valid arguments to kill(1) or the other accessors
# here; pair them with fm_proc_win_pid_matches, which checks liveness Windows-side.

# fm_proc_ps_o_supported / fm_proc_have_proc are probed once and cached, because
# every accessor calls them and the answer cannot change within a process.
FM_PROC_PS_O=
FM_PROC_HAVE_PROC=

fm_proc_ps_o_supported() {
  if [ -z "$FM_PROC_PS_O" ]; then
    if ps -o pid= -p "$$" >/dev/null 2>&1; then FM_PROC_PS_O=1; else FM_PROC_PS_O=0; fi
  fi
  [ "$FM_PROC_PS_O" = 1 ]
}

fm_proc_have_proc() {
  if [ -z "$FM_PROC_HAVE_PROC" ]; then
    if [ -r "/proc/$$/stat" ]; then FM_PROC_HAVE_PROC=1; else FM_PROC_HAVE_PROC=0; fi
  fi
  [ "$FM_PROC_HAVE_PROC" = 1 ]
}

fm_proc_valid_pid() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Print the executable path (callers basename it). Empty output means unknown.
fm_proc_comm() {
  local pid=$1 out
  fm_proc_valid_pid "$pid" || return 1
  if fm_proc_ps_o_supported; then
    out=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  elif fm_proc_have_proc; then
    out=$(cat "/proc/$pid/exename" 2>/dev/null) || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Print the full command line, space-separated on one line.
fm_proc_args() {
  local pid=$1 out
  fm_proc_valid_pid "$pid" || return 1
  if fm_proc_ps_o_supported; then
    out=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  elif fm_proc_have_proc; then
    out=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_proc_ppid() {
  local pid=$1 out
  fm_proc_valid_pid "$pid" || return 1
  if fm_proc_ps_o_supported; then
    out=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  elif fm_proc_have_proc; then
    out=$(tr -d '[:space:]' < "/proc/$pid/ppid" 2>/dev/null) || return 1
  else
    return 1
  fi
  fm_proc_valid_pid "$out" || return 1
  printf '%s\n' "$out"
}

# Print the single-letter process state (R, S, T, Z, ...).
fm_proc_state() {
  local pid=$1 out
  fm_proc_valid_pid "$pid" || return 1
  if fm_proc_ps_o_supported; then
    out=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  elif fm_proc_have_proc; then
    # /proc/<pid>/stat is "<pid> (<comm>) <state> ...". comm can contain spaces
    # and parentheses, so anchor on the LAST ')' rather than splitting on space.
    out=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f1) || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Print a string that changes when the pid is reused by a different process.
# Start time plus command line: a recycled pid has a later start time, and a
# same-start-time collision is not physically possible.
fm_proc_identity() {
  local pid=$1 out starttime cmd
  fm_proc_valid_pid "$pid" || return 1
  if fm_proc_ps_o_supported; then
    # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
    # written under one locale but re-read under the machine's ambient locale, which
    # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
    out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  elif fm_proc_have_proc; then
    # Field 22 of /proc/<pid>/stat is starttime, in clock ticks since boot: fixed
    # for the life of the process and never reused within one boot.
    starttime=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f20) || return 1
    [ -n "$starttime" ] || return 1
    # exename, not cmdline: a cmdline can carry embedded newlines, and this string
    # is round-tripped through a one-value file and compared verbatim.
    cmd=$(fm_proc_comm "$pid" 2>/dev/null) || cmd=""
    out="$starttime $cmd"
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_proc_is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
  esac
  return 1
}

# Print the Windows pid to start a Windows ancestry walk from.
#
# NOT this shell's own winpid. An MSYS fork/exec spawns a stub process that
# forks and then exits, so a nested Git Bash process records a Windows
# ParentProcessId that is already dead, and a walk from it stops at hop one.
# Only the outermost Cygwin shell in this tree was created directly by the
# harness (CreateProcess), so only its Windows parent chain is intact.
# Climb Cygwin's own ancestry to that shell, then hand its winpid to Windows.
fm_proc_win_self_pid() {
  local pid=$$ next
  fm_proc_is_windows || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    next=$(fm_proc_ppid "$pid" 2>/dev/null) || break
    [ "$next" -gt 1 ] || break
    [ -r "/proc/$next/winpid" ] || break
    pid=$next
  done
  [ -r "/proc/$pid/winpid" ] || return 1
  tr -d '[:space:]' < "/proc/$pid/winpid"
}

fm_proc_win_powershell() {
  command -v powershell.exe 2>/dev/null || command -v pwsh.exe 2>/dev/null
}

# Bare interpreters carry the harness in their script path rather than their image
# name, and are the only processes whose command line may be matched. Matching every
# process's command line would be wrong: a Git Bash shell launched by Claude Code has
# ".claude" in its own command line and would match ahead of the real claude.exe.
FM_PROC_WIN_INTERPRETERS='^(node|python[0-9.]*)\.exe$'

# PowerShell fragment: true when process $p is a harness matching regex $pat.
fm_proc_win_match_expr() {
  printf '%s' "(\$p.Name -match \$pat) -or (\$p.Name -match '$FM_PROC_WIN_INTERPRETERS' -and \$p.CommandLine -match \$pat)"
}

# Walk the Windows ancestry of this shell and print the Windows pid of the first
# ancestor that is a harness matching the .NET regex $1.
# Prints nothing and returns 1 when there is no match, no PowerShell, or no
# Windows process tree to walk.
fm_proc_win_ancestor_pid() {
  local pattern=$1 self ps_exe out
  self=$(fm_proc_win_self_pid) || return 1
  ps_exe=$(fm_proc_win_powershell) || return 1
  # One PowerShell invocation for the whole walk: interpreter startup dominates the
  # cost, so eight one-level queries would be eight times as slow as this.
  out=$("$ps_exe" -NoProfile -NonInteractive -Command "
    \$pat = '$pattern'
    \$next = $self
    for (\$i = 0; \$i -lt 8; \$i++) {
      \$p = Get-CimInstance Win32_Process -Filter \"ProcessId=\$next\" -ErrorAction SilentlyContinue
      if (-not \$p) { break }
      if ($(fm_proc_win_match_expr)) { Write-Output \$p.ProcessId; break }
      \$next = \$p.ParentProcessId
      if (-not \$next -or \$next -le 4) { break }
    }" 2>/dev/null | tr -d '[:space:]')
  fm_proc_valid_pid "$out" || return 1
  printf '%s\n' "$out"
}

# True when Windows pid $1 is alive AND is still a harness matching regex $2.
# The second half is the pid-reuse guard: a dead harness's pid handed to an
# unrelated new process must not read as alive.
fm_proc_win_pid_matches() {
  local pid=$1 pattern=$2 ps_exe out
  fm_proc_valid_pid "$pid" || return 1
  ps_exe=$(fm_proc_win_powershell) || return 1
  out=$("$ps_exe" -NoProfile -NonInteractive -Command "
    \$pat = '$pattern'
    \$p = Get-CimInstance Win32_Process -Filter \"ProcessId=$pid\" -ErrorAction SilentlyContinue
    if (\$p -and ($(fm_proc_win_match_expr))) { Write-Output 'yes' }" 2>/dev/null | tr -d '[:space:]')
  [ "$out" = "yes" ]
}
