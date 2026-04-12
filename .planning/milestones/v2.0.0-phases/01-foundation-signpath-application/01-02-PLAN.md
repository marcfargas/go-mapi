---
phase: 01-foundation-signpath-application
plan: 02
type: execute
wave: 2
depends_on: [01]
files_modified:
  - src/native-host/watcher.go
autonomous: true
requirements: [FOUND-01]

must_haves:
  truths:
    - "go test -race ./src/native-host/... runs clean locally on Windows with CGO_ENABLED=1"
    - "The emails map and the MailMessage pointers it holds are never read or mutated outside the EmailWatcher.mu lock"
    - "The fix is surgical to the locations identified by the race detector — no new concurrency primitives introduced, debounce loop structure untouched"
  artifacts:
    - path: "src/native-host/watcher.go"
      provides: "Race-free EmailWatcher with consistent locking around emails map and MailMessage mutations"
      contains: "sync.RWMutex"
  key_links:
    - from: "src/native-host/watcher.go processFile"
      to: "src/native-host/watcher.go EmailWatcher.mu"
      via: "mail.HostVersion stamping must happen before the pointer is published to ew.emails or under the same lock"
      pattern: "ew\\.mu\\.Lock"
---

<objective>
Fix the documented `emails` map race in `src/native-host/watcher.go` so `go test -race ./src/native-host/...` runs clean locally on Windows. The fix is surgical — expose the race via `-race`, match locking changes to exactly the lines flagged, and do not refactor anything else.

Purpose: Unblocks GOTEST-03 in Phase 4 (which enables `-race` in CI). Without this fix, Phase 4 cannot land that gate.
Output: A race-clean `watcher.go` with consistent locking around `emails` map access and `MailMessage` pointer mutations.
</objective>

<execution_context>
This plan implements FOUND-01 from REQUIREMENTS.md. Decisions are locked in `01-CONTEXT.md` section `### FOUND-01 (emails map race fix)`:
- Fix location: `src/native-host/watcher.go`
- Extend existing `sync.RWMutex` — do NOT introduce new primitives
- Run `-race` first, capture the exact race report, match the fix to the reported locations
- Out of scope: any broader concurrency refactor; do not touch debounce loop structure beyond what the race fix requires
- Verification: `go test -race ./src/native-host/...` runs clean locally on Windows with CGO enabled
- **No CI changes** — GOTEST-03 is explicitly Phase 4

This plan depends on Plan 01 (FOUND-02) because `processFile` in watcher.go references the `Version` symbol at line 276 when stamping `mail.HostVersion`. Serializing these two plans avoids a merge conflict on the same lines.
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@.planning/codebase/CONCERNS.md
@src/native-host/watcher.go

<interfaces>
<!-- Suspected race locations extracted from source. The executor MUST NOT pre-commit to a fix until go test -race output is captured. -->

The planner's read of watcher.go identified at least two suspected race sites. The executor must run `-race` first and confirm these from the race detector output before fixing.

**Suspected race 1 — watcher.go lines 269-276 (publishing a pointer then mutating it after unlock):**
```go
// Store email
ew.mu.Lock()
ew.emails[id] = &mail
ew.fileToID[filename] = id
ew.mu.Unlock()

// Stamp host version so the extension knows which versions produced this
mail.HostVersion = Version   // <-- mutation happens AFTER unlock, but ew.emails holds a pointer to this mail
```
The `mail` local variable's address is published into `ew.emails[id]` under the lock, then mutated outside the lock. Any concurrent reader holding `mu.RLock()` can race with this mutation.

**Suspected race 2 — the GetEmails shallow copy returning pointers:**
```go
func (ew *EmailWatcher) GetEmails() map[string]*MailMessage {
    ew.mu.RLock()
    defer ew.mu.RUnlock()
    result := make(map[string]*MailMessage, len(ew.emails))
    for k, v := range ew.emails {
        result[k] = v   // <-- returns the same pointer the watcher holds; caller can read MailMessage fields without any lock
    }
    return result
}
```
Callers in main.go (`for id, mail := range watcher.GetEmails()`) read `MailMessage` fields outside the lock. Combined with race 1 above, this is the exact race the CONCERNS.md note describes.

**Fix approach (match to actual race output):**
- **Minimal fix for race 1**: Move `mail.HostVersion = Version` BEFORE `ew.mu.Lock()` so the mutation happens on the local variable before the pointer is published. Zero new locking.
- **Minimal fix for race 2 IF race output confirms it**: Have GetEmails return a deep copy (copy the MailMessage struct, not the pointer) so callers read an immutable snapshot. Single struct copy per email is cheap and keeps the external API compatible.

