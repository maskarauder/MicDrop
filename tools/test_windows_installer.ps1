# SPDX-License-Identifier: MPL-2.0
# Exercise the real setup/uninstaller with a compile-time isolated product identity.
# Never launch the desktop host or read/write the runner account's MicDrop data.
[CmdletBinding()]
param(
    [string] $PayloadDirectory = 'build/host',
    [string] $CompilerPath = '.deps/inno-setup-7.1.0/ISCC.exe',
    [string] $WorkDirectory = [IO.Path]::GetTempPath(),
    [string] $ReportDirectory = 'build/windows-installer-tests'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7 -or [IntPtr]::Size -ne 8) {
    throw 'Installer lifecycle checks require Windows x64 and PowerShell 7.'
}

$payload = (Resolve-Path -LiteralPath $PayloadDirectory).ProviderPath
$compiler = (Resolve-Path -LiteralPath $CompilerPath).ProviderPath
$workBase = (Resolve-Path -LiteralPath $WorkDirectory).ProviderPath
$reportRoot = [IO.Path]::GetFullPath($ReportDirectory)
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$testId = [Guid]::NewGuid().ToString('D')
# Spaces deliberately exercise compiler/installer argument quoting.
$testRoot = Join-Path $workBase "micdrop installer test $testId"
$appRoot = Join-Path $testRoot 'app'
$dataRoot = Join-Path $testRoot 'data'
# Keep AppId under Inno's 57-character registry-name limit; longer AppIds are
# truncated and CRC-suffixed, so the visible ID is not the uninstall key name.
$productId = "MicDrop.Test.$testId"
$uninstallKey = "Software\Microsoft\Windows\CurrentVersion\Uninstall\${productId}_is1"
$runKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
# A LocalSystem runner's real Programs folder sits below Windows\System32.
# Inno 7.1's shortcut uninstall records redirect that special path to SysWOW64.
# The compile-time fixture uses an ordinary isolated folder for the same shortcut
# create/target/remove checks; actual user Start menu acceptance remains manual.
$programs = Join-Path $testRoot 'start-menu'
$shortcutRoot = Join-Path $programs "MicDrop Installer Test $testId"
$shortcutPath = Join-Path $shortcutRoot 'MicDrop.lnk'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexName = "Local\$productId.$sid"
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
$claimsVerified = $false
$testRootCreated = $false
$uninstallCleanupPending = $false
$fixtureProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$operations = [Collections.Generic.List[object]]::new()
$checks = [Collections.Generic.List[string]]::new()
$report = [ordered]@{
    schema = 1
    result = 'incomplete'
    started_utc = [DateTime]::UtcNow.ToString('o')
    finished_utc = $null
    operations = $operations
    checks = $checks
    error = $null
    cleanup_error = $null
}

function Save-Report {
    $report | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $reportRoot 'installer-tests.json') -Encoding utf8
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Write-FailureDiagnostics {
    Write-Host 'Installer failure diagnostics (only this unique test product):'
    foreach ($operation in @($operations | Select-Object -Last 2)) {
        $log = Join-Path $reportRoot $operation.log
        if (Test-Path -LiteralPath $log) {
            Write-Host "Installer log: $($operation.log)"
            Get-Content -LiteralPath $log -Tail 50 | Write-Host
        }
    }
}

function Get-RunValue {
    $key = $registry.OpenSubKey($runKeyPath)
    if ($null -eq $key) { return $null }
    try { return $key.GetValue($productId, $null) } finally { $key.Dispose() }
}

