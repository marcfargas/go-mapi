# Pitfalls Research — go-mapi v2.1.0

**Domain:** Release pipeline automation — changesets monorepo + dual web store publishing + GitHub Releases for mixed Go/C++/TS project
**Researched:** 2026-04-12
**Confidence:** HIGH (critical pitfalls verified against official docs and GitHub issues; confidence noted per-pitfall where sources are weaker)

> **Scope note:** These pitfalls are specific to the v2.1.0 workstream — adding automated release pipeline infrastructure to a working codebase. The v2.0.0 installer pitfalls are in the archived milestone research.

---

## Critical Pitfalls

### Pitfall 1: GITHUB_TOKEN cannot trigger downstream workflows — Version Packages PR never gets CI checks

**What goes wrong:**
The changesets GitHub Action creates the "Version Packages" PR using `secrets.GITHUB_TOKEN`. GitHub's security model explicitly prevents workflows triggered from PRs created by the built-in token from running. This means your branch protection rules (required status checks from build.yml) will never pass on the Version Packages PR — it's either perpetually blocked or you disable branch protection, which defeats the purpose.

**Why it happens:**
GitHub prevents the built-in token from recursively triggering workflows as a loop-prevention measure. The changesets action documentation shows `GITHUB_TOKEN` in examples, making this a very common mistake. Teams discover it only after they've wired everything together and the first real release attempt stalls indefinitely.

**How to avoid:**
Create a Fine-Grained Personal Access Token (PAT) with `contents: write` and `pull-requests: write` on the repository. Store it as `CHANGESET_TOKEN` (or similar) in repository secrets. Pass it to the changesets action:
```yaml
- uses: changesets/action@v1
  with:
    publish: npm run release
  env:
    GITHUB_TOKEN: ${{ secrets.CHANGESET_TOKEN }}
    NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```
The PAT-created PR is treated as a regular actor and triggers status checks normally.

**Warning signs:**
- Version Packages PR shows "Waiting for status to be reported" indefinitely
- build.yml never appears in the PR's check list
- Branch protection blocks merge with "required checks not run"

**Phase to address:** Changesets setup phase (Phase 1). Verify PAT is configured before wiring branch protection.

