# Phase 8: OAuth + Credentials - Context

**Gathered:** 2026-04-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver Google OAuth desktop sign-in (loopback + PKCE S256), refresh-token storage in Windows Credential Manager via `99designs/keyring`, transparent access-token refresh, clear re-auth UX on `invalid_grant`, and a sign-out control in the main window. Covers requirements: AUTH-01, AUTH-02, AUTH-03, AUTH-04, AUTH-05, AUTH-06, AUTH-07, QUAL-03.

**Out of scope for Phase 8:** draft creation UI and per-email action buttons (Phase 9), Gmail API call path beyond what's needed to prove the token works (the sanity check is that a refresh + userinfo fetch succeed — no draft persistence yet), installer wiring (Phase 10).

</domain>

<decisions>
## Implementation Decisions

### GCP Verification Strategy
- **D-01:** Ship v3.0 unverified with Google's 100-test-user cap. File OAuth verification (sensitive scopes: `gmail.compose`, `gmail.send`) on **Phase 8 day 1** — parallel path, do not block release on Google's queue. Verification lands during v3.x; users hit "This app isn't verified" warning until then, acceptable for FOSS solo-maintained tool.
- **D-02:** Before launching the browser on first sign-in, show a one-time **in-app pre-auth modal** explaining the Google warning verbatim: *"Google will show a warning that go-mapi isn't verified. Click **Advanced** → **Go to go-mapi (unsafe)** to continue."* Screenshot/illustration preferred. Dismissible with "Continue to Google" CTA. Stored as seen in settings so it doesn't re-show after first successful sign-in.

