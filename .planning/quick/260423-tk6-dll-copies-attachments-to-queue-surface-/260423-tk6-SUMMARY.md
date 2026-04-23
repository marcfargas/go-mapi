---
quick_id: 260423-tk6
description: DLL copies attachments to queue + surface attachment errors in UI
status: complete
date: 2026-04-23
commits:
  - bbbfc75 feat(interceptor): copy attachments into queue-owned dir at MAPISendMail time
  - f751852 feat(watcher): remove sibling attachments dir when processing or dismissing queue entry
  - 30b35c6 feat(ui): surface draft-failure reason in auto-draft-result event + toast
  - 0a9d7bf chore: merge quick task 260423-tk6 worktree
---

# Quick Task 260423-tk6 — Summary

## What shipped

### Task 1 — DLL attachment copy (bbbfc75)

DLL now copies each attachment into a queue-owned sibling directory
*during* `MAPISendMail`, while the caller is still blocked. Fixes the
lifetime bug where the legacy Spanish app deletes its own TEMP as soon
as `MAPISendMail` returns, leaving the Wails app unable to read
attachments at draft-creation time.

**On-disk layout locked:**
```
%LOCALAPPDATA%\go-mapi\queue\msg_<ts>_<sfx>.json          <-- JSON file
%LOCALAPPDATA%\go-mapi\queue\msg_<ts>_<sfx>\<basename>    <-- sibling dir
```

**Failure policy (locked):** if *any* attachment copy fails, the DLL
writes `%LOCALAPPDATA%\go-mapi\queue\errors\<stem>.error` with the
reason and does NOT write the JSON — no half-written messages enter
the queue. Partial copies are cleaned up.

**Size field:** populated from the real copied-file byte count
(previously hardcoded 0).

**C++ surface:**
- `fs_utils.{h,cpp}`: new `GenerateUniqueStem()`, `GetAttachmentsDirForStem(stem)`,
  `EnsureDirExists(path)`, `CopyFileToDir(src, destDir, basename, outPath, outSize)`.
- `mapi_impl.cpp`: after the converter produces a `MailMessage`, the
  glue layer iterates `result.attachments` and calls `CopyFileToDir`
  for each, rewriting `att.path` + `att.size`. On failure writes the
  `.error` file and aborts before the JSON write.
- `json_writer.cpp`: small refactor to accept the pre-computed stem.
- `fs_utils_tests.cpp` (new): 7 test cases, 27 assertions covering stem
  generation, dir creation, happy-path copy, source-missing failure.
- `message_converter_tests.cpp`: 27/27 green (untouched by this task
  aside from callsite additions; locks the pass-through contract).

### Task 2 — Go cleanup on JSON delete (f751852)

`internal/mapi/watcher.go`: when `MarkProcessed(id)` or `Delete(id)`
removes the JSON file, it also `os.RemoveAll`s the sibling attachments
dir (same stem). Best-effort — failure is logged, not propagated.
Layout invariant documented at the function level so future refactors
stay consistent.

New tests: `TestMarkProcessed_RemovesSiblingAttachmentsDir`,
`TestDelete_RemovesSiblingAttachmentsDir`. Full `go test` suite green.

Privacy-first invariant preserved: no retention after success/dismiss.

### Task 3 — Error visibility (30b35c6)

**Go log lines (Marc's "the app should have shown a proper error"):**
- `src/app/app.go:552`:
  `logError("CreateDraftForID: draft %s failed: category=%s err=%v", safeIDPrefix(id), category, callErr)`
- `src/app/automode.go:166` — mirror.

**UI:** `auto-draft-result` event payload gains a `reason` field
(raw error text, truncated defensively). `AutoDraftErrorBadge.svelte`
+ `QueueRow.svelte` surface `reason` under the category badge so
users see the real cause, not just "gmail". `classifyAutomodeError`
shape unchanged — no new error categories (scope-discipline).

Frontend tests augmented: `QueueRow.test.ts` asserts `reason`
propagation. 84/84 Vitest pass after the change.

## Verification

End-to-end rebuild after merge:
- C++ `fs_utils_tests`: **7/7 pass**, 27/27 assertions
- C++ `message_converter_tests`: **27/27 pass**, 88/88 assertions
  (no regressions from this task)
- Go `./internal/mapi/... ./src/app/...`: **all green**
- Frontend Vitest: **84/84 pass**
- `svelte-check`: 0 errors (2 pre-existing a11y warnings untouched)
- x64 DLL: `PE32+ x86-64`, 1.46 MB
- x86 DLL: `PE32 Intel i386`, 1.46 MB
- Wails `go-mapi.exe`: 16.58 MB (credentialed via ldflags)
- Installer `go-mapi-setup.exe`: 7.12 MB (timestamp 21:34)

## Manual-test invariant (to confirm on RDS22-2)

1. Install the new `go-mapi-setup.exe`.
2. Trigger the legacy Spanish app with an attachment.
3. After MAPI returns: `%LOCALAPPDATA%\go-mapi\queue\msg_<ts>_<sfx>.json`
   exists AND `%LOCALAPPDATA%\go-mapi\queue\msg_<ts>_<sfx>\H<...>.ZIP`
   exists alongside it. `size > 0`.
4. Wails queue row appears. Click "Create draft" — attachment now reaches
   Gmail as a MIME part.
5. After draft success: both the JSON and the sibling dir are gone.
6. If an unexpected failure ever occurs: the Wails queue row shows the
   actual error reason under the category badge (not just "gmail").

## Deviations

1. `.gitignore` adds `build-x64-test/` — fresh CMake dir the test flow
   creates. Arch-specific; mirrors existing `build-x64/` + `build-x86/`
   entries.
2. No other scope expansion.

## Not done (explicitly deferred)

- No new `"attachment"` error category. Raw-error-text surfacing in UI
  addresses Marc's visibility ask; category taxonomy unchanged.
- No UI surfacing of the DLL-side `errors/*.error` files. These are
  still visible to the user via the diagnostic script
  (`collect-runtime.ps1`); a first-class UI treatment is a later polish
  task.
- No removal of the now-unused `isDevVersion` helper in
  `src/app/updates.go` (carry-over from 260423-qpx scope).
