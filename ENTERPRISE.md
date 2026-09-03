# go-mapi for IT Administrators

Audience: Windows / IT admins deploying go-mapi at scale — RDS, Citrix,
managed desktops, group policy.

## At a glance

**Operational facts**

- Single-file NSIS installer (`go-mapi-setup.exe`) — All Users only, no MSI
- Silent install via `/S`; optional auto-update Scheduled Task via `/AUTOUPDATE=1`
- ~40–50 MB RAM per signed-in session (idle, after 10 min — see *RAM sizing* below)
- SHA-256 checksums published with every release (`SHA256SUMS.txt`)
- Per-user OAuth tokens in Windows Credential Manager (DPAPI-scoped)
- Outbound network: Gmail API + Google OAuth + `go-mapi.app` (update checks);
  GitHub release downloads occur only after an explicit update action.

**Positioning**

- LGPL-3.0-or-later — FOSS, no per-seat licensing, source on GitHub
- Privacy-minimized first-party aggregate update statistics; no email/content
  retention or per-install tracking

## Code signing status

**v3.0.0 is unsigned.** The release pipeline supports SignPath.io OSS
signing, but v3.0.0 was published from a runner without the SignPath
secrets configured and used the unsigned `staged/` build path.

Practical consequences for managed deployments:

- **SmartScreen** will warn users on first interactive run. The dismissal
  flow is **More info → Run anyway**. Silent installs (`/S`) bypass the
  SmartScreen dialog because there is no interactive shell to display it.
- **Microsoft Defender Application Control / WDAC** policies that require
  signed binaries will block go-mapi. You'll need to allow the binary by
  hash, by file path, or by publisher (not applicable while unsigned).
