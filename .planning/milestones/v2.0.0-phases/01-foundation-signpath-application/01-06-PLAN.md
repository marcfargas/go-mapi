---
phase: 01-foundation-signpath-application
plan: 06
type: execute
wave: 1
depends_on: []
files_modified:
  - src/native-host/manifests/com.gomapi.host.chrome.json.tmpl
  - src/native-host/manifests/com.gomapi.host.edge.json.tmpl
  - scripts/install.ps1
autonomous: true
requirements: [FOUND-06]

must_haves:
  truths:
    - "Two .tmpl files exist in src/native-host/manifests/ with HOST_PATH and EXTENSION_ID double-brace placeholders"
    - "scripts/install.ps1 references the .tmpl files and, in Local mode, renders one of them via PowerShell string .Replace() (not regex -replace, to avoid Windows path backslash escaping issues)"
    - "The pre-existing resolved manifest .json files are kept in place so installs do not break mid-refactor"
    - "A future Phase 3 Inno Setup installer can consume the same .tmpl files via StringChange without duplicating placeholder conventions"
  artifacts:
    - path: "src/native-host/manifests/com.gomapi.host.chrome.json.tmpl"
      provides: "Chrome native messaging manifest template with placeholders"
      contains: "HOST_PATH"
    - path: "src/native-host/manifests/com.gomapi.host.edge.json.tmpl"
      provides: "Edge native messaging manifest template with placeholders"
      contains: "HOST_PATH"
    - path: "scripts/install.ps1"
      provides: "Installer that reads templates and substitutes placeholders via .Replace() string method"
      contains: ".tmpl"
  key_links:
    - from: "scripts/install.ps1 Step 4"
      to: "src/native-host/manifests/com.gomapi.host.chrome.json.tmpl"
      via: "Get-Content -Raw + .Replace() string substitution"
      pattern: "\\.tmpl"
---

<objective>
Convert the resolved Chrome and Edge native-messaging manifests in `src/native-host/manifests/` into `.tmpl` template files with double-brace placeholders (HOST_PATH and EXTENSION_ID), and refactor `scripts/install.ps1` to read the templates, substitute via the PowerShell `.Replace()` string method, and write the resolved manifest to the install directory. Keep the existing resolved `.json` files in place so installs do not break mid-refactor.

Purpose: Unblocks INST-03 in Phase 3. The Inno Setup installer consumes the same `.tmpl` files via Pascal Script `StringChange`, so there is a single source of truth for the manifest shape and no drift between the PowerShell and Inno Setup installers.
Output: Two `.tmpl` files, an updated `install.ps1` that consumes them, and the existing `.json` files retained as a safety net.
</objective>

<execution_context>
This plan implements FOUND-06 from REQUIREMENTS.md. Decisions are locked in `01-CONTEXT.md` section `### FOUND-06 (manifest templates)` and phase special constraint 4:
- Template placeholder syntax: **simple double-brace substitution** (the token is an opening double-brace, the name, then a closing double-brace — kept fuzzy here because the opening and closing brace sequences trip up some XML parsers; see Task 1 body below for the literal string). NOT Go `text/template`. CONTEXT.md says PowerShell uses string replacement and Inno Setup will use `StringChange` in Phase 3.
- New files: `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` and `com.gomapi.host.edge.json.tmpl`
- Placeholders: `HOST_PATH` and `EXTENSION_ID` (each wrapped in an opening double-brace and a closing double-brace)
- Refactor `scripts/install.ps1` to read the `.tmpl`, substitute placeholders with the resolved absolute host path and the extension ID
- **Keep the existing resolved-manifest files in place** until the refactor lands so installs don't break mid-refactor (special constraint 4)

**Important planner note on install.ps1 current state:** The current `install.ps1` (lines 628-653) does NOT read from `src/native-host/manifests/*.json`. It builds the manifest inline as a PowerShell hashtable and converts to JSON via `ConvertTo-Json`, then writes to `$InstallDir/com.gomapi.host.json`. All five browsers register that same `$manifestPath`. The existing stub `.json` files in the manifests/ directory are not consumed by install.ps1 today.

**Refactor approach (two modes for two install paths):**
1. **Local mode** (`-Local` flag, script running from a git checkout): read the `.tmpl` from `$repoRoot/src/native-host/manifests/com.gomapi.host.chrome.json.tmpl`, apply string substitution, write to `$InstallDir/com.gomapi.host.json`.
2. **Download mode** (`irm ... | iex` one-liner): the script runs from memory with no repo checkout. Keep the existing inline hashtable approach as a fallback. Add a comment referencing the `.tmpl` file as the canonical schema that Phase 3 Inno Setup consumes.

