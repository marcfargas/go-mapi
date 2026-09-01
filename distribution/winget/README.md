# winget publication

`MarcFargas.go-mapi` is the user app. It always points to the exact signed
standalone NSIS artifact from the immutable `app-v<version>` GitHub Release;
it never installs the Store package, admin MSI, or interceptor DLL.

The release workflow renders these templates, validates them, and submits an
update using a pinned WingetCreate release with
`WINGET_CREATE_GITHUB_TOKEN` from the protected release environment. The
token must be a classic PAT with `public_repo`. Submission only opens or
updates a PR; catalog availability is reported after external validation and
merge.
