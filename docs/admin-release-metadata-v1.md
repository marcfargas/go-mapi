# Admin release metadata v1

The app's optional, administrator-authorized interceptor repair checks a fixed,
build-configured HTTPS metadata URL. A stable release publishes a plain
`admin-targets.json` document with `schema: "go-mapi-admin-targets-v1"`.
The `admin-release.json` asset is a byte-identical alias for existing release
coordination. Development validation manifests use a separate schema and are
not accepted as repair targets.

The target records a canonical version, app compatibility range, queue protocol,
positive release sequence, issue and expiry timestamps, immutable versioned MSI
URL, byte size and SHA-256 digest. The app rejects malformed, expired,
incompatible or replayed targets before download. The metadata URL and artifact
origin are fixed in the release build; UI input cannot replace either. The app
streams the MSI into protected staging and checks size and hash. Windows then
makes the sole artifact signature decision on that staged file before the
installer handoff. No application-managed signing root or publisher policy is
embedded in the app.

The protected `artifact-signing` GitHub Environment and Azure Artifact Signing
OIDC configuration sign the actual PE and MSI files. Stable publication checks
the MSI's Authenticode and timestamp proof. The workflow records the final MSI
hash and size into plain metadata and retains the GitHub run ID as the release
sequence. Explicit admin consent and UAC remain required for initial bootstrap
and repair. A user action does not initiate automatic app replacement.
