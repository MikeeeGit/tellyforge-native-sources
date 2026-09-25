#Requires -Version 5.1
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'NativeProbeBundle.psm1') -Force
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('tellyforge-probe-fixtures-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$script:checks = 0

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
function New-ProbeFixture {
    $directory = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $bin = Join-Path $directory 'angle\bin'
    [IO.Directory]::CreateDirectory($bin) | Out-Null
    $outputs = @{}
    foreach ($name in @('libmpv-2.dll', 'z.dll', 'libGLESv2.dll', 'libEGL.dll')) {
        $path = if ($name -ceq 'libmpv-2.dll') { Join-Path $directory $name } else { Join-Path $bin $name }
        [IO.File]::WriteAllText($path, "Synthetic, nonexecutable fixture: $name", [Text.UTF8Encoding]::new($false))
        $outputs[$name] = [ordered]@{ path = "bin/$name"; size = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() }
    }
    $manifest = [ordered]@{
        schemaVersion = 1; platform = 'windows'; architecture = 'x64'
        builds = @(
            [ordered]@{ id = 'tellyforge-libmpv-windows-x64'; outputs = @($outputs['libmpv-2.dll']) },
            [ordered]@{ id = 'tellyforge-angle-windows-x64'; outputs = @($outputs['z.dll'], $outputs['libGLESv2.dll'], $outputs['libEGL.dll']) }
        )
    }
    $fixture = [pscustomobject]@{
        library = Join-Path $directory 'libmpv-2.dll'
        angle = Join-Path $directory 'angle'
        manifestPath = Join-Path $directory 'native-runtime.json'
        destination = Join-Path $directory 'probe'
        manifest = $manifest
    }
    Save-FixtureManifest $fixture
    return $fixture
}
function Save-FixtureManifest {
    param([object]$Fixture)
    [IO.File]::WriteAllText($Fixture.manifestPath, ($Fixture.manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
function Invoke-Fixture {
    param([object]$Fixture, [string]$ModifiedHash)
    $arguments = @{
        LibraryPath = $Fixture.library; AngleInstallRoot = $Fixture.angle
        RuntimeManifestPath = $Fixture.manifestPath; Destination = $Fixture.destination
    }
    if (-not [string]::IsNullOrWhiteSpace($ModifiedHash)) { $arguments.ModifiedLibrarySha256 = $ModifiedHash }
    New-NativeProbeBundle @arguments
}

try {
    $valid = New-ProbeFixture
    [IO.File]::WriteAllText((Join-Path $valid.angle 'bin\unrelated.dll'), 'Not a probe dependency.')
    $bundle = Invoke-Fixture $valid
    Assert-True ($bundle.files.Count -eq 4 -and @(Get-ChildItem -LiteralPath $bundle.directory -File).Count -eq 4) 'Only four declared native files are staged.'
    foreach ($record in $bundle.files) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $bundle.directory $record.name)).Hash -ieq $record.sha256) 'Staged file matches reviewed hash.'
    }
    Assert-Throws { Invoke-Fixture $valid } 'new empty destination'

    foreach ($name in @('libmpv-2.dll', 'z.dll', 'libGLESv2.dll', 'libEGL.dll')) {
        $bad = New-ProbeFixture
        $path = if ($name -ceq 'libmpv-2.dll') { $bad.library } else { Join-Path $bad.angle "bin\$name" }
        [IO.File]::AppendAllText($path, 'changed')
        Assert-Throws { Invoke-Fixture $bad } 'input hash mismatch'
        Assert-True (-not (Test-Path -LiteralPath $bad.destination)) 'No bundle is created after a bad dependency.'
    }
    $missing = New-ProbeFixture
    Remove-Item -LiteralPath (Join-Path $missing.angle 'bin\z.dll')
    Assert-Throws { Invoke-Fixture $missing } 'does not exist|cannot find'

    $bad = New-ProbeFixture
    $bad.manifest.platform = 'linux'
    Save-FixtureManifest $bad
    Assert-Throws { Invoke-Fixture $bad } 'Windows x64 runtime manifest'
    $bad = New-ProbeFixture
    $bad.manifest.builds += $bad.manifest.builds[1]
    Save-FixtureManifest $bad
    Assert-Throws { Invoke-Fixture $bad } 'duplicate native build identity'
    $bad = New-ProbeFixture
    $bad.manifest.builds[1].outputs += $bad.manifest.builds[1].outputs[0]
    Save-FixtureManifest $bad
    Assert-Throws { Invoke-Fixture $bad } 'invalid native output hash'
    $bad = New-ProbeFixture
    $bad.manifest.builds[1].outputs[0].sha256 = 'invalid'
    Save-FixtureManifest $bad
    Assert-Throws { Invoke-Fixture $bad } 'invalid native output hash'
    $bad = New-ProbeFixture
    $bad.manifest.builds[1].outputs[0].size++
    Save-FixtureManifest $bad
    Assert-Throws { Invoke-Fixture $bad } 'input size mismatch'

    $modified = New-ProbeFixture
    [IO.File]::AppendAllText($modified.library, ' personal-modification')
    $modifiedHash = (Get-FileHash -LiteralPath $modified.library).Hash
    Assert-Throws { Invoke-Fixture $modified } 'input hash mismatch'
    $bundle = Invoke-Fixture $modified -ModifiedHash $modifiedHash
    Assert-True ($bundle.files[0].sha256 -ieq $modifiedHash) 'An explicitly measured modified library is staged with the official dependencies.'
    $bad = New-ProbeFixture
    $officialHash = (Get-FileHash -LiteralPath $bad.library).Hash
    Assert-Throws { Invoke-Fixture $bad -ModifiedHash $officialHash } 'must differ from the official'
    [IO.File]::AppendAllText($bad.library, ' personal-modification')
    [IO.File]::AppendAllText((Join-Path $bad.angle 'bin\libGLESv2.dll'), 'unreviewed dependency')
    $modifiedHash = (Get-FileHash -LiteralPath $bad.library).Hash
    Assert-Throws { Invoke-Fixture $bad -ModifiedHash $modifiedHash } 'input hash mismatch: libGLESv2.dll'
    Write-Host "Native probe bundle fixtures passed: $script:checks checks. No DLL was executed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^tellyforge-probe-fixtures-[a-f0-9]{32}$') {
        throw 'Refusing to remove an unexpected synthetic fixture directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
