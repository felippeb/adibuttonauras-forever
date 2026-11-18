<#
.SYNOPSIS
    Builds the release zip expected by CurseForge and the in-game client.

.DESCRIPTION
    The archive root must contain AdiButtonAuras\ and AdiButtonAuras_Config\ as siblings;
    the config TOC references ..\AdiButtonAuras\ so the layout cannot be flattened.

.EXAMPLE
    pwsh -File .\build-zip.ps1
    pwsh -File .\build-zip.ps1 -Version 11.0.4-forever.2
#>
[CmdletBinding()]
param(
    [string]$Version = "11.0.4-forever.1",
    [string]$OutDir = (Join-Path $PSScriptRoot "release")
)

$ErrorActionPreference = "Stop"

# PowerShell's location and the process working directory are not the same
# thing, and the .NET compression APIs use the latter. Resolve once, absolutely,
# so a relative -OutDir behaves the same from any shell and from CI.
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

$root = $PSScriptRoot
$folders = @("AdiButtonAuras", "AdiButtonAuras_Config")

foreach ($folder in $folders) {
    if (-not (Test-Path (Join-Path $root $folder))) {
        throw "missing addon folder: $folder"
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zipPath = Join-Path $OutDir "AdiButtonAuras-$Version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Windows PowerShell 5.1 ships .NET Framework, where ZipArchiveMode lives in
# System.IO.Compression.dll and ZipFile in System.IO.Compression.FileSystem.dll.
# Load both, and pass the mode as a string so the enum need not be resolved by name.
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

$archive = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($folder in $folders) {
        Get-ChildItem (Join-Path $root $folder) -Recurse -File |
            Where-Object {
                $_.Name -notmatch '\.(bak|orig)$' -and
                $_.FullName -notmatch '\\\.git\\'
            } |
            ForEach-Object {
                # Forward slashes and the addon folder at the archive root.
                $entryName = $_.FullName.Substring($root.Length + 1).Replace('\', '/')

                if ($_.Extension -eq '.toc') {
                    # Stamp the release version into the shipped TOC, so addon
                    # managers (WowUp, CurseForge) see the same version the tag
                    # and the asset name advertise. Written without a BOM.
                    $text = [System.IO.File]::ReadAllText($_.FullName)
                    $text = [regex]::Replace($text, '(?m)^##\s*Version\s*:.*$', "## Version: $Version")
                    $entry = $archive.CreateEntry($entryName)
                    $stream = $entry.Open()
                    try {
                        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
                        $stream.Write($bytes, 0, $bytes.Length)
                    }
                    finally {
                        $stream.Dispose()
                    }
                }
                else {
                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $archive, $_.FullName, $entryName) | Out-Null
                }
            }
    }
}
finally {
    $archive.Dispose()
}

$size = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Write-Host "wrote $zipPath ($size KB)"
