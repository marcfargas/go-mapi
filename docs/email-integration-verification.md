# Email integration verification (Ticket 472)

go-mapi currently supports Simple MAPI Send-To calls through its installed
system component and a running, signed-in user app. It creates Gmail drafts;
it does not send them. It does not handle mailto links or register a MAILTO
handler in Windows Default Apps. Possible mailto support is deferred to
Ticket 484 under separate acceptance.

## Record for every native run

Use an isolated Windows 10 or Windows 11 test machine in the supported range.
Record OS version/build, ordinary-user context, source commit, package identity
and channel, app/system component versions and compatibility, SHA256 of each
tested artifact, exact commands, and observed result. Use owned attachments and
an authorized test Gmail account. Keep account and machine details out of
shared reports. A development fixture, direct-DLL test, registry check or
successful MAPI return alone does not establish installed Send-To behavior.

Build the actual system, suite, direct/winget installer and MSIX test artifacts
with the existing `Justfile` and `scripts/build-wails.ps1`/package builders;
verify each with its existing artifact verifier. Do not modify published bytes.
The winget package uses the direct installer bytes, but record a separate
winget installation result. A sideloaded MSIX does not prove Store delivery.

## Native matrix

Repeat on Windows 10 and Windows 11 with suite and with each available per-user
channel paired with the required system component. Also run the app alone
without a system component. Mark every unavailable OS, channel, artifact, or
authorized-account row **unverified** with its reason; do not treat another
channel as a substitute.

1. Open the app as a fresh user and an existing user whose old
   `default_apps_prompted` value is true. Check signed-out and signed-in states,
   present/missing system component, keyboard and pointer open/close/reopen of
   “Email with Send To,” and the absence of a make-default action. Check that
   settings, auth, queue and startup preferences are preserved. For app-only,
   observe the existing missing-component installation/repair guidance.
2. Observe the Windows 10 Email/MAILTO picker or Windows 11 Default apps link
   type separately from Clients\\Mail provider registration. Record any legacy
   go-mapi entry as installed-state evidence. With an unrelated user-selected
   MAILTO handler, open a harmless mailto link before and after install, repair
   and uninstall. It must remain selected and functional. Never change
   UserChoice. Current packages are expected to add no go-mapi MAILTO handler.
3. With both components installed and the app running in manual draft mode,
   use Explorer **Send to > Mail recipient** (classic menu on Windows 11 if
   needed) with an owned, uniquely named attachment. Observe a newly
   correlated queue descriptor and app row, then create and inspect the Gmail
   draft, attachment content and queue cleanup. Repeat after repair. A real
   Send-To failure is an unresolved functional symptom.
4. Build both caller architectures with
   `pwsh -File src/interceptor/build.ps1 -Arch x64 -Config Release -Tests` and
   the same command with `-Arch x86`. As the ordinary app user, run each
   `installed_mapi_probe` from the corresponding `build-<arch>/bin` directory
   with `<owned-attachment-path> <unique-subject-marker>`. Record PE
   architecture and MAPI status separately from queue/UI/Gmail observations.
   The probe loads the Windows system mapi32.dll and always requests
   `MAPI_DIALOG`; it has no silent-send mode. Expected recipient is
   `SMTP:probe@example.invalid`, with body “Installed Simple MAPI dispatch
   test body. Review draft only.” Check those fields, marker and attachment in
   the resulting draft. Cancel any unexpected other-client compose window and
   record failed installed routing; never send. A success return alone is not
   a pass.
5. Exercise manual and automatic draft creation, dismissal, successful queue
   cleanup and existing failure/retry behavior. No mail is sent automatically.
   For lifecycle, reuse `src/installer/msi/tests/AdminLifecycle.Tests.ps1` and
   `CrossSkuLifecycle.Tests.ps1` as supplemental checks of install/repair/
   uninstall, both provider registry views, original provider restoration,
   coexistence and absence of association residue. Check per-user package
   removal does not take machine provider ownership or remove per-user data.

The old Phase 11 smoke runner covers a legacy package only. Its Send-To,
queue, UI and Gmail observations must be explicit; `-NoHumanPrompts` yields
incomplete evidence. `scripts/run-component-integration.ps1` loads a supplied
DLL directly and is supplemental producer/consumer evidence, not installed
Windows dispatch proof.