- **AppLocker** Publisher rules are not usable while unsigned; use Hash
  rules against the SHA-256 in `SHA256SUMS.txt`, or Path rules anchored
  at `%ProgramFiles%\go-mapi\`.

To suppress SmartScreen warnings for managed deployments:

- **Group Policy:** `Computer Configuration → Administrative Templates →
  Windows Components → File Explorer → Configure Windows Defender
  SmartScreen` — set to *Disable* or *Warn but allow* per your policy.
- **Intune (Win32 app):** pre-stage the installer via the Intune Win32 app
  pipeline; the trust override at deployment time avoids the per-user
  SmartScreen prompt.
- **GPO file allow-list** (per-binary): use Software Restriction Policies
  or AppLocker Hash rules against the published `SHA256SUMS.txt` hash.

A future signed release will replace this section with verification
guidance (Authenticode chain, `Get-AuthenticodeSignature` snippet).

## Install modes

### All Users (the only mode)

`go-mapi-setup.exe` is **All Users only**. go-mapi registers itself as the
machine-wide MAPI handler under `HKLM\SOFTWARE\Clients\Mail\go-mapi`, which is
inherently machine-wide. There is no per-user install path.

The installer requires UAC elevation. Run as an administrator or via a
managed-deployment context that elevates.

Default install directory: `%ProgramFiles%\go-mapi` (64-bit).
The 32-bit MAPI DLL is placed separately at `%ProgramFiles(x86)%\go-mapi`
so that both 32-bit and 64-bit MAPI callers are routed correctly.

Registry footprint:
- `HKLM\SOFTWARE\Clients\Mail\go-mapi` (native/64-bit MAPI registration)
- `HKLM\SOFTWARE\WOW6432Node\Clients\Mail\go-mapi` (32-bit MAPI registration)
- `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi` (Add/Remove Programs)

The installer backs up the previous default mail client name to
`%ProgramData%\go-mapi\uninst\previous-mail-client.json` and restores it on
uninstall.

## Silent install

Silent install with all defaults (no automatic updates):

```
go-mapi-setup.exe /S
```

Silent install to a custom path:

```
go-mapi-setup.exe /S /D=C:\Program Files\go-mapi
```

> Note: `/D` must be the last parameter and must not be quoted even if the
> path contains spaces (NSIS restriction).

Enable the automatic-update Scheduled Task at install time:

```
go-mapi-setup.exe /S /AUTOUPDATE=1
```

The installer is idempotent — running it over an existing install upgrades
in place (the previous mail client backup is preserved across upgrades).

### Exit codes

NSIS uses standard process exit codes. The installer issues `Abort` on
the failure paths below, which translates to a non-zero exit code; success
is `0`.

| Exit code | Meaning | Source |
|---|---|---|
| `0` | Install completed successfully | NSIS default on `SectionEnd` |
| `1` | User cancelled the wizard, or interactive `EnsureAppNotRunning` cancelled | NSIS default on `Quit`/`Abort` |
| `2` | Installation failed (NSIS internal error — file copy, registry write, script error) | NSIS default for `SetErrorLevel 2` and runtime aborts |

The installer's explicit `Abort` paths (interactive cancel of "go-mapi
already running" prompt; `go-mapi.exe` still running after a 10-second
graceful-close poll on silent install) surface as exit `1` and exit `2`
respectively, matching NSIS conventions. SCCM / Intune detection rules
should treat any non-zero exit as install failure and key the success
detection off the `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi`
key existing after the run.

Log output goes to the Windows installer log rather than a file; add
`/LOG=C:\path\to\install.log` if your deployment tooling needs a log file.

## Automatic updates

When installed with `/AUTOUPDATE=1` (or with the "Enable automatic updates"
checkbox ticked during an interactive install), the installer registers a
Windows Scheduled Task:

| Property | Value |
|---|---|
| Task name | `go-mapi Auto Update` |
| Path | `\go-mapi Auto Update` (root of Task Scheduler) |
| Run as | `SYSTEM` (no per-user credential, no logon required) |
| Schedule | Daily 03:00 with ±30 minute random delay |
| Also runs | At system startup (5 minute delay) |
| Network | `RunOnlyIfNetworkAvailable=true` (skips offline runs) |
| Catch-up | `StartWhenAvailable=true` (runs after wake/reboot if missed) |
| Concurrency | `MultipleInstancesPolicy=IgnoreNew` (no overlapping runs) |
| Time limit | 12 hours per run (`ExecutionTimeLimit=PT12H`) |

The task fires `go-mapi.exe --update-check-silent`, which fetches the latest
release, verifies the SHA-256 digest before writing anything, and atomically
replaces the binary. The running interactive go-mapi instance keeps working
until the next launch; the task does **not** forcibly restart it.

Update logs are written to `%ProgramData%\go-mapi\updates\update.log`
(admin-readable; no PII, no message content).

### What happens when an update lands during a user session

The silent updater (`src/app/updates_silent.go`) follows a verify-then-swap
pattern designed to be safe against running user sessions:

1. **Stage:** assets are downloaded into
   `%ProgramData%\go-mapi\updates\staging\` and SHA-256-verified
   in-memory **before** any byte hits the install directory.
2. **Atomic swap (NTFS rename-while-running):** for each of `go-mapi.exe`,
   `go-mapi-x64.dll`, and `go-mapi-x86.dll`, the updater performs a
   two-step rename — `installed → installed.old.<pid>` followed by
   `staged → installed`. This uses `MoveFileEx` and works while the
   running process holds the file open (NTFS allows rename of a file
   under loader lock; deletion would be blocked).
3. **In-memory binary handoff:** any currently running `go-mapi.exe` keeps
   running from the loader-pinned old binary in memory. New launches —
   the next user session, the next time the user clicks the tray icon
   after a quit, or the next reboot — pick up the new binary. **No user
   process is killed** by the updater (D-13 in the silent-updater plan
   makes this explicit; the retry loop is the back-pressure, not
   `WM_CLOSE`).
4. **Orphan cleanup:** the `*.old.<pid>` files are removed on the next
   silent-update cycle, after the running process has exited.
5. **Retry budget:** if a swap fails (`ERROR_SHARING_VIOLATION` from
   Defender / a filter driver briefly holding the file), the updater
   retries with exponential backoff up to a 12-hour wall clock; the next
   Scheduled Task trigger picks up where it left off.

Operational impact: a user who is signed in and idle when an update
lands sees nothing. The next time they launch go-mapi (after quitting
from the tray, after reboot, or at next logon), they get the new
version. There is no forced re-login or restart.

Admin debug log: `%ProgramData%\go-mapi\updates\update.log` (capped at
1 MB, rotated by truncation; records version transitions, swap
attempts, retry counts, verify success/failure — no message content,
no credentials, no hex digests for failed verifications).

### Managing the Scheduled Task

Disable (e.g. during maintenance windows):

```
schtasks /change /tn "go-mapi Auto Update" /disable
```

Re-enable:

```
schtasks /change /tn "go-mapi Auto Update" /enable
```

Force an immediate update check:

```
schtasks /run /tn "go-mapi Auto Update"
```

Query last run and status:

```
schtasks /query /tn "go-mapi Auto Update" /v /fo LIST
```

The task is removed automatically by the go-mapi uninstaller.

To add automatic updates to an existing notify-only install, re-run the
installer over the existing install with `/AUTOUPDATE=1` — idempotent.

To disable automatic updates on a managed host, either install with
`/AUTOUPDATE=0` (the default) or delete the task after install:

```
schtasks /delete /tn "go-mapi Auto Update" /f
```

## Verify download integrity

Every release publishes `SHA256SUMS.txt` alongside the installer:

```
https://github.com/marcfargas/go-mapi/releases/latest/download/SHA256SUMS.txt
```

Format follows the `sha256sum` convention (`<lowercase-hex>  <filename>`).
The automatic updater verifies downloads before applying them. For manual
verification before deployment (returns success or `throws` on mismatch —
suitable for use in a deployment pipeline):

```powershell
$base = "https://github.com/marcfargas/go-mapi/releases/download/vX.Y.Z"
$sums = (Invoke-WebRequest "$base/SHA256SUMS.txt").Content
$expected = ($sums -split "`n" |
    Where-Object { $_ -match 'go-mapi-setup\.exe' } |
    ForEach-Object { ($_ -split '\s+')[0] })