This dual-path is acceptable because both paths produce the same final JSON (the inline hashtable and the rendered template are schema-equivalent by construction, enforced by code review).

**Alternative simpler approach** (acceptable executor choice): keep the existing inline hashtable in install.ps1 entirely, create the `.tmpl` files as Phase 3 source-of-truth, add a clear PowerShell comment pointing at the `.tmpl` as the canonical schema. This avoids the dual-mode complexity while still delivering the `.tmpl` files that Phase 3 Inno Setup consumes. If the executor picks this path, the comment in install.ps1 must be explicit that the inline hashtable mirrors `com.gomapi.host.chrome.json.tmpl` and that any schema change must update both.

**Executor decision rule**: Prefer the Local-mode-reads-template approach because it proves the template is consumable by at least one installer. Fall back to the always-inline approach only if the Local-mode template read introduces material fragility. Document the choice in the plan summary.
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/01-foundation-signpath-application/01-CONTEXT.md
@scripts/install.ps1
@src/native-host/manifests/com.gomapi.host.chrome.json
@src/native-host/manifests/com.gomapi.host.edge.json

<interfaces>
**Current state of src/native-host/manifests/com.gomapi.host.chrome.json (stub, not consumed by install.ps1 today):**

```
{
  "name": "com.gomapi.host",
  "description": "go-mapi Native Messaging Host - bridges MAPI interceptor with browser extension",
  "path": "C:\\Program Files\\go-mapi\\go-mapi-host.exe",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://EXTENSION_ID_PLACEHOLDER/"
  ]
}
```

**Current state of scripts/install.ps1 lines 628-653 (inline manifest construction):**

```
# --- Step 4: Native messaging ---

Write-Host ""
Write-Host "  Step 4: Register native messaging" -ForegroundColor White

$manifest = @{
    name            = "com.gomapi.host"
    description     = "go-mapi Native Messaging Host"
    path            = (Join-Path $InstallDir "go-mapi-host.exe")
    type            = "stdio"
    allowed_origins = @("chrome-extension://$ExtensionId/")
} | ConvertTo-Json -Depth 10

$manifestPath = Join-Path $InstallDir "com.gomapi.host.json"
$manifest | Out-File -FilePath $manifestPath -Encoding UTF8
Write-Step "Created manifest: $manifestPath"
```

**scripts/install.ps1 lines 509-511 — how Local mode locates the repo root:**

```
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
```

In Local mode, the template path resolves to `$repoRoot\src\native-host\manifests\com.gomapi.host.chrome.json.tmpl`.

**PowerShell substitution approach (MANDATORY — do not use -replace):**

PowerShell `-replace` treats its first argument as a regex pattern. This causes two problems with this template:
1. The opening and closing double-brace tokens contain regex metacharacters (curly braces are quantifier delimiters in regex).
2. The substitution string must escape backslashes in Windows paths (e.g. `C:\Program Files\go-mapi\...`), because regex substitution interprets backslashes.

The fix is to use the PowerShell `.Replace()` string method, which performs literal substring replacement with zero escaping:

```
$template = Get-Content -Raw -Path $templatePath
$rendered = $template.Replace($placeholderHostPath, $resolvedHostPath).Replace($placeholderExtensionId, $ExtensionId)
```

