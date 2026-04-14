# Phase 8: OAuth + Credentials - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-14
**Phase:** 08-oauth-credentials
**Areas discussed:** GCP verification strategy, Sign-in UX placement, Re-auth (invalid_grant) UX, Client credential embedding

---

## Gray Area Selection

| Option | Description | Selected |
|--------|-------------|----------|
| GCP verification strategy | How to handle Google's 4–6 week verification queue | ✓ |
| Sign-in UX placement | First-run flow and window treatment | ✓ |
| Re-auth (invalid_grant) UX | How insistent the re-auth signal is | ✓ |
| Client secret embedding | Binary embedding vs BYO-credentials | ✓ |

**User's choice:** All four.

---

## GCP Verification Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Ship unverified; 100-user test cap (Recommended) | File verification day 1; ship v3.0 with warning; verification lands during v3.x; no blocker | ✓ |
| Block v3.0 ship until verified | Hold release 4–6 weeks for Google queue | |
| Ship unverified + skip verification entirely | Accept 100-user cap permanently | |

**User's choice:** Ship unverified; 100-user test cap.

| Option | Description | Selected |
|--------|-------------|----------|
| In-app warning on first sign-in (Recommended) | One-time pre-auth modal explains Google's "unsafe" screen and click-path | ✓ |
| Leave Google's warning to speak for itself | No in-app explanation | |
| Document in README + installer only | No in-app, rely on docs | |

**User's choice:** In-app warning on first sign-in.

---

## Sign-In UX Placement

| Option | Description | Selected |
|--------|-------------|----------|
| Main window opens to welcome/sign-in screen (Recommended) | Installer launches app; window shows welcome + big Sign-in CTA; no queue visible until signed in | ✓ |
| Tray-only, queue visible with sign-in banner | App starts in tray; queue visible later with persistent banner | |
| Blocking modal over empty queue | Modal overlays empty queue | |

**User's choice:** Main window opens to welcome/sign-in screen.

| Option | Description | Selected |
|--------|-------------|----------|
| App stays in tray; watcher collects queue (Recommended) | Emails still captured locally; tray icon error variant; sign-in later | ✓ |
| App quits | Closing sign-in quits app; loses queued emails | |
| Watcher pauses until signed in | Emails pile up in %TEMP% but not shown | |

**User's choice:** App stays in tray; watcher collects queue.

---

## Re-Auth (invalid_grant) UX

| Option | Description | Selected |
|--------|-------------|----------|
| Tray icon → error; banner in main window; toast (Recommended) | Three concurrent signals; queue keeps collecting; actions disabled; never blocks user mid-action | ✓ |
| Blocking modal on next app focus | Modal blocks everything on next window focus | |
| Silent queue + tray icon only | Only tray icon flips; minimal but easily missed | |

**User's choice:** Tray icon → error; banner in main window; toast.

| Option | Description | Selected |
|--------|-------------|----------|
| Button disabled + tooltip 'Sign in first' (Recommended) | Draft-action buttons disabled unauthenticated; sign-in banner is the CTA | ✓ |
| Button enabled; click triggers sign-in, then retries | One-click path but mixes flows | |
| Button enabled; click fails with error toast | Loud fail; frustrating dead-click | |

**User's choice:** Button disabled + tooltip (captured as Phase 9 design contract).

---

## Client Credential Embedding

| Option | Description | Selected |
|--------|-------------|----------|
| Embed via build-time -ldflags; empty strings in source (Recommended) | Standard Go pattern; CI injects from GitHub secrets; source repo publishable | ✓ |
| Embed as string literals directly in source | Committed to repo; simplest but sloppy | |
| User brings their own GCP project | Privacy-max but breaks core value for non-technical users | |

**User's choice:** Embed via build-time -ldflags.

| Option | Description | Selected |
|--------|-------------|----------|
| Env vars at 'wails dev' time (Recommended) | Read GOMAPI_OAUTH_CLIENT_ID/_SECRET from env; Marc keeps gitignored .env.local | ✓ |
| Local config file (gitignored) | auth-dev.json at repo root | |
| Hardcoded test client for dev only | Second dev-only GCP client committed under build tag | |

**User's choice:** Env vars at 'wails dev' time.

---

*Logged: 2026-04-14*
