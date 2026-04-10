---
phase: 01-foundation-signpath-application
plan: 04
type: execute
wave: 2
depends_on: [01, 03]
files_modified:
  - src/native-host/main.go
autonomous: true
requirements: [FOUND-04]

must_haves:
  truths:
    - "GOMAPI_WATCH_DIR environment variable, when set, overrides the default %TEMP%\\go-mapi\\ watch directory"
    - "--gmail-api-base CLI flag, when set, overrides the default Gmail API base URL used by GmailClient"
    - "Precedence order CLI flag > env var > default is implemented and documented in the flag help text"
    - "The resolved watch dir and Gmail API base URL are logged at startup via logInfo so E2E test authors can verify from the log file"
    - "Go stdlib flag package is used — no third-party flag libraries"
  artifacts:
    - path: "src/native-host/main.go"
      provides: "Env var + CLI flag parsing, resolved values passed into EmailWatcher and GmailClient"
      contains: "GOMAPI_WATCH_DIR"
  key_links:
    - from: "main.go flag parsing"
      to: "NewEmailWatcher(watchDir, ...)"
      via: "getWatchDir() resolves env var before construction"
      pattern: "GOMAPI_WATCH_DIR"
    - from: "main.go handleCreateDraft"
      to: "NewGmailClientWithBase(token, gmailAPIBase)"
      via: "resolved --gmail-api-base flag passed through"
      pattern: "NewGmailClientWithBase"
---

<objective>
Wire two testability injection points into the native host entry point: a `GOMAPI_WATCH_DIR` environment variable that overrides the default `%TEMP%\go-mapi\` watch directory, and a `--gmail-api-base` CLI flag that overrides the default Gmail API base URL. Use the Go stdlib `flag` package, document the precedence order in the flag help text, and log the resolved values at startup.

Purpose: Unblocks E2E-02 and E2E-03 in Phase 4 — the Playwright happy-path test writes fixture JSONs into a per-test watch directory (via `GOMAPI_WATCH_DIR`) and points the host at a mock Gmail server (via `--gmail-api-base`). Without these injection points, E2E tests would have to touch `%TEMP%\go-mapi\` and the real Gmail API.
Output: A `main.go` that parses flags, reads env vars, and passes resolved values into `NewEmailWatcher` and the deferred Gmail client construction in `handleCreateDraft`.
</objective>

<execution_context>
This plan implements FOUND-04 from REQUIREMENTS.md. It depends on Plan 03 (FOUND-03) because it plumbs a CLI flag into `NewGmailClientWithBase(token, baseURL)` — that constructor must exist before this plan can wire the flag through.

Decisions are locked in `01-CONTEXT.md` section `### FOUND-04 (env var + CLI flag)`:
- `GOMAPI_WATCH_DIR` environment variable overrides the default watch dir in `main.go` before constructing the `EmailWatcher`
- `--gmail-api-base` CLI flag parsed in `main.go`, passed through to `GmailClient` construction via FOUND-03's injection point
- Precedence: **CLI flag > env var > default** for both watch dir and gmail base (though env var for gmail base is not required by the requirement; only watch dir needs an env var per the REQUIREMENTS.md text — scope discipline: do NOT add `GOMAPI_GMAIL_API_BASE` env var)
- Use Go stdlib `flag` package
- Log the resolved values at startup via existing `logInfo`
- **CONTEXT.md specifics**: "Document the CLI > env > default order in the flag help text so E2E test authors in Phase 4 don't need to read source"

