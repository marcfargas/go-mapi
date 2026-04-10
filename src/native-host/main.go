package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

const (
	HostName = "com.gomapi.host"
)

var (
	logFile *os.File
)

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

	client := NewGmailClient(msg.Token)

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

func initLogging() {
	// Log to file in watch directory for debugging
	logDir := getWatchDir()
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
