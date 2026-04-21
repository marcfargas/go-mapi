# Phase 11: Autoupdate + Release - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-21
**Phase:** 11-autoupdate-release
**Areas discussed:** Update UX, Update Setting, Store Retirement, Smoke-Test Standard

---

## Update UX

| Option | Description | Selected |
|--------|-------------|----------|
| Persistent banner | Show a small persistent banner at the top until dismissed or updated | ✓ |
| Header-only indicator | Show a subtle badge/row in the signed-in header only | |
| Tray only | No in-window treatment; tray notification only | |

**Question:** When an update is available, what should happen in the main window?  
**User's choice:** Persistent banner  
**Notes:** Banner should be the durable in-window signal.

| Option | Description | Selected |
|--------|-------------|----------|
| Release page | Open the GitHub release page | |
| Direct installer URL | Open the stable installer asset directly | |
| In-app panel | Open an in-app “Update available” panel with both links | ✓ |

**Question:** What should the primary action open?  
**User's choice:** In-app panel  
**Notes:** Panel should expose both human-readable and direct-download paths.

| Option | Description | Selected |
|--------|-------------|----------|
| No helper | Do nothing else; user handles install manually | ✓ |
| Reminder | Show a reminder after click | |
| Quit/install helper | Offer a helper flow in this phase | |

**Question:** After the user clicks `Download`, what should the app do?  
**User's choice:** No helper  
**Notes:** Explicitly “until we have autoupdates”.

| Option | Description | Selected |
|--------|-------------|----------|
| Silent | Silent failure; no user-facing error | ✓ |
| Subtle hint | Log it and show a subtle status hint | |
| Explicit warning | Show a tray/UI warning | |

**Question:** If the update check fails, how noisy should it be?  
**User's choice:** Silent  
**Notes:** Logging is fine; user-facing failure noise is not wanted.

---

## Update Setting

| Option | Description | Selected |
|--------|-------------|----------|
| Header/menu | Signed-in header dropdown/menu | |
| Settings panel | Dedicated settings panel/view | |
| Tray menu | Tray context menu | ✓ |

**Question:** Where should the `Check for updates` toggle live?  
**User's choice:** Tray menu  
**Notes:** User explicitly prefers pragmatism for a single setting; settings panel can come later.

| Option | Description | Selected |
|--------|-------------|----------|
| Manual trigger | Add `Check for updates now` | ✓ |
| Auto only | Automatic background checks only | |
| Tray-only check | Only from tray, not main window | |

**Question:** Should the user be able to manually trigger a check?  
**User's choice:** Yes, manual trigger  
**Notes:** Manual check is in scope.

| Option | Description | Selected |
|--------|-------------|----------|
| Toggle only | No version/check metadata | |
| Toggle + last checked + current version | Show both metadata values | ✓ |
| Toggle + current version | Only current version | |

**Question:** What status should the UI show when updates are enabled?  
**User's choice:** Toggle plus `Last checked` / `Current version`

| Option | Description | Selected |
|--------|-------------|----------|
| Enabled | Default on | |
| Disabled | Default off | |
| Enabled + explicit callout | Default on, but make it explicit once | ✓ |

**Question:** On first run after install, should update checks default to?  
**User's choice:** Enabled with explicit callout

---

## Store Retirement

| Option | Description | Selected |
|--------|-------------|----------|
| Remove immediately | Unpublish/remove as soon as v3 is live | |
| Temporary notice then remove | Leave up briefly, then remove | |
| Published but frozen | Keep published with strong deprecation messaging | ✓ |

**Question:** What should happen to the browser store listings on v3.0 GA?  
**User's choice:** Published but frozen  
**Notes:** Strong deprecation messaging is required.

| Option | Description | Selected |
|--------|-------------|----------|
| Main README v3-only | Move v2 out of main docs | ✓ |
| Short retired section + legacy doc | Keep a short legacy pointer | |
| Both install paths in README | Keep both for a while | |

**Question:** How should the README handle v2.x after release?  
**User's choice:** Main README v3-only  
**Notes:** User explicitly does not want maintained legacy docs; git history is enough.

| Option | Description | Selected |
|--------|-------------|----------|
| Strong cutover | Uninstall v2, install v3, v2 is retired | ✓ |
| Softer migration | v3 recommended, v2 legacy | |
| Neutral | Present both | |

**Question:** How hard should the release notes push existing v2.x users?  
**User's choice:** Strong cutover

| Option | Description | Selected |
|--------|-------------|----------|
| Initiated is enough | Proof of submission/initiation is acceptable | ✓ |
| Must be gone | Listings must actually be gone | |
| Chrome only | Edge can trail | |

**Question:** If store unpublish takes time or manual review, what should count as acceptable for completion?  
**User's choice:** Initiated is enough  
**Notes:** Evidence matters more than store processing latency.

---

## Smoke-Test Standard

| Option | Description | Selected |
|--------|-------------|----------|
| Windows Sandbox | Sandbox on the dev machine | |
| Separate VM/machine | Fresh local VM or separate machine | |
| Either clean/reproducible environment | Any clean reproducible Windows environment | ✓ |

**Question:** What should be the preferred execution environment?  
**User's choice:** Either clean, reproducible environment

| Option | Description | Selected |
|--------|-------------|----------|
| Mostly automated with manual tail | Automate as much as practical | ✓ |
| Mostly manual | Manual is acceptable with checklist | |
| Fully automated only | Full automation required | |

**Question:** How much of the smoke test must be automated?  
**User's choice:** Automate as much as practical, allow a short manual tail

**Question:** What evidence should be required in the verification artifact?  
**User's choice:** Conditional rule  
**Notes:** Automated parts must include screenshots and videos. Manual parts require a checklist.

| Option | Description | Selected |
|--------|-------------|----------|
| Installer/update path | Release mechanics matter most | |
| Full clean-machine journey | The whole user journey working once matters most | ✓ |
| Update notification path | Update UX itself is the key proof | |

**Question:** If one part of the flow is still manual-only, which outcome matters most?  
**User's choice:** Full clean-machine journey

---

## the agent's Discretion

- Exact banner/panel copy and placement
- Exact tray-menu wording for update actions and status
- Exact form of the one-time update-enabled callout
- Exact artifact bundling structure for smoke verification

## Deferred Ideas

- Dedicated settings panel for update preferences
- Helper flows like `Quit and install`
- Maintained v2 legacy docs in the current tree
- Fully automated zero-manual-tail smoke verification