function Set-RunValue([string] $Value) {
    $key = $registry.CreateSubKey($runKeyPath)
    try { $key.SetValue($productId, $Value, [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $key.Dispose() }
}

function Assert-Registered([string] $Version) {
    $key = $registry.OpenSubKey($uninstallKey)
    Assert-True ($null -ne $key) 'The per-user uninstall registration is missing.'
    try {
        Assert-True ($key.GetValue('DisplayVersion') -eq $Version) 'The installed display version did not update.'
        $location = [string]$key.GetValue('InstallLocation', '')
        Assert-True ($location.TrimEnd('\') -eq $appRoot) 'The installer used an unexpected install directory.'
        $uninstaller = [string]$key.GetValue('UninstallString', '')
        Assert-True ($uninstaller -match [regex]::Escape($appRoot)) 'The uninstall entry does not reference this test installation.'
    } finally { $key.Dispose() }
    Assert-True (Test-Path -LiteralPath $shortcutPath -PathType Leaf) 'The per-user Start menu shortcut is missing.'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        try {
            Assert-True ($shortcut.TargetPath -eq (Join-Path $appRoot 'MicDrop.exe')) 'The shortcut targets another executable.'
            Assert-True ($shortcut.WorkingDirectory -eq $appRoot) 'The shortcut has the wrong working directory.'
        } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
}

function Assert-Unregistered {
    $key = $registry.OpenSubKey($uninstallKey)
    try { Assert-True ($null -eq $key) 'Uninstall left its own registration behind.' }
    finally { if ($null -ne $key) { $key.Dispose() } }
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) 'Uninstall left its Start menu shortcut behind.'
}

function Get-TreeFingerprint([string] $Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return '<missing>' }
    $inventory = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force |
        Sort-Object FullName | ForEach-Object {
            [ordered]@{
                path = [IO.Path]::GetRelativePath($Directory, $_.FullName)
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        })
    return ConvertTo-Json -InputObject $inventory -Compress -Depth 4
}

function Assert-InstalledPayload([string] $Version, [string] $Revision, [string] $Source) {
    $manifestPath = Join-Path $appRoot 'payload-manifest.json'
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'The installed payload manifest is missing.'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ($manifest.schema -eq 1 -and $manifest.platform -eq 'windows-x64') 'Unexpected installed manifest schema/platform.'
    Assert-True ($manifest.app_version -eq $Version -and $manifest.build_revision -eq $Revision) 'Installed build identity is stale.'
    Assert-True (@($manifest.files).Count -gt 3) 'The payload manifest contains too few files.'
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.path
        Assert-True ($relative -ne '' -and -not [IO.Path]::IsPathRooted($relative) -and
            $relative -notmatch '(^|[/\\])\.\.([/\\]|$)' -and $relative -notmatch ':') 'Unsafe manifest path.'
        $path = Join-Path $appRoot $relative
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Installed payload file is missing: $relative"
        Assert-True ((Get-Item -LiteralPath $path).Length -eq $entry.size) "Installed file size differs: $relative"
        Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $entry.sha256) "Installed file hash differs: $relative"
    }
    # Cross-check manifest claims against independent input bytes, including the
    # changed guide. A self-consistent stale manifest must not pass an upgrade.
    foreach ($name in @('MicDrop.exe', 'micdrop_rtc.dll', 'README.md', 'BETA_TESTING.md', 'LICENSE', 'NOTICE')) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $appRoot $name)).Hash -eq
            (Get-FileHash -LiteralPath (Join-Path $Source $name)).Hash) "Wrong source payload installed: $name"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'windows-host.exe'))) 'The development console host was installed.'
    Assert-Registered $Version
}

function Wait-UninstallCleanup([string] $Executable) {
    # Inno's first phase exits before its temporary child removes that original
    # executable and runs DeinitializeUninstall. Wait for observable ownership
    # release, not an arbitrary delay or just the launcher's exit code.
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    do {
        $held = $null
        $mutexPresent = [Threading.Mutex]::TryOpenExisting($mutexName, [ref]$held)
        if ($null -ne $held) { $held.Dispose() }
        if (-not $mutexPresent -and -not (Test-Path -LiteralPath $Executable)) {
            $lock = $null
            try {
                $lockPath = Join-Path $dataRoot 'identity\paired-listener.lock'
                if (Test-Path -LiteralPath $lockPath) {
                    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::Open,
                        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                }
                $script:uninstallCleanupPending = $false
                return
            } catch [IO.IOException] {
                # The temporary uninstaller still owns the existing data lock.
            } finally { if ($null -ne $lock) { $lock.Dispose() } }
        }
        Start-Sleep -Milliseconds 100
    } while ($deadline.Elapsed.TotalSeconds -lt 30)
    throw 'The temporary uninstaller did not release its fixture ownership within 30 seconds.'
}

