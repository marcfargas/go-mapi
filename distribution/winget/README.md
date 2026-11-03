# winget publication

`MarcFargas.go-mapi` is the user app. It always points to the exact signed
standalone NSIS artifact from the immutable `v<version>` GitHub Release;
it never installs the Store package, admin MSI, or interceptor DLL.

After publication of an accepted stable unified release, the release workflow
validates its public bytes against `release.json` and submits an update using
a pinned WingetCreate release. WingetCreate generates the submission manifests
from the installer URL and version; no YAML files are published as release assets.
The workflow uses
`WINGET_CREATE_GITHUB_TOKEN` from the protected release environment. The
token must be a classic PAT with `public_repo`. Submission only opens or
updates a PR; catalog availability is reported after external validation and
merge.
