# Coding Conventions

**Analysis Date:** 2026-04-10

## Naming Patterns

**Files:**
- CamelCase with underscores for test variants: `protocol.go`, `protocol_test.go`, `protocol_integration_test.go`
- Descriptive names matching primary type or functionality: `watcher.go`, `gmail.go`
- Test files use `_test.go` suffix for unit tests, `_integration_test.go` for integration tests

**Functions:**
- PascalCase for exported functions: `NewEmailWatcher()`, `CreateDraft()`, `SendEmail()`
- camelCase for unexported functions: `processFile()`, `normalizeAddress()`, `handleRemove()`
- Descriptive verb-first names: `Validate()`, `Generate()`, `Normalize()`

**Types:**
- PascalCase for all exported types: `EmailWatcher`, `NativeMessaging`, `MailMessage`, `GmailClient`
- Unexported struct fields in lowercase: `watchDir`, `watcher`, `done`

**Variables:**
- camelCase for local variables: `tmpDir`, `watchDir`, `isDir`
- Short names acceptable for loop counters: `i`, `r`, `c`
- Descriptive names for important state: `lastMod`, `pending`, `processed`
- All caps for constants: `MsgTypeEmail`, `maxFileSize`, `maxRetries`

**Constants:**
- All caps with underscores: `MsgTypeList`, `MsgTypeProcess`, `MsgTypeDelete`, `MsgTypeCreateDraft`
- Package-level constants describe protocol message types or limits: `gmailAPIBase`, `maxFileSize`

## Code Style

**Formatting:**
- Standard Go formatting with `gofmt` (enforced by default)
- Line length: No hard limit, but keep readable (convention: ~100 chars practical maximum)
- Spacing: 1 blank line between function definitions, multiple lines for logical grouping within functions

**Linting:**
- Uses standard Go toolchain (`go vet`, `go test`)
- No explicit linter configured (relies on Go standard conventions)
- Code follows idiomatic Go patterns from effective Go

**Comments:**
- Package-level comments explain purpose: `// NativeMessaging handles Chrome Native Messaging protocol`
- Function-level comments for exported functions document purpose and behavior
- Inline comments explain non-obvious logic or gotchas (e.g., debouncing strategy, retry logic)
- Comments describe "why", not "what" — code should be self-documenting for simple operations

**Error Handling:**
- Always check and propagate errors: `if err != nil { return fmt.Errorf(...) }`
- Wrap errors with context using `%w` verb: `fmt.Errorf("failed to create watcher: %w", err)`
- Error strings are lowercase (Go convention) unless containing code/paths: `"failed to read file"`
- Return early on error, avoid deep nesting

## Import Organization

**Order:**
1. Standard library imports (`fmt`, `io`, `os`, `encoding/json`, `net/http`, etc.)
2. Third-party imports (`github.com/fsnotify/fsnotify`)
3. (No internal imports in this module — single package)

**Path Aliases:**
- No aliases used (imports are explicit)
- Full import paths from standard library or external packages

**Example (from `watcher.go`):**
```go
import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)
```

## Function Design

**Size:** Functions should be focused and understandable at a glance. Average function size: 20-50 lines. Longer functions (100+ lines) like `buildFullMIME()` break complex operations into logical sections with clear comments.

**Parameters:**
- Use explicit parameters, no `...interface{}` variadic types (except for `logInfo`/`logError` which use `...interface{}` for format args)
- Receiver parameters use pointer receivers for methods that modify state: `(ew *EmailWatcher)`
- Config parameters grouped into structs where there are 3+ related parameters (not used extensively here)

**Return Values:**
- Functions return `(result, error)` tuple: `CreateDraft() (string, error)`
- Always check error results; idiomatic Go expects callers to handle errors
- Single return type for simple getters: `GetEmails() map[string]*MailMessage`

**Defer:**
- Used for cleanup: `defer ew.Stop()`, `defer ew.mu.RUnlock()`, `defer resp.Body.Close()`
- Placed immediately after acquiring resource to avoid leak

## Concurrency

**Mutex Usage:**
- `sync.RWMutex` used for protection: `EmailWatcher.mu`
- Lock immediately before accessing shared state: `ew.mu.Lock()` before modifying `ew.emails`
- RUnlock with defer: `defer ew.mu.RUnlock()`
- Write lock for mutations, read lock for reads