The executor MUST run `-race` first and report the exact stack traces before committing to these fixes. Adapt the fix to what the detector actually reports.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="false">
  <name>Task 1: Capture the race report with go test -race</name>
  <files>(investigation only — no files modified in this task)</files>
  <read_first>
    - src/native-host/watcher.go (full file — lines 85-95 GetEmails, lines 266-284 processFile, lines 286-300 handleRemove)
    - src/native-host/watcher_test.go (understand what tests currently exercise the watcher so you can pick the right invocation)
    - src/native-host/main.go (lines 77-81 — confirm that main.go's List handler reads mail fields outside the lock via the GetEmails return value)
    - .planning/codebase/CONCERNS.md lines 32-38 ("Potential race condition in email state map")
  </read_first>
  <action>
    Run `go test -race ./src/native-host/...` from the repository root with `CGO_ENABLED=1`. On Windows this requires a working gcc toolchain (MinGW/tdm-gcc) in PATH — if CGO is not set up locally, set it up first (see STACK.md / project README).

    If the existing `watcher_test.go` test suite does not exercise the race (because it never concurrently calls `GetEmails` + `processFile` + `handleRemove`), write a **temporary** test in `src/native-host/watcher_race_capture_test.go` (file will be DELETED at the end of this task — it is a capture scaffold, not a permanent test) that:
    1. Creates an EmailWatcher pointing at a `t.TempDir()` directory
    2. Starts it
    3. Concurrently from multiple goroutines:
       a. Writes fresh email JSON files into the watch dir (triggers `processFile` via the watch loop)
       b. Calls `watcher.GetEmails()` in a tight loop
       c. Iterates the returned map and reads `mail.Subject`, `mail.HostVersion`, and `mail.Body` fields
    4. Runs for ~2 seconds then stops the watcher
    5. Uses `t.Parallel()` is NOT sufficient — use explicit `go func() { ... }()` spawns and a `sync.WaitGroup`

    Run the test under `-race`. Capture the FULL race detector output (every `==================` block) into a scratch location (e.g. comment block at the top of this task's SUMMARY, or a temporary file under `.planning/phases/01-foundation-signpath-application/.scratch/race-report.txt` — the `.scratch/` directory is gitignored or will be cleaned up at task end).

    If `go test -race` exits 0 with NO race report, that means the existing tests plus your capture test did not exercise the race. In that case, re-read watcher.go with a fresh eye focusing on the pointer published at line 271 and the mutation at line 276 — add a more targeted capture test that specifically writes a file, then reads from GetEmails in another goroutine while processFile is still in its tail section after the unlock. Do not proceed to Task 2 until you have captured at least one race report OR have explicitly documented why the suspected race is not reachable from existing tests (in which case the fix becomes a defensive code-quality improvement, not a race fix).

    DO NOT proceed to Task 2 until you have either:
    (a) a captured race report identifying specific lines in watcher.go, OR
    (b) a written justification explaining why the race is present in the code (per the planner's analysis of lines 269-276) but not observable from any test harness — this becomes a code-review-level fix rather than a test-proven fix.

    At task end: delete `watcher_race_capture_test.go` (it is a capture scaffold, not a shipping test — the permanent race coverage is Phase 4 GOTEST-03).
  </action>
  <verify>
    <automated>cd src/native-host && CGO_ENABLED=1 go test -race -run NONE ./...</automated>
  </verify>
  <acceptance_criteria>
    - A race report (or a written justification for why no report was producible) is captured and referenced in the plan SUMMARY
    - `watcher_race_capture_test.go` does NOT exist in the repo at the end of this task (it was temporary — grep: `ls src/native-host/watcher_race_capture_test.go` returns not found)
    - `CGO_ENABLED=1 go test -race -run NONE ./src/native-host/...` compile-builds successfully (the `-run NONE` skips actual test execution — this task is about the capture, Task 2 verifies the fix)
  </acceptance_criteria>
  <done>
    Either (a) a concrete race detector report exists documenting the racing lines, or (b) a reasoned code analysis is written documenting why the pointer-publish-then-mutate pattern at lines 269-276 is a race even if not observable from existing tests. The temporary capture test is removed.
  </done>
</task>

<task type="auto" tdd="false">
  <name>Task 2: Apply the surgical race fix and verify -race is clean</name>
  <files>src/native-host/watcher.go</files>
  <read_first>
    - src/native-host/watcher.go (re-read after Task 1's investigation)
    - The race report or Task 1's justification document
    - src/native-host/main.go lines 76-81 (the call site that iterates GetEmails and reads MailMessage fields)
  </read_first>
  <action>
    Apply the minimal fix matched to the Task 1 capture. Per CONTEXT.md "Match the fix surgically to the race locations — do not sprinkle extra locks" and "extend existing sync.RWMutex, no new abstractions":

    **Fix 1 (mandatory — pointer-publish-then-mutate in processFile):**

    In `processFile` (lines 266-284 approximately), move the `mail.HostVersion = Version` stamping line to BEFORE the `ew.mu.Lock()` acquisition, so the mutation happens on the local `mail` variable before its address is stored in `ew.emails`. The patch is:

    ```go
    // Generate unique ID from content
    id := generateID(data, filename)

    // Stamp host version on the local mail before publishing the pointer into the map.
    // FOUND-01: publishing then mutating races with readers holding RLock.
    mail.HostVersion = Version

    // Store email
    ew.mu.Lock()
    ew.emails[id] = &mail
    ew.fileToID[filename] = id
    ew.mu.Unlock()

    // Notify extension
    if err := ew.messaging.SendEmail(id, &mail); err != nil {
        logError("failed to send email to extension: %v", err)
    }
    ```

    **Fix 2 (apply ONLY IF the race report confirms GetEmails readers race with the watcher):**

    Change `GetEmails` to return deep copies of the `MailMessage` structs rather than the same pointers the watcher holds:

    ```go
    // GetEmails returns a snapshot of all current emails (deep copy to avoid races with concurrent processFile)
    func (ew *EmailWatcher) GetEmails() map[string]*MailMessage {
        ew.mu.RLock()
        defer ew.mu.RUnlock()

        result := make(map[string]*MailMessage, len(ew.emails))
        for k, v := range ew.emails {
            mailCopy := *v   // struct-copy MailMessage — caller gets a snapshot, not a live pointer
            result[k] = &mailCopy
        }
        return result
    }
    ```

    Note: `MailMessage` embeds `Recipients` which contains slices (`[]Recipient`). A shallow struct copy shares the underlying slice backing arrays. If the race report shows readers racing with slice mutations, the copy must also duplicate the slices. In the current code, recipient slices are set once in `processFile` before the pointer is published and are never mutated after — so a shallow struct copy is sufficient. Confirm this from the code read in "read_first" before committing.

    **Hard constraints (per CONTEXT.md):**
    - Do NOT introduce `sync.Mutex`, `sync.Map`, `atomic.Value`, channels, or any new concurrency primitives
    - Do NOT refactor `watchLoop`, the debounce logic, or the `pending` map
    - Do NOT change the `EmailWatcher` struct fields beyond what the race fix requires (the existing `mu sync.RWMutex` is sufficient)
    - Do NOT change the public method signatures of `GetEmails`, `MarkProcessed`, `Delete`, `Start`, `Stop`
    - Do NOT add new public methods

    After applying the fix, run `go test -race ./src/native-host/...` with CGO enabled and verify it exits 0 with no race warnings. Also run the race-capture scenario you developed in Task 1 (adding it as a permanent test is out of scope for this phase — GOTEST-03/GOTEST-04 will cover that in Phase 4). Just verify locally.
  </action>
  <verify>
    <automated>cd src/native-host && CGO_ENABLED=1 go test -race ./...</automated>
  </verify>
  <acceptance_criteria>
    - `CGO_ENABLED=1 go test -race ./src/native-host/...` exits 0 with zero "DATA RACE" reports
    - `grep -n "mail.HostVersion = Version" src/native-host/watcher.go` shows the stamping line occurring BEFORE the `ew.mu.Lock()` in `processFile` (line number of the stamping is LESS than the line number of the following `ew.mu.Lock()`)
    - `grep -c "sync\." src/native-host/watcher.go` returns the same count as before the fix (no new sync primitives introduced — only the existing `sync.RWMutex` remains)
    - `grep -n "sync.Mutex\b" src/native-host/watcher.go` returns no matches (no plain Mutex added)
    - The `watchLoop` function body is unchanged — diff shows zero lines changed between the `func (ew *EmailWatcher) watchLoop()` line and its closing brace
    - Existing tests still pass: `go test ./src/native-host/...` exits 0
    - `go vet ./src/native-host/...` clean
  </acceptance_criteria>
  <done>
    `go test -race` runs clean, the race is fixed with the smallest possible diff, no new concurrency primitives, debounce loop untouched.
  </done>
</task>

</tasks>

<verification>
- `CGO_ENABLED=1 go test -race ./src/native-host/...` exits 0 with no race reports
- `go test ./src/native-host/...` (non-race) still passes all existing tests
- `go vet ./src/native-host/...` clean
- Diff of watcher.go shows only the stamping line move and (if needed) the GetEmails deep copy change — no other modifications
- No new imports added (sync is already imported)
</verification>

<success_criteria>
- The documented `emails` map race is fixed with minimal changes
- No new concurrency primitives introduced
- Debounce loop structure unchanged
- Existing tests still pass
- Race detector runs clean locally
- No `.github/workflows/` files modified (GOTEST-03 is Phase 4)
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundation-signpath-application/01-02-SUMMARY.md` documenting:
- The captured race report (or the written justification if Task 1 could not reproduce it from existing tests)
- The exact diff applied to watcher.go
- Confirmation that `go test -race` runs clean after the fix
- Confirmation that no new sync primitives were introduced
- Confirmation that watchLoop / debounce logic is untouched
</output>
