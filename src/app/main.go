package main

import (
	"context"
	"embed"
	"os"
	"strings"

	"github.com/pkg/browser"
	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

var Version = "0.0.0-dev" // overridden via -ldflags "-X main.Version=..."

// RequiredInterceptorMin/Max are compiled from the app record in
// components.json. They are independent from the interceptor's own version.
var RequiredInterceptorMin = "4.0.0"
var RequiredInterceptorMax = ""

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		println(Version)
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "--install-admin-component" {
		if err := runElevatedAdminInstall(context.Background()); err != nil {
			println("Error:", err.Error())
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "--purge-user-data" {
		if err := purgeUserData(); err != nil {
			println("Error:", err.Error())
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "--handoff-from-store" {
		if err := runStoreToStandaloneHandoff(context.Background()); err != nil {
			println("Error:", err.Error())
			os.Exit(1)
		}
		return
	}
	if len(os.Args) == 2 && strings.HasPrefix(os.Args[1], "--configure-autostart=") {
		enabledText := strings.TrimPrefix(os.Args[1], "--configure-autostart=")
		if enabledText != "true" && enabledText != "false" {
			println("Error: --configure-autostart must be true or false")
			os.Exit(1)
		}
		if err := configureAutostartFromInstaller(context.Background(), enabledText == "true"); err != nil {
			println("Error:", err.Error())
			os.Exit(1)
		}
		return
	}
	if err := prepareStoreTargetHandoff(context.Background()); err != nil {
		println("Error:", err.Error())
		os.Exit(1)
	}

	raised, siErr := acquireSingleInstance()
	if siErr != nil {
		logError("single-instance: %v", siErr)
		// Handoff and queue ownership require an acquired mutex. Starting
		// without it could create a second consumer, so fail closed.
		os.Exit(1)
	}
	if raised {
		// Another instance owns the mutex; we signaled its named event. Exit now.
		// Use os.Exit to be explicit: no Wails init, no defers needing to run, fastest path out.
		logInfo("second instance detected — signalled first instance, exiting")
		os.Exit(0)
	}
	activationTarget, handoffErr := startupHandoffAction(context.Background())
	if handoffErr != nil {
		releaseSingleInstance()
		logError("channel handoff blocked startup: %v", handoffErr)
		os.Exit(1)
	}
	if activationTarget != "" {
		releaseSingleInstance()
		if err := newHandoffPlatform().Activate(context.Background(), activationTarget); err != nil {
			logError("channel handoff activation failed: %v", err)
			os.Exit(1)
		}
		return
	}
	defer releaseSingleInstance()

	// D-08: Fail fast if the WebView2 Evergreen runtime is missing. Running
	// without it, the Wails window would either show blank or the process
	// would crash inside Wails's WebView2 init. Show a native MessageBox
	// (the only UI primitive we can use — Wails itself is what's broken),
	// point the user at Microsoft's download page, and exit cleanly.
	// Guard is skipped under `bindings` (wailsbindings.exe) like checkOAuthCredentials.
	if err := checkWebView2(); err != nil {
		logError("FATAL: %s", err.Error())
		showWebView2MissingDialog()
		_ = browser.OpenURL("https://developer.microsoft.com/en-us/microsoft-edge/webview2/")
		os.Exit(1)
	}

	// D-10: Fail fast if OAuth credentials were not injected. A release build
	// with empty client_id silently cannot sign anyone in — louder now is kinder.
	// Guard is skipped under the `bindings` build tag (wailsbindings.exe) so that
	// Wails can generate TypeScript bindings without needing real credentials at
	// dev time. In production and wails dev, the guard is always active.
	// The check itself returns an error (testable); main owns the os.Exit(1).
	if err := checkOAuthCredentials(); err != nil {
		logError("FATAL: %s", err.Error())
		os.Exit(1)
	}

	app := NewApp()

	// Note: HideWindowOnClose is intentionally NOT set. With it true, Wails routes the X
	// button straight to f.WindowHide() without invoking OnBeforeClose — that bypasses our
	// visibility tracking (Bug A) and the intentionalQuit gate (Bug B). Instead we let
	// the X button fire OnBeforeClose, and our beforeClose hides the window AND updates
	// visibility (return true = prevent the actual close).
	err := wails.Run(&options.App{
		Title:         "go-mapi",
		Width:         480,
		Height:        600,
		MinWidth:      360,
		MinHeight:     400,
		Assets:        assets,
		OnStartup:     app.startup,
		OnShutdown:    app.shutdown,
		OnBeforeClose: app.beforeClose,
		Bind:          []interface{}{app},
		StartHidden:   true,
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			DisableWindowIcon:    false,
		},
	})
	if err != nil {
		println("Error:", err.Error())
	}
}