**Goroutines:**
- Background work runs in goroutines with explicit lifecycle: `go ew.watchLoop()`
- Signaling done via channel: `ew.done chan struct{}`
- Clean shutdown on `close(ew.done)`

**Channels:**
- Used for event signaling and graceful shutdown
- `watcher.Events` channel from fsnotify library for file system events
- Debouncing implemented with map and ticker instead of chan (see `watchLoop`)

## Message Protocol

**JSON Marshaling:**
- Structs use struct tags for JSON field mapping: `json:"type"`, `json:"omitempty"`
- Uppercase exported fields, lowercase JSON keys: `Type` (Go) → `"type"` (JSON)
- Omit empty fields in outgoing messages: `json:"error,omitempty"`, `json:"data,omitempty"`

**Error Responses:**
- Errors sent as messages, not return codes
- Error messages are user-facing descriptions, not stack traces
- Specific error types (e.g., `draft-error`, `error`) distinguish failure categories

## Logging

**Framework:** Standard `fmt` fprintf to file (no external logging library)

**Implementation (in `main.go`):**
```go
func logInfo(format string, args ...interface{}) {
	if logFile != nil {
		ts := time.Now().Format(time.RFC3339)
		fmt.Fprintf(logFile, "[%s] [INFO] "+format+"\n", append([]interface{}{ts}, args...)...)
		logFile.Sync()
	}
}
```

**Patterns:**
- Timestamp in RFC3339 format
- Log level prefix ([INFO], [ERROR])
- Sync after every write (ensures visibility for debugging)
- Silent graceful failures if logFile not available

**When to Log:**
- Info: startup, shutdown, major operations (`"processing email"`, `"native host ready"`)
- Error: failures that need investigation (`"failed to read file"`, `"invalid email"`)
- Omit verbose logs in hot paths (watch loop events logged at info level only on processing)

## Directory and File Location

**Main Package Location:** `src/native-host/`

**File Purposes:**
- `main.go`: Entry point, message loop, version variable, logging setup
- `protocol.go`: Native Messaging protocol types and serialization
- `watcher.go`: Email file system watching and validation
- `gmail.go`: Gmail API client and MIME message building

**Test Organization:**
- Unit tests co-located: `protocol_test.go` tests `protocol.go`
- Integration tests co-located with related module: `watcher_test.go` tests `watcher.go`
- Protocol integration tests load fixtures: `protocol_integration_test.go`
- Fixtures in external directory: `tests/protocol-fixtures/`

## Build and Release

**Version Management:**
- Version injected at build time via `-ldflags "-X main.Version=..."`
- Default fallback: `var Version = "0.0.0-dev"`
- Version stamped on outgoing messages: `mail.HostVersion = Version`

**Build Command (from CI):**
```bash
go build -ldflags "-s -w" -o build/go-mapi-host.exe .
```
- `-s -w`: Strip symbols and debug info (release optimization)

**Go Version:** 1.21 (from `go.mod`)

## Validation

**Mail Message Validation:**
- Explicit validation function: `validateMailMessage(&mail)`
- Checks required fields: `Version`, `Timestamp`, `BodyFormat`
- Validates enum-like field: `BodyFormat` must be "plain" or "html"
- Validates recipient structure: all recipients must have address
- Early return on first validation error
- Errors moved to `/errors/` directory with `.error` file containing reason

**Address Normalization:**
- Strips MAPI prefixes (SMTP:, mailto:) case-insensitively
- Applied to all recipients during processing
- Function `normalizeAddress()` handles single address, `normalizeRecipients()` handles slices

## Special Patterns

**ID Generation:**
- Content-based SHA256 hash combining message body + filename
- Deterministic (same input → same ID)
- Used to detect duplicates and create unique references
- Stored as hex string (64 characters)

**Debouncing:**
- File write debouncing with 500ms grace period
- Pending map tracks files modified recently: `pending[filename] = time.Now()`
- Ticker checks every 100ms, processes if untouched for 500ms
- Handles antivirus file locking via retry loop with 200ms backoff (3 attempts)

**Privacy-First Deletion:**
- No retention archive (files deleted immediately, not moved to processed/)
- Processed emails deleted with `os.Remove()` not archival
- Explicit comment: `// privacy-first: no retention`

---

*Convention analysis: 2026-04-10*
