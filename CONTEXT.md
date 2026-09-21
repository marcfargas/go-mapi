# go-mapi domain language

This file defines the product terms used in documentation, release automation,
and new code. Existing persisted JSON fields and schema names are compatibility
contracts and are not renamed merely to match this vocabulary.

## Components

- **User component**: the per-user Wails application, tray process, UI, Gmail
  integration, and queue consumer. Its source lives in `src/app`.
- **System component**: the machine-wide x86/x64 MAPI interceptor, Windows
  registration, and MSI. Its source lives in `src/interceptor` and
  `src/installer/msi`.
- **Queue**: the per-user filesystem boundary through which the system
  component hands MAPI requests to the user component (`queue-v1`).

Use **user component** and **system component** for product and release
boundaries. Use narrower implementation terms such as `app`, `interceptor`, or
`MSI` only when referring to that specific executable, source module, artifact,
or compatibility field.

## Release lines

- **Development line**: an odd-major version carrying a prerelease identifier,
  such as `3.1.0-alpha.1`, `3.1.0-beta.2`, or
  `3.1.0-nightly.20260921`. Development artifacts may be signed and published
  to targeted test distributions so the real release path can be verified.
- **Stable line**: the corresponding even-major release without a prerelease
  identifier. For example, the `3.1.0-*` development line promotes to stable
  `4.1.0`.
- **Promotion**: producing the corresponding even-major stable release from a
  tested odd-major candidate while retaining its minor and patch numbers.

Microsoft Store package identity uses the numeric core plus a Store-reserved
zero revision. Therefore each Store-published development build must use a new
patch coordinate (for example `3.1.4-alpha` then `3.1.5-beta`); changing only
the prerelease suffix would reuse the same Store identity version.

`3.0.x` predates this policy and is a stable legacy exception. It does not make
new odd-major versions stable, and 3.0 versions are not accepted by the new
release automation.
