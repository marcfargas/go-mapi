# Phase 11 release + store-retirement evidence

**Status:** PENDING — scaffolding for the GA v3.0.0 release cut. Fill the `TBD` fields during Task 2 (store proof) and Task 3 (GA release) of plan 11-04.

## Alignment note (REL-01 / D-09 / D-12)

REL-01 (retire the Chrome/Edge extension) is implemented as **frozen, deprecated browser-store listings** plus captured proof of the retirement action. This matches D-09 (keep listings published but frozen with strong deprecation messaging) and D-12 (proof of initiated retirement/deprecation action is sufficient for closure).

No store takedown or app removal is required — both listings remain discoverable so existing v2.x users can find the deprecation notice pointing them at v3.0.

## Stable installer URL

`https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`

This URL must always resolve to the newest published GitHub Release asset named `go-mapi-setup.exe`. Post-release verification below includes a `curl -I -L` check to confirm the redirect chain.

## Pre-release checklist

Run these on the `develop` branch, in order, before creating the release tag:

- [ ] `src/app/wails.json` → `info.productVersion` matches the tag we intend to push (e.g., `3.0.0` for tag `v3.0.0`).
- [ ] `README.md` is fully v3-only; no "Planned | Phase N" entries remain.
- [ ] `.github/release-template.md` contains strong cutover language (uninstall v2, install v3, v2 retired, manual update path).
- [ ] `11-SMOKE-EVIDENCE.md` records a passing clean-machine journey on a fresh rc (Phase 11-05 closure gate).
- [ ] Chrome Web Store listing updated with deprecation messaging (Task 2 below).
- [ ] Edge Add-ons listing updated with deprecation messaging (Task 2 below).
- [ ] `screenshot`/form-submission proof of both store actions captured under this file's "Store-retirement proof" section.
- [ ] Local `git status` clean on `develop`; all Phase 11 plan summaries committed.

## Post-release verification checklist

After the GA tag is pushed and `installer-release.yml` completes, verify:

- [ ] GitHub Release for the tag exists with `go-mapi-setup.exe` attached.
- [ ] `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` returns 302/redirect to the new asset (not the prior one).
- [ ] Installer SHA256 matches the value the workflow printed.
- [ ] If unsigned (SignPath fallback in play): note the fact in "GA release proof" below and link to the SignPath submission tracking record.

## Store-retirement proof (Task 2)

### Chrome Web Store

- **Listing URL:** TBD — paste the public listing URL once deprecation copy is live.
- **Screenshot filename:** `chrome-webstore-deprecation.png` (stored under `tests/sandbox/phase11/evidence-*/screenshots/` or similar gitignored path; this file records the filename only).
- **Submission evidence:** TBD — paste the Chrome Developer Dashboard screenshot showing the updated description and/or the "frozen" / "Unpublished — available to existing users" state toggle.
- **Deprecation copy (short summary of what the listing now says):** TBD — e.g., "go-mapi v2.x is retired. Install the v3.0 desktop app from {URL}. This extension no longer receives updates."
- **Action date (ISO):** TBD

### Edge Add-ons

- **Listing URL:** TBD — paste the public listing URL once deprecation copy is live.
- **Screenshot filename:** `edge-addons-deprecation.png`.
- **Submission evidence:** TBD — paste the Partner Center screenshot showing the updated description and/or the frozen/unpublished state.
- **Deprecation copy:** TBD — same strong cutover message as Chrome.
- **Action date (ISO):** TBD

## GA release proof (Task 3)

Populated after the release tag is pushed and the workflow finishes.

- **Tag:** TBD — e.g., `v3.0.0`
- **GitHub Release URL:** TBD
- **Workflow run URL (`.github/workflows/installer-release.yml`):** TBD
- **Workflow outcome:** TBD — pass/fail + run duration
- **`go-mapi-setup.exe` SHA256:** TBD
- **Stable URL resolves to new asset:** TBD — paste the `curl -I -L https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe` final `200` hop
- **SignPath / code-signing note:** TBD — if the release shipped unsigned, note the SmartScreen guidance link in the release body and link to the SignPath submission for the next version.

## Decisions honored

- D-09 Chrome Web Store + Edge Add-ons listings remain published but frozen, with strong deprecation messaging.
- D-10 README is fully v3-only; no maintained legacy doc tree.
- D-11 Release notes use strong cutover language (uninstall v2, install v3, v2 retired).
- D-12 Proof of initiated retirement/deprecation action (screenshots / submitted forms) is sufficient for REL-01 closure.

## Out-of-scope for this phase

- Automated browser-store API updates (Chrome Web Store / Edge Add-ons do not expose a stable API for listing copy; human dashboard edit is the canonical path).
- Post-GA telemetry on v2.x uninstall rate (no telemetry in either version; tracking would violate the project's privacy baseline).
