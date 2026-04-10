# Codebase Concerns

**Analysis Date:** 2026-04-10

## Tech Debt

**Incomplete license specification:**
- Issue: Package.json declares `GPL-3.0-only` but README states "License TBD" and notes "The absence of a license means all rights are reserved"
- Files: `package.json`, `README.md` (lines 173-175)
- Impact: Legal ambiguity - users cannot reliably determine their rights to use, modify, or distribute. Blocks distribution on Chrome Web Store and Edge Add-ons which require clear licensing
- Fix approach: Explicitly choose LGPL-3.0 (as per Marc's preference) or GPL-3.0, update all documentation, commit and tag a release with clear license

**Missing HTTP timeout on Gmail API client:**
- Issue: `gc.httpClient` in `src/native-host/gmail.go` uses default timeout (~infinity). Stalled API calls will block forever
- Files: `src/native-host/gmail.go` (lines 22-32)
- Impact: If Gmail API becomes unresponsive, draft creation hangs indefinitely, extension loses responsiveness. User must restart browser or kill native host
- Fix approach: Add configurable timeout to `NewGmailClient()`, recommend 30-60s default. Propagate timeout context to `CreateDraft()` and HTTP request creation

**Goroutine lifecycle not tracked:**
- Issue: `handleCreateDraft()` spawned as goroutine in `main.go:101` with no wait/completion tracking. If host exits, drafts in-flight are abandoned
- Files: `src/native-host/main.go` (line 101)
- Impact: Race condition - user triggers "Save as Draft", goroutine spawns, host crashes before it completes. Draft never created but no feedback to user. User sees email still in queue indefinitely
- Fix approach: Use `sync.WaitGroup` to track in-flight goroutines. On shutdown message or connection close, wait for all draft creations to complete (with timeout)

**Silent error swallowing in persistence:**
- Issue: `broadcastToPopup()` in extension silently catches all errors when sending to popup
- Files: `src/extension/src/background/service-worker.ts` (line 56)
- Impact: Popup state may be inconsistent with background state. User sees stale email list while background already deleted or processed emails
- Fix approach: Log failed broadcasts, implement retry with exponential backoff for transient failures

## Known Bugs

**Potential race condition in email state map:**
- Issue: While `mu` RWMutex protects reads/writes to `emails` map in `EmailWatcher`, the concurrent goroutine `handleCreateDraft()` runs outside the lock and then tries to send/delete from the same map
- Files: `src/native-host/main.go` (lines 115-140), `src/native-host/watcher.go` (lines 98-125)
- Trigger: Rapid succession of draft creation followed by file deletion: (1) `handleCreateDraft` goroutine spawns, (2) User deletes email file, (3) Goroutine tries to access now-deleted state
- Workaround: Files are moved to `errors/` directory on read failure, preventing re-processing
- Mitigation needed: Pass immutable email copy to `handleCreateDraft`, or add explicit locking around goroutine state access

**Attachment paths may become stale:**
- Issue: Email JSON contains file paths to attachments. If user deletes or moves the original file before draft is created, `buildFullMIME()` fails with "attachment not found"
- Files: `src/native-host/gmail.go` (lines 128-140)
- Trigger: (1) Interceptor writes email with attachment path, (2) User deletes original file, (3) Extension clicks "Save as Draft"
- Current behavior: Draft creation fails, error notification shown
- Impact: High - common scenario if user is sending files from a temp directory
- Fix approach: Copy attachment bytes to watch directory when email is written, reference those instead of original paths

## Security Considerations

**OAuth token stored in session storage without explicit security markers:**
- Risk: Chrome session storage is less protected than chrome.storage.local with encryption
- Files: `src/extension/src/background/service-worker.ts` (lines 24-39, 188-201)
- Current mitigation: Tokens are request-only, passed directly to native host without retention. No persistent cache
- Recommendations: 
  - Add explicit comment that tokens are temporary and non-persistent
  - Consider using chrome.storage.session which auto-clears on extension unload (already done implicitly)
  - Validate token format before sending to native host

**Extension identity/native-host mismatch not validated:**
- Risk: Malicious extension could pretend to be go-mapi and connect to native host
- Files: `src/extension/src/background/service-worker.ts` (line 66), `src/native-host/main.go` (line 16)
- Current mitigation: Native host only listens on stdin from registered extension ID (enforced by Chrome native messaging protocol)
- Recommendations: Document this security boundary clearly. If building alternative clients, warn about the assumption that extension ID is verified by the OS

**No verification of email JSON origin:**
- Risk: Any process can write JSON to `%TEMP%\go-mapi\` and have it processed as a real email
- Files: `src/native-host/watcher.go` (lines 157-174)
- Current mitigation: Only the interceptor DLL (registered via admin installation) should have write access, but no cryptographic validation
- Recommendations:
  - Document assumption that `%TEMP%\go-mapi\` is directory-permission protected
  - Consider adding HMAC signature to JSON (signed by interceptor, verified by host) for defense-in-depth
  - Warn users not to enable world-writable permissions on watch directory

**Logging may contain sensitive email content:**
- Risk: `native-host.log` in `%TEMP%\go-mapi\` contains log messages with email subjects (line 283 of watcher.go: `logInfo("processed email: %s (id: %s)", filename, id[:8])`)
- Files: `src/native-host/watcher.go` (line 283), `src/native-host/main.go` (lines 173-187)
- Impact: Log file could leak confidential email subjects to other users on shared system
- Fix approach: Log only anonymized info (email ID hash, not subject). Add privacy mode flag to suppress even ID logging if needed

## Performance Bottlenecks

**File system polling with 100ms debounce:**
- Problem: Watcher ticks every 100ms, waiting up to 500ms for write stabilization. Adds up to 600ms latency per email
- Files: `src/native-host/watcher.go` (lines 177-220)
- Cause: fsnotify provides multiple events during file write, must debounce to avoid premature reads
- Improvement path: Use inotify on Windows (fsnotify does this) or CRC-based completion detection to reduce debounce window to 50ms if stable

**Full email map serialized on each update:**
- Problem: Every received email triggers `persistEmails()` which serializes entire map to chrome.storage.session
- Files: `src/extension/src/background/service-worker.ts` (lines 24-28)
- Impact: O(n) storage write per email. With 100+ emails, becomes slow
- Improvement path: Use sparse updates - only store/remove changed email IDs rather than full map

**Attachment processing not streamed:**
- Problem: `buildFullMIME()` loads entire attachment file into memory before base64 encoding
- Files: `src/native-host/gmail.go` (lines 137-155)
- Impact: 25MB Gmail limit could spike memory to 50MB+ during encoding. User with many attachments may hit OOM
- Improvement path: Stream base64 encoding or implement chunked MIME construction for large attachments

## Fragile Areas

**MAPI address normalization is string-based:**
- Files: `src/native-host/watcher.go` (lines 345-361)
- Why fragile: Assumes MAPI address format is always `PREFIX:address`. Custom MAPI address types or Unicode prefixes could bypass normalization
- Safe modification: Add comprehensive tests for address formats. Consider using regex or bytes-based matching
- Test coverage: Unit tests exist (`normalizeAddress` tested in watcher_test.go) but limited to 4 prefixes. No tests for edge cases like lowercase, mixed case, or unknown prefixes

**Gmail API error handling lacks retry logic:**
- Files: `src/native-host/gmail.go` (lines 42-89)
- Why fragile: Single POST failure (transient 503, rate limit, network glitch) causes draft creation to fail permanently
- Safe modification: Implement exponential backoff (3 retries) for non-401 errors
- Current state: No retry on transient failures

**Error directory move might silently fail:**
- Files: `src/native-host/watcher.go` (lines 302-314)
- Why fragile: `moveToErrors()` writes `.error` file but if move fails, the error file ends up in wrong place and next startup will re-process bad JSON
- Safe modification: Log failures explicitly. Consider atomic directory operations or use quarantine subdirectory
- Test coverage: No tests for `moveToErrors()` edge cases

**Extension message handlers assume presence of optional fields:**
- Files: `src/extension/src/background/service-worker.ts` (lines 113-163)
- Why fragile: Code like `message.data` and `message.draftId` could be undefined if native host sends malformed message
- Safe modification: Add explicit null checks and default values. TypeScript types should mark fields as required/optional
- Test coverage: Protocol integration tests exist but don't test malformed messages from native host

## Scaling Limits

**Single browser process connection:**
- Current capacity: Single Chrome/Edge window with one native host process
- Limit: If extension crashes, native host orphans and stops processing (though it will reconnect on restart)
- Scaling path: Implement connection pooling or multiple native host instances behind a local proxy

**Watch directory unbounded:**
- Current capacity: No limit on number of JSON files in `%TEMP%\go-mapi\`
- Limit: Once 1000+ files accumulate, directory traversal and file operations degrade. No cleanup of processed/ directory
- Scaling path: Implement automatic cleanup of files older than 30 days. Archive old emails to SQLite instead of files

**In-memory email map unbounded:**
- Files: `src/native-host/watcher.go` (line 24)
- Current capacity: No limit on emails stored in memory or session storage
- Limit: With 10,000+ emails, map lookups degrade and session storage quota hit (10MB on most browsers)
- Scaling path: Implement pagination, store only recent 500 emails in memory, query older ones from disk/DB

## Dependencies at Risk

**fsnotify for file watching:**
- Risk: No longer maintained actively (last update 2022). fsnotify has open issues with long paths on Windows
- Impact: If Windows path API changes, file watching could break on paths > 260 chars
- Migration plan: Monitor upstream fsnotify. If needed, switch to Windows API directly via `syscall.NotifyChangeDirectory`

**Go http.Client without timeouts:**
- Risk: Standard library timeout is infinite. Not a version risk but a design risk
- Impact: Stalled connections block goroutines indefinitely
- Migration plan: Wrap http.Client in custom client with mandatory timeouts (already identified above)

## Missing Critical Features

**No offline queue or retry persistence:**
- Problem: If native host crashes between draft creation attempt and confirmation, draft is lost silently
- Blocks: Full end-to-end reliability. Users cannot trust that clicked emails will eventually become drafts
- Impact: Production blocker for enterprise use

**No email content encryption on disk:**
- Problem: JSON files with email bodies sit in plaintext in `%TEMP%\go-mapi\`
- Blocks: GDPR/security compliance in regulated environments
- Impact: Cannot deploy in environments with data protection requirements

**No multiple Gmail account selection:**
- Problem: OAuth token is for the signed-in user only. No way to create drafts in alternate accounts
- Blocks: Users with multiple Gmail accounts cannot use them
- Impact: Usability issue for multi-account power users

## Test Coverage Gaps

**Native host message loop not tested:**
- What's not tested: Main message loop in `main.go:61-113` - handling of various message types in real conditions
- Files: `src/native-host/main.go`, no dedicated tests
- Risk: Message type routing could silently break in production
- Priority: High (main codepath)

**Extension service worker connection handling:**
- What's not tested: Disconnect/reconnect behavior with state consistency
- Files: `src/extension/src/background/service-worker.ts` (lines 61-90), no tests
- Risk: Connection state may diverge from actual state, showing stale UI
- Priority: High (user-facing reliability)

**Error recovery in attachment processing:**
- What's not tested: What happens when attachment file is deleted between JSON write and draft creation
- Files: `src/native-host/gmail.go` (lines 128-155)
- Risk: Draft creation fails with generic error, no recovery path
- Priority: Medium (common user scenario)

**Goroutine cleanup on shutdown:**
- What's not tested: In-flight draft creation when host receives shutdown message
- Files: `src/native-host/main.go` (lines 103-105)
- Risk: Drafts may be abandoned mid-creation
- Priority: High (data loss risk)

**Charset encoding in MIME headers:**
- What's not tested: Non-ASCII subject lines and recipient names in draft creation
- Files: `src/native-host/gmail.go` (lines 186-201)
- Risk: Email headers may be corrupted for international users
- Priority: Medium (affects non-English users)

---

*Concerns audit: 2026-04-10*
