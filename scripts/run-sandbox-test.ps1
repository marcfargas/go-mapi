#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Smoke,
    [string]$InputDirectory,
    [string]$ScriptPath,
    [ValidateSet('System', 'ExistingLogin')][string]$RunAs = 'System',
    [switch]$RunAsExistingLogin,
    [switch]$Connect,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
    [string]$EvidenceRoot = (Join-Path $env:LOCALAPPDATA 'agent-work/retained/go-mapi/sandbox')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SandboxRunner.ps1')
Invoke-GoMapiSandboxTest @PSBoundParameters
