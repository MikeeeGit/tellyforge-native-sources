#Requires -Version 5.1
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-NativeProbeBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LibraryPath,
        [Parameter(Mandatory)][string]$AngleInstallRoot,
        [Parameter(Mandatory)][string]$RuntimeManifestPath,
        [Parameter(Mandatory)][string]$Destination,
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ModifiedLibrarySha256
    )

    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $destinationPath) {
        throw 'The native API probe requires a new empty destination.'
    }
    $manifest = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $RuntimeManifestPath).Path) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.platform -cne 'windows' -or $manifest.architecture -cne 'x64') {
        throw 'The probe requires the reviewed Windows x64 runtime manifest.'
    }
    $builds = @($manifest.builds)
    $library = (Resolve-Path -LiteralPath $LibraryPath).Path
    $angle = (Resolve-Path -LiteralPath $AngleInstallRoot).Path
    if ([IO.Path]::GetFileName($library) -cne 'libmpv-2.dll') {
        throw 'The probe requires an explicit libmpv-2.dll build output.'
    }
    $inputs = [ordered]@{
        'libmpv-2.dll' = $library
        'z.dll' = Join-Path $angle 'bin\z.dll'
        'libGLESv2.dll' = Join-Path $angle 'bin\libGLESv2.dll'
        'libEGL.dll' = Join-Path $angle 'bin\libEGL.dll'
    }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($name in $inputs.Keys) {
        $buildId = if ($name -ceq 'libmpv-2.dll') { 'tellyforge-libmpv-windows-x64' } else { 'tellyforge-angle-windows-x64' }
        $matchingBuilds = @($builds | Where-Object { $_.id -ceq $buildId })
        if ($matchingBuilds.Count -ne 1) { throw 'Missing or duplicate native build identity in runtime manifest.' }
        $outputs = @($matchingBuilds[0].outputs | Where-Object { $_.path -ceq "bin/$name" })
        if ($outputs.Count -ne 1 -or [string]$outputs[0].sha256 -cnotmatch '^[a-f0-9]{64}$' -or [long]$outputs[0].size -le 0) {
            throw 'Missing, duplicated or invalid native output hash in runtime manifest.'
        }
        $expected = [string]$outputs[0].sha256
        $modified = $name -ceq 'libmpv-2.dll' -and -not [string]::IsNullOrWhiteSpace($ModifiedLibrarySha256)
        if ($modified) {
            if ($ModifiedLibrarySha256 -ieq $expected) { throw 'A modified library must differ from the official library hash.' }
            $expected = $ModifiedLibrarySha256.ToLowerInvariant()
        }
        $inputFile = Get-Item -LiteralPath $inputs[$name] -ErrorAction Stop
        if ($inputFile.PSIsContainer -or ($inputFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The native probe accepts regular build output files only.'
        }
        if ((Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash -ine $expected) {
            throw "Native API probe input hash mismatch: $name"
        }
        if ($inputFile.Length -le 0 -or (-not $modified -and $inputFile.Length -ne [long]$outputs[0].size)) {
            throw "Native API probe input size mismatch: $name"
        }
        $records.Add([pscustomobject]@{ name = $name; sha256 = $expected; bytes = $inputFile.Length })
    }

    # All inputs must pass before creating a bundle. There is no installed-DLL,
    # PATH, SDK or machine-cache fallback, and no wildcard copy.
    [IO.Directory]::CreateDirectory($destinationPath) | Out-Null
    foreach ($record in $records) {
        $target = Join-Path $destinationPath $record.name
        [IO.File]::Copy($inputs[$record.name], $target, $false)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $record.sha256) {
            throw "Staged native API probe hash mismatch: $($record.name)"
        }
    }
    return [pscustomobject][ordered]@{
        directory = $destinationPath
        libraryPath = Join-Path $destinationPath 'libmpv-2.dll'
        files = $records.ToArray()
    }
}

Export-ModuleMember -Function New-NativeProbeBundle
