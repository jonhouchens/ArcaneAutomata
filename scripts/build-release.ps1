[CmdletBinding()]
param(
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$addonPath = Join-Path $repositoryRoot 'arcaneautomata.lua'
$versionLine = Select-String -LiteralPath $addonPath `
    -Pattern "^addon\.version\s*=\s*'([^']+)'\s*;" |
    Select-Object -First 1

if ($null -eq $versionLine) {
    throw 'Could not read addon.version from arcaneautomata.lua.'
}

$version = $versionLine.Matches[0].Groups[1].Value
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'dist'
}

$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$archivePath = Join-Path $outputPath "ArcaneAutomata-v$version.zip"

$archiveFiles = @(
    @{ Source = 'arcaneautomata.lua'; Entry = 'addons/arcaneautomata/arcaneautomata.lua' }
    @{ Source = 'maneuverview.lua'; Entry = 'addons/arcaneautomata/maneuverview.lua' }
    @{ Source = 'actionpacket.lua'; Entry = 'addons/arcaneautomata/actionpacket.lua' }
    @{ Source = 'README.md'; Entry = 'addons/arcaneautomata/README.md' }
    @{ Source = 'LICENSE'; Entry = 'addons/arcaneautomata/LICENSE' }
    @{ Source = 'THIRD_PARTY_NOTICES.md'; Entry = 'addons/arcaneautomata/THIRD_PARTY_NOTICES.md' }
    @{ Source = 'libs/burdenmodel.lua'; Entry = 'addons/libs/burdenmodel.lua' }
    @{ Source = 'libs/burdenforecast.lua'; Entry = 'addons/libs/burdenforecast.lua' }
    @{ Source = 'libs/pupstats.lua'; Entry = 'addons/libs/pupstats.lua' }
)

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open(
    $archivePath,
    [IO.Compression.ZipArchiveMode]::Create)

try {
    foreach ($file in $archiveFiles) {
        $sourcePath = Join-Path $repositoryRoot $file.Source
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $sourcePath,
            $file.Entry,
            [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

$archive = Get-Item -LiteralPath $archivePath
$hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256

[PSCustomObject]@{
    Version = $version
    Path = $archive.FullName
    Bytes = $archive.Length
    SHA256 = $hash.Hash
}
