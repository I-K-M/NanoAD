# Read-only host inventory. Windows PowerShell 5.1 or later.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LabPath,
    [string]$MediaPath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'A Windows reference host is required.' }
if ($ExpectedSha256 -and -not $MediaPath) { throw 'ExpectedSha256 requires MediaPath.' }

$warnings = [System.Collections.Generic.List[string]]::new()
$computer = $null
$os = $null
$processors = @()
try { $computer = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 10 } catch { $warnings.Add('computer_system_unavailable') }
try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 10 } catch { $warnings.Add('operating_system_unavailable') }
try { $processors = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec 10) } catch { $warnings.Add('processor_inventory_unavailable') }

function Get-PropertyOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Convert-KiBToBytes {
    param($Value)
    if ($null -eq $Value) { return $null }
    return [uint64]([decimal]$Value * 1024)
}

$resolved = Resolve-Path -LiteralPath $LabPath
if ($resolved.Provider.Name -ne 'FileSystem' -or -not (Test-Path -LiteralPath $resolved.ProviderPath -PathType Container)) {
    throw 'LabPath must be an existing filesystem directory.'
}
# Report volume information for conventional local drive-letter paths only.
# Mounted-volume/reparse-point configurations require separate verification.
$disk = $null
try {
    $root = [IO.Path]::GetPathRoot($resolved.ProviderPath)
    if ($root -notmatch '^[A-Za-z]:\\$') { throw 'non-local root' }
    $dir = Get-Item -LiteralPath $resolved.ProviderPath
    while ($null -ne $dir) {
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse point' }
        $dir = $dir.Parent
    }
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'non-fixed volume' }
    $disk = [ordered]@{
        filesystem = $drive.DriveFormat
        total_bytes = [uint64]$drive.TotalSize
        available_to_caller_bytes = [uint64]$drive.AvailableFreeSpace
    }
} catch { $warnings.Add('volume_mapping_unverified') }

$vbox = $null
$candidates = [System.Collections.Generic.List[string]]::new()
try {
    $install = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Oracle\VirtualBox' -Name InstallDir).InstallDir
    if ($install) { $candidates.Add((Join-Path $install 'VBoxManage.exe')) }
} catch { }
if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe')) }
foreach ($candidate in $candidates) {
    if (-not [IO.Path]::IsPathRooted($candidate)) { continue }
    try {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $file = Get-Item -LiteralPath $candidate
            $vbox = [ordered]@{
                executable_found = $true
                file_version = $file.VersionInfo.FileVersion
                provider_runtime_verified = $false
            }
            break
        }
    } catch { $warnings.Add('provider_metadata_unavailable') }
}
if ($null -eq $vbox) {
    $vbox = [ordered]@{ executable_found = $false; file_version = $null; provider_runtime_verified = $false }
    $warnings.Add('virtualbox_not_found_in_known_locations')
}

$media = $null
if ($MediaPath) {
    $item = Get-Item -LiteralPath $MediaPath
    if ($item -isnot [IO.FileInfo] -or $item.Extension -ine '.iso') { throw 'MediaPath must be an existing ISO file.' }
    $digest = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $match = $null
    if ($ExpectedSha256) { $match = $digest -eq $ExpectedSha256.ToLowerInvariant() }
    $media = [ordered]@{
        bytes = [uint64]$item.Length
        sha256 = $digest
        expected_digest_match = $match
        licence_verified = $false
    }
    if ($match -eq $false) { $warnings.Add('media_digest_mismatch') }
}

$cpu = @($processors | ForEach-Object {
    [ordered]@{
        architecture = Get-PropertyOrNull $_ 'Architecture'
        logical_processors = Get-PropertyOrNull $_ 'NumberOfLogicalProcessors'
        firmware_virtualisation_enabled = Get-PropertyOrNull $_ 'VirtualizationFirmwareEnabled'
        second_level_address_translation = Get-PropertyOrNull $_ 'SecondLevelAddressTranslationExtensions'
    }
})

[ordered]@{
    schema_version = 1
    captured_at_utc = [DateTime]::UtcNow.ToString('o')
    os = [ordered]@{ version = Get-PropertyOrNull $os 'Version'; build = Get-PropertyOrNull $os 'BuildNumber'; architecture = Get-PropertyOrNull $os 'OSArchitecture' }
    physical_ram_bytes = Get-PropertyOrNull $computer 'TotalPhysicalMemory'
    available_ram_bytes = Convert-KiBToBytes (Get-PropertyOrNull $os 'FreePhysicalMemory')
    hypervisor_present = Get-PropertyOrNull $computer 'HypervisorPresent'
    processors = $cpu
    volume = $disk
    virtualbox = $vbox
    media = $media
    capability_qualification = 'pending'
    warnings = @($warnings.ToArray())
} | ConvertTo-Json -Depth 6

if ($null -ne $media -and $media.expected_digest_match -eq $false) { exit 3 }
