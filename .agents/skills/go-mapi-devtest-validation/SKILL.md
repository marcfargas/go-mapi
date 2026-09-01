---
name: go-mapi-devtest-validation
description: Validate go-mapi installer, interceptor, and Wails desktop changes on an approved Azure DevTest Labs Windows VM. Use after the general DevTest workspace runbook, not for ordinary Go or frontend tests.
---

# go-mapi DevTest validation

Use this skill for live Windows acceptance when a change affects the MAPI
interceptor, machine-wide installer/elevation, installed product path, or
Wails/WebView2 integration.

First use `azure-devtest-labs-windows-workspace` for the VM, source snapshot,
private ingress, and RDPilot same-session rules. This skill adds only the
go-mapi acceptance boundary.

## Acceptance layers

Keep these independent; a pass in one does not substitute for another:

1. Build and exercise the interceptor for every supported caller bitness.
2. Run the repository's package and installer checks, including the
   machine-wide registration and prior-install cleanup paths.
3. Prove the installed interceptor writes the production local queue and that
   the user application watcher consumes it.
4. For desktop-impacting changes, prove the Wails/WebView2 path in the same
   interactive Windows session controlled by RDPilot.

The project supports x86 and x64 callers; this does not require a 32-bit
Windows guest.

## Evidence and boundary

Do not claim the lane validated from a fixture that writes queue JSON directly:
the installed interceptor-to-queue-to-watcher path must be observed.

Before any source export or acceptance claim, RDPilot must complete both its
connection handshake and its first perception request. On a timeout, follow
the general DevTest runbook's stop-and-diagnose path; do not use a Session 0
workaround or treat ordinary RDP/SSH connectivity as equivalent evidence.

Record only sanitized test outcomes, artifact identifiers, and the
same-session control result. Leave VM lifecycle decisions to
`azure-devtest-labs-lifecycle`.
