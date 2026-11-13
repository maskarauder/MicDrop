# Build a per-user development installer from the already built matching harness.
# SPDX-License-Identifier: MPL-2.0
[CmdletBinding()]
param(
    [string] $PayloadDirectory = 'build/host',
    [string] $OutputDirectory = 'build/windows-installer',
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$')][string] $AppVersion,
    [ValidatePattern('^[a-fA-F0-9]{12,40}$')][string] $BuildRevision,
    [string] $CompilerPath,
    [switch] $SignInstaller,
    [string] $PublisherName = $env:MICDROP_WINDOWS_PUBLISHER,
    # These compile-time overrides create a different product for isolated CI.
    [string] $InstallerTestRoot,
    [ValidatePattern('^[a-fA-F0-9-]{36}$')][string] $InstallerTestId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
    throw 'Build the installer with 64-bit PowerShell 7 on Windows.'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $AppVersion) {
    $identity = Get-Content -LiteralPath (Join-Path $repoRoot 'internal/version/version.properties') -Raw | ConvertFrom-StringData
    $AppVersion = $identity.version
    if ($AppVersion -notmatch '^\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.[1-9]\d*)?$') {
        throw 'Invalid shared release version.'
    }
}
$payloadRoot = (Resolve-Path -LiteralPath $PayloadDirectory).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if ([bool]$InstallerTestRoot -ne [bool]$InstallerTestId) {
    throw 'InstallerTestRoot and InstallerTestId must be supplied together.'
}
if ($InstallerTestRoot -and -not [IO.Path]::IsPathFullyQualified($InstallerTestRoot)) {
    throw 'The isolated installer test root must be an absolute path.'
}
if ($SignInstaller -and $InstallerTestRoot) {
    throw '-SignInstaller cannot be combined with -InstallerTestRoot.'
}
$pythonExe = $null
$signingScript = $null
if ($SignInstaller) {
    if (-not $PublisherName -or -not $PublisherName.Trim()) {
        $PublisherName = 'Noah Seymour'
    }
    $PublisherName = $PublisherName.Trim()
    if ($PublisherName.Length -gt 120 -or $PublisherName -match '[\x00-\x1f";#]') {
        throw 'Invalid -PublisherName for Inno Setup.'
    }
    $pythonExe = (Get-Command python -ErrorAction Stop).Source
    $signingScript = Join-Path $repoRoot 'tools/windows_signing.py'
}
if (-not $BuildRevision) {
    $BuildRevision = (& git -C $repoRoot rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $BuildRevision -notmatch '^[a-fA-F0-9]{40}$') {
        throw 'Supply the source commit with -BuildRevision when building outside a checkout.'
    }
}
$BuildRevision = $BuildRevision.ToLowerInvariant()

function Invoke-InstallerTool([string] $Executable, [string[]] $Arguments, [int] $TimeoutSeconds = 180) {
    # ArgumentList keeps paths as individual arguments; no shell interpolation.
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "Installer build tool exceeded its $TimeoutSeconds-second deadline."
        }
        if ($process.ExitCode -ne 0) { throw "Installer build tool failed with exit code $($process.ExitCode)." }
    } finally { $process.Dispose() }
}

