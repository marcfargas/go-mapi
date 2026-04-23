## go-mapi v3.0

A standalone Windows desktop app that routes legacy "Send to Mail recipient" calls to Gmail as drafts. Wails v2 + Svelte 5 + WebView2 + C++17 MAPI DLL.

### ⚠️ v2.x is retired

> **The v2.x Chrome/Edge extension + Go native-host is retired and receives no further updates.** Its store listings are frozen with deprecation messaging. If you are on v2.x:
>
> 1. **Uninstall v2.x first** via **Settings → Apps → Installed apps** — this removes both the browser extension and the native-host.
> 2. **Then install v3.0.** go-mapi does not migrate v2 artifacts, and running both side-by-side is unsupported.

### Install

1. Download `go-mapi-setup.exe` from the assets below, or use the stable URL:
   `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`
2. Run the installer as administrator. Admin elevation is required because the installer registers go-mapi as a machine-wide MAPI handler under `HKLM\SOFTWARE\Clients\Mail`.
3. First launch: sign in with your Google account — the app opens your default browser for OAuth consent.

### Updates are manual

go-mapi surfaces an in-app "update available" banner when a newer release is published, but does **not** replace its own binary. Clicking the banner opens this release page in your browser; you download and run the new installer yourself. Manual path is an explicit design decision, not a limitation.

### System requirements

- Windows 10 (22H2) or Windows 11
- Microsoft Edge WebView2 Evergreen Runtime — auto-bootstrapped by the installer if missing
- Gmail or Google Workspace account

### Release artifacts

- `go-mapi-setup.exe` — single-file installer (~7 MB, bundles WebView2 bootstrapper + MAPI DLL + Wails binary)

### License

LGPL-3.0 — see [LICENSE](https://github.com/marcfargas/go-mapi/blob/main/LICENSE).

---

Full docs: [README](https://github.com/marcfargas/go-mapi#readme). Privacy model, uninstall steps, and the v2.x → v3.0 cutover note live there.