$actual = (Get-FileHash .\go-mapi-setup.exe -Algorithm SHA256).Hash.ToLower()
if ($actual -eq $expected) {
    Write-Output "OK ($actual)"
} else {
    throw "Checksum mismatch: expected $expected, got $actual"
}
```

Replace `vX.Y.Z` with the tagged release you're verifying. The script
exits non-zero (via `throw`) on mismatch — wire this into your SCCM /
Intune pre-install step.

## Mass deployment

go-mapi uses a standard NSIS installer with a silent mode and a documented
registry footprint, which makes it compatible with most Windows software
distribution tooling:

- **Intune / SCCM**: deploy `go-mapi-setup.exe /S` as a Win32 app. Detection
  rule: key `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi`
  exists. Treat any non-zero exit code as failure (see *Exit codes* above).
- **Group Policy (Software Installation)**: NSIS produces an EXE, not an MSI.
  Use a GP startup script or a third-party EXE-to-MSI wrapper if your policy
  requires MSI format.
- **Chocolatey / Scoop**: no official package yet. Use the GitHub Releases URL
  directly in your internal feed.

## Privacy posture

go-mapi makes network calls only to:

- `https://go-mapi.app/api/updates/v1/check` (an update check when enabled or
  explicitly requested) and a versioned `go-mapi.app` download route after an
  explicit update action; that route redirects to the signed GitHub artifact
- Google OAuth endpoints (sign-in and token refresh)
- Gmail API (`https://gmail.googleapis.com/`) — only when the user is signed in

The update service records daily aggregate counts for app version,
distribution channel, operating system, result, and Cloudflare-derived country
and first-level area. It stores no raw application events, install identifier,
cookies, application-level IP/user-agent values, account data, email data, or
interceptor-version telemetry; low-count regional cells aggregate to country
and counters expire after 12 months. Email content is never stored outside of
Gmail's own API. The silent-update log at `%ProgramData%\go-mapi\updates\update.log`
records version transitions and download success/failure only — no message
bodies, recipient data, or credential material.

Credential storage: each user's OAuth tokens are stored in the Windows
Credential Manager (DPAPI-scoped, per user). go-mapi never stores tokens in
shared locations.

## RAM sizing

The "~40–50 MB RAM per session" figure is measured idle, signed-in, with
the tray window hidden, after 10 minutes of running on Windows 11 22H2
(working set, `Get-Process go-mapi`). Memory grows modestly during draft
creation and returns to baseline once the draft is posted to Gmail. There
is no observed long-running growth — the watcher and OAuth refresh paths
are stateless w.r.t. heap retention.

For RDS / Citrix capacity planning, treat 50 MB / concurrent signed-in
session as a working ceiling. Sessions that have not yet signed in (the
first-launch SignInScreen state) consume noticeably less.

## Limitations

### Multi-user / RDS hosts

