---
name: go-mapi-devtest-setup
description: Prepare an approved Azure DevTest Labs Windows lease for go-mapi native build, installer, and SSH-driven validation. Use before go-mapi Windows acceptance; not for Azure platform or formula changes.
---

# go-mapi DevTest setup

Use this project companion after the general `azure-devtest-labs` lifecycle
workflow has supplied an owned VM and before `go-mapi-devtest-validation`.
It records the lease-local setup observed for the current v4 work, not a
request to alter the shared Azure platform.

## Formula and access

- The current approved formulas (`two-vm-e2e`, `two-vm-e2e-v4`, and
  `two-vm-e2e-v4-public`) contain no DevTest artifacts. They select the base
  Windows image, network configuration, and expiry; do not assume a compiler
  toolchain is preinstalled.
- Create or change a formula, artifact, or image only with separate Azure
  platform authority. For an isolated validation lease, install tools locally
  and record the versions/result.
- Use native OpenSSH for automation. Record whether the host identity was
  verified. If the caller explicitly authorizes relaxed host checking for a
  disposable lease, record it as **unverified**; never imply it was pinned.
- Do not require RDPilot for non-interactive installer or interceptor
  validation. Wails/WebView2 CDP validation does require a logged-on Windows
  desktop session: SSH/Run Command execute in Session 0, where WebView2 may
  create an environment but Wails cannot create its UI surface.
- For that desktop lane, use RDPilot and require a successful connection and
  first perception before source transfer. If perception times out after
  connect, disconnect, collect the approved read-only DVC diagnostic, and do
  not retry, use ordinary RDP as a substitute, or continue the desktop lane.

## Source transfer

Select the precise worktree. Create a BuildKit context with an external
Dockerfile containing only `FROM scratch` and `COPY . /workspace/`, honoring
the worktree's `.dockerignore`. Transfer a deterministic archive and sorted
content manifest over SSH, then prove the archive and extracted-file hashes.
Windows reparse-point links (for example npm workspace links) are not regular
files; exclude them when comparing against a Linux regular-file manifest.

## Lease-local toolchain

The native interceptor build needs all of the following:

- Go, Node LTS, and .NET SDK. Chocolatey has been a reliable lease-local path
  on the base image.
- `mingw-mstorsjo-llvm-ucrt`, installed through the lease user's Scoop path;
  the build script requires its triple-prefixed x64 and x86 clang drivers.
- CMake and Ninja. Install whichever route leaves `cmake` and `ninja` on the
  lease user's PATH; verify their resolved paths before building.

Large Scoop archives can outlive a short SSH command. If the package download
completes but extraction is interrupted, run the install from an owned
background PowerShell process and poll its local log/package state. Do not
start overlapping installs for the same package or delete a locked archive.

Verify the actual executable paths and versions before running the repository
scripts; a fresh SSH session may not inherit updated machine/user PATH values.

## Validation handoff

Run the repository scripts, not substitute ad hoc compilation:

1. `src/interceptor/build.ps1` plus x64/x86 harness and CTest lanes.
2. Interceptor release verification, admin MSI build/verification, and admin
   lifecycle tests.
3. Wails/WebView2 e2e through its local CDP harness where the test command
   supports the current SSH session.

Keep VM identifiers, endpoints, private keys, passwords, and logs containing
credentials out of Git and handoff reports. Remove only lease-owned temporary
archives, remote workspace state, ingress rules, and VM resources through the
recorded lifecycle cleanup path.