function Invoke-Installer([string] $Name, [string] $Executable, [bool] $ShouldSucceed, [string[]] $Extra = @()) {
    $logName = '{0:D2}-{1}.log' -f ($operations.Count + 1), $Name
    $logPath = Join-Path $reportRoot $logName
    Write-Host "Installer check: $Name"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in (@('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$logPath") + $Extra)) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start installer check: $Name" }
        if (-not $process.WaitForExit(90000)) {
            # Only terminate the exact child process tree started by this test.
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw "Installer check exceeded its 90-second deadline: $Name"
        }
        $code = $process.ExitCode
        $operations.Add([ordered]@{ name = $Name; exit_code = $code; expected_success = $ShouldSucceed; log = $logName })
        Save-Report
        if (($code -eq 0) -ne $ShouldSucceed) {
            if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 45 | Write-Host }
            throw "Unexpected installer exit code $code for $Name (success expected: $ShouldSucceed)."
        }
        if ($ShouldSucceed -and [IO.Path]::GetFileName($Executable) -like 'unins*.exe') {
            $script:uninstallCleanupPending = $true
            Wait-UninstallCleanup $Executable
        }
    } finally { $process.Dispose() }
}

function Build-HostFixture([string] $Module, [string] $Name) {
    $root = Join-Path $testRoot $Name
    $source = Join-Path $root 'apps\windows-host'
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    "module $Module`n`ngo 1.26.7" | Set-Content -LiteralPath (Join-Path $root 'go.mod')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'testdata\installer-host\main_windows.go') -Destination $source
    $exe = Join-Path $root 'windows-host.exe'
    & go -C $root build -buildvcs=false -o $exe ./apps/windows-host
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the disposable host fixture.' }
    return $exe
}

function Start-HostFixture([string] $Executable, [bool] $HoldIdentity) {
    $ready = Join-Path $testRoot ("ready-" + [Guid]::NewGuid().ToString('N'))
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    foreach ($arg in @('--ready', $ready)) { [void]$start.ArgumentList.Add($arg) }
    if ($HoldIdentity) {
        foreach ($arg in @('--mutex', $mutexName, '--lock', (Join-Path $dataRoot 'identity\paired-listener.lock'))) {
            [void]$start.ArgumentList.Add($arg)
        }
    }
    $process = [Diagnostics.Process]::Start($start)
    $fixtureProcesses.Add($process)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready)) {
        if ($process.HasExited -or $timer.Elapsed.TotalSeconds -gt 10) { throw 'Disposable host fixture did not become ready.' }
        Start-Sleep -Milliseconds 50
    }
    return $process
}

function Build-TestInstaller([string] $Version, [string] $Revision, [string] $Source, [string] $Output) {
    & (Join-Path $PSScriptRoot 'build_windows_installer.ps1') -PayloadDirectory $Source `
        -OutputDirectory $Output -CompilerPath $compiler -AppVersion $Version -BuildRevision $Revision `
        -InstallerTestRoot $testRoot -InstallerTestId $testId | Out-Host
    $executables = @(Get-ChildItem -LiteralPath $Output -Filter '*-setup.exe' -File)
    Assert-True ($executables.Count -eq 1) 'Expected exactly one isolated setup executable.'
    return $executables[0].FullName
}

