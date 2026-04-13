package testutil

import (
	"path/filepath"
	"runtime"
)

// FixturePath resolves tests/protocol-fixtures/* from repo root regardless of where tests run.
func FixturePath(rel string) string {
	_, thisFile, _, _ := runtime.Caller(0)
	// thisFile = <repo>/internal/mapi/testutil/fixtures.go
	// Ascend 3 levels: testutil -> mapi -> internal -> repo root
	repoRoot := filepath.Join(filepath.Dir(thisFile), "..", "..", "..")
	return filepath.Join(repoRoot, "tests", "protocol-fixtures", rel)
}
