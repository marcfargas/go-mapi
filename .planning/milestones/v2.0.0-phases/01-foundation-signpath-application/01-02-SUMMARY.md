---
phase: 01-foundation-signpath-application
plan: 02
subsystem: infra
tags: [go, concurrency, race-detector, sync, rwmutex, watcher]

requires:
  - phase: 01-foundation-signpath-application
    provides: "Plan 01 (FOUND-02) centralized Version into version.go; this plan mutates the same surrounding lines in processFile"
provides:
  - "Race-free EmailWatcher.processFile: host version stamping happens before the pointer is published into ew.emails"
  - "Unblocks Phase 4 GOTEST-03 (turning -race on in CI) — the documented emails map race is gone"
affects: [phase-04-testing, GOTEST-03]

tech-stack:
  added: []
  patterns:
    - "Mutate-before-publish: set all fields on a local struct before its address is stored in a shared map, so post-lock readers see a fully-initialized snapshot"

key-files:
  created: []
  modified:
    - src/native-host/watcher.go

key-decisions:
  - "Fix 1 (move stamp before lock) alone was sufficient — the captured race report showed ONLY mail.HostVersion was mutated post-unlock; Subject/Body/Recipients are all set before the lock and never touched after, so GetEmails deep-copy (Fix 2 from the plan) was unnecessary"
  - "Used GOOS=windows GOARCH=amd64 cross-compile for -race because Go 1.26 windows/arm64 does not support the race detector — the production x86_64 toolchain catches the race the same way CI will"

patterns-established:
  - "FOUND-01 fix template: if a struct field needs stamping alongside map insertion, mutate the local variable BEFORE acquiring the lock, not after releasing it"

requirements-completed: [FOUND-01]

# Metrics
duration: 4 min
completed: 2026-04-10
---

# Phase 1 Plan 2: FOUND-01 EmailWatcher emails map race fix Summary

**Moved `mail.HostVersion = Version` stamp in `processFile` to BEFORE `ew.mu.Lock()` so the post-unlock mutation no longer races with `GetEmails` readers holding the shared `*MailMessage` pointer — three-line diff, no new concurrency primitives, race detector clean on windows/amd64.**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-04-10T16:07:27Z
- **Completed:** 2026-04-10T16:11:38Z
- **Tasks:** 2
- **Files modified:** 1 (`src/native-host/watcher.go`)

## Accomplishments

- **Race reproduced, not just hypothesized.** Wrote a temporary capture test (`watcher_race_capture_test.go`, deleted after use) that spawned a writer goroutine calling `processFile` in a tight loop alongside 4 reader goroutines calling `GetEmails()` and then reading `mail.HostVersion`. First run under `-race` produced the exact race the planner predicted: write at `watcher.go:276` vs. read via the `GetEmails` returned pointer.
- **Surgical fix applied.** Moved the `mail.HostVersion = Version` stamp from its post-unlock position (line 276, after `ew.mu.Unlock()`) to BEFORE `ew.mu.Lock()` (now line 273). The mutation now happens on the local `mail` variable before its address is published into `ew.emails`, so any reader that subsequently acquires the RLock and reads via the pointer sees a fully-stamped struct. Zero new locking, zero new primitives, three-line diff.
- **Verified race-clean.** Re-ran the capture scenario after the fix — the previously-racing test now passes. Removed the capture test per the plan's "temporary, delete at task end" instruction. Full existing test suite also passes under `-race`.

## Task Commits

Each task was committed atomically on `develop`:

1. **Task 1: Capture the race report** — no commit (investigation only, temporary capture test written and then deleted in the same task; race report embedded in this summary)
2. **Task 2: Apply the surgical fix and verify -race is clean** — `d6d3bfb` (fix)

Plan metadata commit pending.

## Files Modified

- `src/native-host/watcher.go` — Relocated `mail.HostVersion = Version` from post-unlock (below the `ew.mu.Unlock()`) to pre-lock (above the `ew.mu.Lock()`) in `processFile`. Added a FOUND-01 comment explaining why the order matters. No other changes — `watchLoop`, the debounce `pending` map, `handleRemove`, `GetEmails`, `MarkProcessed`, `Delete`, and the `EmailWatcher` struct are all byte-for-byte identical to pre-fix. The `sync.` import count stays at 1 (the existing `sync.RWMutex`).

## Exact Diff Applied

```diff
@@ -266,15 +266,18 @@ func (ew *EmailWatcher) processFile(filename string) {
 	// Generate unique ID from content
 	id := generateID(data, filename)
 
+	// Stamp host version on the local mail before publishing the pointer into
+	// the map. FOUND-01: if we stamp after the unlock, concurrent readers
+	// holding the RLock via GetEmails receive the same *MailMessage and race
+	// with this write. Mutate before publish to keep the fix surgical.
+	mail.HostVersion = Version
+
 	// Store email
 	ew.mu.Lock()
 	ew.emails[id] = &mail
 	ew.fileToID[filename] = id
 	ew.mu.Unlock()
 
-	// Stamp host version so the extension knows which versions produced this
-	mail.HostVersion = Version
-
 	// Notify extension
 	if err := ew.messaging.SendEmail(id, &mail); err != nil {
 		logError("failed to send email to extension: %v", err)
```

