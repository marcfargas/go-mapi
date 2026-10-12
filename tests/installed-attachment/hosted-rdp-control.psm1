function Initialize-Ticket569HostedRdpControlType {
    if ('Ticket569HostedRdpControl' -as [type]) { return }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
        throw 'Hosted RDP ActiveX control must be initialized on an STA thread'
    }

    Add-Type -AssemblyName System.ComponentModel.Primitives -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $references = @(
        [System.Windows.Forms.AxHost].Assembly.Location
        [System.ComponentModel.Component].Assembly.Location
    ) | Select-Object -Unique
    Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
public class Ticket569HostedRdpControl : AxHost {
 public Ticket569HostedRdpControl() : base(Type.GetTypeFromProgID("MsTscAx.MsTscAx.10").GUID.ToString("B")) {}
 public object ClientObject { get { return GetOcx(); } }
}
'@ -ReferencedAssemblies $references -ErrorAction Stop
}

Export-ModuleMember -Function Initialize-Ticket569HostedRdpControlType