The uninstaller scrubs the uninstalling admin's profile and all machine-wide
locations (`HKLM\SOFTWARE\Clients\Mail\go-mapi`, `%ProgramFiles%\go-mapi\`,
`%ProgramData%\go-mapi\`, and the Scheduled Task). It does **not** enumerate
every user profile on the host.

Residue that persists per user after uninstall:
- `%APPDATA%\go-mapi\` (settings, log) — per user, not touched by the uninstaller
- Windows Credential Manager target `go-mapi:oauth-tokens` — per user (DPAPI-scoped)

**Is the residue harmful?** No. The Credential Manager entry holds a
DPAPI-encrypted Google refresh token scoped to that user's profile. Without
the matching go-mapi binary on the host, the token has no privileged
caller; without that user's interactive logon, DPAPI will not decrypt it.
Leaving the residue in place after uninstall does not grant access to the
user's Gmail account — Google will rotate / revoke unused refresh tokens
on its own schedule. The `%APPDATA%\go-mapi\` residue is a settings file
and a log; neither contains message content or credentials.

If your security policy requires per-user cleanup anyway, the most
operationally tractable patterns on RDS / Citrix are:

- **At-logon scheduled task (per user):** deploy a logon-triggered task
  via GPO that runs:
  ```powershell
  Remove-Item -Recurse -Force "$env:APPDATA\go-mapi" -ErrorAction SilentlyContinue
  cmdkey /list:go-mapi:oauth-tokens 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { cmdkey /delete:go-mapi:oauth-tokens | Out-Null }
  ```
  This runs in the user's own session context, so DPAPI and Credential
  Manager are reachable without impersonation.
- **Off-session impersonation** (e.g. `psexec -i -s -u <user>`) is
  possible but operationally expensive on a 60-host farm and is generally
  not worth the effort given the residue is harmless.

### RDS firewall loopback

go-mapi's OAuth sign-in opens a short-lived loopback listener on `127.0.0.1`
with an ephemeral port. The installer creates a Windows Firewall inbound rule
(`go-mapi OAuth loopback`, scoped to the binary) to suppress the first-bind
consent prompt. On RDS hosts, that prompt appears on the server console (not in
the user's RDP session) if the rule is absent or blocked by group policy. If
your GPO blocks `netsh advfirewall` writes, pre-create the rule via policy
before deploying go-mapi.

The exact rule the installer creates is:

```
netsh advfirewall firewall add rule ^
  name="go-mapi OAuth loopback" ^
  dir=in ^
  program="%ProgramFiles%\go-mapi\go-mapi.exe" ^
  action=allow ^
  profile=any
```

Translated to PowerShell `New-NetFirewallRule` / GPO equivalents:

| Property | Value |
|---|---|
| Name / DisplayName | `go-mapi OAuth loopback` |
| Direction | Inbound |
| Action | Allow |
| Profile | Any (Domain + Private + Public) |
| Program | `%ProgramFiles%\go-mapi\go-mapi.exe` (full path required by GPO; resolve `%ProgramFiles%` to `C:\Program Files` if your policy editor doesn't expand) |
| Protocol | Any (the rule is program-scoped, not protocol-scoped) |
| Local port | Any (the OAuth listener binds an ephemeral port on `127.0.0.1`) |
| Remote address | Any (loopback is not enforced at firewall layer; the binary itself binds `127.0.0.1` only) |

PowerShell equivalent for GPO startup scripts or pre-staging:

```powershell
New-NetFirewallRule `
  -DisplayName "go-mapi OAuth loopback" `
  -Direction Inbound `
  -Action Allow `
  -Program "$env:ProgramFiles\go-mapi\go-mapi.exe" `
  -Profile Any
```

Pre-creating the rule via GPO before go-mapi is deployed avoids the
first-bind UI prompt entirely; the installer's own `netsh` call becomes a
no-op (the rule already exists with the same name) and a non-fatal
non-zero return is logged but ignored.

### No MSI

The installer is an NSIS EXE. There is no MSI wrapper. This is a known
limitation for GPO-based Software Installation policies.

## Support

[GitHub Issues](https://github.com/marcfargas/go-mapi/issues)

---

For end-user installation and usage, see [README.md](README.md).
For contributors and maintainers, see [DEVELOPMENT.md](DEVELOPMENT.md).
