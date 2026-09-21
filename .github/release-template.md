## go-mapi component vX.Y.Z

### Channel

- Component: user / system
- Release line: development / stable
- Distribution: GitHub / Microsoft Store flight / WinGet target
- Promotion source (stable releases): `X.Y.Z-beta.N`

Development releases use odd major versions with an explicit `alpha`, `beta`,
or `nightly` prerelease identifier. Stable releases use the corresponding even
major without a prerelease identifier.

### Changes

- <!-- user-visible change -->

### Verification

- [ ] Artifact versions match the tag and component manifest
- [ ] All executable payloads are signed and signatures are verified
- [ ] Targeted publication and clean-machine installation passed
- [ ] Native x86 and x64 MAPI producers reached the real user-component queue consumer
- [ ] Upgrade and rollback behavior passed for this channel
- [ ] Stable only: the corresponding odd-major candidate passed promotion review

### System requirements

- Windows 10 (22H2) or Windows 11
- Microsoft Edge WebView2 Evergreen Runtime — auto-bootstrapped by the installer if missing
- Gmail or Google Workspace account

### License

LGPL-3.0-or-later — see [LICENSE](https://github.com/marcfargas/go-mapi/blob/develop/LICENSE).

---

Full docs: [README](https://github.com/marcfargas/go-mapi/blob/develop/README.md).
