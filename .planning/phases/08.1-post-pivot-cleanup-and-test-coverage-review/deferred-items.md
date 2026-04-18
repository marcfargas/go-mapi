# Phase 08.1 — Deferred items

Out-of-scope findings surfaced during plan execution. Do not fix inline; track here
and route to the appropriate later plan/phase.

## From Plan 08.1-01 (test port)

### D-01-01: `go build ./src/app/...` requires frontend dist

- **Found during:** Task 4 full-module verification.
- **Finding:** `go build ./src/app/...` fails with
  `src\app\main.go:12:12: pattern all:frontend/dist: no matching files found`
  when `src/app/frontend/dist/` is absent (gitignored build output).
- **Root cause:** `src/app/main.go` line 12 uses `//go:embed all:frontend/dist`;
  the dist directory only exists after `npm run -w @marcfargas/go-mapi-app-frontend build`
  or `wails build`.
- **Reproduces at baseline:** Yes — verified against the Phase 08.1 base commit
  before any of this plan's changes. Unrelated to the `internal/mapi/` test ports.
- **Impact on Plan 01:** None — this plan only adds files under `internal/mapi/`;
  `go test ./internal/mapi/...` and `go vet ./internal/mapi/...` pass.
- **Route:** The must-hold invariant (Phase 8.1 CONTEXT §Specifics) requires the
  build pipeline to run in order: `npm run build:interceptor` →
  `npm run -w @marcfargas/go-mapi-app-frontend build` → `go build ./src/app/...`
  → `go test ./src/app/...`. Subsequent plans that run the full must-hold
  invariant (e.g., Plan 04 delete-src/native-host, Plan 07 CI rewrite) should
  ensure `src/app/frontend/dist` exists before invoking the Go-side tools, or
  run `wails build` which handles the sequencing automatically. No action required
  for this plan.
