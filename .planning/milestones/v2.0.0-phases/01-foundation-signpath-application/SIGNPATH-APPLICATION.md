# SignPath Foundation OSS Application — go-mapi

**Status:** DRAFT — not yet filed
**Drafted by:** Claude (per `/gsd-execute-phase 1`, plan 01-07)
**Drafted on:** 2026-04-10
**Filing URL:** https://signpath.org/apply (Marc: please verify this is still the current URL for the SignPath Foundation OSS program before filing)

---

## How to use this document

This file contains the full text Marc will paste into the SignPath Foundation OSS application form. Sections 2 through 7 are written to be copy-pasted directly into form fields. Sections 1 and 8 are for Marc's own reference and should not be submitted.

Read the pre-filing checklist in Section 1 (repeated in Section 8) before opening the application form.

---

## Section 1 — Pre-filing checklist (for Marc, not for submission)

Before filing, confirm each item:

- [ ] Resolve the LGPL-3.0 vs GPL-3.0-only license discrepancy in the repository. Currently `package.json` declares `GPL-3.0-only` and `README.md` says "License TBD" with an "all rights reserved" fallback notice. The project's stated convention (per `CLAUDE.md` and this draft) is LGPL-3.0. Align all three before filing: update `package.json` to `LGPL-3.0-or-later`, update `README.md` to state LGPL-3.0, and add a `LICENSE` file at the repo root containing the full LGPL-3.0 text. This tech-debt item is tracked in `.planning/codebase/CONCERNS.md`.
- [ ] Decide: file now with a clearly marked "Chrome Web Store listing pending" note, or wait until the Chrome Web Store listing is published before filing. SignPath Foundation approval can take weeks, so filing early is recommended; waiting for the CWS listing risks delaying the signing-ready milestone.
- [ ] Confirm the GitHub repository `https://github.com/marcfargas/go-mapi` is public and the README accurately describes v2.0.0 scope.
- [ ] Verify the filing URL (https://signpath.org/apply) is still current. If SignPath has moved the OSS program to a different URL, use the current one.
- [ ] Verify that SignPath Foundation still accepts individual maintainers (as of the last public guidance, they do, but confirm before filing).
- [ ] Confirm no confidential material (employer names, client names, internal tooling references) appears in the submitted text. This draft was written with that constraint in mind; do a final read-through before pasting.

---

## Section 2 — Project identity (paste into the form's project info fields)

**Project name:** go-mapi

**Project homepage / repository URL:** https://github.com/marcfargas/go-mapi

**Primary contact:** Marc Fargas (GitHub: https://github.com/marcfargas)

**License:** LGPL-3.0-or-later. The repository's license metadata is currently being aligned with this declaration — the `LICENSE` file, `package.json`, and `README.md` will all state LGPL-3.0-or-later before the application is filed.

**Project description (one sentence):** go-mapi is a Free Software bridge that lets Windows users route the system "Send to Mail recipient" action to Gmail as drafts, replacing the Outlook requirement for legacy desktop applications.

---

## Section 3 — Why this project needs code signing (paste into the "purpose of signing" form field)

go-mapi ships a small set of Windows binaries: a MAPI handler DLL, a Go native messaging host executable, and an Inno Setup installer that copies both into place and registers them. Without an Authenticode signature, the installer triggers SmartScreen warning dialogs that require non-technical users to click through "More info" and "Run anyway" to complete a standard install. In practice, most non-technical users abandon the install at that dialog.

go-mapi's stated audience is non-technical Windows users who want their existing desktop applications to compose email through Gmail without installing Outlook. The SmartScreen friction is therefore a distribution blocker for the project's core use case, not a minor polish item. A SignPath Foundation signature would let go-mapi ship a signed installer, a signed native host, and a signed handler DLL so that end users see a trustworthy publisher identity and complete installation without clicking through security warnings. The project has no commercial budget for an EV code-signing certificate; SignPath Foundation's OSS program is the only realistic path to signed binaries for this project.

---

## Section 4 — What the binaries do (paste into the "project functionality" form field)

This section describes exactly what go-mapi does on the user's machine. It is written deliberately at a level of detail that lets SignPath reviewers evaluate the security posture without needing to read source code, though all source is public and auditable at https://github.com/marcfargas/go-mapi.

**What it does.** go-mapi registers itself as a Mail client handler under the registry key `HKLM\SOFTWARE\Clients\Mail\go-mapi`. This is the standard Windows registration that any Mail client — Outlook, Thunderbird, Mailbird, Windows Mail — uses to register as an available recipient for the "Send to Mail recipient" shell action and as a possible default Mail client. When a Win32 application invokes the Simple MAPI functions `MAPISendMail` or `MAPISendMailW` exported by the system `mapi32.dll`, Windows routes the call to the registered handler. This is the standard documented Windows extensibility mechanism for Mail clients, described in the Windows Platform SDK. go-mapi's handler DLL receives the MAPI call, serializes the message to a local JSON file under `%TEMP%\go-mapi\`, and a small Go-language native messaging host process forwards the message to a Chrome or Edge browser extension. The extension presents the message to the user as a Gmail draft preview. No email is ever sent automatically — the user must explicitly click "Save as Draft" in the go-mapi popup, which creates a draft in the user's Gmail account via the Gmail API. The user must then open Gmail and explicitly click Send if they want the message to leave their account.

**Installation and user consent.** Installation is performed by an Inno Setup installer that requires a single UAC elevation prompt. During installation, the user is informed that go-mapi will become the default Mail client handler on their machine, and the installer backs up the identity of the previous default Mail client (if any) so that uninstall can restore it. There is no silent installation path exposed to end users, no background service, no auto-start entry, no scheduled task, and no mechanism by which go-mapi can be installed without explicit user action. Uninstall removes all registry entries, all files under the install directory, all native-messaging manifest entries for the five supported Chromium-family browsers, and restores the previous default Mail client from the backup file written at install time.

**Privacy posture.** go-mapi is privacy-first by design:
(a) no telemetry of any kind,
(b) no long-term storage of message content — messages handed to go-mapi are written as transient JSON files under `%TEMP%\go-mapi\` and deleted immediately after the user clicks "Save as Draft" or "Delete",
(c) no network calls except to the Gmail API on behalf of the signed-in user for draft creation,
(d) no logging of message content (only metadata like message IDs truncated to 8 hex characters appears in logs),
(e) no crash reporting,
(f) no update-check beacons.
The privacy posture is documented in the public `CLAUDE.md` file in the repository and is a hard project constraint, not a preference.

**Scope limitation.** go-mapi only creates Gmail drafts. It does not send email directly, does not support SMTP, does not support POP3 or IMAP, and does not support any email provider other than Gmail. This is an explicit scope decision: sending is always mediated by the Gmail web UI so the user has a final review of every message before it leaves their account. The project has no roadmap plans to add direct-send capability.

---

## Section 5 — MAPI handler registration is standard Windows extensibility (paste into the form if there is a "security considerations" or "additional details" field)

This section addresses a predictable concern a security reviewer may raise when reading the phrase "MAPI handler" in a signing request. It is included so the reviewer does not have to reconstruct it from source.

go-mapi is the standard Mail client registration mechanism that Outlook, Thunderbird, Windows Mail, and every other Mail client on Windows uses. go-mapi is not hooking, patching, or attaching to other processes. go-mapi registers itself as a Mail client handler, identically to how any other Mail client registers. The user chooses to make go-mapi their default Mail client during the installer's UAC-elevated install step; Windows then routes Simple MAPI calls to it per the standard documented extensibility model for Mail clients.

Specifically:

- There is no DLL injection into other processes.
- There is no API hooking or detouring.
- There is no process attachment, memory reading, or memory patching.
- There is no kernel driver.
- go-mapi's DLL is loaded only by processes that explicitly call `mapi32.dll`'s Simple MAPI entry points and Windows routes the call to the registered handler — the same path Outlook takes when it is the default Mail client.
- The handler is registered by standard HKLM registry writes under `HKLM\SOFTWARE\Clients\Mail\go-mapi`, authored by the Inno Setup installer during a UAC-elevated install.

go-mapi is a legitimate Mail client registration, authorized by explicit user consent at install time, that happens to forward messages to a web email service (Gmail) instead of sending them via SMTP directly. It is architecturally identical to a lightweight Mail client — the only difference is that composition is finished in the browser rather than in a native GUI.

---

## Section 6 — Source code and build reproducibility (paste into the form's "source and build" field)

- **Repository:** https://github.com/marcfargas/go-mapi
- **License:** LGPL-3.0-or-later (see pre-filing checklist — the repo's license metadata is being aligned to this declaration before filing)
- **Issue tracker:** https://github.com/marcfargas/go-mapi/issues
- **Build system:**
  - Go 1.21 for the native messaging host (`src/native-host/`, built with `go build`)
  - MinGW (gcc/g++ C++17) + CMake 3.16+ for the MAPI handler DLL (`src/interceptor/`)
  - TypeScript 5.3 + Vite 5 for the browser extension (`src/extension/`)
  - Inno Setup 6 for the Windows installer (arriving in Phase 3 of the v2.0.0 roadmap)
- **Continuous integration:** GitHub Actions with public build logs. CI builds the DLL via MinGW + CMake, the Go native host, and the Vite extension bundle, and runs the Go test suite. For v2.0.0 the CI pipeline will gain a SignPath signing step before the installer build and a second signing step for the installer itself.
- **Source language mix:** Go (native host), C++17 (interceptor DLL), TypeScript (extension UI), PowerShell and Pascal Script (install glue).
- **Reproducibility:** The project follows reproducible build practices where the toolchain permits. Release builds strip symbols via `-s -w` (Go) and `-O2` with stripped symbols (C++).
- **Version embedding:** The version string is embedded at build time via Go `-ldflags "-X main.Version=..."` and CMake-injected define macros. No runtime version detection.

---

## Section 7 — Links (paste into the form's "links" field)

- Repository: https://github.com/marcfargas/go-mapi
- Maintainer GitHub profile: https://github.com/marcfargas
- Issue tracker: https://github.com/marcfargas/go-mapi/issues
- License text (in repository): https://github.com/marcfargas/go-mapi/blob/main/LICENSE — **Marc: confirm this file exists and contains the full LGPL-3.0 text before filing. The pre-filing checklist in Section 1 / Section 8 covers this.**
- Project README: https://github.com/marcfargas/go-mapi/blob/main/README.md
- Project privacy and scope documentation: https://github.com/marcfargas/go-mapi/blob/main/CLAUDE.md
- Chrome Web Store listing: **PLACEHOLDER — TODO before filing.** The Chrome Web Store listing does not exist yet at draft time. Marc must decide one of two options before submitting the application:
  1. File now with the note "Chrome Web Store listing pending publication" in place of the URL, accepting that the reviewer may ask for the listing before approving.
  2. Wait until the Chrome Web Store listing is live and then fill in the real URL here before filing.
  Do NOT submit this document with the literal string "PLACEHOLDER" still present in this field.

---

## Section 8 — Pre-filing checklist (final reminder before submission)

This is the same checklist as Section 1, repeated at the end so it cannot be missed:

- [ ] Resolve the LGPL-3.0 vs GPL-3.0-only license discrepancy. Update `package.json` to `LGPL-3.0-or-later`, update `README.md` to state LGPL-3.0, and add a `LICENSE` file at the repo root containing the full LGPL-3.0 text. (Tracked in `.planning/codebase/CONCERNS.md`.)
- [ ] Decide: file now with a "Chrome Web Store listing pending" note, or wait until the Chrome Web Store listing is published.
- [ ] Confirm the GitHub repository is public and the README is up to date.
- [ ] Verify the filing URL (https://signpath.org/apply) is still current; if SignPath has moved the OSS program, use the new URL.
- [ ] Verify that SignPath Foundation still accepts individual maintainers.
- [ ] Final read-through: confirm no employer names, client names, internal tooling references, or other confidential material have crept into the text to be submitted.
- [ ] Replace the Chrome Web Store URL placeholder in Section 7 with either the real URL or the "listing pending" note before submitting.
- [ ] Confirm all sections 2-7 have been copied into the correct SignPath form fields and nothing from sections 1 or 8 has been copied into the submission.

---

*End of draft.*
