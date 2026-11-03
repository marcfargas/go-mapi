function Invoke-ExplorerSendTo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][string]$EvidenceDirectory
    )
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
    if (-not ('ExplorerSendToWindow' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ExplorerSendToWindow {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
}
'@
    }
    $Folder = (Get-Item -LiteralPath $Folder -ErrorAction Stop).FullName.TrimEnd('\')
    New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
    $record = [ordered]@{
        passed = $false; folder = $Folder; expectedNames = @($ExpectedNames)
        selectedPaths = @(); explorer = $null; pid = $null; session = $null; ownerSid = $null
        actions = @(); menus = @(); menuSnapshot = @(); modernMenuSnapshot = @()
        triggerAttempted = $false; invoked = $false; windowClosed = $false
        error = $null; cleanupError = $null
    }
    $shell = $null; $window = $null; $ownedHandle = [IntPtr]::Zero
    function Save-ExplorerEvidence {
        [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'explorer.json'),
            ($record | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    }
    function Find-FolderWindows {
        @($shell.Windows() | Where-Object {
            try { $_.FullName -like '*\explorer.exe' -and $_.Document.Folder.Self.Path.TrimEnd('\') -ieq $Folder } catch { $false }
        })
    }
    function Get-ExplorerRoots {
        # Modern menus live inside a window or XAML popup; classic menus can
        # be desktop siblings. Scope every root to the selected Explorer PID.
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$record.explorer.pid)
        @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition))
    }
    function Find-MenuItem([string]$Name) {
        $found = @()
        $snapshot = @()
        $condition = [System.Windows.Automation.OrCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
        foreach ($menu in @(Get-ExplorerRoots)) {
            $root = $menu.Current
            if ($root.ProcessId -ne $record.explorer.pid) { throw 'Explorer automation root identity changed' }
            foreach ($item in @($menu.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition))) {
                $current = $item.Current
                $bounds = $current.BoundingRectangle
                $runtimeId = @($item.GetRuntimeId()) -join '.'
                $snapshot += @{name=$current.Name; enabled=$current.IsEnabled; offscreen=$current.IsOffscreen; process=$current.ProcessId; rootProcess=$root.ProcessId; rootHandle=$root.NativeWindowHandle; class=$current.ClassName; type=$current.ControlType.ProgrammaticName;runtimeId=$runtimeId;bounds=@($bounds.X,$bounds.Y,$bounds.Width,$bounds.Height)}
                # XAML menu peers report PID 0; they inherit this verified root.
                if ($current.ProcessId -in @(0,$record.explorer.pid) -and !$current.IsOffscreen -and $current.IsEnabled -and $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and ($current.Name -replace '&','').Trim() -ceq $Name) {
                    if (!@($found | Where-Object { [System.Windows.Automation.Automation]::Compare($_,$item) }).Count) { $found += $item }
                }
            }
        }
        $record.menuSnapshot = $snapshot
        if ($found.Count -gt 1) { throw ('Ambiguous Explorer menu item: ' + $Name) }
        if ($found.Count -eq 1) { return $found[0] }
    }
    function Wait-MenuItem([string]$Name) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $item = Find-MenuItem $Name
            if ($item) { Save-ExplorerEvidence; return $item }
            if ([DateTime]::UtcNow -ge $deadline) { throw ('English Explorer menu item did not appear: ' + $Name) }
            Start-Sleep -Milliseconds 150
        } while ($true)
    }
    try {
        if ((Get-UICulture).Name -notmatch '^en($|-)') { throw 'Explorer SendTo automation currently requires an English Windows guest' }
        if ($ExpectedNames.Count -ne 2 -or @($ExpectedNames | Select-Object -Unique).Count -ne 2) { throw 'Select exactly two distinct attachment names' }
        foreach ($name in $ExpectedNames) {
            if ([IO.Path]::GetFileName($name) -cne $name -or !(Test-Path -LiteralPath (Join-Path $Folder $name) -PathType Leaf)) { throw ('Invalid owned attachment name: ' + $name) }
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $session = (Get-Process -Id $PID).SessionId
        if ($session -le 0 -or ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Explorer SendTo requires the ordinary desktop user' }
        $shell = New-Object -ComObject Shell.Application
        if (@(Find-FolderWindows).Count) { throw 'An Explorer window already displays the selected folder; ownership is not established' }
        $shell.Explore($Folder)
        $record.actions += 'Open Explorer for the unique attachment folder'
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            $matches = @(Find-FolderWindows)
            if ($matches.Count -gt 1) { throw 'Multiple Explorer windows display the selected folder' }
            if ($matches.Count -eq 1) { $window = $matches[0]; break }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Explorer did not open the owned attachment folder' }
            Start-Sleep -Milliseconds 150
        } while ($true)
        $ownedHandle = [IntPtr][long]$window.HWND
        [uint32]$explorerProcess = 0
        $null = [ExplorerSendToWindow]::GetWindowThreadProcessId($ownedHandle, [ref]$explorerProcess)
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $explorerProcess)
        if (!$process -or $process.Name -ine 'explorer.exe' -or $process.SessionId -ne $session) { throw 'Selected window is not Explorer in the caller desktop session' }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0 -or $owner.Sid -cne $identity.User.Value) { throw 'Explorer owner differs from the caller' }
        $record.explorer = @{pid=[int]$explorerProcess; session=$session; sid=$owner.Sid; handle=$ownedHandle.ToInt64()}
        $record.pid = [int]$explorerProcess
        $record.session = $session
        $record.ownerSid = $owner.Sid
        # SVSI_SELECT | DESELECTOTHERS | ENSUREVISIBLE | FOCUSED, then add the second file.
        $first = $true
        foreach ($name in $ExpectedNames) {
            $item = $window.Document.Folder.ParseName($name)
            if (!$item -or $item.Path -ine (Join-Path $Folder $name)) { throw 'Explorer resolved an unexpected attachment path' }
            $flags = if ($first) { 29 } else { 9 }
            $window.Document.SelectItem($item, $flags)
            $first = $false
        }
        $record.selectedPaths = @($window.Document.SelectedItems() | ForEach-Object { $_.Path })
        $expectedPaths = @($ExpectedNames | ForEach-Object { Join-Path $Folder $_ } | Sort-Object)
        if ($record.selectedPaths.Count -ne 2 -or (($record.selectedPaths | Sort-Object) -join "`n") -ine ($expectedPaths -join "`n")) { throw 'Explorer selection differs from the exact two owned attachment paths' }
        $record.actions += 'Verify the exact two selected attachment paths'
        $null = [ExplorerSendToWindow]::SetForegroundWindow($ownedHandle)
        # Explorer's top-level window is not a keyboard-focusable UIA element.
        # SelectItem already focused the file; activate that exact window.
        if ([ExplorerSendToWindow]::GetForegroundWindow() -ne $ownedHandle) { throw 'Could not focus the owned Explorer window' }
        [System.Windows.Forms.SendKeys]::SendWait('+{F10}')
        $record.actions += 'Shift+F10 in the owned Explorer window'
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            if (Find-MenuItem 'Send to') { break }
            $modern = Find-MenuItem 'Show more options'
            if ($modern) {
                $record.actions += 'Invoke Show more options in the same Explorer process'
                $record.modernMenuSnapshot = $record.menuSnapshot
                Save-ExplorerEvidence
                $modernInvoke = $null
                if (!$modern.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$modernInvoke)) { throw 'Show more options lacks a UIAutomation invoke action' }
                $modernInvoke.Invoke()
                break
            }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Neither classic nor modern Explorer context menu appeared' }
            Start-Sleep -Milliseconds 150
        } while ($true)
        $sendTo = Wait-MenuItem 'Send to'
        $record.menus += 'Send to'
        $pattern = $null
        if ($sendTo.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
            $pattern.Expand()
        } else {
            $sendTo.SetFocus()
            [System.Windows.Forms.SendKeys]::SendWait('{RIGHT}')
        }
        $record.actions += 'Expand Send to in the same Explorer process menu'
        $recipient = Wait-MenuItem 'Mail recipient'
        $record.menus += 'Mail recipient'
        $invoke = $null
        if (!$recipient.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) { throw 'Mail recipient does not expose a UIAutomation invoke action' }
        # Record intent before this single effect. Never retry a possibly completed handoff.
        $record.triggerAttempted = $true
        $record.actions += 'Invoke Mail recipient exactly once'
        Save-ExplorerEvidence
        $invoke.Invoke()
        $record.invoked = $true
        $record.passed = $true
    } catch {
        $record.error = $_.Exception.Message
        try {
            Add-Type -AssemblyName System.Drawing
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
                $bitmap.Save((Join-Path $EvidenceDirectory 'explorer-failure.png'), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $graphics.Dispose(); $bitmap.Dispose() }
        } catch { $record.actions += ('Failure screenshot unavailable: ' + $_.Exception.Message) }
    } finally {
        if ($window) {
            try {
                # The retained COM window is the only cleanup target; never stop Explorer.
                if ([long]$window.HWND -ne $ownedHandle.ToInt64() -or $window.Document.Folder.Self.Path.TrimEnd('\') -ine $Folder) { throw 'Owned Explorer window identity changed before close' }
                if ([ExplorerSendToWindow]::GetForegroundWindow() -eq $ownedHandle) {
                    # A failure before Invoke can leave a modal context menu open.
                    [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
                }
                $window.Quit()
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                do {
                    $remaining = @(Find-FolderWindows | Where-Object { [long]$_.HWND -eq $ownedHandle.ToInt64() })
                    if (!$remaining.Count) { $record.windowClosed = $true; break }
                    if ([DateTime]::UtcNow -ge $deadline) { throw 'Owned Explorer window did not close' }
                    Start-Sleep -Milliseconds 150
                } while ($true)
            } catch { $record.cleanupError = $_.Exception.Message }
        }
        $record.passed = $record.passed -and $record.windowClosed -and !$record.cleanupError
        Save-ExplorerEvidence
    }
    if (!$record.passed) { throw ('Explorer SendTo failed; inspect explorer.json: ' + $record.error + ' ' + $record.cleanupError) }
    [pscustomobject]$record
}