Where `$placeholderHostPath` and `$placeholderExtensionId` are the literal token strings (constructed programmatically in install.ps1 to avoid any confusion about which characters are tokens). See Task 2 for the exact construction.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="false">
  <name>Task 1: Create .tmpl files with double-brace HOST_PATH and EXTENSION_ID placeholders</name>
  <files>src/native-host/manifests/com.gomapi.host.chrome.json.tmpl, src/native-host/manifests/com.gomapi.host.edge.json.tmpl</files>
  <read_first>
    - src/native-host/manifests/com.gomapi.host.chrome.json (the stub file with the current structure)
    - src/native-host/manifests/com.gomapi.host.edge.json (the stub file)
    - scripts/install.ps1 lines 628-653 (the current inline manifest construction — the .tmpl must produce the same final JSON when placeholders are substituted)
  </read_first>
  <action>
    Create `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` with the following exact content (UTF-8 without BOM, LF line endings are fine — install.ps1 can handle either):

    The content is a JSON document with:
    - `name` set to the literal string `com.gomapi.host`
    - `description` set to the literal string `go-mapi Native Messaging Host`
    - `path` set to the HOST_PATH placeholder token (opening double-brace, the word HOST_PATH, closing double-brace)
    - `type` set to the literal string `stdio`
    - `allowed_origins` set to an array containing the single string `chrome-extension://` followed immediately by the EXTENSION_ID placeholder token (opening double-brace, the word EXTENSION_ID, closing double-brace), followed by a trailing slash

    Concretely, the file content must be exactly this (copy verbatim, the placeholder tokens use double-opening-brace and double-closing-brace — if this XML rendering escapes them, use your plain-text understanding to produce the literal tokens):

    ```
    {
      "name": "com.gomapi.host",
      "description": "go-mapi Native Messaging Host",
      "path": "HOST_PATH_PLACEHOLDER_TOKEN",
      "type": "stdio",
      "allowed_origins": [
        "chrome-extension://EXTENSION_ID_PLACEHOLDER_TOKEN/"
      ]
    }
    ```

    Then replace `HOST_PATH_PLACEHOLDER_TOKEN` in the file with the literal 12-character string formed by: two opening curly braces, the word HOST_PATH, two closing curly braces. And replace `EXTENSION_ID_PLACEHOLDER_TOKEN` with the literal 16-character string formed by: two opening curly braces, the word EXTENSION_ID, two closing curly braces.

    You can verify this is correct after writing by running `grep` for the literal byte sequence (two open braces + HOST_PATH + two close braces) against the file — the grep must match.

    Create `src/native-host/manifests/com.gomapi.host.edge.json.tmpl` with the same content byte-for-byte. Chrome and Edge accept the same manifest schema, so both templates are identical. The separation is for clarity so Phase 3 Inno Setup can render one by name, and to future-proof any divergence.

    **Placeholder conventions (locked):**
    - HOST_PATH placeholder will be substituted with the absolute path to go-mapi-host.exe (example: `C:\Program Files\go-mapi\go-mapi-host.exe`)
    - EXTENSION_ID placeholder will be substituted with the 32-character lowercase Chrome/Edge extension ID
    - No other placeholders are defined in this phase

    **Scope discipline:**
    - Do NOT add new placeholders beyond HOST_PATH and EXTENSION_ID
    - Do NOT change the JSON structure (name, description, type, allowed_origins) from what install.ps1 currently writes
    - Do NOT delete the existing `.json` stub files — they stay as safety net per special constraint 4
    - Do NOT add JSON comments (JSON does not support them)
    - Do NOT add a BOM
  </action>
  <verify>
    <automated>test -f src/native-host/manifests/com.gomapi.host.chrome.json.tmpl && test -f src/native-host/manifests/com.gomapi.host.edge.json.tmpl && diff src/native-host/manifests/com.gomapi.host.chrome.json.tmpl src/native-host/manifests/com.gomapi.host.edge.json.tmpl</automated>
  </verify>
  <acceptance_criteria>
    - File `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` exists
    - File `src/native-host/manifests/com.gomapi.host.edge.json.tmpl` exists
    - The two files are byte-identical (diff returns empty)
    - Both files contain the literal HOST_PATH double-brace token (grep for the 12-byte sequence returns at least 1 match in each file)
    - Both files contain the literal EXTENSION_ID double-brace token (grep for the 16-byte sequence returns at least 1 match in each file)
    - The existing `com.gomapi.host.chrome.json` and `com.gomapi.host.edge.json` stub files STILL exist (they are kept as a safety net — grep: `ls src/native-host/manifests/` shows all four files)
    - Both `.tmpl` files parse as valid JSON AFTER placeholder substitution (simulate by replacing the tokens with test values and running `jq . on the result`) — you can test this inline: `sed 's/open-brace-twice HOST_PATH close-brace-twice/C:\\test\\host.exe/' file.tmpl | sed 's/open-brace-twice EXTENSION_ID close-brace-twice/abcdefghijklmnopqrstuvwxyz123456/' | jq .` should exit 0 with valid JSON output
    - Neither `.tmpl` file contains a BOM (first byte is `{`, not 0xEF 0xBB 0xBF)
  </acceptance_criteria>
  <done>
    Two byte-identical `.tmpl` files exist with HOST_PATH and EXTENSION_ID double-brace placeholders, the existing stub `.json` files are preserved, the templates parse as valid JSON after substitution.
  </done>
</task>

