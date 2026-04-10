---
plan: 03-02
phase: 03
status: complete
completed: 2026-04-10
commits:
  - 754ce59 ci(03-02): add installer-release workflow with SignPath gate (SIGN-02/03/04)
---

# Plan 03-02 Summary: Installer release workflow

## What shipped

- `.github/workflows/installer-release.yml` — 232-line GitHub Actions
  workflow that, on tag push `v*`, builds the DLL + host + installer,
  optionally signs all three via SignPath (gated on the
  `SIGNPATH_API_TOKEN` secret), and attaches `go-mapi-setup.exe` to the
  GitHub Release at the stable URL.

## Requirements satisfied

- **SIGN-02**: Two `SignPath/github-action-submit-signing-request@v1`
  steps:
  1. **Before `iscc.exe`**: signs `go-mapi.dll` and `go-mapi-host.exe`
     as a single request (`artifact-configuration-slug: go-mapi-binaries`)
     from `sign-input/` (a staging directory created from the build
     outputs). Signed binaries replace the unsigned ones in the original
     build output paths, so `iscc.exe` bundles the signed versions.
  2. **After `iscc.exe`**: signs the produced `go-mapi-setup.exe`
     (`artifact-configuration-slug: go-mapi-installer`). Signed installer
     replaces the unsigned one before the release-publish step.
- **SIGN-03**: Every signing-related step is gated on
  `env.SIGNPATH_API_TOKEN != ''`. When the secret is missing (SignPath
  Foundation approval pending), all four SignPath-related steps
  (upload-unsigned, SignPath submit, replace-with-signed, for DLL+host
  and again for installer) skip, and the workflow continues with
  unsigned artifacts. A `Note unsigned fallback` step emits a CI warning
  annotation so the unsigned run is clearly flagged in the workflow log.
- **SIGN-04**: `softprops/action-gh-release@v2` publishes
  `src/installer/dist/go-mapi-setup.exe` to the tag's GitHub Release
  with the stable filename. Combined with GitHub's built-in
  `/releases/latest/download/<filename>` redirect, the URL
  `https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe`
  resolves to every non-prerelease release's installer.

## Notable decisions

- **Workflow is additive, not a replacement** for the existing
  `release.yml`. Both run on the same tag. `release.yml` continues to
  publish the raw DLL / host / extension ZIP; this workflow adds
  `go-mapi-setup.exe` to the same release. Scope-discipline rule: Phase
  3 does not modify Phase 1 / Phase 4 territory files.
- **`append_body: true`** on `action-gh-release` lets the release notes
  template from Plan 03-03 be ADDED to whatever auto-generated release
  notes `release.yml` has already created on the same tag, rather than
  overwriting them. Order of workflow runs does not matter.
- **`contents: write` + `id-token: write` permissions**: `contents` is
  required for the release publish step; `id-token` is a SignPath
  requirement on the OIDC-based variant of the action and is harmless
  when the signing steps are gated off.
- **Inno Setup install path**: hard-coded to
  `C:\Program Files (x86)\Inno Setup 6\iscc.exe` — the Chocolatey
  default install location, identical to what the smoke-test workflow
  uses.
- **`workflow_dispatch` input**: lets the workflow run without a real
  tag for debug builds; `0.0.0-dev` default so the installer compiles.
  The publish step is gated on `startsWith(github.ref, 'refs/tags/v')`
  so manual runs never touch the Releases page — they just upload the
  workflow artifact.
- **Secret gate pattern**: `env.SIGNPATH_API_TOKEN != ''` reads from the
  job-level `env:` which in turn reads `secrets.SIGNPATH_API_TOKEN`.
  This is the standard GitHub Actions idiom for "skip if secret missing"
  because `if: secrets.X != ''` has historically been flaky on some
  runner versions.

## Verification

- **Grep checks**: all 12 acceptance-criteria patterns from the plan
  match. No tabs in the YAML. 232 lines total.
- **`release.yml` untouched**: `git diff .github/workflows/release.yml`
  is empty on the phase branch.
- **YAML syntax**: parse-check via Python `yaml` module not possible on
  the executor host (no `yaml` module installed). Workflow will be
  parsed by GitHub Actions on first push; invalid YAML fails fast at
  the workflow list page.
- **SignPath action parameter schema**: the `v1` action's documented
  inputs at
  `https://github.com/SignPath/github-action-submit-signing-request`
  were followed as closely as possible. If the action's schema evolved,
  the gated `if: env.SIGNPATH_API_TOKEN != ''` means the failure path
  (bad parameters) only triggers once a real signing attempt happens —
  the unsigned fallback keeps shipping.

## Known gaps

- **Untested on a real SignPath project**: without a SignPath
  organization, project, and signing policy, the signed path is dead
  code in this repo. When Marc files SignPath, the first signed run may
  surface parameter-name mismatches. The `artifact-configuration-slug`
  values (`go-mapi-binaries`, `go-mapi-installer`) are placeholders that
  must match the SignPath project config exactly.
- **No retry on signing failures**: the signing step fails the whole
  workflow if SignPath returns an error. For a solo-maintainer FOSS
  project, that's acceptable — rerun the workflow manually. Could be
  revisited with `continue-on-error` + conditional fallback if signing
  becomes a flake source.
