# Phase 11 clean-machine smoke evidence

**Status:** PENDING — awaiting the sandbox run.

Paste the auto-generated `<EvidenceDir>\EVIDENCE.md` block below once the sandbox run
completes. The sandbox script writes it for you; you only copy-paste here and commit.

## Harness run metadata

- Run at: (fill in)
- Evidence dir: (fill in)
- Installer path: (fill in)
- Installer SHA256: (fill in)

## Outcomes

| Step | Outcome |
|------|---------|
| install   | (fill in — PASS or FAIL with reason) |
| launch    | (fill in) |
| oauth     | (fill in — [HUMAN] Prompt 1 completed: sign-in detected via `oauth: signed in as` log line) |
| mapi      | (fill in — mailto: routed through go-mapi handler) |
| queue     | (fill in — JSON in `%TEMP%\go-mapi\`) |
| draft     | (fill in — [HUMAN] Prompt 2 completed: `gmail: draft created id=` log line) |
| gmail     | (fill in — [HUMAN] Prompt 3: draft actually visible in Gmail Drafts) |
| uninstall | (fill in — silent uninstall via `uninstall.exe /S`) |
| clean     | (fill in — no residual HKLM\SOFTWARE\Clients\Mail\go-mapi, no `C:\Program Files\go-mapi`) |

## Screenshot references

Expected files under `<EvidenceDir>\screenshots\`:

- `01-pre-install.png`
- `02-post-install.png`
- `03-launched.png`
- `04-signed-in.png`
- `05-queue-row.png`
- `06-draft-created.png`
- `07-post-uninstall.png`

## Final verdict

- Overall: (fill in — PASS / FAIL)

Note: evidence binaries (screenshots, app.log copy) stay under `tests/sandbox/phase11/evidence-*/`
and are gitignored. Only THIS ledger is committed.
