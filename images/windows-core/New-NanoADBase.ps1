# Windows host: verified media, read-only plan, explicit preparation of an offline VM.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$VBoxManage,
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [ValidateRange(3072,8192)][int]$MemoryMiB = 4096,
    [ValidateRange(1,4)][int]$Vcpus = 2,
    [ValidateRange(40960,131072)][int]$DiskMiB = 40960,
    [switch]$Prepare
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows reference host required.' }

function Resolve-LocalPath {
    param([string]$Path, [bool]$Directory)
    $resolved = Resolve-Path -LiteralPath $Path
    if ($resolved.Provider.Name -ne 'FileSystem' -or $resolved.ProviderPath -notmatch '^[A-Za-z]:\\') { throw 'Local drive-letter path required.' }
    $item = Get-Item -LiteralPath $resolved.ProviderPath
    if ($Directory -ne [bool]$item.PSIsContainer) { throw 'Unexpected path type.' }
    $cursor = $item
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points are not supported.' }
        if ($cursor -is [IO.FileInfo]) { $cursor = $cursor.Directory } else { $cursor = $cursor.Parent }
    }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($item.FullName))
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'Fixed local volume required.' }
    return $item
}

$root = Resolve-LocalPath $BuildRoot $true
$iso = Resolve-LocalPath $IsoPath $false
$vbox = Resolve-LocalPath $VBoxManage $false
if ($iso.Extension -ine '.iso' -or $vbox.Name -ine 'VBoxManage.exe') { throw 'Expected ISO and VBoxManage.exe.' }
$rootPrefix = $root.FullName.TrimEnd('\') + '\'
if ($iso.FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep installation media outside the build root.' }
if ($vbox.FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Provider executable must be outside the build root.' }
$actual = (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Media digest mismatch.' }

# Avoid starting external provider processes in plan mode.
$versionHint = $vbox.VersionInfo.FileVersion
if (-not $versionHint -or $versionHint -notmatch '^7\.') { throw 'This initial recipe targets VirtualBox 7.x; inspect provider metadata and compatibility.' }
$os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 10
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root.FullName))
$requiredRam = ([uint64]$MemoryMiB * 1MB) + 2GB + 512MB
$requiredDisk = ([uint64]$DiskMiB * 1MB) + 8GB
$availableRam = [uint64]$os.FreePhysicalMemory * 1KB
$availableDisk = [uint64]$drive.AvailableFreeSpace
$ready = $availableRam -ge $requiredRam -and $availableDisk -ge $requiredDisk
$plan = [ordered]@{
    schema_version = 1
    action = 'prepare_offline_build'
    media_sha256 = $actual
    media_bytes = [uint64]$iso.Length
    provider_file_version = $versionHint
    memory_mib = $MemoryMiB
    vcpus = $Vcpus
    virtual_disk_mib = $DiskMiB
    available_ram_bytes = $availableRam
    required_ram_bytes = $requiredRam
    available_disk_bytes = $availableDisk
    required_disk_bytes = $requiredDisk
    resource_preflight_passed = $ready
    provider_qualification = 'pending'
    starts_guest = $false
    network = 'none'
}
if (-not $Prepare) { $plan | ConvertTo-Json -Depth 4; return }
if (-not $ready) { throw 'Insufficient build headroom. No VM created.' }
if (-not $PSCmdlet.ShouldProcess($root.FullName, 'Create new powered-off offline build VM and disk')) { return }

# Fresh per-operation path and UUID; never adopt an existing VM by name.
$id = [Guid]::NewGuid().ToString()
$name = "nanoad-base-$id"
$dir = Join-Path $root.FullName $name
if (Test-Path -LiteralPath $dir) { throw 'Unexpected existing operation directory.' }
New-Item -ItemType Directory -Path $dir | Out-Null
$journal = Join-Path $dir 'build-journal.jsonl'
$disk = Join-Path $dir 'base.vdi'
function Add-Journal {
    param([string]$Step, [string]$State)
    $entry = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); vm_uuid = $id; step = $Step; state = $State }
    Add-Content -LiteralPath $journal -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
}
function Invoke-Provider {
    param([string]$Step, [string[]]$Arguments)
    Add-Journal $Step 'intent'
    & $vbox.FullName @Arguments
    if ($LASTEXITCODE -ne 0) { Add-Journal $Step 'failed'; throw "Provider step failed: $Step. Inspect journal; no automatic deletion." }
    Add-Journal $Step 'complete'
}

# Record intent before every side effect. No arbitrary provider commands are accepted.
$plan.vm_uuid = $id
$plan.vm_name = $name
$plan | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'plan.json') -Encoding UTF8
try {
    Invoke-Provider 'create_vm' @('createvm','--name',$name,'--ostype','Windows2022_64','--basefolder',$dir,'--uuid',$id,'--register')
    $settings = @('modifyvm',$id,'--memory',"$MemoryMiB",'--cpus',"$Vcpus",'--vram','16','--boot1','dvd','--boot2','disk','--boot3','none','--boot4','none','--clipboard-mode','disabled','--drag-and-drop','disabled')
    foreach ($index in 1..8) { $settings += @("--nic$index",'none') }
    Invoke-Provider 'offline_settings' $settings
    Invoke-Provider 'create_disk' @('createmedium','disk','--filename',$disk,'--size',"$DiskMiB",'--format','VDI','--variant','Standard')
    Invoke-Provider 'storage_controller' @('storagectl',$id,'--name','SATA','--add','sata','--controller','IntelAhci','--portcount','2')
    Invoke-Provider 'attach_disk' @('storageattach',$id,'--storagectl','SATA','--port','0','--device','0','--type','hdd','--medium',$disk)
    Invoke-Provider 'attach_media' @('storageattach',$id,'--storagectl','SATA','--port','1','--device','0','--type','dvddrive','--medium',$iso.FullName)
    Add-Journal 'preparation' 'pending_manual_isolation_check'
    Write-Host "Prepared powered-off VM $id. Verify isolation and media before any boot."
    Write-Host "Local journal: $journal"
} catch {
    Add-Journal 'preparation' 'recovery_required'
    throw
}
