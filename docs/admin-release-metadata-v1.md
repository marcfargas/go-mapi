# Admin release metadata v1

This is the authorization contract for the non-elevated app's optional repair
of the machine-wide interceptor. HTTPS and GitHub are transport only; neither
an asset name, tag, nor `latest` URL authorizes an MSI.

## Envelope

An envelope has `schema: "go-mapi-admin-envelope-v1"`, a base64url-without-
padding `signed` UTF-8 payload, and keyed Ed25519 signatures. Signatures are
verified over the decoded payload bytes before parsing the payload. The bytes
are produced by the release signer, not by re-marshalling an arbitrary JSON
map in a consumer.

Root metadata is bundled with the app and lists root and targets public keys,
their thresholds, the permitted metadata/artifact HTTPS origin, and a root
version. A root update needs threshold signatures from both the currently
trusted root and the incoming root. Old targets keys are accepted only while
the current root lists them.

The signed targets payload binds one `interceptor` release: canonical SemVer
version; `requires` app min/max range; queue protocol; positive sequence;
issued and expiry RFC3339 UTC timestamps; immutable release-specific HTTPS MSI
URL; byte size; lowercase SHA-256; and Authenticode publisher/EKU policy.

Consumers retain the highest accepted sequence and the payload SHA-256
atomically per user. Lower sequences fail; an equal sequence succeeds only for
the identical payload digest. `latest` in an authorized artifact URL, redirects
outside the configured HTTPS origin, expired records, malformed ranges,
untrusted keys, invalid signatures, and incompatible app versions all fail
before download authorization or UAC.

After download, consumers verify exact byte count/hash and Windows
Authenticode chain validity plus the signed durable publisher/EKU policy. A
certificate leaf thumbprint is never a trust anchor.

## Protected release inputs

Public release requires protected CI configuration for metadata signing keys,
root/targets public-key IDs and thresholds, release sequence, allowed origin,
publisher identity, code-signing EKU, and the enrolled Artifact Signing
subscriber-identity EKU. The latter identity is tenant/certificate specific and
must be supplied by the authorized Azure Artifact Signing configuration; it is not guessed
from source. Private keys are never committed.

The protected `artifact-signing` GitHub Environment supplies the concrete signing and metadata inputs:
`ADMIN_RELEASE_ROOT_JSON`, `ADMIN_RELEASE_TARGETS_KEY_ID`,
`ADMIN_RELEASE_METADATA_ORIGIN`, `ADMIN_RELEASE_PUBLISHER`,
`ADMIN_RELEASE_EKUS_JSON`, `ADMIN_RELEASE_POLICY_ID`, and the secret
`ADMIN_RELEASE_TARGETS_PRIVATE_KEY_PEM_B64`. Stable publication fails before
packaging when any is absent. Development-channel prereleases instead publish
an explicitly test-only manifest and may use Azure's TEST ONLY certificate;
that manifest is not accepted by the automatic admin updater. The private-key
secret is a base64-encoded PEM Ed25519 key, materialized only in the runner
temporary directory for `openssl pkeyutl` and then removed. The protected
GitHub run ID is the monotonically increasing release sequence; it is not
taken from a source-controlled file.

Signed releases publish `admin-targets.json` (the envelope) and
`admin-release-root.json` (the public root). `admin-release.json` remains a
byte-identical envelope alias during the independent-channel transition; it is
not an unsigned descriptor. Development-channel validation releases publish a
separate `go-mapi-admin-development-release-v1` manifest alongside the signed
MSI so the GitHub release, immutable URL, digest, provenance, and test signer
can be exercised without weakening the stable updater trust boundary.