if (-not $CompilerPath) {
    # Official immutable release; digest from the release asset, independently
    # verified before execution. Portable mode adds no compiler registration.
    $toolVersion = '7.1.0'
    $toolHash = '0362a383ed217d4c4239b5933866dd96d3eb2102737da92f80f6057a4b40df2f'
    $toolURL = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe'
    $toolRoot = Join-Path $repoRoot ".deps/inno-setup-$toolVersion"
    $cacheRoot = Join-Path $repoRoot '.deps/cache'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $archive = Join-Path $cacheRoot "$toolHash-innosetup-$toolVersion-x64.exe"
    if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $toolHash) {
        $partial = "$archive.partial"
        try {
            Invoke-WebRequest -Uri $toolURL -OutFile $partial -TimeoutSec 120
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $toolHash) {
                throw 'Inno Setup compiler download checksum mismatch.'
            }
            Move-Item -LiteralPath $partial -Destination $archive -Force
        } finally { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
    # Refresh from verified bytes rather than trusting a stamp for executable tools.
    Invoke-InstallerTool $archive @('/PORTABLE=1', '/CURRENTUSER', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', '/TASKS=', "/DIR=$toolRoot")
    $CompilerPath = Join-Path $toolRoot 'ISCC.exe'
}
$CompilerPath = (Resolve-Path -LiteralPath $CompilerPath).Path
# ISCC's PE file version does not identify the loaded compiler engine. Query
# the engine version actually used to compile (Inno Setup 7's --version option).
$compilerVersion = (@(& $CompilerPath '--version' 2>&1) -join "`n").Trim()
if ($LASTEXITCODE -ne 0 -or $compilerVersion -ne '7.1.0') {
    throw "Use the pinned Inno Setup 7.1.0 compiler. Reported version: $compilerVersion"
}

# Do not recursively package arbitrary build directories: they can contain private
# logs, configuration or stale outputs from a local or CI build.
$payloadPolicy = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows_payload.json') -Raw | ConvertFrom-Json
$requiredFiles = @($payloadPolicy.portable.PSObject.Properties.Name)
function Copy-PayloadFile([string] $Source, [string] $RelativePath) {
    $item = Get-Item -LiteralPath $Source
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Payload must contain regular files: $RelativePath"
    }
    $destination = Join-Path $stageRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination
}
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('micdrop-installer-payload-' + [guid]::NewGuid().ToString('N'))
$uninstSignDir = $null
if ($SignInstaller) {
    $uninstSignDir = Join-Path ([IO.Path]::GetTempPath()) ('micdrop-signed-uninst-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $uninstSignDir | Out-Null
}
New-Item -ItemType Directory -Path $stageRoot | Out-Null
try {
    foreach ($name in $requiredFiles) { Copy-PayloadFile (Join-Path $payloadRoot $name) $name }
    # Pure Go: this helper can stop old hosts even when their media DLL is missing.
    $helper = Join-Path $stageRoot 'MicDrop-maintenance.exe'
    Invoke-InstallerTool 'go' @('-C', $repoRoot, 'build', '-buildvcs=false', '-trimpath', '-o', $helper, './tools/windows-maintenance')
    if ($SignInstaller) {
        Invoke-InstallerTool $pythonExe @($signingScript, 'sign', $helper) 240
    }
    Copy-PayloadFile (Join-Path $repoRoot 'third_party/INNOSETUP-NOTICE.txt') 'INNOSETUP-NOTICE.txt'
    $files = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = [IO.Path]::GetRelativePath($stageRoot, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            size = $_.Length
        }
    })
    $manifest = [ordered]@{
        schema = 1
        app_version = $AppVersion
        build_revision = $BuildRevision
        platform = 'windows-x64'
        files = $files
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stageRoot 'payload-manifest.json') -Encoding utf8
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    $arguments = @('/Qp', "/DPayloadDir=$stageRoot", "/DOutputDir=$outputRoot", "/DAppVersion=$AppVersion", "/DBuildRevision=$BuildRevision")
    if ($InstallerTestRoot) { $arguments += @('/DInstallerTest', "/DTestRoot=$InstallerTestRoot", "/DTestId=$InstallerTestId") }
    if ($SignInstaller) {
        $arguments += @(
            '/DSignInstaller',
            "/DPublisherName=$PublisherName",
            "/DSignedUninstallerDir=$uninstSignDir",
            "/Smicdrop=`$q$pythonExe`$q `$q$signingScript`$q sign `$f"
        )
    }
    $arguments += Join-Path $repoRoot 'deploy/windows/MicDrop.iss'
    Invoke-InstallerTool $CompilerPath $arguments $(if ($SignInstaller) { 480 } else { 300 })
    Copy-Item -LiteralPath (Join-Path $stageRoot 'payload-manifest.json') -Destination $outputRoot -Force
    Write-Host "Installer and payload manifest: $outputRoot"
} finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($uninstSignDir -and (Test-Path -LiteralPath $uninstSignDir)) {
        Remove-Item -LiteralPath $uninstSignDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
