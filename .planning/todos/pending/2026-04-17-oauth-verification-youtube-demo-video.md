---
created: 2026-04-17T21:08:31.524Z
title: OAuth verification YouTube demo video
area: auth
files:
  - .planning/phases/08-oauth-credentials/08-01-PLAN.md
  - .planning/phases/08-oauth-credentials/08-05-PLAN.md
---

## Problem

Google's OAuth verification process (AUTH-06) requires a YouTube video demonstrating how the app uses every requested scope, and the video must include all OAuth clients assigned to the GCP project. Verbatim from the verification form:

> Provide a YouTube video demonstrating how you'll use the data from these scopes in your app. Your video must include all OAuth clients that you assigned to this project.

The rest of the GCP verification submission (Desktop OAuth client, consent screen, scope justifications, privacy policy, homepage) is already submitted as of 2026-04-17. The video is the remaining blocker on verification review.

Scopes to demo:
- `https://www.googleapis.com/auth/gmail.compose` — creating drafts from intercepted MAPI calls (core v3.0 flow)
- `https://www.googleapis.com/auth/gmail.send` — Auto-send path (post-v3.0, may need a minimal demo path if retaining this scope)
- `https://www.googleapis.com/auth/userinfo.email` — showing "Signed in as <email>" in the header
- `https://www.googleapis.com/auth/userinfo.profile` — showing the user's display name

Cannot record until the app has an end-to-end working flow: SignIn → loopback callback → token persisted → signed-in header shows email/name → MAPI trigger → draft appears in Gmail. That requires Plans 08-02 through 08-05 to be shipped at minimum.

## Solution

Earliest opportunity: after Plan 08-05 completes (welcome/sign-in screen, pre-auth modal, signed-in header, re-auth banner all wired to the real AuthManager). At that point the demo is:

1. Launch the app on a clean Windows VM — tray icon + welcome screen visible
2. Click "Sign in with Google" — pre-auth modal appears, then system browser opens to `accounts.google.com`
3. Complete consent — browser shows "You can close this tab", app header flips to "Signed in as <email>"
4. Trigger a MAPI send from Explorer ("Send to Mail recipient") — draft appears in Gmail web UI
5. (If keeping `gmail.send`) Toggle the appropriate mode and demo send — or narrate that the scope is pre-requested for the Auto-send feature slated for a future release
6. Click Sign out — header returns to welcome screen; Credential Manager entry cleared
7. Show each OAuth client_id from GCP Console → Credentials during the video (per Google's explicit requirement that all project clients must be shown)

Record on the same clean VM used for Phase 7 RAM measurement to keep the demo reproducible. Upload as an unlisted YouTube video, paste the URL back into GCP Console → OAuth consent screen → Prepare for verification.

If `gmail.send` is dropped per the earlier "concern" note (v3.0 doesn't ship Auto-send), remove the send demo step and resubmit scope justifications accordingly before recording.
