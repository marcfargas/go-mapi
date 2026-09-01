# README

## About

This is the official Wails Svelte-TS template.

## Live Development

To run in live development mode, run `wails dev` in the project directory. This will run a Vite development
server that will provide very fast hot reload of your frontend changes. If you want to develop in a browser
and have access to your Go methods, there is also a dev server that runs on http://localhost:34115. Connect
to this in your browser, and you can call your Go code from devtools.

## Building

To build a redistributable, production mode package, use `wails build`.
## Component boundary

This is the per-user Wails queue consumer. Build it with `npm run build:app` at
the repository root; test it with `npm run test:app`. It consumes queue-v1 and
can start with an empty queue when no interceptor is installed. The app does
not install, register, elevate, or download the machine-wide interceptor.

The app has an independent version and counterpart range. See
`../../docs/component-compatibility.md`. Release builds embed only the app
version and its required interceptor bounds; supported rolling-upgrade pairs,
not a shared repository tag, are the compatibility contract.

## User settings

Canonical settings live at `%APPDATA%\go-mapi\settings.json`. `mode` is
exactly `manual` or `auto-draft`; unknown values and malformed/unreadable
files are preserved and shown as actionable errors. They are never silently
reported as manual. Unknown additive JSON fields are accepted.

`autostart_enabled` is the user's requested state and defaults to `true` when
absent. It is distinct from Windows' registered/effective startup state.
Windows can still disable startup by user action or policy, which the app must
report with a link to `ms-settings:startupapps`.

At runtime the Store channel reads and changes
`Windows.ApplicationModel.StartupTask`; it requests enablement only from an
explicit user action and never overrides `DisabledByUser` or
`DisabledByPolicy`. The standalone channel reads back the Task Scheduler XML,
requires the exact current executable plus `--startup`, and requires
`InteractiveToken`/`LeastPrivilege` before reporting a registration healthy.

The app may offer “Make go-mapi your default mail app” guidance and open
`ms-settings:defaultapps`. It never writes `UserChoice`; Windows owns the final
selection. The admin MSI separately owns only the active MAPI DLL registration
in HKLM.

## Distribution

All user-app channels are x64, per-user, and non-elevated:

- Store: full-trust MSIX with an ordinary user-controlled StartupTask;
- direct: separately signed, current-user NSIS installer;
- winget: the exact signed direct-installer GitHub Release artifact.

The MSIX disables filesystem-write virtualization and declares
`unvirtualizedResources`, keeping `%APPDATA%\go-mapi` and
`%LOCALAPPDATA%\go-mapi\queue` canonical across channels. That capability and
the reserved package identity require Partner Center approval. Normal removal
preserves those paths and saved credentials; only the standalone uninstall
checkbox (or a separately confirmed in-app action for Store users) invokes
`--purge-user-data`.

Use `scripts/build-app-msix.ps1`, `scripts/build-app-installer.ps1`, and
`scripts/verify-app-distribution.ps1` after the guarded Wails release build.
Public GitHub Actions releases fail closed unless the app EXE and both packages
complete the configured signing route. No app package contains or registers
the interceptor.

## Channel handoff

Direct and winget are one standalone identity. Store/standalone transitions
use `%APPDATA%\go-mapi\channel-handoff-v1.json`, written atomically with a
per-transition random token. The target process acquires the existing session
mutex before replaying the journal, removes only the known per-user source
registration, verifies the source is absent, and deletes the journal only
after verification. Any malformed journal, target mismatch, removal failure,
or verification failure exits before `NewApp` can start the queue watcher.

Standalone-to-Store gives Store precedence, launches the configured Partner
Center package family/AUMID, and lets the packaged target run the known
preserve-data uninstaller. Store-to-standalone is initiated by the installer’s
`--handoff-from-store` call: the running Store app accepts shutdown only when
the per-user journal is valid, then the standalone helper removes the current
user package. Interrupted phases are safe to retry.
