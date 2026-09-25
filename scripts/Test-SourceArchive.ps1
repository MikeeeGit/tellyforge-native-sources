#Requires -Version 5.1
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SourceArchive.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('tellyforge-source-fixtures-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$script:checks = 0
$paths = [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'windows-source-allowlist.txt'))

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw "Assertion failed: $Message" }
    $script:checks++
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Expected)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught -and $caught -match $Expected) "Expected '$Expected', got '$caught'."
}
function New-SourceFixture {
    param([string[]]$Names = $paths, [string]$SpecialName, [int]$SpecialAttributes = 0, [switch]$Empty)
    $path = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N') + '.zip')
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Names) {
            $entry = $archive.CreateEntry("TellyForge-native-corresponding-source/$name")
            if ($name -ceq $SpecialName) { $entry.ExternalAttributes = $SpecialAttributes }
            if (-not $Empty) {
                $writer = [IO.StreamWriter]::new($entry.Open())
                try { $writer.Write('Entirely synthetic source-boundary test fixture.') }
                finally { $writer.Dispose() }
            }
        }
    }
    finally { $archive.Dispose() }
    return $path
}
function Assert-BadFixture {
    param([string[]]$Names, [string]$Message)
    $zip = New-SourceFixture -Names $Names
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Assert-Throws { Assert-WindowsSourceArchive -Path $zip -Sha256 $hash } $Message
}

try {
    $uri = Get-WindowsSourceAssetUri -ReleaseTag 'v1.0.0' -AssetName 'TellyForge-1.0.0-windows-x64-native-corresponding-source.zip'
    Assert-True ($uri -ceq 'https://github.com/MikeeeGit/tellyforge-native-sources/releases/download/v1.0.0/TellyForge-1.0.0-windows-x64-native-corresponding-source.zip') 'Fixed public source repository URL.'
    $alphaUri = Get-WindowsSourceAssetUri -ReleaseTag 'v1.1.0-alpha.612' -AssetName 'TellyForge-1.1.0-alpha.612-windows-x64-native-corresponding-source.zip'
    Assert-True ($alphaUri -ceq 'https://github.com/MikeeeGit/tellyforge-native-sources/releases/download/v1.1.0-alpha.612/TellyForge-1.1.0-alpha.612-windows-x64-native-corresponding-source.zip') 'Prerelease source URL preserves the exact GitVersion tag and asset suffix.'
    foreach ($tag in @('v1.0.0-rc.1', 'v1.1.0-alpha.0', 'v1.1.0-beta-2.3', 'v1.1.0-0', 'v1.1.0-01alpha')) {
        $asset = "TellyForge-$($tag.Substring(1))-windows-x64-native-corresponding-source.zip"
        $accepted = Get-WindowsSourceAssetUri -ReleaseTag $tag -AssetName $asset
        Assert-True ($accepted.EndsWith("/$tag/$asset", [StringComparison]::Ordinal)) 'Valid SemVer prerelease identifiers remain exact.'
    }
    foreach ($tag in @('main', 'v0.9.0', 'v0.9.0-alpha.1', 'v1.0.0/../x', 'v01.0.0',
            'v1.0.0+1', 'v1.1.0-alpha.1+build.2', 'https://example.com', 'V1.1.0-alpha.1',
            'v1.1.0-', 'v1.1.0-alpha..1', 'v1.1.0-01', 'v1.1.0-alpha.01',
            'v1.1.0-alpha/1', 'v1.1.0-alpha\1', 'v1.1.0-alpha.1?raw=1', 'v1.1.0-alpha.1#fragment',
            'v1.1.0-alpha_1', 'v1.1.0-alpha.1 ', "v1.1.0-alpha.1`n")) {
        Assert-Throws { Get-WindowsSourceAssetUri -ReleaseTag $tag -AssetName 'source.zip' } 'exact release tag'
    }
    Assert-Throws { Get-WindowsSourceAssetUri -ReleaseTag 'v1.0.0' -AssetName 'TellyForge-1.0.1-windows-x64-native-corresponding-source.zip' } 'exact release tag'
    Assert-Throws { Get-WindowsSourceAssetUri -ReleaseTag 'v1.0.0' -AssetName '../source.zip' } 'exact release tag'
    foreach ($asset in @('TellyForge-1.1.0-windows-x64-native-corresponding-source.zip',
            'TellyForge-1.1.0-alpha.613-windows-x64-native-corresponding-source.zip',
            'TellyForge-1.1.0-Alpha.612-windows-x64-native-corresponding-source.zip',
            '../TellyForge-1.1.0-alpha.612-windows-x64-native-corresponding-source.zip')) {
        Assert-Throws { Get-WindowsSourceAssetUri -ReleaseTag 'v1.1.0-alpha.612' -AssetName $asset } 'exact release tag'
    }

    $valid = New-SourceFixture
    $hash = (Get-FileHash -LiteralPath $valid -Algorithm SHA256).Hash
    $result = Assert-WindowsSourceArchive -Path $valid -Sha256 $hash
    Assert-True ($result.files -eq 63 -and $result.expandedBytes -gt 0 -and $result.sha256 -ceq $hash.ToLowerInvariant()) 'Reviewed source boundary accepts 63 synthetic allowed files.'
    Assert-Throws { Assert-WindowsSourceArchive -Path $valid -Sha256 ('0' * 64) } 'reviewed SHA-256'
    Assert-Throws { Assert-WindowsSourceArchive -Path $valid -Sha256 $hash -MaximumExpandedBytes 1 } 'expanded-size'
    Assert-Throws { Assert-WindowsSourceArchive -Path $valid -Sha256 $hash -MaximumExpandedBytes 536870913 } '512 MiB'
    Assert-BadFixture -Names $paths[0..61] -Message 'file count'
    Assert-BadFixture -Names ($paths + 'lib/private.dart') -Message 'file count'

    foreach ($replacement in @('lib/private.dart', 'data/app.so', 'libmpv-2.dll', 'household-baseline.json', 'README.TXT')) {
        $names = [string[]]$paths.Clone()
        $names[0] = $replacement
        Assert-BadFixture -Names $names -Message 'native-only allowlist'
    }
    foreach ($replacement in @('../escape.txt', 'tool/../../escape.txt', 'tool\native\windows\README.md', 'C:/escape.txt', '/escape.txt', 'tool//file', 'README.txt/')) {
        $names = [string[]]$paths.Clone()
        $names[0] = $replacement
        Assert-BadFixture -Names $names -Message 'unsafe or duplicate path'
    }
    $duplicate = [string[]]$paths.Clone()
    $duplicate[1] = $duplicate[0]
    Assert-BadFixture -Names $duplicate -Message 'unsafe or duplicate path'
    foreach ($attributes in @(-1610612736, 1024)) {
        $linked = New-SourceFixture -SpecialName $paths[0] -SpecialAttributes $attributes
        Assert-Throws { Assert-WindowsSourceArchive -Path $linked -Sha256 (Get-FileHash -LiteralPath $linked).Hash } 'link|reparse'
    }
    $empty = New-SourceFixture -Empty
    Assert-Throws { Assert-WindowsSourceArchive -Path $empty -Sha256 (Get-FileHash -LiteralPath $empty).Hash } 'entry is empty'
    Write-Host "Source archive fixtures passed: $script:checks checks. No native compilation or download was run."
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^tellyforge-source-fixtures-[a-f0-9]{32}$') {
        throw 'Refusing to remove an unexpected synthetic fixture directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
