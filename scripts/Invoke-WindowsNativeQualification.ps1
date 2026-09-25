#Requires -Version 5.1
# SPDX-License-Identifier: MIT

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$AssetName,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$SourceSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:RUNNER_OS -cne 'Windows' -or
    $env:GITHUB_REPOSITORY -cne 'MikeeeGit/tellyforge-native-sources') {
    throw 'This qualification script runs only on this public repository''s GitHub-hosted Windows job.'
}
Import-Module (Join-Path $PSScriptRoot 'SourceArchive.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NativeProbeBundle.psm1') -Force
$uri = Get-WindowsSourceAssetUri -ReleaseTag $ReleaseTag -AssetName $AssetName
$work = 'C:\tfnq'
if (Test-Path -LiteralPath $work) { throw 'Refusing to reuse an existing native qualification workspace.' }
[IO.Directory]::CreateDirectory($work) | Out-Null
$receiptDirectory = Join-Path $env:GITHUB_WORKSPACE 'qualification'
[IO.Directory]::CreateDirectory($receiptDirectory) | Out-Null
$receiptPath = Join-Path $receiptDirectory 'windows-native-qualification.json'
$receipt = [ordered]@{
    schemaVersion = 1
    status = 'running'
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    releaseTag = $ReleaseTag
    sourceUrl = $uri
    sourceSha256 = $SourceSha256.ToLowerInvariant()
    workflowCommit = $env:GITHUB_SHA
    runUrl = "https://github.com/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    runnerImage = [string]$env:ImageOS
    runnerImageVersion = [string]$env:ImageVersion
    officialNativeHashesVerified = $false
    modifiedNativeApiQualified = $false
    fullAppRelinkQualified = $false
    storeSubmissionQualified = $false
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $work 'source.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $zip -TimeoutSec 600
    $receipt.sourceBoundary = Assert-WindowsSourceArchive -Path $zip -Sha256 $SourceSha256
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)
    $root = Join-Path $work 'TellyForge-native-corresponding-source'
    $recipes = Join-Path $root 'tool\native\windows'
    & (Join-Path $recipes 'Test-NativeToolIntegrity.ps1')

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $visualStudios = @((& $vswhere -version '[17.0,18.0)' -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -format json | Out-String) | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $visualStudios.Count -ne 1) {
        throw 'Expected one supported Visual Studio 2022 C++ installation on the hosted image.'
    }
    $vsRoot = [string]$visualStudios[0].installationPath
    $receipt.visualStudioVersion = [string]$visualStudios[0].installationVersion
    $env:VCPKG_VISUAL_STUDIO_PATH = $vsRoot
    $env:VCPKG_MAX_CONCURRENCY = '4'
    $env:CMAKE_BUILD_PARALLEL_LEVEL = '4'
    $nativeWork = Join-Path $work 'native'

    # Production wrappers retain their exact output-hash assertions. A rolling
    # hosted image mismatch is a failed qualification, never a new approved pin.
    $angle = & (Join-Path $recipes 'Build-Angle.ps1') -WorkRoot $nativeWork | Select-Object -Last 1
    $buildTools = & (Join-Path $recipes 'Install-NativeBuildTools.ps1') -WorkRoot $nativeWork
    $source = & (Join-Path $recipes 'Prepare-LibmpvSource.ps1') -WorkRoot $nativeWork | Select-Object -Last 1
    $libmpv = & (Join-Path $recipes 'Build-Libmpv.ps1') -SourceRoot $source `
        -AngleInstallRoot $angle -Python $buildTools.Python -MesonRoot $buildTools.MesonRoot `
        -LlvmBin $buildTools.LlvmBin -NasmBin $buildTools.NasmBin `
        -VisualStudioRoot $vsRoot -BuildRoot (Join-Path $nativeWork 'build\libmpv') | Select-Object -Last 1
    $library = Join-Path $libmpv 'libmpv-2.dll'
    $receipt.officialNativeHashesVerified = $true
    $receipt.officialLibmpvSha256 = (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant()
    $officialBundle = New-NativeProbeBundle -LibraryPath $library -AngleInstallRoot $angle `
        -RuntimeManifestPath (Join-Path $root 'native-runtime.json') `
        -Destination (Join-Path $work 'probe-official')
    $receipt.officialProbeFiles = @($officialBundle.files)
    $officialProbe = & (Join-Path $PSScriptRoot 'Read-LibmpvVersion.ps1') -LibraryPath $officialBundle.libraryPath
    $receipt.officialMpvVersion = $officialProbe.version
    $receipt.officialLoadedModulePaths = @($officialProbe.loadedModulePaths)
    if ([string]$receipt.officialMpvVersion -notmatch '^mpv ' -or
        [string]$receipt.officialMpvVersion -match 'personal-modification') {
        throw 'The unchanged library returned an unexpected version.'
    }

    $versionSource = Join-Path $source 'common\version.c'
    $original = [IO.File]::ReadAllText($versionSource)
    $needle = 'const char mpv_version[]  = "mpv " VERSION;'
    if (($original.Split(@($needle), [StringSplitOptions]::None)).Count -ne 2) {
        throw 'Expected exactly one pinned mpv version declaration.'
    }
    [IO.File]::WriteAllText($versionSource,
        $original.Replace($needle, 'const char mpv_version[]  = "mpv " VERSION " personal-modification";'),
        [Text.UTF8Encoding]::new($false))
    $receipt.modification = 'Append personal-modification to the mpv version string; no ABI or playback change.'
    $receipt.modifiedVersionSourceSha256 = (Get-FileHash -LiteralPath $versionSource -Algorithm SHA256).Hash.ToLowerInvariant()
    # Keep the environment established by Build-Libmpv in this process. Rebuild
    # the changed objects directly; do not weaken the official wrapper's hashes.
    & $buildTools.Python -m mesonbuild.mesonmain compile -C $libmpv --jobs 2
    if ($LASTEXITCODE -ne 0) { throw 'Modified native compilation failed.' }
    $receipt.modifiedLibmpvSha256 = (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.modifiedLibmpvSha256 -ceq $receipt.officialLibmpvSha256) {
        throw 'The source modification did not change the compiled library.'
    }
    $modifiedBundle = New-NativeProbeBundle -LibraryPath $library -AngleInstallRoot $angle `
        -RuntimeManifestPath (Join-Path $root 'native-runtime.json') `
        -Destination (Join-Path $work 'probe-modified') `
        -ModifiedLibrarySha256 $receipt.modifiedLibmpvSha256
    $receipt.modifiedProbeFiles = @($modifiedBundle.files)
    $modifiedProbe = & (Join-Path $PSScriptRoot 'Read-LibmpvVersion.ps1') -LibraryPath $modifiedBundle.libraryPath
    $receipt.modifiedMpvVersion = $modifiedProbe.version
    $receipt.modifiedLoadedModulePaths = @($modifiedProbe.loadedModulePaths)
    if ([string]$receipt.modifiedMpvVersion -cne ([string]$receipt.officialMpvVersion + ' personal-modification')) {
        throw 'The loaded replacement library did not report the exact modification marker.'
    }
    $receipt.modifiedNativeApiQualified = $true
    $receipt.status = 'native-only-pass'
    Write-Host 'Native rebuild and modified-library API probe passed. Full application relinking and Store acceptance remain unqualified.'
}
catch {
    $receipt.status = 'failed'
    throw
}
finally {
    $receipt.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
}
