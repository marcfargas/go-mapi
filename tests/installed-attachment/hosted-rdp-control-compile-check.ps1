$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'The hosted RDP control compile check must run in STA'
}

Import-Module (Join-Path $PSScriptRoot 'hosted-rdp-control.psm1') -Force
Initialize-Ticket569HostedRdpControlType

$type = 'Ticket569HostedRdpControl' -as [type]
if (!$type -or $type.BaseType -ne [System.Windows.Forms.AxHost]) {
    throw 'The exact hosted AxHost helper did not compile with the expected base type'
}
Write-Output 'HOSTED_RDP_CONTROL_COMPILE_CHECK_PASSED'