**Scope clarification on precedence**:
- Watch dir: CLI flag (`--watch-dir`) > env var (`GOMAPI_WATCH_DIR`) > default (`%TEMP%\go-mapi\`) — requires adding `--watch-dir` flag to support the CLI > env precedence
- Gmail base: CLI flag (`--gmail-api-base`) > default (`gmailAPIBase` constant) — no env var for gmail base per requirement

Adding `--watch-dir` is a minor expansion to support the stated precedence order consistently. Alternative reading: env var alone is sufficient for watch dir, skip the `--watch-dir` flag entirely. **Executor decision**: Implement `--watch-dir` flag + `GOMAPI_WATCH_DIR` env var + default, in that precedence. The requirement text says "env variable" for watch dir but CONTEXT.md says "Precedence: CLI flag > env var > default (for both watch dir and gmail base)" — CONTEXT.md wins and means both get flags.
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@src/native-host/main.go
@src/native-host/gmail.go

<interfaces>
<!-- Current state of main.go — extracted so the executor does not need to re-scavenge -->

From src/native-host/main.go lines 22-60 — current main() structure:
```go
func main() {
    // Initialize logging
    initLogging()
    defer closeLogging()

    logInfo("go-mapi native host starting (version %s)", Version)

    // Get watch directory
    watchDir := getWatchDir()
    logInfo("watching directory: %s", watchDir)

    // Create native messaging handler
    messaging := NewNativeMessaging()

    // Create email watcher
    watcher, err := NewEmailWatcher(watchDir, messaging)
    // ... error handling ...

    // Start watching
    if err := watcher.Start(); err != nil { ... }
    defer watcher.Stop()

    // Send ready message
    if err := messaging.SendReady(Version); err != nil { ... }

    logInfo("native host ready, waiting for messages")

    // Main message loop
    for {
        msg, err := messaging.Read()
        // ... dispatch ...
    }
}
```

From src/native-host/main.go lines 115-140 — the Gmail client construction site (must be updated to use the resolved CLI flag):
```go
func handleCreateDraft(messaging *NativeMessaging, msg *IncomingMessage) {
    // ... validation ...
    client := NewGmailClient(msg.Token)
    // ... CreateDraft ...
}
```

From src/native-host/main.go lines 142-152 — the current watch dir resolver:
```go
func getWatchDir() string {
    // Use TEMP environment variable
    tempDir := os.Getenv("TEMP")
    if tempDir == "" {
        tempDir = os.Getenv("TMP")
    }
    if tempDir == "" {
        tempDir = os.TempDir()
    }
    return filepath.Join(tempDir, "go-mapi")
}
```

**Note**: Chrome Native Messaging invokes the host with specific arguments — Chrome passes the origin as `argv[1]` (the extension's chrome-extension://... URL). On Windows, Chrome may also pass the parent window handle. `flag.Parse()` called on `os.Args` would fail on these. The executor MUST use a custom `flag.FlagSet` and parse only arguments that look like flags (or only flags that begin with `--`), OR accept that unknown positional arguments are harmless. Consult https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging — Chrome's invocation passes the origin as an argument. Use `flag.NewFlagSet("go-mapi-host", flag.ContinueOnError)` and call `Parse(os.Args[1:])` with a custom error handler that logs unknown arguments as info rather than exiting — this keeps Chrome invocation working.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="false">
  <name>Task 1: Add flag parsing, resolve watch dir and gmail base URL, log them, pass through</name>
  <files>src/native-host/main.go</files>
  <read_first>
    - src/native-host/main.go (full file — understand main() flow, getWatchDir, and handleCreateDraft)
    - src/native-host/gmail.go (confirm that Plan 03 landed and `NewGmailClientWithBase(token, baseURL)` exists)
    - Chrome Native Messaging invocation conventions (Chrome passes the extension origin as an argument when launching the host — flag parsing must tolerate unknown positional args)
  </read_first>
  <action>
    Implement flag parsing + env var + default precedence in `src/native-host/main.go`. The changes have four parts:

    **Part A — Add a struct to hold the resolved config (package-level, for handleCreateDraft to read):**

    Near the top of `main.go`, alongside the existing `var Version` declaration (which now lives in `version.go`), add:

    ```go
    // hostConfig holds the resolved startup configuration for the native host.
    // Populated once in main() from CLI flags + env vars + defaults, then read by
    // goroutines like handleCreateDraft. Do not mutate after main() has set it.
    var hostConfig struct {
        watchDir     string
        gmailAPIBase string
    }
    ```

    **Part B — Add a `parseFlags()` helper that reads os.Args, applies precedence, and populates hostConfig:**

    ```go
    // parseFlags resolves startup configuration from CLI flags, environment variables, and defaults.
    //
    // Precedence (highest wins): CLI flag > env var > default.
    //
    // Flags:
    //   --watch-dir DIR        Override the default watch directory (%TEMP%\go-mapi\).
    //                          Also respects GOMAPI_WATCH_DIR env var (flag takes precedence).
    //   --gmail-api-base URL   Override the default Gmail API base URL (https://www.googleapis.com/gmail/v1/users/me).
    //                          No env var fallback — flag only.
    //
    // Unknown arguments (e.g. Chrome's extension origin URL passed as argv[1]) are ignored
    // with a debug log line — this keeps Chrome Native Messaging invocation working.
    func parseFlags() {
        fs := flag.NewFlagSet("go-mapi-host", flag.ContinueOnError)
        fs.SetOutput(io.Discard) // suppress default error output — we log ourselves

        watchDirFlag := fs.String("watch-dir", "",
            "Watch directory override. Precedence: --watch-dir flag > GOMAPI_WATCH_DIR env var > default (%TEMP%\\go-mapi\\)")
        gmailBaseFlag := fs.String("gmail-api-base", "",
            "Gmail API base URL override (for tests and E2E). Precedence: --gmail-api-base flag > default (https://www.googleapis.com/gmail/v1/users/me)")

        // Parse — tolerate unknown args (Chrome passes the extension origin as argv[1])
        if err := fs.Parse(os.Args[1:]); err != nil {
            logInfo("flag parse warning (unknown args ignored): %v", err)
        }

        // Resolve watch dir: flag > env > default
        switch {
        case *watchDirFlag != "":
            hostConfig.watchDir = *watchDirFlag
        case os.Getenv("GOMAPI_WATCH_DIR") != "":
            hostConfig.watchDir = os.Getenv("GOMAPI_WATCH_DIR")
        default:
            hostConfig.watchDir = defaultWatchDir()
        }

        // Resolve gmail base: flag > default
        if *gmailBaseFlag != "" {
            hostConfig.gmailAPIBase = *gmailBaseFlag
        } else {
            hostConfig.gmailAPIBase = gmailAPIBase
        }
    }
    ```

    The import block must now include `flag` and `io`. Add them if missing.

    **Part C — Rename the existing `getWatchDir()` to `defaultWatchDir()` and have main() use `hostConfig.watchDir`:**

    ```go
    // defaultWatchDir returns the default watch directory (%TEMP%\go-mapi\).
    // Used as a fallback when neither --watch-dir flag nor GOMAPI_WATCH_DIR env var is set.
    func defaultWatchDir() string {
        tempDir := os.Getenv("TEMP")
        if tempDir == "" {
            tempDir = os.Getenv("TMP")
        }
        if tempDir == "" {
            tempDir = os.TempDir()
        }
        return filepath.Join(tempDir, "go-mapi")
    }
    ```

    Also update `initLogging()` — it currently calls `getWatchDir()` to find the log file location. It must continue to write the log file into the resolved watch dir, but since logging is initialized BEFORE flag parsing (so that parseFlags() can itself log), the log file initialization must be re-done after parseFlags() if the watch dir changed. Simplest approach: in `main()`, call `parseFlags()` FIRST (before `initLogging()`), then call `initLogging()` which now reads `hostConfig.watchDir`. Refactor `initLogging()` to use `hostConfig.watchDir` instead of calling `defaultWatchDir()` directly.

    Updated `main()`:
    ```go
    func main() {
        // Resolve config from CLI flags + env vars + defaults FIRST,
        // so logging goes into the resolved watch directory.
        parseFlags()

        // Initialize logging (writes to hostConfig.watchDir/native-host.log)
        initLogging()
        defer closeLogging()

        logInfo("go-mapi native host starting (version %s)", Version)
        logInfo("resolved watch dir: %s", hostConfig.watchDir)
        logInfo("resolved gmail api base: %s", hostConfig.gmailAPIBase)

        // Create native messaging handler
        messaging := NewNativeMessaging()

        // Create email watcher using resolved watch dir
        watcher, err := NewEmailWatcher(hostConfig.watchDir, messaging)
        if err != nil {
            logError("failed to create watcher: %v", err)
            messaging.SendError(fmt.Sprintf("failed to create watcher: %v", err))
            os.Exit(1)
        }

        // ... rest unchanged ...
    }
    ```

    And refactor `initLogging()`:
    ```go
    func initLogging() {
        logDir := hostConfig.watchDir
        if logDir == "" {
            // Fallback in case parseFlags() somehow failed to populate it
            logDir = defaultWatchDir()
        }
        os.MkdirAll(logDir, 0755)
        // ... rest unchanged ...
    }
    ```

    **Part D — Update `handleCreateDraft` to use the resolved gmail base:**

    ```go
    func handleCreateDraft(messaging *NativeMessaging, msg *IncomingMessage) {
        // ... existing validation ...
        client := NewGmailClientWithBase(msg.Token, hostConfig.gmailAPIBase)
        // ... existing CreateDraft logic ...
    }
    ```

    **Scope discipline:**
    - Do NOT add a `GOMAPI_GMAIL_API_BASE` env var — only `--gmail-api-base` flag (per requirement wording)
    - Do NOT add any other flags (no `--verbose`, no `--help`, no `--version`)
    - Do NOT change the native-messaging protocol or any message types
    - Do NOT touch `gmail.go`, `protocol.go`, or `watcher.go`
    - Do NOT use a third-party flag library (stdlib `flag` only)
    - Do NOT fail on unknown arguments — Chrome passes the extension origin as `argv[1]` and the host must keep running
    - Do NOT add HTTP timeouts to the Gmail client (still out of scope)

    After the changes, the file should still compile and all existing tests should pass. Run `go build` and `go test` to verify.
  </action>
  <verify>
    <automated>cd src/native-host && go build ./... && go vet ./... && go test ./...</automated>
  </verify>
  <acceptance_criteria>
    - `src/native-host/main.go` imports the `flag` package (grep: `grep -n "\"flag\"" src/native-host/main.go` returns a match)
    - `src/native-host/main.go` imports the `io` package (grep: `grep -n "\"io\"" src/native-host/main.go` returns a match — was already imported for io.EOF, confirm it remains)
    - A `parseFlags()` function exists (grep: `grep -n "^func parseFlags" src/native-host/main.go` returns exactly 1 match)
    - The `--watch-dir` flag is registered (grep: `grep -n '"watch-dir"' src/native-host/main.go` returns a match)
    - The `--gmail-api-base` flag is registered (grep: `grep -n '"gmail-api-base"' src/native-host/main.go` returns a match)
    - The `GOMAPI_WATCH_DIR` env var is read (grep: `grep -n "GOMAPI_WATCH_DIR" src/native-host/main.go` returns at least 1 match)
    - A `hostConfig` struct or similar exists at package level holding `watchDir` and `gmailAPIBase` fields (grep: `grep -n "hostConfig" src/native-host/main.go` returns at least 3 matches — declaration, watch dir use, gmail base use)
    - `main()` calls `parseFlags()` before `initLogging()` (inspected visually; the `parseFlags()` call appears before the `initLogging()` call in main)
    - `handleCreateDraft` calls `NewGmailClientWithBase(msg.Token, hostConfig.gmailAPIBase)` instead of `NewGmailClient(msg.Token)` (grep: `grep -n "NewGmailClientWithBase.*hostConfig" src/native-host/main.go` returns a match; grep: `grep -n "NewGmailClient(msg.Token)" src/native-host/main.go` returns NO match)
    - `logInfo` calls exist for both the resolved watch dir and the resolved gmail api base (grep: `grep -c "resolved watch dir\|resolved gmail" src/native-host/main.go` returns at least 2)
    - The flag help text for `--watch-dir` documents the precedence order (grep: `grep "watch-dir.*Precedence" src/native-host/main.go` returns a match)
    - `go build ./src/native-host/...` succeeds
    - `go vet ./src/native-host/...` clean
    - `go test ./src/native-host/...` passes all existing tests (no new tests added)
    - The binary tolerates unknown arguments: `go run ./src/native-host/ chrome-extension://abcdefg/` does not crash immediately on argument parsing — it may exit due to stdin being a terminal, but the flag parse error (if any) is logged, not fatal
  </acceptance_criteria>
  <done>
    Flag parsing implemented with CLI > env > default precedence, resolved values logged at startup, Gmail client construction uses the resolved base URL, Chrome's extension-origin argument is tolerated, existing tests still pass.
  </done>
</task>

</tasks>

<verification>
- `go build ./src/native-host/...` succeeds
- `go vet ./src/native-host/...` clean
- `go test ./src/native-host/...` passes
- Running the binary with `--watch-dir=/tmp/test` and `--gmail-api-base=http://localhost:9999` and writing a test fixture into `/tmp/test` causes the host to log the resolved values and write the log into `/tmp/test/native-host.log`
- Running the binary with `GOMAPI_WATCH_DIR=/tmp/envtest` (no CLI flag) causes the host to use `/tmp/envtest`
- Running the binary with both `GOMAPI_WATCH_DIR=/tmp/env` AND `--watch-dir=/tmp/cli` causes the host to use `/tmp/cli` (CLI wins)
- Running the binary with no flag and no env var causes it to use `%TEMP%\go-mapi\`
</verification>

<success_criteria>
- `GOMAPI_WATCH_DIR` env var override works
- `--watch-dir` CLI flag override works
- `--gmail-api-base` CLI flag override works
- Precedence CLI > env > default is enforced for watch dir
- Precedence CLI > default is enforced for gmail base
- Flag help text documents the precedence order
- Resolved values logged at startup via `logInfo`
- Chrome's extension-origin argument does not crash flag parsing
- Only stdlib `flag` package used — no third-party dependencies
- No `GOMAPI_GMAIL_API_BASE` env var added (scope discipline)
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundation-signpath-application/01-04-SUMMARY.md` documenting:
- The exact diff to main.go
- The chosen `hostConfig` package-level struct layout
- Confirmation that Chrome's extension-origin argument is tolerated (how: `flag.ContinueOnError` + `io.Discard` + logged warning)
- Manual verification of each precedence path (CLI-only, env-only, both-set, neither-set)
- Confirmation that gmail.go, protocol.go, watcher.go were NOT touched
</output>
