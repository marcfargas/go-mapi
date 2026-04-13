package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var (
	logFile   *os.File
	logMu     sync.Mutex
	logInitMu sync.Once
)

// initLog opens (or creates) the app log file at %APPDATA%\go-mapi\app.log.
// Per-user path (not %TEMP%) provides per-session isolation under RDS.
// T-07-23: uses APPDATA (per-user ACL), NOT PROGRAMDATA.
func initLog() {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		// Fallback: write to stderr if APPDATA not set.
		return
	}
	dir := filepath.Join(appData, "go-mapi")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return
	}
	path := filepath.Join(dir, "app.log")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	logFile = f
}

func writeLog(level, format string, args ...interface{}) {
	logInitMu.Do(initLog)

	ts := time.Now().UTC().Format(time.RFC3339)
	msg := fmt.Sprintf(format, args...)
	line := fmt.Sprintf("%s [%s] %s\n", ts, level, msg)

	logMu.Lock()
	defer logMu.Unlock()

	if logFile != nil {
		_, _ = logFile.WriteString(line)
		// Sync after every write for visibility during debugging.
		_ = logFile.Sync()
	} else {
		// Fallback to stderr if log file unavailable.
		_, _ = fmt.Fprint(os.Stderr, line)
	}
}

// logInfo writes a timestamped [INFO] entry to app.log.
// Do NOT log email bodies or subjects (T-07-22 mitigation).
func logInfo(format string, args ...interface{}) {
	writeLog("INFO", format, args...)
}

// logError writes a timestamped [ERROR] entry to app.log.
// Do NOT log email bodies or subjects (T-07-22 mitigation).
func logError(format string, args ...interface{}) {
	writeLog("ERROR", format, args...)
}
