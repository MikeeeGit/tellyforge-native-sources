#Requires -Version 5.1
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WindowsSourceAssetUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseTag,
        [Parameter(Mandatory)][string]$AssetName
    )

    $number = '(?:0|[1-9][0-9]*)'
    $identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    $pattern = '\Av(?<core>' + $number + '\.' + $number + '\.' + $number + ')' +
        '(?:-' + $identifier + '(?:\.' + $identifier + ')*)?\z'
    $tag = [regex]::Match($ReleaseTag, $pattern)
    if (-not $tag.Success -or [version]$tag.Groups['core'].Value -lt [version]'1.0.0') {
        throw 'An exact release tag with core version v1.0.0 or later is required.'
    }
    $expected = "TellyForge-$($ReleaseTag.Substring(1))-windows-x64-native-corresponding-source.zip"
    if ($AssetName -cne $expected) { throw 'Source asset name must match the exact release tag.' }
    return "https://github.com/MikeeeGit/tellyforge-native-sources/releases/download/$ReleaseTag/$AssetName"
}

function Assert-WindowsSourceArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
        [long]$MaximumExpandedBytes = 536870912
    )

    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -gt 268435456) {
        throw 'The source ZIP must be a nonempty file no larger than 256 MiB.'
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Sha256) {
        throw 'The source ZIP hash does not match the reviewed SHA-256.'
    }
    if ($MaximumExpandedBytes -le 0 -or $MaximumExpandedBytes -gt 536870912) {
        throw 'Expanded source limit must be positive and no larger than 512 MiB.'
    }
    $allowlistPath = Join-Path $PSScriptRoot 'windows-source-allowlist.txt'
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($allowlistPath)) {
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $allowed.Add($line)) {
            throw 'Duplicate source allowlist entry.'
        }
    }
    if ($allowed.Count -ne 63) { throw 'The reviewed 63-file source allowlist has changed.' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($file.FullName)
    try {
        if ($archive.Entries.Count -ne $allowed.Count) {
            throw 'Source archive file count does not match the reviewed allowlist.'
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [long]$expanded = 0
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ($name -cnotmatch '^TellyForge-native-corresponding-source/[A-Za-z0-9_.\-/]+$' -or
                $name.Contains('//') -or $name -match '(^|/)\.{1,2}(/|$)' -or
                $name.EndsWith('/') -or -not $seen.Add($name)) {
                throw 'Source archive contains an unsafe or duplicate path.'
            }
            $relative = $name.Substring('TellyForge-native-corresponding-source/'.Length)
            if (-not $allowed.Contains($relative)) {
                throw 'Source archive contains a file outside the reviewed native-only allowlist.'
            }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -ne 0 -and $unixType -ne 0x8000) {
                throw 'Source archive contains a link or nonregular file.'
            }
            if (($entry.ExternalAttributes -band 0x400) -ne 0) {
                throw 'Source archive contains a reparse point.'
            }
            if ($entry.Length -le 0 -or $entry.Length -gt 134217728) {
                throw 'Source archive entry is empty or exceeds 128 MiB.'
            }
            $expanded += $entry.Length
            if ($expanded -gt $MaximumExpandedBytes) {
                throw 'Source archive exceeds the expanded-size limit.'
            }
        }
        return [pscustomobject][ordered]@{
            files = $seen.Count
            expandedBytes = $expanded
            sha256 = $Sha256.ToLowerInvariant()
        }
    }
    finally { $archive.Dispose() }
}

Export-ModuleMember -Function Get-WindowsSourceAssetUri, Assert-WindowsSourceArchive