### Sign-In UX Placement
- **D-03:** First-run experience: installer launches the app; **main window opens automatically to a welcome/sign-in screen**. No queue list visible until signed in. Single prominent "Sign in with Google" button; brief copy explaining what go-mapi does with the account. Matches Slack/Notion/Zoom first-run pattern.
- **D-04:** If user closes the sign-in window without signing in, the **app stays running in the tray**. Watcher keeps collecting queued emails (they're local JSON files regardless). Tray icon shows the **error variant** from Phase 7 (D-11: error covers "auth needed"). User can open window later and sign in; draft actions are disabled until then.

### Re-Auth (`invalid_grant`) UX
- **D-05:** When refresh fails (`invalid_grant`, revoked token, network-independent failure), surface through **three concurrent signals**: (a) tray icon flips to error variant, (b) if main window is open, a red banner appears at the top with copy *"Sign-in expired — click to restore"* and a CTA button that opens the browser for re-auth, (c) Windows toast (WinRT — Phase 9 toast infrastructure lands then, but Phase 8 can ship a stub/basic toast via `golang.org/x/sys/windows` if trivial, otherwise defer to Phase 9 and rely on banner+icon only for Phase 8). **Never interrupt the user with a blocking modal.** Queue keeps collecting.
- **D-06:** Re-auth flow on click: same loopback + PKCE path as first-run, but skip the pre-auth explainer modal (D-02) since the user has already seen it. Success dismisses banner, restores tray icon, resumes transparently.

### Draft-Action Button State (design contract for Phase 9)
- **D-07:** **Design contract for Phase 9:** when no valid token is available (initial state or post-`invalid_grant`), per-email "Create draft" buttons are **disabled with tooltip "Sign in first"**. The sign-in banner/screen is the only CTA. Rationale: unambiguous — users can never queue an action that fails because of auth. Phase 8 implements the `GetAuthStatus()` binding that Phase 9 will use to toggle button state.

### Client Credential Embedding
- **D-08:** OAuth `client_id` and `client_secret` are **embedded in the binary via build-time `-ldflags` injection**. Source tree contains empty string constants (e.g., `var oauthClientID = ""` in `auth.go`). CI injects real values from GitHub secrets: `GOMAPI_OAUTH_CLIENT_ID`, `GOMAPI_OAUTH_CLIENT_SECRET`. Standard Go build pattern, matches v2.1 changesets CI posture. Rotation is a GCP operation + next release — acceptable. Source repo stays publishable without leaked credentials.
- **D-09:** Local dev sources credentials from **env vars at `wails dev` time**: `GOMAPI_OAUTH_CLIENT_ID` and `GOMAPI_OAUTH_CLIENT_SECRET` read in an init path (or build tag) that falls back to the `-ldflags`-injected values in release. Marc keeps values in a gitignored `.env.local` (or equivalent). No hardcoded dev client committed to the repo.
- **D-10:** Missing credentials at runtime (empty client_id after init) is a **fatal startup error** with a clear log message ("OAuth client credentials missing — build was not wired correctly"), not a silent partial-function state. Rationale: prevents shipping a release that silently can't sign anyone in.

### Keyring + Storage
- **D-11:** Keyring service name: `go-mapi`; key: `oauth-tokens`. Stored payload: JSON blob with `access_token`, `refresh_token`, `expiry` (RFC3339), `token_type`. Structure matches research ARCHITECTURE.md §5. Single entry — no per-account separation (multi-account is out of scope per PROJECT.md).
- **D-12:** Keyring fallback: if `99designs/keyring` cannot open the Windows Credential Manager backend (permissions, locked credential store, etc.), **fail hard at sign-in time** with a clear error surfaced via the welcome screen / re-auth banner. Do NOT fall back to encrypted file — research explicitly rejects this (ARCH.md Anti-Pattern 4). Sign-out when no keyring entry exists is a no-op.

### Token Refresh
- **D-13:** Refresh is **proactive + reactive**: before each Gmail API call the App struct checks `tokens.Expiry.Before(time.Now().Add(5 * time.Minute))` and refreshes ahead of time; on an unexpected 401 from Gmail, refresh + retry once. Matches research ARCHITECTURE.md §5 exactly. Refresh is serialized via a mutex on the App struct's auth manager to prevent thundering-herd refresh if multiple calls race.
- **D-14:** `GmailClient` stays **stateless**: receives token per call, does not hold state, does not initiate refresh. All refresh orchestration lives in the App struct's auth layer (`auth.go`). Preserves v2 architecture separation.

### Sign-Out
- **D-15:** Sign-out control lives in the **main window** (not tray menu). Placement: top-right header area near the account display. Clicking sign-out: (a) best-effort `POST https://oauth2.googleapis.com/revoke` with the refresh token, (b) clear the keyring entry unconditionally (even if revoke fails), (c) emit `auth-changed` with `{authenticated: false}`, (d) return main window to the welcome/sign-in screen. No confirmation modal — reversible (user can sign in again) and Slack/Discord precedent.
- **D-16:** Signing out does **not** quit the app. Watcher keeps running; tray stays. Matches D-04 closure behavior.

### Account Display (userinfo)
- **D-17:** After successful sign-in, fetch `https://www.googleapis.com/oauth2/v3/userinfo` with the access token; cache `email` and `name` **in memory only** (App struct field). Displayed in main window header as *"Signed in as marc@example.com"*. Not persisted to disk — re-fetched on every app start. QUAL-03 (privacy) honored.

### File Layout
- **D-18:** `auth.go` lives in **`src/app/`** (not `internal/mapi/`). Rationale: OAuth is app-specific (native-host is retiring), not shared core logic. Research ARCHITECTURE.md §81 confirms this placement. Uses `internal/mapi/` types only for the MailMessage boundary.
- **D-19:** New Wails-exposed bindings (methods on App struct) that Phase 9 will consume: `GetAuthStatus() AuthStatus` (returns `{authenticated, email, name}`), `SignIn() error` (initiates loopback flow, blocks until consent + token exchange complete), `SignOut() error` (revoke + clear). Events emitted: `auth-changed` with the same `AuthStatus` payload.

### Claude's Discretion
- Exact UI copy for welcome screen, pre-auth modal, re-auth banner, sign-out button — planner/UI-spec decide final text (Spanish/English per project convention — English UI for FOSS project).
- Loopback listener timeout (research suggests 2–5 min; planner picks). Cancel button in welcome screen stops listener + returns to sign-in screen.
- Specific URL opener on Windows: `exec.Command("rundll32", "url.dll,FileProtocolHandler", authURL)` vs `ShellExecuteW` — research mentions both; planner picks whichever is cleanest with Go stdlib.
- Pre-auth explainer modal visual treatment (plain modal vs screenshot-embedded).
- Token refresh mutex placement (package-level vs per-App-instance) — App struct is per-process so per-instance is fine.
- Logging level for OAuth events (success/failure/refresh) — align with Phase 7 `%APPDATA%\go-mapi\app.log` convention; never log token contents.
- Stub/basic toast for re-auth (D-05c) — implement trivially in Phase 8 if `golang.org/x/sys/windows` `ToastAPI` is a few lines, otherwise punt to Phase 9 and accept banner+icon-only for Phase 8.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project-level specs
- `.planning/PROJECT.md` — v3.0 milestone scope, privacy baseline, OUT-OF-SCOPE exclusions (multi-account, SMTP)
- `.planning/REQUIREMENTS.md` §OAuth & Credentials — AUTH-01..07 acceptance criteria; §Quality Gates QUAL-03
- `.planning/ROADMAP.md` §Phase 8 — goal statement and 5 success criteria

### Research (patterns locked here)
- `.planning/research/SUMMARY.md` — executive summary, scope-verification timing
- `.planning/research/ARCHITECTURE.md` §5 OAuth Token Storage and Refresh (full algorithm) — **primary reference**
- `.planning/research/ARCHITECTURE.md` §App struct & bindings layout (auth.go placement, field structure)
- `.planning/research/ARCHITECTURE.md` Anti-Pattern 4 (no file-based token storage)
- `.planning/research/FEATURES.md` §4 Desktop OAuth Flow — RFC 8252 requirements, PKCE S256, loopback pattern, keyring rationale, signed-in-as pattern
- `.planning/research/PITFALLS.md` — relevant auth-related pitfalls (planner to scan for OAuth-tagged items)

### Upstream phase context (decisions carry forward)
- `.planning/phases/07-wails-shell-ram-gate/07-CONTEXT.md` — App struct shape, `internal/mapi/` extraction, tray error-icon variant (D-11), logging conventions
- `.planning/phases/07-wails-shell-ram-gate/07-VERIFICATION.md` — RAM gate PASS; Phase 8 may proceed

### Codebase (existing patterns to preserve)
- `.planning/codebase/CONVENTIONS.md` — Go naming, error wrapping with `%w`, lowercase error strings, mutex/done-channel pattern
- `.planning/codebase/STACK.md` — toolchain baseline
- `src/native-host/gmail.go` — current stateless GmailClient shape (preserve the pattern when auth.go wraps calls)

### External specs (Google)
- `https://developers.google.com/identity/protocols/oauth2/native-app` — loopback flow for desktop apps (authoritative)
- `https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration` — confirms loopback stays supported
- `https://github.com/99designs/keyring` — library docs, Windows Credential Manager backend
- RFC 8252 — OAuth 2.0 for Native Apps (forbids embedded webviews, mandates loopback or custom URI schemes)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `src/native-host/gmail.go` — stateless `GmailClient`. Phase 8 wraps it with the App struct's auth layer; do NOT fold refresh logic into the client itself.
- `src/app/` workspace — created in Phase 7; `auth.go` is a new file inside this workspace.
- `internal/mapi/` — Phase 7 extraction target; auth.go does not live here (app-specific). Imports `MailMessage` types only if needed for response shapes.

### Established Patterns
- Build-time version injection via `-ldflags "-X main.Version=..."` already wired in v2.x — same mechanism carries the OAuth client credentials.
- `sync.RWMutex` + `chan struct{}` done-signal for graceful goroutine shutdown — apply to the loopback listener's context/cancel.
- Error wrapping with `%w`; lowercase error strings — preserve.
- Logging via timestamped RFC3339 + `[INFO]`/`[ERROR]` prefix — new lines go to `%APPDATA%\go-mapi\app.log` (Phase 7 D-choice). Never log token contents.

### Integration Points
- **Wails `OnStartup`**: call `authManager.LoadFromKeyring()`; if tokens present and non-expired (or refreshable), emit `auth-changed {authenticated: true, ...userinfo}`; else emit `{authenticated: false}`. Welcome screen / main queue reacts.
- **App struct bindings exposed to frontend**: `GetAuthStatus()`, `SignIn()`, `SignOut()`.
- **Events emitted**: `auth-changed` (payload: `AuthStatus`).
- **Gmail API call path (future, Phase 9)**: `App.makeAuthenticatedGmailCall(ctx, fn)` helper that (a) ensures fresh token via refresh-if-near-expiry, (b) invokes `fn(token)` which calls `GmailClient`, (c) on 401 retries once after forced refresh, (d) on `invalid_grant` emits `auth-changed {authenticated:false}` and surfaces to UI.

</code_context>

<specifics>
## Specific Ideas

- **Verification filed day 1:** Marc files GCP verification paperwork on Phase 8 kickoff — privacy policy URL, app homepage, demo video, scope justifications. Running in parallel with Phase 8 implementation; landing date non-blocking.
- **Pre-auth explainer modal content** should include the exact Google warning wording users will see ("Google hasn't verified this app") and the click-path: *Advanced → Go to go-mapi (unsafe)*. Screenshot preferred over prose.
- **"Signed in as" display copy:** `marc@example.com` (email primary, name secondary/tooltip if space-tight).
- **Tray icon states (from Phase 7 D-11):** idle / error. Phase 8 drives the transitions: `error` = unauthenticated OR `invalid_grant`; `idle` = authenticated and token valid. Has-queue variant still deferred to Phase 9.
- **Sign-out revoke is best-effort:** the `POST /revoke` call has a 5s timeout; keyring clear + UI update happen regardless. Log revoke failures but don't surface them to user.

</specifics>

<deferred>
## Deferred Ideas

- **WinRT toast infrastructure** for rich notifications — Phase 9 (toast work + AppUserModelID registration). Phase 8 may ship a basic stub toast if trivial; otherwise banner + tray icon are sufficient signaling.
- **Per-email draft-action buttons** — Phase 9. Phase 8 only provides the `GetAuthStatus()` binding and the design contract (D-07) that Phase 9 uses to toggle button state.
- **Multi-account / account switcher** — deferred to a future milestone per PROJECT.md Out of Scope.
- **Per-action mode (Auto-draft / Auto-send / Manual)** — Phase 9. Phase 8 only enables auth; action modes are separate.
- **Pause-watching tray menu item** — Phase 9 (SHELL-02 completion per Phase 7 D-10 note).
- **Installer + credential injection verification in CI build** — Phase 10 wires the GitHub-secrets → `-ldflags` plumbing into the signed installer pipeline. Phase 8 establishes the source-tree pattern and proves it works in local `wails build`.
- **Explicit scope-incremental consent / account chooser hint** — not needed now; both scopes requested at initial consent per research FEATURES.md §4.

</deferred>

---

*Phase: 08-oauth-credentials*
*Context gathered: 2026-04-14*