## Captured Race Report (pre-fix)

The plan required capturing the actual race detector output before committing to a fix. Full output from the temporary `watcher_race_capture_test.go` run (capture test file and line numbers no longer exist in tree — the test was deleted after capture per the plan's instructions):

```
==================
WARNING: DATA RACE
Read at 0x00c00035a018 by goroutine 12:
  github.com/marcfargas/go-mapi/native-host.TestRaceCapture_WatcherEmailsMap.func2()
      C:/dev/go-mapi/src/native-host/watcher_race_capture_test.go:92 +0x17c

Previous write at 0x00c00035a018 by goroutine 11:
  github.com/marcfargas/go-mapi/native-host.(*EmailWatcher).processFile()
      C:/dev/go-mapi/src/native-host/watcher.go:276 +0xd44
  github.com/marcfargas/go-mapi/native-host.TestRaceCapture_WatcherEmailsMap.func1()
      C:/dev/go-mapi/src/native-host/watcher_race_capture_test.go:76 +0x264
==================
==================
WARNING: DATA RACE
Read at 0x00c00035ab78 by goroutine 14:
  github.com/marcfargas/go-mapi/native-host.TestRaceCapture_WatcherEmailsMap.func2()
      C:/dev/go-mapi/src/native-host/watcher_race_capture_test.go:92 +0x17c

Previous write at 0x00c00035ab78 by goroutine 10:
  github.com/marcfargas/go-mapi/native-host.(*EmailWatcher).processFile()
      C:/dev/go-mapi/src/native-host/watcher.go:276 +0xd44
  github.com/marcfargas/go-mapi/native-host.(*EmailWatcher).watchLoop()
      C:/dev/go-mapi/src/native-host/watcher.go:219 +0x74f
==================
--- FAIL: TestRaceCapture_WatcherEmailsMap (1.04s)
    testing.go:1712: race detected during execution of test
```

**Interpretation:**
- `watcher.go:276` (pre-fix line number) is `mail.HostVersion = Version` — the post-unlock mutation the plan flagged as "suspected race 1".
- The capture test's line 92 is `_ = mail.HostVersion` inside the reader loop iterating `ew.GetEmails()`. The reader holds no lock because `GetEmails` has already released its RLock and returned the pointer.
- Both racing paths into `processFile` were caught: (a) the direct call from the capture test, and (b) the real production path via `watchLoop` → `processFile` from `fsnotify` events.
- **Crucially, only `mail.HostVersion` races.** The reader also reads `mail.Subject` and `mail.Body` in the same loop, but those fields were set before the lock and never mutated after, so they do not produce race reports. This confirms the planner's "Fix 2 IF needed" (GetEmails deep copy) is **not needed** — moving the one stamping line is sufficient.

## Verification (post-fix)

All commands run from repository root unless noted:

```
cd src/native-host && GOOS=windows GOARCH=amd64 CGO_ENABLED=1 go test -race ./...
-> ok  github.com/marcfargas/go-mapi/native-host  1.907s

# Also re-ran the race-capture scenario (temporary test re-added, run, then
# deleted again). Pre-fix: DATA RACE at watcher.go:276 (twice) + FAIL.
# Post-fix: ok  github.com/marcfargas/go-mapi/native-host  2.971s

cd src/native-host && go test ./...
-> ok  github.com/marcfargas/go-mapi/native-host  0.091s

cd src/native-host && go vet ./...
-> (no output, exit 0)
```

**Grep-based acceptance criteria (all passing):**

```
$ grep -n "mail.HostVersion = Version" src/native-host/watcher.go
273:    mail.HostVersion = Version

$ grep -n "ew\.mu\.Lock()" src/native-host/watcher.go
99:    ew.mu.Lock()
129:   ew.mu.Lock()
276:   ew.mu.Lock()   # <-- processFile's lock, AFTER the stamp at line 273
290:   ew.mu.Lock()

$ grep -n "sync\." src/native-host/watcher.go
26:    mu          sync.RWMutex   # <-- only one sync. reference, unchanged

$ grep -n "sync.Mutex\b" src/native-host/watcher.go
(no matches)
```

Line 273 (`mail.HostVersion = Version`) is strictly less than line 276 (`ew.mu.Lock()` in processFile), so the stamping happens before the lock acquisition. The `sync.` reference count is 1 (the pre-existing `sync.RWMutex` on line 26), and no `sync.Mutex` was added.

## Decisions Made

- **Used `GOOS=windows GOARCH=amd64` cross-compile for `-race`.** Go 1.26 `windows/arm64` does not support the race detector (error: `-race is not supported on windows/arm64`). The dev machine is arm64 Windows with an x86_64 MinGW gcc in PATH, so cross-compiling to `windows/amd64` with `CGO_ENABLED=1` works and reproduces the exact race that Phase 4 GOTEST-03 will catch in CI (CI runs on `windows-latest` = x86_64). Documented so GOTEST-03 can reuse the same invocation pattern.
- **Fix 1 alone, no deep copy.** The plan authorized Fix 2 (GetEmails returning deep copies) ONLY if the race report confirmed readers racing with other mutations. The capture clearly showed only `mail.HostVersion` was mutated post-unlock; `Subject`, `Body`, `Recipients`, and all slice contents are set before the lock and are read-only afterward. Applying Fix 2 would have been scope creep with no race-fixing benefit, so it was skipped per scope discipline.
- **Used `ew.processFile(filename)` as a direct call in the capture test.** The production path is `fsnotify` event → `watchLoop` debounces 500ms → `processFile`. Waiting for 500ms debounces in a capture test would need a multi-second sleep to observe the race. Calling `processFile` directly from the same package (both in `package main`) kept the race window tight and the test fast. The race detector still caught the `watchLoop` path too, as the second race report block above shows.
- **Kept the comment explicit about why.** The in-code comment calls out FOUND-01 so future maintainers reading the diff out of context don't "clean up" the stamping line back to its previous position.

## Deviations from Plan

None — plan executed exactly as written. The plan gave two possible fixes (Fix 1 mandatory, Fix 2 conditional); the captured race report authorized applying only Fix 1, which is what landed. The temporary `watcher_race_capture_test.go` was written, used, and deleted per the plan's "DELETED at the end of this task" instruction.

**Environment note (not a deviation):** The plan's `<automated>` verification command is `cd src/native-host && CGO_ENABLED=1 go test -race ./...`. On the `windows/arm64` dev machine this fails with `-race is not supported on windows/arm64`. The actual command used was `cd src/native-host && GOOS=windows GOARCH=amd64 CGO_ENABLED=1 go test -race ./...` which cross-compiles to the target architecture the race detector supports. The result is the same test binary CI will run on `windows-latest` (x86_64). No code change required; this is a toolchain fact about the arm64 Windows Go port.

## Issues Encountered

- **Race detector unsupported on windows/arm64** — diagnosed in 30 seconds (clear error message), resolved by adding `GOOS=windows GOARCH=amd64` to the invocation. Not a project issue; a fact of the Go 1.26 arm64 Windows port.
- **Existing `watcher_test.go` does not exercise the race** — expected, and the plan explicitly anticipated this (Task 1 says "if the existing test suite does not exercise the race, write a temporary capture test"). Wrote the capture scaffold, caught the race on the first run, deleted it after the fix was verified.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- **Ready for Plan 01-03 / next incomplete plan.** Plan 01-02 lands cleanly on `develop` with the documented race fix in place.
- **GOTEST-03 (Phase 4) is unblocked.** That plan turns `-race` on in CI; it depended on this fix landing so that `go test -race` doesn't immediately fail on the main branch. It now won't.
- **No CI changes in this plan, as required.** `.github/workflows/` was not touched. GOTEST-03 is explicitly Phase 4.
- **No blockers or concerns.** The fix is three lines, the diff is entirely inside `processFile`, and no consumer of `EmailWatcher` needs any adjustment.

## Self-Check: PASSED

- `src/native-host/watcher.go` exists on disk (modified in commit `d6d3bfb`)
- `src/native-host/watcher_race_capture_test.go` does NOT exist (deleted after capture — confirmed via `ls src/native-host/ | grep -i race` returning nothing)
- Commit `d6d3bfb` exists in `git log --oneline`: `fix(01-02): FOUND-01 move HostVersion stamp before lock to eliminate emails map race`
- `grep -n "mail.HostVersion = Version" src/native-host/watcher.go` returns line 273 (BEFORE the `ew.mu.Lock()` at line 276 in `processFile`)
- `grep -n "sync\." src/native-host/watcher.go` returns 1 match (`sync.RWMutex` on line 26) — unchanged from pre-fix
- `grep -n "sync.Mutex\b" src/native-host/watcher.go` returns zero matches (no plain Mutex added)
- `GOOS=windows GOARCH=amd64 CGO_ENABLED=1 go test -race ./src/native-host/...` exits 0 with zero DATA RACE reports
- `go test ./src/native-host/...` exits 0 (existing suite still passes)
- `go vet ./src/native-host/...` clean
- No `.github/workflows/` files touched (confirmed via `git diff --name-only HEAD~1 HEAD` showing only `src/native-host/watcher.go`)

---
*Phase: 01-foundation-signpath-application*
*Completed: 2026-04-10*
