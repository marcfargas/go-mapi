---
phase: 01-foundation-signpath-application
plan: 06
subsystem: infra
tags: [powershell, native-messaging, manifest, installer, templates]

# Dependency graph
requires:
  - phase: 01-foundation-signpath-application
    provides: existing scripts/install.ps1 inline manifest construction (Step 4)
provides:
  - Canonical com.gomapi.host.chrome.json.tmpl with {{HOST_PATH}} and {{EXTENSION_ID}} placeholders
  - Canonical com.gomapi.host.edge.json.tmpl (byte-identical to chrome template)
  - Render-ManifestTemplate PowerShell helper using literal String.Replace() substitution
  - install.ps1 Step 4 branching Local (template-driven) vs Download (inline fallback) modes
affects:
  - 03-installer (INST-03 Inno Setup — will consume the same .tmpl via Pascal Script StringChange)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Double-brace placeholder template rendering via literal String.Replace()"
    - "Dual-path installer: file-backed template in Local mode, in-memory inline fallback in Download mode"

key-files:
  created:
    - src/native-host/manifests/com.gomapi.host.chrome.json.tmpl
    - src/native-host/manifests/com.gomapi.host.edge.json.tmpl
  modified:
    - scripts/install.ps1

key-decisions:
  - "Chose dual-path approach (Local reads .tmpl, Download uses inline hashtable) over always-inline; proves the template is consumable by at least one installer before Phase 3 Inno Setup picks it up"
  - "Use String.Replace() instead of regex -replace to avoid Windows path backslash escaping and double-brace regex metachar pitfalls"
  - "JSON-escape backslashes in HOST_PATH before substitution (same behavior ConvertTo-Json gives in the download-mode fallback); Phase 3 Inno Setup will need to do the same in Pascal Script"
  - "Hoisted \$scriptDir/\$repoRoot to script scope so Step 4 can reuse it without re-detecting"
  - "Kept the pre-existing resolved .json stub files (com.gomapi.host.chrome.json and com.gomapi.host.edge.json) as a safety net per phase special constraint 4"

patterns-established:
  - "Manifest template placeholder convention: {{HOST_PATH}}, {{EXTENSION_ID}}, double-brace, uppercase snake_case"
  - "Render helpers validate output by round-tripping through ConvertFrom-Json before writing to disk"

requirements-completed: [FOUND-06]

# Metrics
duration: 5min
completed: 2026-04-10
---

# Phase 1 Plan 06: Manifest Templates + install.ps1 Refactor Summary

**Native-messaging manifest templates with {{HOST_PATH}}/{{EXTENSION_ID}} placeholders and a PowerShell Render-ManifestTemplate helper that install.ps1 uses in Local mode; Phase 3 Inno Setup now has a canonical schema file to consume.**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-04-10T15:53:44Z
- **Completed:** 2026-04-10T15:58:23Z
- **Tasks:** 2/2
- **Files modified:** 3 (2 created, 1 modified)

## Accomplishments

- Created `com.gomapi.host.chrome.json.tmpl` and `com.gomapi.host.edge.json.tmpl` with `{{HOST_PATH}}` and `{{EXTENSION_ID}}` double-brace placeholders (byte-identical for future divergence if needed)
- Added `Render-ManifestTemplate` helper in `install.ps1` using literal `String.Replace()` (explicitly not regex `-replace`) plus JSON-escape of backslashes in the host path, with `ConvertFrom-Json` validation before returning
- Wired Step 4 (native messaging registration) to consume the template in `-Local` mode, keeping the existing inline hashtable path as the in-memory fallback for the `irm | iex` download flow
- Preserved the pre-existing resolved `.json` stub files so `-Local` installs never broke mid-refactor

## Task Commits

1. **Task 1: Create .tmpl files** — `67ede33` (feat)
2. **Task 2: Refactor install.ps1** — `1eec268` (refactor)

Plan metadata commit follows this SUMMARY creation.

## Files Created/Modified

