# ADR-0001: Odd/even release lines and component names

**Status:** Accepted  
**Date:** 2026-09-21

## Context

go-mapi has two independently packaged parts, but “app/admin” does not clearly
describe their ownership or installation scope. We also need to exercise the
real signing, publishing, targeted-distribution, and installation path before a
stable release without making test builds look stable to automation.

## Decision

Product-facing material calls the per-user application the **user component**
and the machine-wide MAPI integration the **system component**. Existing wire,
file, and schema identifiers remain compatible until deliberately versioned.

New development releases use odd major versions and an explicit SemVer
prerelease identifier (`alpha`, `beta`, or `nightly`). A tested development
version promotes to the next even major while retaining minor and patch:
`3.1.0-beta.2` promotes to `4.1.0`. Stable releases use even major versions and
have no prerelease identifier. Existing stable `3.0.x` releases are a legacy
exception rather than precedent for new releases.

Development releases may traverse the complete signed release pipeline and
targeted Microsoft Store/WinGet distribution. Public stable channels accept
only stable-line versions.

The Store sees only the four-part numeric package identity, with its revision
field reserved as zero. Store-published candidates therefore advance the patch
number rather than relying on a changed SemVer suffix for uniqueness.

## Consequences

- Scripts can classify release intent from the canonical version rather than a
  loosely coupled flag.
- Beta installations exercise the same artifacts and trust boundaries as
  stable installations.
- Promotion changes the major version, so compatibility ranges and website
  metadata must explicitly map a development line to its stable counterpart.
- Internal compatibility identifiers such as `app`, `interceptor`, and current
  `admin-*` schema names are not silently renamed.
