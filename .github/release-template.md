## go-mapi v3.0

Standalone Windows desktop app (replacing the Chrome/Edge extension) that intercepts "Send to Mail recipient" calls and routes them to Gmail as drafts. Powered by Wails v2 + Svelte 5 + WebView2 + a C++17 MAPI DLL.

### Installation

1. Download `go-mapi-setup.exe` from the assets below.
2. Run the installer as administrator. The installer requires admin elevation because it registers go-mapi as a machine-wide MAPI handler under `HKLM\SOFTWARE\Clients\Mail`.
3. First launch: sign in with your Google account. The first-run will open your default browser for OAuth consent.

### Upgrading from v2.x

> **Uninstall v2.x first.** Go to **Settings → Apps → Installed apps** and remove any prior go-mapi v2.x (the Chrome/Edge extension + native-host). Then install v3.0. go-mapi does not migrate v2 artifacts automatically; running both side-by-side is unsupported.

### System requirements

- Windows 10 (22H2) or Windows 11
- Microsoft Edge WebView2 Evergreen Runtime — auto-bootstrapped by the installer if missing
- Gmail or Google Workspace account

### Release artifacts

- `go-mapi-setup.exe` — single-file signed installer (~20 MB, includes WebView2 bootstrapper + MAPI DLL + Wails binary)

### License

LGPL-3.0 — see [LICENSE](https://github.com/marcfargas/go-mapi/blob/main/LICENSE) in the repository.

---

See the [README](https://github.com/marcfargas/go-mapi#readme) for usage details, privacy model, and uninstall instructions.
