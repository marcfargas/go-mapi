# Testing Patterns

**Analysis Date:** 2026-04-10

## Test Framework

**Runner:**
- Go testing package (`testing`) with `go test` command
- Go version: 1.21 (from `go.mod`)

**Assertion Library:**
- Standard Go testing: no external assertion library
- Manual assertions using `if` statements and `t.Errorf()`
- Table-driven tests for parameterized testing

**Run Commands:**
```bash
go test -v ./...              # Run all tests with verbose output
go test -v ./...              # From src/native-host/ directory
go test -run TestName         # Run specific test by name
go test -cover                # Run with coverage reporting
```

**CI Command (from `.github/workflows/build.yml`):**
```bash
go test -v ./...              # Run from src/native-host/ directory
```

## Test File Organization

**Location:**
- Tests co-located in same directory as implementation
- Unit tests in `*_test.go` files
- Integration tests in `*_integration_test.go` files

**Naming Convention:**
- `protocol_test.go` — Unit tests for protocol messaging
- `watcher_test.go` — Unit and basic integration tests for file watcher
- `protocol_integration_test.go` — Integration tests using protocol fixtures

**Test Functions:**
- Named `TestXxx()` where Xxx describes the function/behavior being tested
- Exported signature: `func TestName(t *testing.T)`
- Convention: `TestFunctionName_Scenario` (e.g., `TestNativeMessaging_Read_ValidMessage`)

## Test Structure

**Basic Test Pattern (from `protocol_test.go`):**
```go
func TestNativeMessaging_Read_ValidMessage(t *testing.T) {
	// Arrange: Set up test data
	input := IncomingMessage{
		Type: MsgTypeList,
	}
	data := createNativeMessage(t, input)

	// Act: Execute function under test
	nm := &NativeMessaging{
		reader: bytes.NewReader(data),
		writer: io.Discard,
	}
	msg, err := nm.Read()

	// Assert: Verify results
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}
	if msg.Type != MsgTypeList {
		t.Errorf("Read() type = %v, want %v", msg.Type, MsgTypeList)
	}
}
```

**Patterns:**
- **Setup:** Create test data and inject dependencies (e.g., custom readers/writers)
- **Execution:** Call function under test
- **Verification:** Use `t.Errorf()` for assertion failures (test continues) and `t.Fatalf()` for fatal errors (test stops)
- **Cleanup:** Deferred cleanup where needed

**Test Helpers:**
- `t.Helper()` marks function as test helper for accurate line number reporting
- Helper example (from `protocol_test.go`):
```go
func createNativeMessage(t *testing.T, msg interface{}) []byte {
	t.Helper()
	body, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("failed to marshal message: %v", err)
	}
	// ... build binary format
	return buf.Bytes()
}
```

## Mocking

**Approach:** Dependency injection of interfaces, not mocking libraries

**File I/O Mocking:**
- Tests use `t.TempDir()` for real temporary directories
- No file I/O stubbing — tests exercise actual file system operations
- Example from `watcher_test.go`:
```go
tmpDir := t.TempDir()
watchDir := filepath.Join(tmpDir, "watch")
os.MkdirAll(watchDir, 0755)

email := MailMessage{ /* ... */ }
data, _ := json.Marshal(email)
os.WriteFile(filepath.Join(watchDir, "process-me.json"), data, 0644)
```

**I/O Interface Mocking:**
- `NativeMessaging` struct accepts `reader` and `writer` interfaces
- Tests inject `bytes.Buffer`, `bytes.Reader`, `io.Discard`
- Example from `protocol_test.go`:
```go
nm := &NativeMessaging{
	reader: bytes.NewReader(data),
	writer: buf,
}
```

**HTTP Mocking:**
- Gmail API client (`gmail.go`) does NOT have tests
- No HTTP mocking implemented (client is simple and verified via fixtures)

## Fixtures

**Protocol Fixtures:**
- Location: `tests/protocol-fixtures/`
- Format: JSON message definitions
- Used to verify wire format compatibility between Go and TypeScript

**Fixture Files:**
- `ready-message.json` — Ready notification format
- `email-message.json` — Email message with attachments
- `removed-message.json` — Email removed notification
- `error-message.json` — Error message format
- `list-command.json` — List request format
- `process-command.json` — Process request with ID
- `delete-command.json` — Delete request with ID
- `shutdown-command.json` — Shutdown request

**Loading Fixtures (from `protocol_integration_test.go`):**
```go
func loadFixture(t *testing.T, name string) []byte {
	t.Helper()
	path := filepath.Join("..", "..", "tests", "protocol-fixtures", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to load fixture %s: %v", name, err)
	}
	return data
}
```

## Test Types

**Unit Tests:**
- Protocol serialization/deserialization: `TestNativeMessaging_Read_*`, `TestNativeMessaging_Write_*`
- Message validation: `TestValidateMailMessage_*`
- Utility functions: `TestGenerateID_*`, `TestNormalizeAddress_*`
- Scope: Single function in isolation with injected dependencies
- Count: ~40 unit tests across files

**Integration Tests:**
- Email watcher directory operations: `TestEmailWatcher_*` in `watcher_test.go`
- Protocol format verification: `TestNativeMessagingFormat_*` in `protocol_integration_test.go`
- Fixture validation: `TestFixture_*` in `protocol_integration_test.go`
- Scope: Multiple components interacting with temporary file system
- Count: ~15 integration tests

**E2E Tests:**
- Not present in codebase
- Actual file watching behavior tested via CI workflow (artifact generation)

## Common Testing Patterns