- `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` — Canonical Chrome native-messaging manifest template with `{{HOST_PATH}}` and `{{EXTENSION_ID}}` placeholders. 9 lines, UTF-8 no BOM, `{` is byte 0
- `src/native-host/manifests/com.gomapi.host.edge.json.tmpl` — Byte-identical copy for Edge (separate file so Phase 3 Inno Setup can render one per target browser and allow future divergence)
- `scripts/install.ps1` — Added `Render-ManifestTemplate` helper (lines 134-194), hoisted `$scriptDir`/`$repoRoot` to script scope, refactored Step 4 to branch on `$Local` (template rendering vs inline fallback). +115/-12 lines

### Template content (both files, identical)

```
{
  "name": "com.gomapi.host",
  "description": "go-mapi Native Messaging Host",
  "path": "{{HOST_PATH}}",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://{{EXTENSION_ID}}/"
  ]
}
```

### `Render-ManifestTemplate` helper

```powershell
function Render-ManifestTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$ExtensionId
    )

    if ([string]::IsNullOrWhiteSpace($TemplatePath)) { throw "..." }
    if ([string]::IsNullOrWhiteSpace($InstallDir))    { throw "..." }
    if ([string]::IsNullOrWhiteSpace($ExtensionId))   { throw "..." }
    if (-not (Test-Path $TemplatePath))               { throw "..." }

    Write-Log "Rendering manifest template: $TemplatePath" "INFO"

    # Build placeholder tokens programmatically
    $openToken = '{' + '{'
    $closeToken = '}' + '}'
    $hostPathPlaceholder    = $openToken + 'HOST_PATH'    + $closeToken
    $extensionIdPlaceholder = $openToken + 'EXTENSION_ID' + $closeToken

    $hostExePath = (Join-Path $InstallDir "go-mapi-host.exe")

    # JSON-escape backslashes so the rendered document is valid JSON.
    $hostExePathJson = $hostExePath.Replace('\', '\\').Replace('"', '\"')

    $template = Get-Content -Raw -Path $TemplatePath

    # Literal String.Replace() — no regex, no backslash escape surprises.
    $rendered = $template.Replace($hostPathPlaceholder, $hostExePathJson).Replace($extensionIdPlaceholder, $ExtensionId)

    try {
        $null = $rendered | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Render-ManifestTemplate: rendered template is not valid JSON. ..."
    }

    return $rendered
}
```

## Decisions Made

- **Dual-path (Local reads .tmpl, Download inline)** — The plan's execution decision rule preferred the Local-mode-reads-template approach because it proves the template is consumable by at least one installer before Phase 3. Download-mode (`irm | iex`) cannot read repo files, so it keeps the inline hashtable with a comment pointing at the `.tmpl` as canonical schema.
- **JSON-escape HOST_PATH before substitution** — Windows install paths (`C:\Program Files\go-mapi\...`) contain backslashes that are invalid JSON escape sequences when emitted raw. This matches the behavior `ConvertTo-Json` already provides in the download-mode fallback, so the rendered manifest is byte-equivalent between both paths. Phase 3 Inno Setup will need to apply the same backslash-doubling in its Pascal Script.
- **String.Replace() over regex -replace** — Locked by the plan and CONTEXT.md. Double-brace tokens contain regex metacharacters (`{`/`}`), and regex substitution would also interpret backslashes in the substitution text. Literal string replacement has zero escaping surface.
- **Hoist `$scriptDir`/`$repoRoot` to script scope** — Step 4 Local branch needs `$repoRoot`, which was previously only defined inside the `if ($Local)` artifact acquisition block. Moving the two-line resolution up once is cleaner than re-detecting inside Step 4.
- **Kept both .tmpl files byte-identical** — Chrome and Edge accept the same native-messaging manifest schema today. Separate files give Phase 3 Inno Setup a clean per-browser rendering target and future-proof any divergence.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] JSON-escape backslashes in HOST_PATH before substitution**
- **Found during:** Task 2 (dry-run rendering with a realistic Windows install path)
- **Issue:** The plan specified literal `.Replace($hostPathPlaceholder, $hostExePath)` with no escaping. When the host path is `C:\Program Files\go-mapi\go-mapi-host.exe`, the rendered JSON contains `"path": "C:\Program Files\go-mapi\..."` — invalid JSON (unrecognized escape sequences), which the helper's `ConvertFrom-Json` validation correctly rejected. The inline hashtable fallback does not hit this bug because `ConvertTo-Json` already handles backslash escaping. Without the fix, Local-mode installs would throw every time.
- **Fix:** Before calling `.Replace()`, transform the host path with `$hostExePath.Replace('\', '\\').Replace('"', '\"')` to match JSON string-escape rules. Added a comment noting Phase 3 Inno Setup will need the equivalent transformation in Pascal Script.
- **Files modified:** scripts/install.ps1 (Render-ManifestTemplate body)
- **Verification:** Re-ran the dry-run — rendered manifest is valid JSON, round-trips through `ConvertFrom-Json` / `jq .` cleanly, and produces byte-equivalent output to the download-mode inline path for the same inputs.
- **Committed in:** 1eec268 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** The fix is essential for correctness — without it, Local mode would fail on every real install path. Phase 3 Inno Setup will need to mirror the escape logic, which is now documented in the helper comment. No scope creep.