**Sources:** [changesets/action#70](https://github.com/changesets/action/issues/70), [changesets/action#99](https://github.com/changesets/action/issues/99)

---

### Pitfall 2: Extension manifest.json version and package.json version drift — store rejects upload

**What goes wrong:**
The Chrome Web Store and Edge Add-ons both validate that the `version` field in `manifest.json` is greater than the currently-published version and matches whatever you claim in the submission. When changesets bumps `src/extension/package.json` but nothing syncs that version into `src/extension/public/manifest.json`, the upload either fails (version not incremented) or the store publishes a ZIP whose internal version mismatches what's expected.

**Why it happens:**
Changesets only understands `package.json` — it has no awareness of `manifest.json`. Chrome extensions have two separate version declarations. The existing build pipeline reads version from `package.json` but the manifest has a hardcoded value (currently `"version": "2.0.0"` in `manifest.json`). Without an explicit sync step, these diverge the first time changesets bumps the extension package.

**How to avoid:**
Add a `prebuild` or post-version script that copies the version from `package.json` into `manifest.json`. For example, in the extension's `package.json`:
```json
"scripts": {
  "version": "node scripts/sync-manifest-version.js && git add public/manifest.json"
}
```
The `version` lifecycle hook in npm runs automatically after changesets writes the new version to `package.json`. The sync script reads `package.json` version and patches `manifest.json`. Commit both files. Verify the build artifact's `manifest.json` contains the bumped version before uploading.

**Warning signs:**
- Chrome Web Store API returns HTTP 400 with "version must be greater than existing version"
- `manifest.json` in the built ZIP shows the old version string
- `jq '.version' src/extension/dist/manifest.json` differs from `jq -r '.version' src/extension/package.json`

**Phase to address:** Changesets monorepo setup + extension publishing phase. Add version sync as a release prerequisite check.

---

### Pitfall 3: Go binary version injection reads root package.json — breaks when host gets its own version track

**What goes wrong:**
The current build scripts read version from the root `package.json` and inject it into the Go binary via `-ldflags "-X main.Version=$v"`. When changesets monorepo is configured with two separate packages (extension at `src/extension/`, host at a separate `packages/host/` or similar), the host package gets its own `package.json` with its own version. But the build scripts still read the root version — so the Go binary can be stamped with the wrong version indefinitely without any error.

**Why it happens:**
The version injection step in `build:native-host` (and in the CI workflows) uses a PowerShell one-liner that reads `package.json` from the current directory (repo root). This was fine with a single version but silently reads the wrong file after the monorepo split.

**How to avoid:**
When structuring the host package, place `package.json` at `packages/host/package.json` (or wherever changesets will manage it). Update the `build:native-host` script and the `installer-release.yml` workflow step to read version from that specific file:
```bash
SEMVER=$(jq -r '.version' packages/host/package.json)
go build -ldflags "-s -w -X main.Version=$SEMVER" -o build/go-mapi-host.exe .
```
Add a CI check that asserts the version embedded in the built binary (`go-mapi-host.exe --version`) matches the expected package version.

**Warning signs:**
- Go binary reports a different version than the GitHub Release tag
- `go-mapi-host.exe --version` outputs the extension version instead of the host version after an extension-only release
- Version Packages PR bumps extension to 2.1.0 but host binary still reports 2.0.0 at build time

**Phase to address:** Changesets monorepo split phase. Must be verified before the first automated host release.

---

### Pitfall 4: Edge Add-ons Publish API v1 was deprecated January 10, 2025 — old tooling silently fails

**What goes wrong:**
Microsoft deprecated Publish API v1 on January 10, 2025. Any CI action or script that uses the old credential format (access token URL based auth) will receive failures when attempting to publish or update the Edge extension. This includes older GitHub Actions in the marketplace and community scripts written before September 2024.

**Why it happens:**
The new Edge Publish API changed the authentication mechanism entirely: API keys now expire every 72 days (previously 2 years) and the token URL is generated internally rather than passed explicitly. Teams that set up Edge publishing automation more than a year ago and haven't touched it will hit this wall on the first automated release attempt.

**How to avoid:**
Use the [microsoft/edge-addon-upload](https://github.com/marketplace/actions/upload-to-edge-add-ons) action or official Microsoft Learn guidance for the new API. Credentials required: `EDGE_PRODUCT_ID`, `EDGE_CLIENT_ID`, `EDGE_API_KEY`. The API key expires every 72 days — add a calendar reminder or a workflow that validates credential age. The first submission must be done manually through Partner Center; automation only handles updates.

**Warning signs:**
- Edge publishing step exits with authentication error despite correct-looking secrets
- HTTP 401 or "Unauthorized" from the Edge Add-ons REST endpoint
- `EDGE_ACCESS_TOKEN_URL` secret still present in workflow from pre-2025 setup

**Phase to address:** Extension publishing phase. Verify against official Microsoft Learn docs at time of implementation; do not trust any blog post written before September 2024.

**Sources:** [Microsoft Edge Blog — Jan 2025](https://blogs.windows.com/msedgedev/2025/01/08/enhanced-security-for-extensions-with-publish-api-next-steps/), [Microsoft Learn Edge Add-ons API](https://learn.microsoft.com/en-us/microsoft-edge/extensions/update/api/using-addons-api)

---

### Pitfall 5: Two workflows both trigger on the same tag and race to create the GitHub Release

**What goes wrong:**
The project already has `release.yml` (publishes raw DLL/host/extension ZIP) and `installer-release.yml` (publishes `go-mapi-setup.exe`), both triggered on `push: tags: v*`. When changesets starts pushing host release tags, both workflows fire simultaneously. Whichever job calls `softprops/action-gh-release` first creates the release; the second job either silently appends to it (if `softprops` is lenient) or fails with "release already exists." In the failure case, one set of artifacts is missing from the published release.

**Why it happens:**
Tag-triggered workflows have no inherent ordering. The existing pair of workflows was manageable by hand-tagging, but automated tagging from changesets removes the human gate that previously ensured sequential execution.

**How to avoid:**
Redesign the release workflows to use a single "create release" job. One approach: have one workflow create the release and all others use `fail_on_unmatched_files: false` with `softprops/action-gh-release` pointing at the same tag (it will append). A cleaner approach: use a single orchestrator workflow that calls all build workflows via `workflow_call`, collects all artifacts, then creates one release at the end. Add `concurrency` groups scoped to the tag:
```yaml
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false  # don't cancel — queue instead
```

**Warning signs:**
- GitHub Release shows only the installer but not the raw DLL/host artifacts (or vice versa)
- One of the release workflows shows "release already exists" error
- Release assets list is incomplete without a re-run

**Phase to address:** GitHub Releases integration phase. Audit existing workflows before wiring changesets tags to avoid introducing a new race on top of the existing pair.

---

### Pitfall 6: Changesets treats the root package as a publishable npm package — spurious publish attempts

**What goes wrong:**
The root `package.json` has `"private": true` and `"name": "go-mapi"`. Changesets correctly skips publishing private packages to npm, but the version tracking and tagging behavior for the root package depends on how `privatePackages` is configured in `.changeset/config.json`. Without explicit configuration, changesets may try to tag the root package, create a `go-mapi@2.x.x` tag, and trigger workflows that have no handler for that tag shape — or, worse, skip creating any GitHub tags at all for the host package.

**Why it happens:**
Changesets' default `privatePackages` config is `{ version: true, tag: false }` — it bumps the version in `package.json` but does not create a git tag. If the host release workflow listens for `push: tags: host-v*` (the intended pattern for decoupled tracks), no tag is ever pushed and the workflow never fires. This requires explicitly setting `privatePackages: { version: true, tag: true }` and `tagFormat` for each package.

**How to avoid:**
Set explicit tag formats in `.changeset/config.json`:
```json
{
  "changelog": "@changesets/cli/changelog",
  "commit": false,
  "linked": [],
  "access": "restricted",
  "baseBranch": "main",
  "updateInternalDependencies": "patch",
  "privatePackages": { "version": true, "tag": true }
}
```
Use `tagFormat` at the package level if supported, or adopt tag patterns that separate extension tags (`extension-v*`) from host tags (`host-v*`). Update all workflow `on.push.tags` filters accordingly.

**Warning signs:**
- No git tag is created after merging a Version Packages PR for the host package
- `git tag -l` shows `go-mapi-extension@2.1.0` but nothing for host
- Host release workflow never fires after a host changeset is consumed

**Phase to address:** Changesets setup phase. Validate tag creation in a dry-run on a branch before merging to develop.

---

### Pitfall 7: Chrome Web Store review delay decouples "published to store" from "released on GitHub"

**What goes wrong:**
The pipeline pushes the extension ZIP to the Chrome Web Store and calls the publish endpoint. The workflow reports success. But Chrome review takes anywhere from a few hours to 3+ weeks (longer for extensions requesting broad host permissions or with large codebases). Users who install go-mapi from GitHub see the new host version; users who get the extension via Chrome auto-update may be running the old extension against the new host for weeks. If the new host introduced a breaking protocol change, this causes silent failures.

**Why it happens:**
The Chrome Web Store publish API returns success when the item is accepted for review — not when it is approved and live. Automated pipelines conflate "submitted" with "shipped." Go-mapi's native messaging protocol between host and extension is a shared contract; version skew between the two can cause JSON parse errors or unhandled message types.

**How to avoid:**
- Maintain backward compatibility in the native messaging protocol across at least one minor version boundary. Add protocol version negotiation if needed.
- Do not ship breaking host-protocol changes without a corresponding extension release that is already live in the store. Stage host releases to wait for extension approval, or make the host tolerate both old and new message shapes during a transition window.
- Add a note in the release checklist: "Verify extension is live in Chrome Web Store before promoting the host installer URL in the extension popup."

**Warning signs:**
- Extension popup shows "unknown message type" errors after a host update
- Chrome Web Store dashboard shows status "In Review" while GitHub Release is already published
- User reports: "Install went fine but drafts aren't creating" — classic symptom of protocol skew

**Phase to address:** Publishing coordination phase. Protocol backward-compatibility is a design constraint, not a CI step.

---

### Pitfall 8: CWS OAuth refresh token has no expiry warning — pipeline silently fails months later

**What goes wrong:**
The Chrome Web Store publish flow uses a refresh token obtained via OAuth 2.0. The refresh token itself does not expire on a schedule, but it is invalidated when: the Google account password changes, the user revokes the OAuth grant, or the GCP project credentials are rotated. When this happens, the CI job fails with an authentication error — but there is no proactive warning. Teams discover this on a release day, often after the PR is already merged.

**Why it happens:**
The refresh token is stored in a repository secret and treated as permanent. Teams obtain it once during setup and forget it exists. CI pipelines have no credential health-check step; the failure surface is only visible on the publish step.

**How to avoid:**
- Document the token generation steps in the repository (not the token itself — the steps to regenerate it).
- Add a workflow that runs monthly (on a schedule) and attempts a dry-run API call (e.g., `GET /items/{extensionId}`) using the stored credentials. If it fails, post an issue or a Slack alert.
- Keep the GCP project used for CWS publishing separate from the GCP project used for the extension's OAuth (they are currently the same per the manifest). Credential rotation in one should not silently break the other.

**Warning signs:**
- CI returns HTTP 401 or "invalid_grant" from Google OAuth
- Error occurs only on the publish step, not on build/test
- Last successful publish was months ago

**Phase to address:** Extension publishing phase. Build the health-check workflow alongside the publish workflow.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Use GITHUB_TOKEN for changesets action | Zero secret setup | Version Packages PR never gets CI checks; must re-configure under branch protection | Never — PAT is required from day one |
| Single root `package.json` version for all components | Simple; matches current state | Host and extension can't release independently; changesets can't decouple tracks | Acceptable until v2.1.0; must split before pipeline is live |
| Hard-code manifest.json version | No sync script to maintain | Store rejects upload after first automated bump | Never if automating extension publishing |
| Trigger on any `v*` tag | Simple workflow trigger | Both old workflows and new changesets tags fire on the same pattern; race conditions | Never with two concurrent release workflows |
| Store all credentials under one GCP project | Single console to manage | Password change or grant revocation breaks all CI auth simultaneously | Only for personal/hobby projects; add health-check |
| Skip protocol backward-compat during host releases | Faster host iteration | Users on delayed extension update get broken experience for days to weeks | Never — the review delay is unavoidable |

---

## Integration Gotchas

Common mistakes when connecting to external services.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Chrome Web Store Publish API | Assume success = live | API returns 200 when submitted for review, not when approved. Poll status or add review-awareness to docs |
| Chrome Web Store Publish API | Use "Chrome Extension" OAuth client type | Use "Desktop App" client type for CI tools. "Chrome Extension" is for in-extension OAuth flows |
| Edge Add-ons Publish API | Use pre-2025 credentials or actions | API v1 deprecated January 10, 2025. Use new API with 72-day rotating keys |
| Edge Add-ons Publish API | Automate first submission | First publish must go through Partner Center manually; API only handles updates |
| changesets action | Use GITHUB_TOKEN for PR creation | Use a PAT; GITHUB_TOKEN-created PRs don't trigger required CI checks |
| changesets + private packages | Assume tag is created automatically | Default `privatePackages` does not create tags; set `{ version: true, tag: true }` explicitly |
| Go build version injection | Read version from repo root `package.json` | After monorepo split, read from the host package's own `package.json` |
| softprops/action-gh-release | Run from two concurrent workflows on same tag | First creates release, second may silently fail or duplicate. Consolidate release creation |
| Edge API key | Treat as permanent credential | Keys expire every 72 days. Rotate proactively and set calendar reminders |

---

## Security Mistakes

Domain-specific security issues beyond general web security.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Committing CWS refresh token or Edge API key to repo | Full publishing control for attackers | Store only in GitHub encrypted secrets; document regeneration steps, not the value |
| Using the same GCP project for end-user Gmail OAuth and CWS publishing OAuth | Credential incident in one domain disables the other | Separate GCP projects or at minimum separate OAuth clients |
| Broad PAT scope for changesets token | PAT with `repo` scope can read all private repos | Use Fine-Grained PAT scoped to this repository only, with `contents: write` and `pull-requests: write` |
| Publishing workflow without concurrency lock | Concurrent publishes can submit two versions simultaneously | `concurrency: group: publish-${{ github.ref }}` on the publish job |
| Release artifacts not verified before upload | Corrupted or wrong-version binary shipped to users | Assert binary version via `go-mapi-host.exe --version` and manifest.json version check in release workflow before upload step |

---

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **Changesets setup:** PAT configured and tested — verify a test PR created by the action triggers required status checks
- [ ] **Extension version sync:** `manifest.json` version matches `package.json` version in the built ZIP — run `jq '.version' src/extension/dist/manifest.json` post-build
- [ ] **Host version injection:** Go binary version matches host `package.json` — run `go-mapi-host.exe --version` in release workflow and assert against `jq -r '.version' packages/host/package.json`
- [ ] **Edge API migration:** Workflow uses new API format (EDGE_API_KEY, no access token URL) — confirm against [Microsoft Learn docs](https://learn.microsoft.com/en-us/microsoft-edge/extensions/update/api/using-addons-api) at implementation time
- [ ] **Release race prevention:** Only one workflow creates the GitHub Release object — confirm by checking release creation steps across all tag-triggered workflows
- [ ] **Tag pattern isolation:** Extension tags and host tags use distinct patterns — `extension-v*` and `host-v*` (or similar); no workflow triggers on both
- [ ] **CWS credential health check:** Monthly scheduled workflow calls a read-only CWS API endpoint with stored credentials and alerts on failure
- [ ] **Protocol compatibility:** Host and extension can interoperate across one minor version — document the contract and add a test that loads the old message shape
- [ ] **First store submission:** Both Chrome Web Store and Edge Add-ons have an initial manual submission completed before any automation is attempted

---

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| PAT missing — Version Packages PR blocked | LOW | Add PAT secret, re-run changesets action, PR will be recreated |
| manifest.json version drift — store rejected upload | MEDIUM | Manually bump manifest.json, rebuild ZIP, re-upload via API or dashboard; add sync script to prevent recurrence |
| Go binary stamped with wrong version | LOW | Re-run release workflow with corrected version read path; delete and recreate GitHub Release if already published |
| Edge API key expired — publish blocked | LOW | Regenerate API key in Partner Center, update EDGE_API_KEY secret, re-run workflow |
| CWS refresh token invalidated | MEDIUM | Re-run OAuth flow (manual steps, 15–30 minutes), update CWS_REFRESH_TOKEN secret, re-run publish workflow |
| Duplicate GitHub Release from tag race | MEDIUM | Delete the duplicate release via GitHub UI or `gh release delete`, remove duplicate assets, re-run the failed workflow; fix concurrency group |
| Extension in review during breaking host release | HIGH | Roll back host installer URL in extension popup to previous version; wait for extension approval before re-pointing; or release a host version that supports both protocol shapes |

---

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| GITHUB_TOKEN blocks CI on Version Packages PR | Phase 1 — Changesets setup | Create a test changeset → merge → Version Packages PR gets CI checks |
| manifest.json / package.json version drift | Phase 1 — Changesets setup + Phase 2 — Extension publishing | Post-build assertion: `jq '.version' dist/manifest.json` matches `package.json` |
| Go binary reads wrong version after monorepo split | Phase 1 — Changesets setup | Release dry-run: binary `--version` matches host package.json |
| Edge API v1 deprecated | Phase 2 — Extension publishing | Workflow uses new API format; test publish with Edge credentials |
| Tag-triggered release workflow race | Phase 3 — GitHub Releases | Only one workflow creates the release; confirmed by reviewing all tag-triggered jobs |
| changesets privatePackages not tagging | Phase 1 — Changesets setup | After Version Packages merge, `git tag -l` shows expected tag for each package |
| Chrome review delay + protocol skew | Phase 2 — Extension publishing + ongoing | Protocol backward-compat documented; host releases gated on extension being live |
| CWS credential staleness | Phase 2 — Extension publishing | Monthly health-check workflow in place before first automated publish |

---

## Sources

- [changesets/action#70 — GITHUB_TOKEN does not trigger downstream workflows](https://github.com/changesets/action/issues/70)
- [changesets/action#99 — How can I run actions on Version Packages PR](https://github.com/changesets/action/issues/99)
- [changesets discussion#1312 — How to version a private project](https://github.com/changesets/changesets/discussions/1312)
- [Microsoft Edge Blog, Jan 2025 — New Publish API migration](https://blogs.windows.com/msedgedev/2025/01/08/enhanced-security-for-extensions-with-publish-api-next-steps/)
- [Microsoft Learn — Edge Add-ons Publish API](https://learn.microsoft.com/en-us/microsoft-edge/extensions/update/api/using-addons-api)
- [Chrome Web Store review process — official docs](https://developer.chrome.com/docs/webstore/review-process)
- [Chrome Web Store API — using the API](https://developer.chrome.com/docs/webstore/using-api)
- [Chrome Web Store API v2 announcement](https://developer.chrome.com/blog/cws-api-v2)
- [jam.dev — Chrome extension publishing with GitHub Actions](https://jam.dev/blog/automating-chrome-extension-publishing/)
- [GitHub release race condition — tauri-apps/tauri-action#914](https://github.com/tauri-apps/tauri-action/issues/914)
- [GitHub concurrency control — oneuptime.com](https://oneuptime.com/blog/post/2026-01-25-github-actions-concurrency-control/view)
- [changesets issues#1120 — privatePackages still versioned when using privatePackages: false](https://github.com/changesets/changesets/issues/1120)

---
*Pitfalls research for: go-mapi v2.1.0 release pipeline automation (changesets + dual web store + GitHub Releases)*
*Researched: 2026-04-12*