Save-Report
try {
    # An early test AppId exceeded Inno's 57-character registry-name limit.
    # Remove only its orphan registration after its isolated files were cleaned
    # up. Never touch a live fixture, another account, or the real MicDrop entry.
    $uninstallParentPath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $parent = $registry.OpenSubKey($uninstallParentPath)
    try {
        if ($null -ne $parent) {
            foreach ($name in @($parent.GetSubKeyNames() | Where-Object { $_ -like 'MicDrop.InstallerTest.*_is1' })) {
                $entry = $parent.OpenSubKey($name)
                try {
                    $label = [string]$entry.GetValue('DisplayName', '')
                    $location = ([string]$entry.GetValue('InstallLocation', '')).TrimEnd('\')
                } finally { $entry.Dispose() }
                if ($label -match '^MicDrop Installer Test ([0-9a-fA-F-]{36})$') {
                    $previousId = $Matches[1]
                    $previousRoot = Join-Path $workBase "micdrop installer test $previousId"
                    if ($location -eq (Join-Path $previousRoot 'app') -and -not (Test-Path -LiteralPath $previousRoot)) {
                        $registry.DeleteSubKeyTree("$uninstallParentPath\$name", $false)
                    }
                }
            }
        }
    } finally { if ($null -ne $parent) { $parent.Dispose() } }
    Assert-True (-not (Test-Path -LiteralPath $testRoot)) 'Refusing to reuse an existing installer-test directory.'
    Assert-True (-not (Test-Path -LiteralPath $shortcutRoot)) 'The isolated Start menu group already exists.'
    $existing = $registry.OpenSubKey($uninstallKey)
    try { Assert-True ($null -eq $existing) 'The isolated uninstall registration already exists.' }
    finally { if ($null -ne $existing) { $existing.Dispose() } }
    Assert-True ($null -eq (Get-RunValue)) 'The isolated Run value already exists.'
    $claimsVerified = $true
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $testRootCreated = $true
    $reparse = @(Get-ChildItem -LiteralPath $payload -Recurse -Force |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    Assert-True ($reparse.Count -eq 0) 'The test input must not contain links/junctions.'
    $source0 = Join-Path $testRoot 'payload-before'
    $source1 = Join-Path $testRoot 'payload-after'
    Copy-Item -LiteralPath $payload -Destination $source0 -Recurse
    Copy-Item -LiteralPath $payload -Destination $source1 -Recurse
    Add-Content -LiteralPath (Join-Path $source1 'README.md') -Value "`nInstaller upgrade fixture $testId"
    $revision0 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $revision1 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $setup0 = Build-TestInstaller '0.1.0-dev' $revision0 $source0 (Join-Path $testRoot 'setup-before')
    $setup1 = Build-TestInstaller '0.1.1-dev' $revision1 $source1 (Join-Path $testRoot 'setup-after')

    # A portable GUI must block even the first install, not just replacement of
    # already-installed binaries. Merely closing its window is insufficient.
    $created = $false
    $mutex = [Threading.Mutex]::new($false, $mutexName, [ref]$created)
    try {
        Assert-True $created 'The isolated GUI mutex already exists.'
        Invoke-Installer 'fresh-install-gui-running' $setup0 $false
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'MicDrop.exe'))) 'Blocked fresh install wrote application files.'
        Assert-Unregistered
    } finally { $mutex.Dispose() }
    Invoke-Installer 'fresh-install' $setup0 $true
    Assert-InstalledPayload '0.1.0-dev' $revision0 $source0
    Assert-True ($null -eq (Get-RunValue)) 'Fresh installation enabled sign-in startup without consent.'
    $checks.Add('Fresh per-user install, matching payload, shortcut, registration, and startup off')

    # These are deliberately opaque fixtures, not live keys or credentials.
    New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'identity'), (Join-Path $dataRoot 'logs') | Out-Null
    '{"version":1,"port":9844,"notifications":true}' | Set-Content -LiteralPath (Join-Path $dataRoot 'desktop-v1.json')
    foreach ($name in @('host-identity-v1.dpapi', 'paired-devices-v1.dpapi', 'remote-connection-v1.dpapi', 'paired-listener.lock')) {
        [IO.File]::WriteAllBytes((Join-Path $dataRoot "identity\$name"), [Text.Encoding]::UTF8.GetBytes("Opaque installer fixture: $testId / $name"))
    }
    '{"fixture":"retained-session-log"}' | Set-Content -LiteralPath (Join-Path $dataRoot 'logs\retained.jsonl')
    $dataBefore = Get-TreeFingerprint $dataRoot
    $extraFile = Join-Path $appRoot 'keep-unmanaged-file.txt'
    'This file is not installer-owned.' | Set-Content -LiteralPath $extraFile
    $extraBefore = (Get-FileHash -LiteralPath $extraFile).Hash
    $ownStartup = '"' + (Join-Path $appRoot 'MicDrop.exe') + '" desktop --background'
    $legacyStartup = '"' + (Join-Path $appRoot 'windows-host.exe') + '" desktop --background'
    Set-RunValue $legacyStartup
    # Simulate the previous shipped package, plus a user-added file in its tools folder.
    $legacyFiles = @(
        'windows-host.exe', 'DESKTOP-GUIDE.md', 'INPUT-BRIDGE-GUIDE.md',
        'MICROPHONE-RETURN-GUIDE.md', 'DUPLEX-GUIDE.md', 'HEADSET-INPUTS-GUIDE.md',
        'REMOTE-GUIDE.md', 'M3_TURN_TESTING.md', 'ADVANCED_SETTINGS.md',
        'ANDROID_ADB_TESTING.md', 'PR39_REMAINING_TESTS.md', 'M3_CLOSEOUT.md',
        'M3_ICE_STARTUP.md', 'M3_ICE_TRICKLE.md', 'M3_ROUTE_SELECTION.md',
        'INSTALLER-GUIDE.md', 'latency-tools/latency.py',
        'latency-tools/requirements.txt', 'latency-tools/README.md'
    )
    foreach ($name in $legacyFiles) {
        $path = Join-Path $appRoot $name
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        'Legacy package fixture' | Set-Content -LiteralPath $path
    }
    $extraTool = Join-Path $appRoot 'latency-tools/keep-my-report.txt'
    'User measurement report' | Set-Content -LiteralPath $extraTool
    $extraToolBefore = (Get-FileHash -LiteralPath $extraTool).Hash
    $appBefore = Get-TreeFingerprint $appRoot
    $uninstaller = Join-Path $appRoot 'unins000.exe'
    Assert-True (Test-Path -LiteralPath $uninstaller -PathType Leaf) 'The uninstaller is missing.'

    foreach ($guard in @('gui', 'paired-cli', 'binary')) {
        $handle = $null
        try {
            switch ($guard) {
                'gui' {
                    $created = $false
                    $handle = [Threading.Mutex]::new($false, $mutexName, [ref]$created)
                    Assert-True $created 'A previous installer leaked its GUI mutex handle.'
                }
                'paired-cli' {
                    $handle = [IO.File]::Open((Join-Path $dataRoot 'identity\paired-listener.lock'),
                        [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                }
                'binary' {
                    $handle = [IO.File]::Open((Join-Path $appRoot 'micdrop_rtc.dll'),
                        [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                }
            }
            Invoke-Installer "upgrade-blocked-$guard" $setup1 $false
            Invoke-Installer "uninstall-blocked-$guard" $uninstaller $false
        } finally { if ($null -ne $handle) { $handle.Dispose() } }
        Assert-True ((Get-TreeFingerprint $appRoot) -eq $appBefore) "Blocked $guard operation changed application files."
        Assert-True ((Get-TreeFingerprint $dataRoot) -eq $dataBefore) "Blocked $guard operation changed personal data."
        Assert-True ((Get-RunValue) -eq $legacyStartup) "Blocked $guard operation changed startup."
        Assert-Registered '0.1.0-dev'
        $checks.Add("Upgrade and uninstall reject $guard activity without changing files/data/startup")
    }

    Invoke-Installer 'upgrade-after-cleanup' $setup1 $true
    Assert-InstalledPayload '0.1.1-dev' $revision1 $source1
    Assert-True ((Get-TreeFingerprint $dataRoot) -eq $dataBefore) 'Upgrade changed settings, pairing, remote configuration or logs.'
    Assert-True ((Get-RunValue) -eq $ownStartup) 'Upgrade changed the saved startup opt-in.'
    Assert-True ((Get-FileHash -LiteralPath $extraFile).Hash -eq $extraBefore) 'Upgrade changed an unmanaged file.'
    foreach ($name in $legacyFiles) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot $name))) "Upgrade left obsolete package file: $name"
    }
    Assert-True ((Get-FileHash -LiteralPath $extraTool).Hash -eq $extraToolBefore) 'Upgrade removed a user-added tools file.'
    # A subsequent repair may remove the old tools directory only when it is empty.
    Remove-Item -LiteralPath $extraTool
    Invoke-Installer 'repair-removes-empty-legacy-tools-directory' $setup1 $true @('/MAINTENANCE=modify')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'latency-tools'))) 'Repair left an empty legacy tools directory.'
    $checks.Add('Upgrade removes old packaged files, migrates installed CLI startup and preserves personal/unmanaged files')

    # Only these disposable, same-account fixture processes may be stopped.
    # The compile-time --scope prevents touching a real host on the runner.
    $hostFixture = Build-HostFixture 'github.com/maskarauder/MicDrop' 'portable'
    $unrelatedFixture = Build-HostFixture 'example.invalid/unrelated' 'unrelated'
    $unrelated = Start-HostFixture $unrelatedFixture $false
    $portable = Start-HostFixture $hostFixture $true
    Invoke-Installer 'upgrade-closes-portable-host' $setup1 $true
    Assert-True ($portable.WaitForExit(5000)) 'Upgrade did not stop the old portable host.'
    Assert-True (-not $unrelated.HasExited) 'Installer stopped an unrelated same-name executable.'
    Assert-InstalledPayload '0.1.1-dev' $revision1 $source1
    Assert-True ((Get-TreeFingerprint $dataRoot) -eq $dataBefore) 'Automatic shutdown/upgrade changed personal data.'

    # Simulate an installed legacy host holding its executable and identity.
    Copy-Item -LiteralPath $hostFixture -Destination (Join-Path $appRoot 'windows-host.exe') -Force
    $installedHost = Start-HostFixture (Join-Path $appRoot 'windows-host.exe') $true
    Invoke-Installer 'modify-repairs-and-closes-installed-host' $setup1 $true @('/MAINTENANCE=modify', '/TASKS=desktopicon')
    Assert-True ($installedHost.WaitForExit(5000)) 'Modify did not stop the installed host.'
    Assert-InstalledPayload '0.1.1-dev' $revision1 $source1
    $desktopShortcut = Join-Path $testRoot "desktop\MicDrop Installer Test $testId.lnk"
    Assert-True (Test-Path -LiteralPath $desktopShortcut) 'Modify did not create the requested desktop shortcut.'
    Invoke-Installer 'upgrade-preserves-shortcut-option' $setup1 $true
    Assert-True (Test-Path -LiteralPath $desktopShortcut) 'Upgrade forgot the chosen desktop shortcut.'
    Invoke-Installer 'modify-removes-desktop-shortcut' $setup1 $true @('/MAINTENANCE=modify', '/TASKS=')
    Assert-True (-not (Test-Path -LiteralPath $desktopShortcut)) 'Modify did not remove its unchecked desktop shortcut.'
    Assert-True ((Get-TreeFingerprint $dataRoot) -eq $dataBefore) 'Modify changed personal data.'
    $checks.Add('Upgrade/modify close old portable and installed hosts, repair files, preserve unrelated processes and shortcut preferences')

    Invoke-Installer 'uninstall-preserve-data' $uninstaller $true
    Assert-Unregistered
    foreach ($name in @('MicDrop.exe', 'windows-host.exe', 'micdrop_rtc.dll', 'payload-manifest.json', 'LICENSE', 'NOTICE')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot $name))) "Uninstall left owned file $name."
    }
    Assert-True ((Get-TreeFingerprint $dataRoot) -eq $dataBefore) 'Uninstall removed or changed personal data.'
    Assert-True ((Get-FileHash -LiteralPath $extraFile).Hash -eq $extraBefore) 'Uninstall removed an unmanaged file.'
    Assert-True ($null -eq (Get-RunValue)) 'Uninstall left startup pointing at the removed application.'
    $checks.Add('Uninstall removes owned files/registration/startup, preserves all personal data and unmanaged files')

    Invoke-Installer 'reinstall-with-retained-data' $setup1 $true
    Assert-InstalledPayload '0.1.1-dev' $revision1 $source1
    Assert-True ((Get-TreeFingerprint $dataRoot) -eq $dataBefore) 'Reinstall changed retained personal data.'
    Assert-True ($null -eq (Get-RunValue)) 'Reinstall unexpectedly enabled startup.'
    $foreignStartup = '"' + (Join-Path $testRoot 'portable\MicDrop.exe') + '" desktop --background'
    Set-RunValue $foreignStartup
    Invoke-Installer 'upgrade-retain-portable-startup' $setup1 $true
    Assert-True ((Get-RunValue) -eq $foreignStartup) 'Installer stole the portable application startup entry.'
    $portable = Start-HostFixture $hostFixture $true
    Invoke-Installer 'maintenance-uninstall-retain-portable-startup' $setup1 $true @('/MAINTENANCE=uninstall')
    Assert-True ($portable.WaitForExit(5000)) 'Maintenance uninstall did not stop the running host.'
    Assert-Unregistered
    Assert-True ((Get-RunValue) -eq $foreignStartup) 'Uninstall removed a different portable application startup entry.'
    Assert-True ((Get-TreeFingerprint $dataRoot) -eq $dataBefore) 'Final uninstall changed retained personal data.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $appRoot 'MicDrop.exe'))) 'Maintenance uninstall reinstalled the application.'
    Assert-True (-not $unrelated.HasExited) 'Maintenance uninstall stopped the unrelated fixture.'
    $checks.Add('Reinstall preserves data; setup maintenance uninstall removes the app while preserving unrelated portable startup')
    $report.result = 'passed'
    Write-Host 'Windows installer lifecycle checks passed. Real interactive installation and audio remain workstation acceptance.'
} catch {
    $report.result = 'failed'
    $report.error = $_.Exception.Message
    Write-Host "Installer test failed: $($report.error)"
    try { Write-FailureDiagnostics } catch { Write-Host "Could not collect installer diagnostics: $($_.Exception.Message)" }
    throw
} finally {
    $report.finished_utc = [DateTime]::UtcNow.ToString('o')
    Save-Report
    try {
        foreach ($process in $fixtureProcesses) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
            $process.Dispose()
        }
        if ($uninstallCleanupPending) {
            throw "The test fixture is still owned by its uninstaller; retained at $testRoot"
        }
        if ($claimsVerified) {
            # Only unique test-owned entries are removed; never delete the shared Run key.
            $registry.DeleteSubKeyTree($uninstallKey, $false)
            $run = $registry.OpenSubKey($runKeyPath, $true)
            if ($null -ne $run) {
                try { $run.DeleteValue($productId, $false) } finally { $run.Dispose() }
            }
            if (Test-Path -LiteralPath $shortcutRoot) { Remove-Item -LiteralPath $shortcutRoot -Recurse -Force }
        }
        if ($testRootCreated -and (Test-Path -LiteralPath $testRoot)) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    } catch {
        $report.result = 'failed'
        $report.cleanup_error = $_.Exception.Message
        Save-Report
        if ($null -eq $report.error) { throw }
        Write-Host "Installer test cleanup also failed: $($report.cleanup_error)"
    } finally { $registry.Dispose() }
}
