$ErrorActionPreference='Stop'
# Compile the actual production-independent native helper without invoking a
# Windows kernel API on Linux. Its adapter below tests only safe projection.
$path=Join-Path $PSScriptRoot 'hosted-framework-job-security.psm1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
if($e.Count){throw 'Fixture Job security helper parse failed'}
$native=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('using System;')},$true))
if($native.Count -ne 1){throw 'Actual native helper source missing or ambiguous'}
Add-Type -TypeDefinition $native[0].Value.Replace('T569FrameworkJobSecurity','T569FrameworkJobSecurityCompile') -ErrorAction Stop
Add-Type @'
using System;
using System.ComponentModel;
public static class T569FrameworkJobSecurity {
 public static int SecurityError,IntegrityError,QueryError;
 public static string Integrity="S-1-16-8192";
 public static string ReadJobDaclAndLabel(IntPtr handle){if(handle!=new IntPtr(123))throw new Exception("secret-canary");if(SecurityError!=0)throw new Win32Exception(SecurityError,"secret-canary");return "D:P(A;;GA;;;SY)(A;;0x5;;;S-1-5-21-1-2-3-1001)S:(ML;;NW;;;HI)";}
 public static string ReadCurrentTokenIntegrity(){if(IntegrityError!=0)throw new Win32Exception(IntegrityError,"secret-canary");return Integrity;}
 public static int QueryOnlyJobOpen(string name){if(name!="Global\\Ticket569-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-recovery")throw new Exception("secret-canary");return QueryError;}
}
'@
foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$name='Global\Ticket569-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-recovery'
$r=Get-FrameworkRecoveryJobSecurity @{Handle=[IntPtr]123}
if($r.daclAndLabelSddl -cne 'D:P(A;;GA;;;SY)(A;;0x5;;;S-1-5-21-1-2-3-1001)S:(ML;;NW;;;HI)' -or $null -ne $r.errorCode){throw 'Owned handle security projection differs'}
[T569FrameworkJobSecurity]::SecurityError=5
$r=Get-FrameworkRecoveryJobSecurity @{Handle=[IntPtr]123}
if($null -ne $r.daclAndLabelSddl -or $r.errorCode -ne 5 -or (ConvertTo-Json $r).Contains('secret-canary')){throw 'Security read failure lost safe code or leaked message'}
foreach($case in @('query-success','query-denied','integrity-failed','unsafe-integrity')){
 [T569FrameworkJobSecurity]::Integrity='S-1-16-8192';[T569FrameworkJobSecurity]::IntegrityError=0;[T569FrameworkJobSecurity]::QueryError=0
 switch($case){query-denied {[T569FrameworkJobSecurity]::QueryError=5};integrity-failed {[T569FrameworkJobSecurity]::IntegrityError=5};unsafe-integrity {[T569FrameworkJobSecurity]::Integrity='secret-canary'}}
 $r=Get-FrameworkRecoveryJobAccess $name
 if((ConvertTo-Json $r).Contains('secret-canary')){throw 'Job access projection leaked native exception message'}
 if($r.queryOnlyErrorCode -ne $(if($case -ceq 'query-denied'){5}else{0})){throw 'Exact read-only Job open result changed'}
 if($case -in @('query-success','query-denied')){if($r.integritySID -cne 'S-1-16-8192' -or $null -ne $r.integrityErrorCode){throw 'Actual token SID projection differs'}}
 elseif($null -ne $r.integritySID){throw 'Failed/unsafe token integrity fabricated SID'}
 if($case -ceq 'integrity-failed' -and $r.integrityErrorCode -ne 5){throw 'Integrity failure omitted safe code'}
 Write-Output "FRAMEWORK_JOB_SECURITY_SAFE_PROJECTION case=$case;NATIVE_API_ADAPTER_WINDOWS_UNRUN"
}
# Keep this helper strictly observational: no creation/set/token adjustment API.
$source=[IO.File]::ReadAllText($path)
if($source -match 'SetKernelObjectSecurity|SetSecurityInfo|SetTokenInformation|AdjustTokenPrivileges|CreateJobObject|AssignProcessToJobObject'){throw 'Fixture security discriminator introduced a mutator'}
if(!$source.Contains('GetKernelObjectSecurity(handle,0x14') -or !$source.Contains('GetTokenInformation(identity.Token,25') -or !$source.Contains('OpenJobObjectW(0x4,false,name)') -or !$source.Contains('needed>65536') -or !$source.Contains('Marshal.FreeHGlobal(buffer)') -or !$source.Contains('CloseHandle(handle)')){throw 'Native helper lost exact read scope, allocation bound or cleanup'}
Write-Output 'FRAMEWORK_JOB_SECURITY_HELPER_COMPILED_AND_SAFE_PROJECTION_PASSED;ACTUAL_WINDOWS_DESCRIPTOR_TOKEN_QUERY_OPEN_UNRUN'
