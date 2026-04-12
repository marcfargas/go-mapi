---
plan: 03-03
phase: 03
status: complete_with_merge_followup
completed: 2026-04-10
commits:
  - 970ecdf docs(03-03): add GitHub Release notes template with SmartScreen guidance (SIGN-05)
---

# Plan 03-03 Summary: Release notes template and extension URL swap

## What shipped

- `.github/release-template.md` — 87-line GitHub Releases body template
  used by `installer-release.yml` via `softprops/action-gh-release`'s
  `body_path` parameter. Content: one-line summary, download link,
  installation instructions, SmartScreen click-through guidance, what
  the installer writes, uninstall instructions, privacy statement,
  support links.

## Requirements satisfied

- **SIGN-05**: Release notes include prominent SmartScreen guidance.
  The "If Windows SmartScreen blocks the installer" section explains:
  - Why SmartScreen appears (unsigned fallback builds during SignPath
    approval wait, AND newly-signed builds before Microsoft's
    reputation engine learns the cert).
  - The three-step click-through: "More info" link → "Run anyway"
    button → normal UAC prompt.
  - Reassurance that this is a one-time click-through per file, not a
    permanent degradation.

- **EXT-07**: NOT applied in this worktree. The target file
  `src/extension/src/popup/InstallPrompt.tsx` does not exist because
  Phase 2 is running in parallel and has not yet created it. This is
  documented as a **merge-time follow-up for the Phase 4 reviewer**.

## EXT-07 merge-time coordination note

Per Phase 3 CONTEXT D-25/D-26 and the Phase 2 handoff constraint:

- Phase 2 was instructed (per its CONTEXT D-12) to use
  `'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe'`
  as the placeholder value for `INSTALLER_DOWNLOAD_URL` in
  `InstallPrompt.tsx`.
- Phase 3 CONTEXT D-26 locks the final URL to exactly that same value.
- Expected outcome at merge time: **EXT-07 is a pre-matched no-op**.
  The Phase 4 reviewer should verify that after merging Phase 2 into
  develop, `grep -c "https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe" src/extension/src/popup/InstallPrompt.tsx`
  returns `>= 1` with no active `// EXT-07:` TODO comment remaining.
- If Phase 2 shipped with a different placeholder (e.g. a staging URL
  or a literal `'TODO'`), the reviewer MUST edit `InstallPrompt.tsx`
  to the final URL above before closing Phase 3. This is a one-line
  change and requires no other file modifications.

## Notable decisions

- **English-only copy** per user's global i18n rule for external
  projects. Non-technical tone targeted at the Windows user persona
  described in PROJECT.md's Core Value statement.
- **Markdown-compatible with GitHub Releases rendering**: uses `##`
  headings, unordered lists, angle-bracket URLs, and `code` spans.
  Renders cleanly in the Releases page and in email/RSS notifications
  that consume the release body.
- **No emojis** per project convention.
- **Links point at `marcfargas/go-mapi`** (confirmed via `git remote
  -v` on the worktree: `origin` is
  `https://github.com/marcfargas/go-mapi.git`).
- **Privacy restatement** is a one-paragraph summary — the full privacy
  posture lives in `CLAUDE.md` and the SignPath application draft.
  Release notes get the distilled version so a skimming user sees the
  key facts.

## Verification

- **Grep checks**: all 7 acceptance-criteria patterns match (case-
  insensitive for copy phrases like `SmartScreen`, `More info`, `Run
  anyway`, `privacy`).
- **Rendered preview**: not verified (no GitHub Markdown renderer on
  the executor host). Will render on the first tag-triggered release
  run.

## Known gaps

- **EXT-07 is deferred to merge time**. The Phase 2 worktree is not
  visible from this worktree; when Marc merges Phases 2 and 3 into
  develop, the Phase 4 reviewer should perform the EXT-07 check
  described above. Flagged in `03-VERIFICATION.md` as a human_needed
  item for the merge coordination.
