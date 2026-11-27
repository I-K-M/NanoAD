# Pure identity test; no Windows services or hypervisor required.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../provisioning/windows/ad-core/Common.ps1')
$uuid = [Guid]'01234567-89ab-cdef-0123-456789abcdef'
$id = Get-NanoADIdentity -LabId $uuid
if ($id.ComputerName -ne 'DC-0123456789AB' -or $id.NetbiosName -ne 'NAD0123456789AB' -or
    $id.DomainName -ne 'lab-0123456789abcdef0123456789abcdef.nanoad.test' -or
    $id.BaseDn -ne 'DC=lab-0123456789abcdef0123456789abcdef,DC=nanoad,DC=test' -or
    $id.ComputerName.Length -gt 15 -or $id.NetbiosName.Length -gt 15 -or
    $id.ComputerName -eq $id.NetbiosName) { throw 'Invalid lab identity.' }
$next = Get-NanoADIdentity -LabId ([Guid]'fedcba98-7654-3210-fedc-ba9876543210')
if ($id.DomainName -eq $next.DomainName -or $id.ComputerName -eq $next.ComputerName) { throw 'Identity collision in test.' }
$rejected = $false
try { $null = Get-NanoADIdentity -LabId ([Guid]::Empty) } catch { $rejected = $true }
if (-not $rejected) { throw 'Empty UUID was accepted.' }
Write-Host 'Identity tests passed; no guest integration exercised.'
