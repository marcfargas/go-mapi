# Feature Research

**Domain:** Automated release pipeline — changesets monorepo versioning, dual web store publishing (Chrome + Edge), GitHub Releases with binary artifacts
**Researched:** 2026-04-12
**Confidence:** MEDIUM-HIGH

Scope: v2.1.0 milestone only. Existing features (CI builds, single-version package.json, manual publishing, Edge developer account) are already built. This covers what automated release pipelines for browser extensions with companion binaries look like, what users/contributors expect, and what patterns are standard vs. problematic.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features contributors and maintainers assume exist. Missing these makes the pipeline feel incomplete or unsafe.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Changeset files per PR describing what changed and the semver bump | Contributors in any JS monorepo with changesets expect to add a `.changeset/*.md` file alongside their PR. Without it, the release bot complains or skips their changes. | LOW | `changeset add` interactive CLI; CI can check that a changeset was added on non-trivial PRs |
| "Version Packages" PR auto-created by CI when changesets accumulate on `develop` | This is the canonical changesets flow. PR aggregates all pending changeset files into version bumps + CHANGELOG entries per package. Merging the PR triggers publishing. | MEDIUM | Uses `changesets/action` with a `GITHUB_TOKEN`. PR updates automatically as new changesets land. |
| Separate version tracks for extension vs host | Extension iterates frequently (UI, OAuth, popup); host is stable C++/Go binary. A host release should not be required for every extension tweak. | MEDIUM | Two `package.json` files in workspace packages (`extension/`, `host/`). Each gets its own `CHANGELOG.md` and git tag (e.g. `extension@2.3.0`, `host@2.1.0`). |
| Changelog auto-generated per package from changeset summaries | Contributors expect their changeset summary to appear in the CHANGELOG.md. No changelog = no release notes = users can't tell what changed. | LOW | `changeset version` writes `CHANGELOG.md` in each package directory. Changesets action does this in the Version Packages PR. |
| Git tags created per package on publish | e.g. `extension@2.3.0`, `host@2.1.0`. Without tags, GitHub Releases and rollback are impossible. | LOW-MEDIUM | Changesets `publish` step creates tags. For non-npm packages, must use `changeset tag` in the custom publish script or set `privatePackages: { version: true, tag: true }`. |
| GitHub Release created automatically on host version bump | Host releases include a Windows installer binary (`.exe`). Users need a GitHub Release page with the asset download link and the changelog excerpt. | MEDIUM | `softprops/action-gh-release@v2` uploads the `.exe` artifact. Can be triggered by the changesets publish step or by watching for the host tag. |
| Extension zip auto-built and uploaded to Chrome Web Store | Chrome users expect store auto-updates. Manual uploads are error-prone (wrong zip, forgot to bump version). | MEDIUM | `chrome-webstore-upload-cli` or a wrapper GitHub Action. Credentials stored as repo secrets (Client ID, Client Secret, Refresh Token). Extension ID required. |
| Extension zip auto-uploaded to Edge Add-ons | Extension already supports Edge. Users on Edge deserve auto-updates just like Chrome users. | MEDIUM | `wdzeng/edge-addon` GitHub Action or `edge-webstore-upload` CLI. Credentials: Product ID + Client ID + API key (72-day expiry as of Jan 2025). |
| Installer `.exe` artifact attached to the GitHub Release | Non-technical users follow the link in the extension popup to download the host installer. The GitHub Release is the distribution point. Must be the same stable URL referenced in the popup. | LOW | `softprops/action-gh-release@v2` `files:` glob. Already built by CI; just needs to be fetched and uploaded at release time. |

### Differentiators (Competitive Advantage)

