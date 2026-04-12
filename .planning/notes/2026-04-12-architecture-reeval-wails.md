---
title: "Architecture re-evaluation: extension → standalone Wails app"
date: 2026-04-12
context: explore session — strategic architecture pivot discussion
---

## Why

The current native-host + browser extension split was built on the assumption that extension updates are frictionless. That assumption is wrong:

- Chrome and Edge addon store reviews are slow and unpredictable
- No Firefox support possible with current architecture
- Extension sandbox limits what we can build (automode, composer, enterprise management)

## Decision Direction

Replace the browser extension with a standalone **Wails** (Go + WebView2) desktop app.

### What stays the same
- C++ MAPI interceptor DLL — unchanged
- Filesystem-based IPC (`%TEMP%\go-mapi\`) — unchanged
- Privacy-first model — unchanged
- Go as primary language — unchanged

### What changes
- UI moves from Chrome extension popup → system tray icon + native window
- Toast notifications for new emails in queue
- Automode: auto-draft or auto-send without user interaction
- OAuth moves from Chrome Identity API → Google desktop app OAuth flow (loopback redirect)
  - Reference: https://developers.google.com/identity/protocols/oauth2/native-app
- Opt-out autoupdate (Wails/WebView2 may have built-in support)
- Future: in-app composer for editing before send (prep for SMTP support)
- Future: enterprise control plane for managed deployments

### Why Wails over alternatives
- **vs Fyne/Gio:** Web UI layer lets us reuse JS/TS skills, especially for future composer
- **vs Tauri:** We already have Go buildchain; Wails is the Go-native equivalent
- **vs Electron:** WebView2 reuses Edge engine already in memory on Windows — critical for RDS

### Key constraint: RAM in RDS
Main deployment target includes RDS environments (30 users on shared server). Current go-mapi-host.exe is tiny. Wails/WebView2 must stay lightweight — 30x200Mb is unacceptable, 30x10-30Mb is the target. WebView2 shares the Edge runtime process, so per-instance overhead should be lower than Electron, but needs verification.

## Scope
This is a major architecture pivot — likely a new milestone (v3.0) after v2.1.0 changesets work lands.
