# Component compatibility contract

go-mapi releases the per-user Wails app and machine-wide interceptor independently. `components.json` schema 2 is the source contract: each component has its own version file and a structured `requires` record containing the counterpart name, an inclusive minimum, and an optional exclusive maximum. A repository tag and equality between component versions are never compatibility evidence.

Versions are canonical SemVer 2.0 without a leading `v`. Prerelease identifiers follow SemVer precedence and build metadata does not affect ordering. Empty, malformed, partial, leading-zero, and `0.0.0-dev` values are not release or installed-state versions. The shared cases in `tests/component-compatibility/compatibility-v1.json` are consumed by both Go and C++ tests.

## Per-user app state

After its queue consumer starts, the app maintains `%APPDATA%\go-mapi\app-component-state-v1.json` atomically alongside the unchanged `app-presence-v1` liveness token:

```json
{"schema":"go-mapi-app-component-state-v1","version":"4.0.0","queueProtocol":"queue-v1","refreshedAt":"2026-08-30T12:00:00Z"}
```

The interceptor permits the established missing-app warning path when no fresh presence token exists. A fresh presence token makes the version state mandatory. A missing, stale, malformed, or incompatible state returns `MAPI_E_FAILURE` before attachments or a queue descriptor are published.

## Installed interceptor manifest

The app queries exactly `%ProgramFiles%\go-mapi\interceptor\installed-component-v1.json`, resolving `%ProgramFiles%` through `FOLDERID_ProgramFiles`. It does not use an environment, current-directory, queue, or registry fallback and never writes machine state.

```json
{
  "schema": "go-mapi-installed-interceptor-v1",
  "component": "interceptor",
  "version": "4.0.0",
  "queueProtocol": "queue-v1",
  "requires": {"component":"app","minInclusive":"4.0.0"},
  "artifacts": [
    {"architecture":"x86","path":"x86\\go-mapi.dll","peProductVersion":"4.0.0","sha256":"<64 lowercase hex>"},
    {"architecture":"x64","path":"x64\\go-mapi.dll","peProductVersion":"4.0.0","sha256":"<64 lowercase hex>"}
  ]
}
```

There must be exactly one x86 and one x64 artifact. Paths are relative and confined below the manifest directory. The app checks each file hash and PE ProductVersion against the artifact and top-level versions without loading either DLL. Admin distribution owns atomic installation and removal of this exact manifest and files; the version gate owns its query-only reader and validation.

## Persistent mismatch health

On a known app mismatch, either interceptor architecture atomically replaces the one bounded per-user file `%LOCALAPPDATA%\go-mapi\queue\warnings\component-version-mismatch-v1.json`:

```json
{
  "schema":"go-mapi-component-version-mismatch-v1",
  "interceptor":{"version":"4.1.0","architecture":"x86","requires":{"component":"app","minInclusive":"4.2.0"}},
  "app":{"observedStatus":"below-minimum","observedVersion":"4.0.0"},
  "action":"update-app",
  "createdAt":"2026-08-30T12:00:00Z"
}
```

It contains no mail, recipient, attachment, OAuth, credential, installation URL, process, or machine identity. The Wails app strictly parses it on startup, queue activity, a coalesced 60-second refresh, and an explicit health query. The issue is merged with installed-interceptor health and rendered persistently. A compatible app removes a resolved warning; malformed diagnostics become a persistent `diagnostic-invalid` / `repair-interceptor` issue.

Component compatibility and queue protocol validation are separate gates. A compatible pairing continues to exchange queue-v1 with additive-field tolerance. This contract performs no download, elevation, installation, registration, Default Apps selection, telemetry, or update-service work.