**Error Testing:**
```go
func TestNativeMessaging_Read_OversizedMessage(t *testing.T) {
	buf := new(bytes.Buffer)
	binary.Write(buf, binary.LittleEndian, uint32(2*1024*1024)) // 2MB

	nm := &NativeMessaging{
		reader: buf,
		writer: io.Discard,
	}

	_, err := nm.Read()
	if err == nil {
		t.Error("Read() expected error for oversized message")
	}
}
```

**Parametric Testing (Table-Driven):**
```go
func TestNormalizeAddress(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"SMTP:user@example.com", "user@example.com"},
		{"smtp:user@example.com", "user@example.com"},
		{"MAILTO:user@example.com", "user@example.com"},
		{"mailto:user@example.com", "user@example.com"},
		{"user@example.com", "user@example.com"},
		{"", ""},
	}

	for _, tt := range tests {
		result := normalizeAddress(tt.input)
		if result != tt.expected {
			t.Errorf("normalizeAddress(%q) = %q, want %q", tt.input, result, tt.expected)
		}
	}
}
```

**Roundtrip Testing (Write then Read):**
```go
func TestNativeMessaging_Roundtrip(t *testing.T) {
	pipe := new(bytes.Buffer)
	writer := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: pipe,
	}

	mail := &MailMessage{ /* populated */ }
	if err := writer.SendEmail("roundtrip-id", mail); err != nil {
		t.Fatalf("SendEmail() error = %v", err)
	}

	// Parse output
	data := pipe.Bytes()
	var length uint32
	binary.Read(bytes.NewReader(data[:4]), binary.LittleEndian, &length)

	var msg OutgoingMessage
	if err := json.Unmarshal(data[4:4+length], &msg); err != nil {
		t.Fatalf("failed to unmarshal: %v", err)
	}

	// Verify all fields preserved
	if msg.Data.Subject != "Roundtrip Test" {
		t.Errorf("subject mismatch")
	}
}
```

**Temporary Directory Testing:**
```go
func TestEmailWatcher_Creation(t *testing.T) {
	tmpDir := t.TempDir()  // Automatically cleaned up after test
	watchDir := filepath.Join(tmpDir, "watch")

	nm := &NativeMessaging{
		reader: bytes.NewReader([]byte{}),
		writer: io.Discard,
	}

	ew, err := NewEmailWatcher(watchDir, nm)
	if err != nil {
		t.Fatalf("NewEmailWatcher() error = %v", err)
	}
	defer ew.Stop()

	// Verify directories created
	if _, err := os.Stat(watchDir); os.IsNotExist(err) {
		t.Error("watch directory not created")
	}
}
```

## Coverage

**Requirements:** No explicit coverage requirements enforced

**Tools:** Built-in `go test -cover` can be used

**Typical Coverage:**
- Protocol layer (~95%): serialization, deserialization, error cases well-tested
- Validation layer (~90%): all validation rules tested
- Watcher layer (~80%): core operations tested, edge cases for file system timing covered
- MIME building (~0%): not tested directly (verified via fixtures)
- Logging (~0%): utility functions not tested

**High-Risk Untested Areas:**
- `buildFullMIME()` in `gmail.go` — complex MIME formatting, only validated via fixture loads
- Actual Gmail API calls — HTTP layer not tested (token validation is mocked in behavior)
- Race conditions — concurrency tested via manual inspection, not race detector

## Testing Failures and Edge Cases

**File System Timing:**
- Tests wait for file writes to complete with 500ms debounce
- Antivirus interference handled via retry loop (200ms backoff, 3 attempts)
- No explicit test for retry logic — relies on integration test resilience

**Message Format Errors:**
- Truncated messages tested: `TestNativeMessaging_Read_TruncatedBody`
- Oversized messages tested: `TestNativeMessaging_Read_OversizedMessage`
- Invalid JSON tested: `TestNativeMessaging_Read_InvalidJSON`

**Validation Failures:**
- Missing required fields: `TestValidateMailMessage_MissingVersion`, `TestValidateMailMessage_MissingTimestamp`
- Invalid enum values: `TestValidateMailMessage_InvalidBodyFormat`
- Invalid recipient data: `TestValidateMailMessage_ToRecipientMissingAddress`
- Empty collections valid: `TestValidateMailMessage_NoRecipients`

**Concurrent Access:**
- `MarkProcessed()` and `Delete()` tested with mutex protection implicit in tests
- No explicit race condition tests (single-threaded test execution)
- RWMutex correctness assumed from standard library

## Test Naming Convention

**Pattern:** `Test{Function}_{Scenario}` or `Test{Type}_{Method}_{Scenario}`

**Examples:**
- `TestNativeMessaging_Read_ValidMessage` — testing Read method with valid input
- `TestNativeMessaging_Read_OversizedMessage` — testing Read with error case
- `TestValidateMailMessage_MissingVersion` — testing validation function with missing field
- `TestGenerateID_Deterministic` — testing utility function behavior
- `TestEmailWatcher_MarkProcessed` — testing watcher method
- `TestFixture_ReadyMessage` — testing fixture parsing

## Running Tests in CI

**Workflow:** `.github/workflows/build.yml` (job: `build-native-host`)

**Steps:**
1. Checkout repository
2. Setup Go 1.21
3. Run `go test -v ./...` from `src/native-host/` directory
4. If tests pass, build binary with `go build -ldflags "-s -w"`

**Test Output:**
- Verbose mode (`-v`) shows each test name and pass/fail
- Exit code 0 on success, non-zero on failure
- Failed tests block binary build (no continue-on-error)

---

*Testing analysis: 2026-04-10*
