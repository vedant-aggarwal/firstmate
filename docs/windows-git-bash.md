# Windows (Git Bash) environment facts

Empirical record of the Git Bash / Cygwin behaviors that firstmate's supervision
machinery depends on, and what each one broke before it was accounted for.

Verified 2026-07-10 on Windows 11 Pro 10.0.22631, Git Bash, `ps (cygwin) 3.4.9`,
harness `claude.exe`.

## 1. `ln -s` copies a directory instead of linking to it

Git Bash leaves `winsymlinks` unset by default, so `ln -s` on a directory makes a
recursive copy and reports success.

```
$ mkdir owner && ln -s owner lk && echo "-L=$([ -L lk ] && echo yes || echo no) readlink='$(readlink lk)'"
-L=no readlink=''

$ MSYS=winsymlinks:nativestrict ln -s owner lk2 && echo "-L=$([ -L lk2 ] && echo yes || echo no) readlink='$(readlink lk2)'"
-L=yes readlink='owner'
```

Native symlinks require Developer Mode or an elevated shell. They are available
on this machine; they are not guaranteed on every Windows host.

**What it broke.** `bin/fm-wake-lib.sh`'s lock protocol publishes a lock by
symlinking `<lock>` at a private `<lock>.owner.XXXXXX` directory whose `pid` file
was written first. With a copy instead of a symlink, the acquirer's own pid landed
at `<lock>/pid`; `fm_lock_try_create` then failed its `readlink` check, and
`fm_lock_try_acquire` read that pid back and concluded a live peer held the lock.
Every watcher collided with itself and exited 0 within a second of starting:

```
$ bash bin/fm-watch.sh
watcher: already running pid 49026     # 49026 is this process
```

Supervision was therefore off for the whole fleet, and stray copied directories
were left behind at `state/.watch.lock`, `state/.watch.lock.steal`,
`state/.wake-queue.lock`, and `state/.supervise-daemon.lock`, permanently
poisoning later acquisitions.

**Handled by.** `fm_lock_ln_s` asks for a native symlink (`MSYS`/`CYGWIN`
`winsymlinks:nativestrict`) and then verifies `[ -L ]`, deleting any copy it got
instead. `fm_lock_symlinks_supported` probes once per process; when symlinks are
genuinely unavailable the lock falls back to a plain `mkdir` directory, which is
atomic on Windows, with `fm_lock_mid_acquire_is_fresh` covering the window between
the `mkdir` and the `pid` write.

## 2. Cygwin `ps` has no `-o` option

```
$ ps -o comm= -p $$
ps: unknown option -- o
```

**What it broke.** Every process-introspection call site returned empty and each
caller silently took its "cannot determine" branch:

| Call site | Effect |
| --- | --- |
| `fm_pid_identity` (`bin/fm-wake-lib.sh`) | a live, beating watcher never read as healthy, so `fm-watch-arm.sh` reported `FAILED - no live watcher with a fresh beacon` and `fm-guard.sh` alarmed on every fleet action |
| `harness_pid` (`bin/fm-lock.sh`) | the session lock could never be acquired, so every session start printed the read-only banner and skipped all mutating steps |
| `detect_own` (`bin/fm-harness.sh`) | ancestry detection fell through to `unknown` (the `CLAUDECODE=1` env marker still covered claude) |

**Handled by.** `bin/fm-proc-lib.sh` probes `ps -o` once and otherwise reads
`/proc/<pid>/{stat,cmdline,ppid,exename}`, which Cygwin does provide. Process
identity uses field 22 of `stat` (`starttime`, fixed for the life of the process)
plus `exename`, rather than `ps -o lstart=`.

## 3. A Windows harness is invisible to the Cygwin process table

`claude.exe` is a native Windows process. Cygwin does not list it, and a Git Bash
shell spawned by it reports `ppid 1`, so a Cygwin ancestry walk can never reach
the harness.

Worse, the Windows ancestry of a *nested* Git Bash is also broken: an MSYS
fork/exec leaves a stub that exits, so the nested shell's recorded
`ParentProcessId` is already dead.

```
hop0: bash.exe pid=59928 ppid=513580
STOP: pid 513580 not found
```

Only the outermost Cygwin shell in a tree was created directly by the harness via
`CreateProcess`, so only its Windows parent chain is intact:

```
bash.exe    pid=315324  ppid=133452
bash.exe    pid=133452  ppid=78128
claude.exe  pid=78128
```

**Handled by.** `fm_proc_win_self_pid` climbs Cygwin's own ancestry to the
outermost shell, then hands that shell's `winpid` to `fm_proc_win_ancestor_pid`,
which walks the Windows tree in a single PowerShell call. `bin/fm-lock.sh` records
the result as `win:<windows pid>` and checks liveness with
`fm_proc_win_pid_matches`, which re-verifies the image name so a recycled pid
belonging to some unrelated process never reads as a live harness.

Image name is matched first, and command line only for bare interpreters
(`node.exe`, `python*.exe`). Matching every process's command line would be wrong:
a Git Bash shell launched by Claude Code has `.claude` in its own command line and
would match ahead of the real `claude.exe`.

## Known Windows limitations, not fixed here

- `tests/fm-turnend-guard.test.sh`'s `test_hook_silent_without_jq` sets
  `PATH="$fakebin"` with only a handful of symlinked tools. On Windows the dynamic
  loader resolves a `.exe`'s DLLs through `PATH`, so `bash.exe` itself then fails
  to start (`error while loading shared libraries`) and the hook exits 127 before
  running a single line. The test cannot pass under Git Bash on any branch.
- `tests/fm-watch-checkpoint.test.sh` and `tests/fm-secondmate-harness.test.sh`
  each have one case failing on Windows both before and after this change.
- `fm_backend_detect_cmux_app_is_ancestor` (`bin/fm-backend.sh`) still calls
  `ps -o`. cmux is macOS-only, where `ps -o` works, and on Windows the function
  correctly reports "not a cmux ancestor" either way.
- Cygwin cannot deliver a POSIX signal to a native Windows process: `kill -TERM`
  on `node.exe` terminates it regardless of any `SIGTERM` handler it installed.
  Test fixtures that need a signal-resistant peer must use a trapping shell.