## Issues Encountered

- Initial dry-run surfaced the HOST_PATH JSON-escape bug (see deviation above). Caught before commit thanks to the `ConvertFrom-Json` validation guard — the guard was in the plan, which paid for itself immediately.

## User Setup Required

None — no external services or dashboard configuration. Developers running `install.ps1 -Local` from a git checkout transparently use the new template path; the `irm | iex` one-liner path is unchanged.

## Verification Performed

1. `diff src/native-host/manifests/com.gomapi.host.chrome.json.tmpl src/native-host/manifests/com.gomapi.host.edge.json.tmpl` — empty (byte-identical)
2. `ls src/native-host/manifests/` — all four files present (2 stubs + 2 .tmpl)
3. `od -c` on chrome.json.tmpl — first byte is `{` (no BOM)
4. `sed '...' | jq .` — template produces valid JSON after placeholder substitution
5. `grep "function Render-ManifestTemplate" scripts/install.ps1` — 1 match
6. `grep "\.Replace(" scripts/install.ps1` — multiple matches (helper body + comments)
7. `grep "\.tmpl" scripts/install.ps1` — multiple matches (helper comment + Step 4 Local branch)
8. `grep "ConvertTo-Json -Depth 10" scripts/install.ps1` — 2 matches (download-mode fallback retained + install metadata write)
9. `grep "-replace.*HOST_PATH" scripts/install.ps1` — 0 matches (no regex used for placeholder substitution)
10. PowerShell parse check: `[System.Management.Automation.Language.Parser]::ParseInput(...)` — clean parse, no errors
11. End-to-end dry-run: invoked `Render-ManifestTemplate` with `InstallDir='C:\Program Files\go-mapi'` and `ExtensionId='abcdefghijklmnopqrstuvwxyz123456'`, wrote output to temp file, verified JSON fields match expected values
12. `jq .` on the dry-run output — valid JSON, all fields correct
13. `grep -c 'New-ItemProperty -Path $goMapiRegPath'` (2 matches) and `grep -c 'Set-ItemProperty -Path $browser.Path'` (1 match) — registry and browser loops untouched

## Next Phase Readiness

- `.tmpl` files exist and are consumable. Phase 3 Inno Setup installer (INST-03) can now read `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` via Pascal Script `StringChange` and render the same manifest shape without duplicating schema between PowerShell and Inno Setup.
- Phase 3 implementers: remember to backslash-double `HOST_PATH` before substitution (same as `Render-ManifestTemplate` does). Extension IDs are 32-char lowercase and need no escaping.
- No blockers for subsequent Phase 1 plans (01-07, 01-08) — this plan is self-contained and its only downstream consumer is Phase 3.

## Self-Check: PASSED

- Files created:
  - FOUND: src/native-host/manifests/com.gomapi.host.chrome.json.tmpl
  - FOUND: src/native-host/manifests/com.gomapi.host.edge.json.tmpl
- Files modified:
  - FOUND: scripts/install.ps1 (contains Render-ManifestTemplate function)
- Stub files preserved:
  - FOUND: src/native-host/manifests/com.gomapi.host.chrome.json
  - FOUND: src/native-host/manifests/com.gomapi.host.edge.json
- Commits:
  - FOUND: 67ede33 (Task 1: feat(01-06): add native-messaging manifest templates)
  - FOUND: 1eec268 (Task 2: refactor(01-06): render native-messaging manifest from .tmpl in Local mode)

---
*Phase: 01-foundation-signpath-application*
*Plan: 06*
*Completed: 2026-04-10*