Features that go beyond the baseline automated pipeline and reduce friction for a solo FOSS maintainer.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| SHA-256 checksum sidecar file uploaded alongside the installer | Security-minded users (FOSS crowd willing to install an unsigned MAPI DLL) want to verify. Extension popup can fetch and display the hash. Costs nothing to generate. | LOW | `sha256sum go-mapi-installer.exe > go-mapi-installer.exe.sha256` in the release job. Upload both as release assets. |
| "Latest" redirect URL pointing to the most recent installer | Extension popup links to a stable URL (not a versioned GitHub release URL). GitHub's `/releases/latest/download/` pattern satisfies this for public repos. | LOW | `https://github.com/org/repo/releases/latest/download/go-mapi-installer.exe` is a free stable URL provided by GitHub. No custom server needed. |
| Changesets bot comment on PRs reminding contributors to add a changeset | Reduces review friction; maintainer doesn't need to leave the same "please add a changeset" comment manually. | LOW | `changesets/action` running in "check" mode on pull_request events posts an automated comment. |
| Dry-run / preview mode for the publish step | Lets Marc validate the pipeline without actually publishing. Critical during initial setup. | LOW | `chrome-webstore-upload` supports `--no-publish` (upload only, no submit for review). Edge action has `upload-only: true`. Both useful for first-run validation. |
| Decoupled CI jobs: extension publish and host release as separate workflow jobs | Host release is rare and involves building a Windows binary + installer. Extension publish is frequent. Mixing them in one job means a failed host build blocks extension updates. | MEDIUM | Two jobs triggered by the same Version Packages merge, but gated by which package was actually bumped (check `publishedPackages` output from changesets action). |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Single version for both extension and host | Simpler mental model; everything at the same version is easy to communicate. | Extension iterates ~10x more than host. Coupled versioning forces unnecessary host releases and makes the host changelog noisy. Also creates ambiguity: which `v2.3.0` binary goes with which extension? | Two separate package workspaces with independent changelogs and tags. Extension tag: `extension@X.Y.Z`, host tag: `host@X.Y.Z`. |
| Auto-publishing to Chrome Web Store on every commit to `develop` | Faster feedback loop for rapid changes. | Web Store review takes hours to days; flooding submissions triggers rate limits and can get the extension flagged. Also, every commit is not production-ready. | Publish only on Version Packages PR merge (i.e., explicit intent to release). |
| Publishing from `develop` branch directly | Convenient — no need to manage a release branch. | Store submissions from a non-release branch make it harder to reproduce what was shipped. Tags on `develop` clutter the branch history. | Merge Version Packages PR into `develop` (acceptable for this project), but tag at the version commit. Alternatively, promote to `main` for formal releases. |
| npm registry publishing for the extension or host packages | Changesets defaults assume npm publish. Users copying examples might add `npm publish` to the workflow. | Neither the extension nor the host is an npm library. Publishing to npm is meaningless and pollutes the registry. | Mark both workspace packages `private: true` in their `package.json`. Use `privatePackages: { version: true, tag: true }` in `.changeset/config.json` so changesets still versions and tags them without attempting npm publish. |
| GitHub Releases for every changeset (including extension-only releases) | Consistency — always have a release for every tag. | Extension releases don't ship binary artifacts. An empty GitHub Release with just a changelog excerpt adds noise. Users looking for the installer get confused. | Create GitHub Releases only for host version bumps (where the installer binary is the artifact). Extension releases = git tag + CHANGELOG only. |
| Edge Add-ons API key stored as a long-lived secret | Old Edge API (v1) had 2-year expiry, felt like a permanent credential. | New Edge API v1.1 (mandatory since Jan 10, 2025) issues API keys with 72-day expiry. Keys stored in GitHub Secrets silently expire, causing CI failures. | Set a calendar reminder or GitHub Actions scheduled check to refresh the key every 60 days. Document the rotation procedure in the repo. |
| Automated release announcements (social posts, blog, Telegram) | Nice for visibility. | Out of scope per PROJECT.md; adds maintenance burden to a solo FOSS project. | Excluded explicitly. Changelog in the GitHub Release is sufficient. |

---

## Feature Dependencies

