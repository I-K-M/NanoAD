# Read-only file allocation estimate for a stopped lab on a dedicated local NTFS directory.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Guid]$RunId,
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][switch]$QuiescentConfirmed,
    [ValidateRange(1,100000)][int]$MaxEntries = 20000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or $RunId -eq [Guid]::Empty -or -not $QuiescentConfirmed) { throw 'Windows, run UUID and explicit quiescent confirmation required.' }
$resolved = Resolve-Path -LiteralPath $LabPath
if ($resolved.Provider.Name -ne 'FileSystem' -or $resolved.ProviderPath -notmatch '^[A-Za-z]:\\') { throw 'A local filesystem directory is required.' }
$root = Get-Item -LiteralPath $resolved.ProviderPath -Force
if (-not $root.PSIsContainer -or $null -eq $root.Parent) { throw 'Use a dedicated lab subdirectory, never the volume root.' }
$cursor = $root
while ($null -ne $cursor) {
    if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points and mounted volumes are not supported.' }
    $cursor = $cursor.Parent
}
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root.FullName))
if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -ne 'NTFS') { throw 'Only fixed local NTFS is supported by this initial estimator.' }

if (-not ('NanoADBench.NativeAllocation' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;
namespace NanoADBench {
    public static class NativeAllocation {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        private static extern uint GetCompressedFileSizeW(string path, out uint high);
        [DllImport("kernel32.dll", ExactSpelling=true)]
        private static extern void SetLastError(uint error);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        private static extern bool GetDiskFreeSpaceW(string root, out uint sectors, out uint bytes, out uint free, out uint total);
        public static ulong Size(string path) {
            uint high;
            SetLastError(0);
            uint low = GetCompressedFileSizeW(path, out high);
            int error = Marshal.GetLastWin32Error();
            if (low == UInt32.MaxValue && error != 0) throw new Win32Exception(error);
            return ((ulong)high << 32) | low;
        }
        public static ulong ClusterSize(string root) {
            uint sectors, bytes, free, total;
            if (!GetDiskFreeSpaceW(root, out sectors, out bytes, out free, out total)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return checked((ulong)sectors * bytes);
        }
    }
}
'@
}

$cluster = [NanoADBench.NativeAllocation]::ClusterSize($drive.RootDirectory.FullName)
if ($cluster -eq 0) { throw 'Unknown NTFS allocation unit.' }
$start = [DateTime]::UtcNow
$freeBefore = [uint64]$drive.TotalFreeSpace
$totals = @{ entries = 0; files = 0; logical = [decimal]0; allocated = [decimal]0; namedStreams = 0; namedStreamEstimate = [decimal]0 }
function Round-Allocation {
    param([decimal]$Bytes)
    if ($Bytes -eq 0) { return [decimal]0 }
    return [Math]::Ceiling($Bytes / [decimal]$cluster) * [decimal]$cluster
}
function Visit-Directory {
    param([IO.DirectoryInfo]$Directory,[int]$Depth)
    if ($Depth -gt 32) { throw 'Directory depth limit exceeded.' }
    foreach ($entry in $Directory.EnumerateFileSystemInfos()) {
        $totals.entries++
        if ($totals.entries -gt $MaxEntries) { throw 'Directory entry limit exceeded; no partial result emitted.' }
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse point encountered; no result emitted.' }
        if ($entry -is [IO.DirectoryInfo]) { Visit-Directory $entry ($Depth + 1); continue }
        if ($entry -isnot [IO.FileInfo]) { throw 'Unknown filesystem entry.' }
        # Quiescence is an operator prerequisite; repeat if files can change.
        $length = $entry.Length
        $write = $entry.LastWriteTimeUtc
        $size = [NanoADBench.NativeAllocation]::Size($entry.FullName)
        $streams = @(Get-Item -LiteralPath $entry.FullName -Stream * -ErrorAction Stop)
        $entry.Refresh()
        if (-not $entry.Exists -or $entry.Length -ne $length -or $entry.LastWriteTimeUtc -ne $write -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'File changed during measurement.' }
        $totals.files++
        $totals.logical += [decimal]$length
        $totals.allocated += (Round-Allocation ([decimal]$size))
        foreach ($stream in $streams) {
            if ($stream.Stream -eq ':$DATA') { continue }
            $totals.namedStreams++
            $totals.namedStreamEstimate += (Round-Allocation ([decimal]$stream.Length))
        }
    }
}
Visit-Directory $root 0
$freeAfter = [uint64]$drive.TotalFreeSpace
[ordered]@{
    schema_version = 1
    run_id = $RunId.ToString('D')
    started_utc = $start.ToString('o')
    ended_utc = [DateTime]::UtcNow.ToString('o')
    filesystem = 'NTFS'
    allocation_unit_bytes = $cluster
    files = $totals.files
    logical_default_stream_bytes = [uint64]$totals.logical
    rounded_default_stream_allocated_bytes = [uint64]$totals.allocated
    named_stream_count = $totals.namedStreams
    named_stream_conservative_bytes = [uint64]$totals.namedStreamEstimate
    estimated_file_data_bytes = [uint64]($totals.allocated + $totals.namedStreamEstimate)
    volume_free_before_bytes = $freeBefore
    volume_free_after_bytes = $freeAfter
    exact_physical_footprint_verified = $false
    accounting = 'conservative_per_file_data; hardlinks_may_be_counted_twice; filesystem_metadata_excluded'
    result = 'measurement_estimate'
} | ConvertTo-Json -Depth 4
