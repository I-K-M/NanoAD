# Run only in a disposable, standalone Windows Server Core build guest.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Inventory')]
param(
    [Parameter(ParameterSetName = 'Cleanup', Mandatory = $true)][switch]$Cleanup,
    [Parameter(ParameterSetName = 'Generalize', Mandatory = $true)][switch]$Generalize
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'Windows guest required.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevated PowerShell required.' }

$os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10
$computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10
$cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($cv.InstallationType -ne 'Server Core' -or $os.ProductType -ne 3 -or $computer.PartOfDomain -ne $false -or $computer.DomainRole -ne 2) {
    throw 'Refusing: standalone Windows Server Core required; never run against a domain member or DC.'
}
$features = @(Get-WindowsFeature)
$ad = $features | Where-Object Name -eq 'AD-Domain-Services'
if ($null -eq $ad -or $ad.Installed) { throw 'Refusing: AD DS must not be installed on the generalised base.' }

function Show-Inventory {
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($env:SystemRoot))
    $pagefiles = @(Get-CimInstance Win32_PageFileUsage -OperationTimeoutSec 10)
    [ordered]@{
        schema_version = 1
        captured_utc = [DateTime]::UtcNow.ToString('o')
        installation_type = $cv.InstallationType
        edition = $cv.EditionID
        build = $os.BuildNumber
        ubr = $cv.UBR
        version = $os.Version
        standalone = $true
        system_volume_total_bytes = [uint64]$drive.TotalSize
        system_volume_used_bytes = [uint64]($drive.TotalSize - $drive.TotalFreeSpace)
        configured_pagefile_mib = ($pagefiles | Measure-Object -Property AllocatedBaseSize -Sum).Sum
        installed_feature_count = @($features | Where-Object Installed).Count
    } | ConvertTo-Json -Depth 4
}
function Invoke-Dism {
    param([string]$Operation)
    & (Join-Path $env:SystemRoot 'System32\dism.exe') '/Online' '/Cleanup-Image' $Operation
    if ($LASTEXITCODE -ne 0) { throw "DISM $Operation failed or requires a restart: $LASTEXITCODE" }
}

Show-Inventory
Invoke-Dism '/AnalyzeComponentStore'
if ($Cleanup) {
    if ($PSCmdlet.ShouldProcess('disposable standalone Core guest', 'Supported component cleanup (no ResetBase)')) {
        Invoke-Dism '/StartComponentCleanup'
        Show-Inventory
        Invoke-Dism '/AnalyzeComponentStore'
    }
}
if ($Generalize) {
    if ($PSCmdlet.ShouldProcess('disposable standalone Core guest', 'Sysprep generalise, clear guest-specific state and shut down')) {
        $sysprep = Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe'
        $process = Start-Process -FilePath $sysprep -ArgumentList '/generalize','/oobe','/shutdown','/quiet' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Sysprep failed: $($process.ExitCode). Inspect Panther logs." }
        Write-Host 'Verify successful Sysprep shutdown on the host. Do not restart this base.'
    }
}
