---
title: "Spanish (es) translation for the Wails UI and installer"
trigger_condition: "v3.1 milestone planning, or sooner if the first Spanish-speaking end-user pilot lands"
planted_date: 2026-04-24
---

## Idea

Ship a Spanish (`es`) translation alongside the existing English UI — covering the Svelte frontend (sign-in screen, queue view, settings, re-auth banner, toasts) and the NSIS installer strings (page titles, scope choice, finish-page toggles, uninstaller prompts). Detect the locale from Windows (`GetUserDefaultLocaleName` / `navigator.language` inside WebView2) and allow a manual override in settings.

## Why

go-mapi's primary audience is legacy-Windows desktop-app users — many of those apps (Spanish SendEmail-style clients and similar line-of-business tools) ship Spanish-only UIs, and the users running them typically do too. Right now every piece of UI they see — sign-in, Gmail permission explainer, queue actions, installer pages, toast notifications — is English. That is a comprehension barrier at the exact moments the user needs to trust the app (consent flow, install, privacy copy).

Spanish is the only second language worth doing first: matches Marc's own user base, matches the legacy-app ecosystem that motivates the whole project, and the copy volume is small enough to hand-translate without a full i18n platform.

## Breadcrumbs

- Frontend: no i18n framework currently — Svelte strings are hard-coded in components (`SignInScreen.svelte`, `PreAuthModal.svelte`, `ReAuthBanner.svelte`, `SignedInHeader.svelte`, `QueueRow.svelte`, toast copy). Options: (a) `svelte-i18n` or `@lingui/core` for a real message catalog, (b) simpler in-house `$derived` dictionary lookup keyed on a `lang` store. Lean towards (b) for a two-locale app — minimal dependency surface, matches the "privacy/minimal deps" posture.
- Backend: Go-side error strings and toast-summary fallbacks in `internal/mapi/` + `src/app/` — smaller surface, but the ones that bubble to the user (e.g. "Failed to create draft: ...") need the same treatment.
- Installer: NSIS has first-class i18n via `!insertmacro MUI_LANGUAGE "Spanish"` + per-language string tables in the `.nsi`. Zero new dependency, just per-page string pairs.
- Locale detection: `GetUserDefaultLocaleName` at Go startup → pass through to frontend via a Wails binding, persist user override in AppSettings (already has atomic-write via Phase 9 D-13).
- Translation source: Marc is native-level Spanish — hand-translate, no external service, no telemetry. Keep strings in version control as plain JSON/JS.

## When to surface

During v3.1 milestone planning. Pairs well with any UX-polish phase and benefits from being scoped after Phase 11 ships (string inventory is stable once autoupdate/release UI is locked). Estimated 2-3 plans: string extraction + i18n plumbing, Spanish catalogue + locale detection/override, installer NSIS language pack.

## Risk / constraints

- Keep the dependency footprint small — a heavy i18n framework for two locales is premature.
- Toast summary copy must stay short enough that the Spanish version still fits Windows' toast length constraints without truncating subject/sender.
- Translate privacy-sensitive copy (OAuth consent explainer, keyring/credential storage text) with extra care — misleading translation here is the worst class of bug for this project.
- Do not translate log messages (they stay English for grep/support purposes); user-visible UI only.
- Installer: Spanish string table must stay in sync with English on every installer-touching phase — add a CI check or at least a PR-review note.