```
[Changesets monorepo setup]
    └──requires──> [Two workspace package.json files (extension/, host/)]
    └──requires──> [.changeset/config.json with privatePackages: { version: true, tag: true }]

[Version Packages PR automation]
    └──requires──> [Changesets monorepo setup]
    └──requires──> [changesets/action in CI with GITHUB_TOKEN]

[Chrome Web Store publish]
    └──requires──> [Version Packages PR automation] (triggered on merge)
    └──requires──> [Extension zip build (already in CI)]
    └──requires──> [Chrome OAuth credentials as repo secrets]
    └──enhances──> [Extension CHANGELOG.md] (provides store listing release notes)

[Edge Add-ons publish]
    └──requires──> [Version Packages PR automation]
    └──requires──> [Extension zip build (already in CI)]
    └──requires──> [Edge API credentials as repo secrets (72-day rotation)]
    └──conflicts──> [Long-lived credentials assumption] (must plan for key rotation)

[GitHub Release with installer artifact]
    └──requires──> [Version Packages PR automation]
    └──requires──> [Host installer build (already in CI)]
    └──requires──> [Git tag created for host package]
    └──enhances──> [SHA-256 sidecar file] (both uploaded as release assets)

[Stable installer download URL]
    └──requires──> [GitHub Release with installer artifact]
    └──enhances──> [Extension popup download link] (already built in v2.0.0)
```

### Dependency Notes

- **Changesets monorepo setup requires two workspace packages:** Root `package.json` stays as the npm workspace root. `src/extension/package.json` and a new `src/native-host/package.json` (or `host/package.json`) become the two tracked packages. The root `package.json` version is decoupled from both.
- **Edge credential rotation conflicts with set-and-forget:** This is the single highest-maintenance operational concern. The 72-day expiry (as of Jan 2025 Edge API v1.1) means the credential will expire roughly 5 times per year. Without active management, Edge publishing silently breaks.
- **Git tags required before GitHub Release:** The changesets publish step must emit `New tag:` to stdout (either via `changeset tag` or `privatePackages: { tag: true }`) for the changesets action to create GitHub Releases. Without this, `createGithubReleases: true` is a no-op.

---

## MVP Definition

### Launch With (v2.1.0)

Minimum pipeline to automate what Marc currently does manually.

- [ ] Changesets monorepo setup — two workspace packages, private (no npm publish), tagged — **foundation everything else depends on**
- [ ] Version Packages PR automation via `changesets/action` — CI creates/updates the PR when changesets exist on `develop`
- [ ] Extension publish to Chrome Web Store on Version Packages PR merge — removes the most frequent manual step
- [ ] Extension publish to Edge Add-ons on Version Packages PR merge — same zip, second destination, existing Edge account
- [ ] GitHub Release for host version bumps with installer `.exe` and SHA-256 sidecar — replaces manual GitHub release creation

### Add After Validation (v2.1.x)

- [ ] Changesets bot PR comments — useful once contributors other than Marc exist; overkill for solo work right now
- [ ] Dry-run job in CI for publishing (separate workflow triggered manually) — useful for testing credential changes

### Future Consideration (v3+)

- [ ] Host self-update — extension detects version mismatch, offers in-place update; deferred per PROJECT.md
- [ ] Automated key rotation reminder workflow — a scheduled GitHub Actions job that warns 14 days before Edge API key expiry

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Changesets monorepo setup | HIGH (enables everything else) | LOW | P1 |
| Version Packages PR automation | HIGH (eliminates manual tracking) | LOW | P1 |
| Chrome Web Store auto-publish | HIGH (most frequent release step) | LOW-MEDIUM | P1 |
| Edge Add-ons auto-publish | MEDIUM (existing Edge users) | MEDIUM | P1 |
| GitHub Release + installer artifact | HIGH (non-technical user install path) | MEDIUM | P1 |
| SHA-256 sidecar | MEDIUM (FOSS security hygiene) | LOW | P2 |
| Stable `releases/latest/download/` URL | HIGH (extension popup link) | LOW (GitHub provides it free) | P1 |
| Decoupled CI jobs (extension vs host) | MEDIUM (resilience) | MEDIUM | P2 |
| Changesets bot PR comments | LOW (solo maintainer now) | LOW | P3 |

**Priority key:**
- P1: Must have for v2.1.0 launch
- P2: Should have, add when P1s are working
- P3: Nice to have, future consideration

---

## Implementation Notes by Feature

### Changesets Monorepo Setup

Two approaches for marking packages non-publishable:
1. `"private": true` in each workspace `package.json` + `privatePackages: { version: true, tag: true }` in `.changeset/config.json` — packages are versioned and tagged but never pushed to npm. **Recommended.**
2. `ignore` field in `.changeset/config.json` — explicitly excludes packages from publishing, but is documented as "DESIGNED FOR TEMPORARY USE" and can cause changeset validation failures.

