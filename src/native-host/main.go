package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	mapi "github.com/marcfargas/go-mapi/native-host/internal/mapi"
)

const (
	HostName = "com.gomapi.host"
)

var (
	logFile *os.File
)

// hostConfig holds the resolved startup configuration for the native host.
// Populated once in main() from CLI flags + env vars + defaults, then read by
// goroutines like handleCreateDraft. Do not mutate after main() has set it.
var hostConfig struct {
	watchDir     string
	gmailAPIBase string
}

// parseFlags resolves startup configuration from CLI flags, environment variables,
// and defaults, populating the package-level hostConfig.
//
// Precedence (highest wins): CLI flag > env var > default.
//
// Flags:
//
//	--watch-dir DIR        Override the default watch directory (%TEMP%\go-mapi\).
//	                       Also respects GOMAPI_WATCH_DIR env var; the flag takes precedence.
//	--gmail-api-base URL   Override the default Gmail API base URL. Flag-only, no env var
//	                       fallback — scope-limited to what FOUND-04 requires.
//
// Unknown arguments (e.g. Chrome's extension origin URL passed as argv[1] by the
// Native Messaging host invocation) are tolerated: flag.ContinueOnError + an
// io.Discard error sink keep the host alive. Any parse warning is silently
// dropped because logging is not yet initialized when parseFlags runs; the
// resolved values are logged from main() once logging is up.
func parseFlags() {
	fs := flag.NewFlagSet("go-mapi-host", flag.ContinueOnError)
	fs.SetOutput(io.Discard) // suppress default error output — Chrome passes unknown args

	watchDirFlag := fs.String("watch-dir", "",
		"Watch directory override. Precedence: --watch-dir flag > GOMAPI_WATCH_DIR env var > default (%TEMP%\\go-mapi\\)")
	gmailBaseFlag := fs.String("gmail-api-base", "",
		"Gmail API base URL override (for tests and E2E). Precedence: --gmail-api-base flag > default (https://www.googleapis.com/gmail/v1/users/me)")

	// Parse — tolerate unknown args. Chrome invokes the host with the extension
	// origin as argv[1]; a parse error here must NOT kill the host. Logging is
	// not yet initialized so any warning silently drops via io.Discard.
	_ = fs.Parse(os.Args[1:])

	// Resolve watch dir: flag > env > default
	switch {
	case *watchDirFlag != "":
		hostConfig.watchDir = *watchDirFlag
	case os.Getenv("GOMAPI_WATCH_DIR") != "":
		hostConfig.watchDir = os.Getenv("GOMAPI_WATCH_DIR")
	default:
		hostConfig.watchDir = defaultWatchDir()
	}

	// Resolve gmail base: flag > default. No env var per FOUND-04 scope.
	if *gmailBaseFlag != "" {
		hostConfig.gmailAPIBase = *gmailBaseFlag
	} else {
		hostConfig.gmailAPIBase = mapi.GmailAPIBase
	}
}

func main() {
	// Resolve config from CLI flags + env vars + defaults FIRST, so logging
	// writes into the resolved watch directory (not the default) when
	// --watch-dir or GOMAPI_WATCH_DIR is set.
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

	// Start watching
	if err := watcher.Start(); err != nil {
		logError("failed to start watcher: %v", err)
		messaging.SendError(fmt.Sprintf("failed to start watcher: %v", err))
		os.Exit(1)
	}
	defer watcher.Stop()

	// Send ready message
	if err := messaging.SendReady(Version); err != nil {
		logError("failed to send ready message: %v", err)
	}

	logInfo("native host ready, waiting for messages")

	// Main message loop
	for {
		msg, err := messaging.Read()
		if err != nil {
			if err == io.EOF {
				logInfo("extension disconnected")
				break
			}
			logError("failed to read message: %v", err)
			continue
		}

		logInfo("received message: type=%s id=%s", msg.Type, msg.ID)

		switch msg.Type {
		case MsgTypeList:
			// Send all current emails
			for id, mail := range watcher.GetEmails() {
				if err := messaging.SendEmail(id, mail); err != nil {
					logError("failed to send email: %v", err)
				}
			}

		case MsgTypeProcess:
			if err := watcher.MarkProcessed(msg.ID); err != nil {
				logError("failed to mark processed: %v", err)
				messaging.SendError(fmt.Sprintf("failed to mark processed: %v", err))
			}

		case MsgTypeDelete:
			if err := watcher.Delete(msg.ID); err != nil {
				logError("failed to delete: %v", err)
				messaging.SendError(fmt.Sprintf("failed to delete: %v", err))
			} else {
				// Confirm deletion
				messaging.SendRemoved(msg.ID)
			}

		case MsgTypeCreateDraft:
			logInfo("create-draft request: emailId=%s, %d attachments",
				msg.ID, len(msg.Email.Attachments))
			go handleCreateDraft(messaging, msg)

		case MsgTypeShutdown:
			logInfo("shutdown requested")
			return

		default:
			logError("unknown message type: %s", msg.Type)
		}
	}

	logInfo("native host exiting")
}

func handleCreateDraft(messaging *NativeMessaging, msg *IncomingMessage) {
	if msg.Token == "" {
		logError("create-draft: missing OAuth token")
		messaging.SendDraftError(msg.ID, "Missing OAuth token")
		return
	}
	if msg.Email == nil {
		logError("create-draft: missing email data")
		messaging.SendDraftError(msg.ID, "Missing email data")
		return
	}

	client := mapi.NewGmailClientWithBase(msg.Token, hostConfig.gmailAPIBase)

	logInfo("creating draft with %d attachments", len(msg.Email.Attachments))
	draftID, err := client.CreateDraft(msg.Email)
	if err != nil {
		logError("failed to create draft: %v", err)
		messaging.SendDraftError(msg.ID, fmt.Sprintf("Failed to create draft: %v", err))
		return
	}

	gmailURL := fmt.Sprintf("https://mail.google.com/mail/u/0/#drafts?compose=%s", draftID)
	logInfo("draft created: %s", draftID)
	messaging.SendDraftCreated(msg.ID, draftID, gmailURL)
}

// defaultWatchDir returns the default watch directory (%TEMP%\go-mapi\).
// Used as a fallback when neither the --watch-dir flag nor the
// GOMAPI_WATCH_DIR env var is set. See parseFlags for the full precedence.
func defaultWatchDir() string {
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

func initLogging() {
	// Log to file in the resolved watch directory for debugging.
	// parseFlags() must run before initLogging() so hostConfig.watchDir is set;
	// the fallback exists as a safety net in case that ordering ever breaks.
	logDir := hostConfig.watchDir
	if logDir == "" {
		logDir = defaultWatchDir()
	}
	os.MkdirAll(logDir, 0755)

	logPath := filepath.Join(logDir, "native-host.log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return
	}
	logFile = f
}

func closeLogging() {
	if logFile != nil {
		logFile.Close()
	}
}

func logInfo(format string, args ...interface{}) {
	if logFile != nil {
		ts := time.Now().Format(time.RFC3339)
		fmt.Fprintf(logFile, "[%s] [INFO] "+format+"\n", append([]interface{}{ts}, args...)...)
		logFile.Sync()
	}
}

func logError(format string, args ...interface{}) {
	if logFile != nil {
		ts := time.Now().Format(time.RFC3339)
		fmt.Fprintf(logFile, "[%s] [ERROR] "+format+"\n", append([]interface{}{ts}, args...)...)
		logFile.Sync()
	}
}