<task type="auto" tdd="false">
  <name>Task 2: Refactor install.ps1 to consume the .tmpl in Local mode</name>
  <files>scripts/install.ps1</files>
  <read_first>
    - scripts/install.ps1 (full file — focus on lines 504-580 for the Local-vs-download mode branching, and lines 628-653 for the native messaging step)
    - src/native-host/manifests/com.gomapi.host.chrome.json.tmpl (the file you created in Task 1)
  </read_first>
  <action>
    Modify `scripts/install.ps1` Step 4 (Register native messaging, lines 628-653) to render the manifest from the `.tmpl` file when in Local mode, and fall back to the existing inline hashtable construction when in Download mode.

    **Part A — Add a helper function near the top of the script (after the logging helpers around line 131, before the `$browsers` array):**

    Add a function `Render-ManifestTemplate` that takes two string parameters (template path and extension ID) plus the install dir path, reads the template, performs literal string substitution using the `.Replace()` method (NOT the `-replace` regex operator), and returns the rendered JSON content as a string. The function must:
    1. Read the template with `Get-Content -Raw -Path $TemplatePath` (the `-Raw` flag preserves line endings and returns a single string, not an array)
    2. Build the two placeholder token strings programmatically so the PowerShell parser never sees literal braces in positions that would confuse it. Use string concatenation: `$openToken = '{' + '{'` and `$closeToken = '}' + '}'` so the tokens are built at runtime without triggering any PowerShell brace expansion ambiguity. Then form `$hostPathPlaceholder = $openToken + 'HOST_PATH' + $closeToken` and `$extensionIdPlaceholder = $openToken + 'EXTENSION_ID' + $closeToken`.
    3. Resolve the host exe path: `$hostExePath = (Join-Path $InstallDir "go-mapi-host.exe")`
    4. Substitute using the string method (literal replacement, no regex): first call `.Replace($hostPathPlaceholder, $hostExePath)` on the template content, then chain `.Replace($extensionIdPlaceholder, $ExtensionId)` on the result.
    5. Return the rendered string.
    6. If any of the inputs is null or empty, throw a clear error.
    7. Validate the output is parseable JSON by attempting `ConvertFrom-Json` on it before returning; if parsing fails, throw a descriptive error (indicates a malformed template).

    Add a Write-Log line at the start of the function logging which template is being rendered.

    **Part B — Modify Step 4 (native messaging) to use the helper in Local mode, fall back to inline in Download mode:**

    Replace the existing Step 4 body (the `$manifest = @{ ... } | ConvertTo-Json -Depth 10` block) with a conditional that checks whether the script is running in Local mode. The Local flag is the `-Local` script parameter (already exists at line 74: `[switch]$Local`).

    In Local mode:
    1. Compute the template path: `$templatePath = Join-Path $repoRoot 'src\native-host\manifests\com.gomapi.host.chrome.json.tmpl'`
    2. Verify the template exists: `if (-not (Test-Path $templatePath)) { throw "Manifest template not found: $templatePath" }`
    3. Call `Render-ManifestTemplate` to get the rendered JSON string
    4. Write it to `$manifestPath` with `Set-Content -Path $manifestPath -Value $rendered -Encoding UTF8 -NoNewline`
    5. Write-Step to confirm

    In Download mode (the existing path):
    1. Keep the existing `$manifest = @{ ... } | ConvertTo-Json -Depth 10` construction unchanged
    2. Add a PowerShell comment immediately above the inline hashtable explaining: "This inline construction mirrors src/native-host/manifests/com.gomapi.host.chrome.json.tmpl. Any schema change must update BOTH. In Local mode, the template file is consumed directly."

    Both modes end up with `$manifestPath = Join-Path $InstallDir "com.gomapi.host.json"` pointing at the rendered manifest, and both call the same loop to register browsers.

    **Note about `$repoRoot`:** `$repoRoot` is only defined inside the `if ($Local) { ... }` block at lines 509-511. To use it in Step 4, either (a) move the `$scriptDir` and `$repoRoot` assignment up to script scope (before the Acquire artifacts block), or (b) compute it again inside the Step 4 Local branch using the same pattern. Approach (a) is cleaner — move the two lines up so `$repoRoot` is always defined when `$Local` is true.

    **Scope discipline:**
    - Do NOT change the download-mode behavior beyond adding the comment
    - Do NOT change any other step of install.ps1 (not the registry writes, not the prerequisites check, not the artifact acquisition)
    - Do NOT change the browser list or the registry key paths
    - Do NOT use `-replace` (regex) anywhere — use `.Replace()` (string method) exclusively for template substitution
    - Do NOT add a `ConvertFrom-Json | ConvertTo-Json` round-trip on the rendered output (that would change the whitespace compared to the template)
    - Do NOT touch the uninstall block
    - Do NOT add a new CLI parameter to install.ps1
    - Do NOT modify the version detection, metadata writing, or install completion messages
  </action>
  <verify>
    <automated>pwsh -NoProfile -Command "Set-Location C:/dev/go-mapi; $ErrorActionPreference = 'Stop'; . { $code = Get-Content -Raw scripts/install.ps1; if ($code -notmatch 'Render-ManifestTemplate') { throw 'helper function not found' }; if ($code -notmatch '\.tmpl') { throw 'tmpl reference not found' }; if ($code -match '-replace .*HOST_PATH') { throw 'used regex -replace for HOST_PATH — must use .Replace() string method' }; Write-Host OK }" 2>&1 || powershell -NoProfile -Command "Set-Location C:/dev/go-mapi; $code = Get-Content -Raw scripts/install.ps1; if ($code -notmatch 'Render-ManifestTemplate') { throw 'helper function not found' }; if ($code -notmatch '\.tmpl') { throw 'tmpl reference not found' }; Write-Host OK"</automated>
  </verify>
  <acceptance_criteria>
    - `scripts/install.ps1` contains a function named `Render-ManifestTemplate` (grep: `grep -n "function Render-ManifestTemplate" scripts/install.ps1` returns 1 match)
    - The function uses the `.Replace()` string method, not `-replace` regex, for placeholder substitution (grep: `grep -n "\.Replace(" scripts/install.ps1` returns at least 2 matches — one per placeholder)
    - `scripts/install.ps1` references at least one `.tmpl` file path (grep: `grep -n "\.tmpl" scripts/install.ps1` returns at least 1 match)
    - The download-mode inline hashtable construction still exists (grep: `grep -n "ConvertTo-Json -Depth 10" scripts/install.ps1` returns at least 1 match — retained as fallback)
    - A comment exists above the download-mode inline hashtable pointing at the `.tmpl` as the canonical schema (grep: `grep -B 1 "name            = \"com.gomapi.host\"" scripts/install.ps1 | grep -i "tmpl\|canonical\|template"` returns at least 1 match)
    - The script still runs `New-Item -Path $browser.Path -Force` and `Set-ItemProperty -Path $browser.Path -Name "(Default)" -Value $manifestPath` for each browser in the `$browsers` array (unchanged)
    - PowerShell syntax check passes: `powershell -NoProfile -Command "$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw scripts/install.ps1), [ref]$null); Write-Host OK"` exits 0 (or equivalent pwsh invocation). If PowerShell is not available in the dev environment, skip this check and rely on grep-based acceptance.
    - A dry-run render of the template (in a temp directory, simulating Local mode with a fake `$InstallDir` and a fake `$ExtensionId` of 32 lowercase letters) produces a valid JSON file that parses with `jq .` and contains the expected `path` and `allowed_origins` values
  </acceptance_criteria>
  <done>
    install.ps1 has a `Render-ManifestTemplate` helper that uses literal string `.Replace()`, Local mode renders from the `.tmpl` file, Download mode keeps the inline construction with a comment pointing at the template as canonical, no other install.ps1 logic is touched.
  </done>