Use approach 1. Each workspace package needs its own `package.json` with a `name`, `version`, and `"private": true`. The host `package.json` does not currently exist; it must be created.

### Chrome Web Store Credentials

Three secrets needed: `CHROME_EXTENSION_ID`, `CHROME_CLIENT_ID`, `CHROME_CLIENT_SECRET`, `CHROME_REFRESH_TOKEN`. OAuth consent screen must be configured in Google Cloud Console with the Chrome Web Store API enabled. The "Desktop App" OAuth client type is correct for CI use (not "Chrome Extension"). Refresh tokens do not expire unless the app is revoked or the user revokes access — low rotation burden.

Tool: `fregante/chrome-webstore-upload-cli` (npm package, well-maintained, used by many extension developers). GitHub Actions wrappers exist but the CLI is more composable.

### Edge Add-ons Credentials

Two secrets needed: `EDGE_PRODUCT_ID`, `EDGE_CLIENT_ID`, `EDGE_API_KEY`. Generated in Partner Center under the Edge program's "Publish API" page. The API key expires every 72 days (Edge API v1.1, mandatory since Jan 10, 2025). The previous 2-year expiry is gone. Must plan for rotation.

Tool: `wdzeng/edge-addon` GitHub Action (supports API v1.1). Alternative: `hankxdev/edge-webstore-upload` CLI. Action is simpler for CI; the `upload-only: true` option is useful for first-run testing.

### GitHub Releases for Host

The host tag pattern should be `host@X.Y.Z` (changesets default for workspace packages). The `softprops/action-gh-release@v2` action can be triggered by this tag pattern. The installer `.exe` is already built by CI — the release job needs to download it from the build artifact and attach it. Must also generate and upload the SHA-256 sidecar.

The GitHub-provided stable URL `https://github.com/<owner>/<repo>/releases/latest/download/go-mapi-installer.exe` satisfies the extension popup's need for a stable download link without any custom server.

### Non-npm Publish + Git Tags + GitHub Releases

The changesets action's `createGithubReleases: true` (default) only fires if the publish step emits `New tag: <package>@<version>` to stdout. For non-npm packages with `private: true` and `privatePackages: { tag: true }`, `changeset publish` handles this. The custom `publish:` script in the changesets workflow must call `changeset tag` (or rely on `changeset publish` which calls it internally) to ensure tags and releases are created.

Confirmed working pattern (from changesets/action issue #269): include `npx changeset tag` in the publish script, or rely on `changeset publish` with `privatePackages: { tag: true }`. Do not use a dummy echo workaround — it is fragile.

---

## Sources

- [changesets/changesets GitHub](https://github.com/changesets/changesets) — official repo, config docs
- [changesets/action GitHub](https://github.com/changesets/action) — GitHub Action, inputs/outputs reference
- [changesets config-file-options.md](https://github.com/changesets/changesets/blob/main/docs/config-file-options.md) — `privatePackages`, `fixed`, `linked`, `ignore` options
- [changesets/action issue #269: Create GitHub release with custom publishing](https://github.com/changesets/action/issues/269) — working pattern for non-npm packages
- [fregante/chrome-webstore-upload-cli](https://github.com/fregante/chrome-webstore-upload-cli) — Chrome Web Store CLI tool
- [Chrome Web Store API docs](https://developer.chrome.com/docs/webstore/using-api) — OAuth setup for automated publishing
- [wdzeng/edge-addon GitHub Action](https://github.com/wdzeng/edge-addon) — Edge Add-ons action (API v1.1)
- [Edge Add-ons API 2025 security changes](https://blogs.windows.com/msedgedev/2025/01/08/enhanced-security-for-extensions-with-publish-api-next-steps/) — 72-day API key expiry, mandatory since Jan 10 2025
- [Microsoft Learn: Edge Add-ons REST API](https://learn.microsoft.com/en-us/microsoft-edge/extensions/update/api/using-addons-api) — credential setup in Partner Center
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release) — GitHub Releases with artifact upload

---
*Feature research for: go-mapi v2.1.0 release pipeline automation*
*Researched: 2026-04-12*