</task>

</tasks>

<verification>
- `src/native-host/manifests/com.gomapi.host.chrome.json.tmpl` and `com.gomapi.host.edge.json.tmpl` exist and are byte-identical
- Both `.tmpl` files parse as valid JSON after placeholder substitution with test values
- The existing stub `.json` files are retained
- `scripts/install.ps1` has a `Render-ManifestTemplate` helper that uses literal `.Replace()` substitution (not regex `-replace`)
- Local-mode install path reads the template, renders it, writes the manifest
- Download-mode install path keeps the inline hashtable with a comment referencing the template as canonical
- PowerShell syntax parse of install.ps1 succeeds
- A manual dry-run of Local mode (pointing at a fake install dir) writes a valid manifest JSON file that jq can parse
</verification>

<success_criteria>
- Two `.tmpl` files with HOST_PATH and EXTENSION_ID double-brace placeholders
- Existing stub `.json` files preserved (safety net during refactor)
- install.ps1 helper function `Render-ManifestTemplate` using literal string substitution
- Local mode consumes the `.tmpl`
- Download mode falls back to inline construction with a comment pointing at the template
- No regex `-replace` used for template substitution (avoids Windows path backslash escaping issues)
- Phase 3 Inno Setup can consume the same `.tmpl` files via Pascal Script `StringChange`
</success_criteria>

<output>
After completion, create `.planning/phases/01-foundation-signpath-application/01-06-SUMMARY.md` documenting:
- The final content of both `.tmpl` files
- The `Render-ManifestTemplate` function body
- The decision made about Local vs Download mode (dual-path or always-inline)
- Confirmation that the existing stub `.json` files are preserved
- A dry-run rendering of the template with test values, showing the output is valid JSON
- Confirmation that `.Replace()` is used, not `-replace`
</output>
