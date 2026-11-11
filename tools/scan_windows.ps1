# Scan a Windows CI package with Microsoft Defender custom archive/script scanning.
[CmdletBinding(DefaultParameterSetName = 'Scan')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Scan')][string[]] $Path,
    [Parameter(Mandatory, ParameterSetName = 'Scan')][string] $ReportDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Check')][switch] $CheckConfiguration,
    [Parameter(Mandatory, ParameterSetName = 'Configure')][switch] $ConfigureEphemeralRunner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'

function Assert-ElevatedWindows {
    if (-not $IsWindows) { throw 'This scan requires Windows and PowerShell 7.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Microsoft Defender scanning requires an elevated PowerShell session.'
    }
}

function Assert-DefenderConfiguration {
    Assert-ElevatedWindows
    if ((Get-Service -Name WinDefend).Status -ne 'Running') {
        throw 'Microsoft Defender (WinDefend) must be running before scanning packages.'
    }
    $preferences = Get-MpPreference
    if ($preferences.DisableArchiveScanning -or $preferences.DisableScriptScanning) {
        throw 'Enable Defender archive and script scanning before scanning packages.'
    }
    if ($preferences.SubmitSamplesConsent -ne 2 -or $preferences.MAPSReporting -ne 0) {
        throw 'CI package scanning requires cloud reporting off (MAPSReporting=0) and sample submission set to Never send (SubmitSamplesConsent=2).'
    }
    return $preferences
}

if ($ConfigureEphemeralRunner) {
    Assert-ElevatedWindows
    if ($env:GITHUB_ACTIONS -ne 'true') {
        throw '-ConfigureEphemeralRunner is restricted to ephemeral GitHub Actions runners.'
    }
    $atpPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
    if (Test-Path -LiteralPath $atpPolicy) {
        Remove-ItemProperty -LiteralPath $atpPolicy -Name 'ForceDefenderPassiveMode' -Force -ErrorAction SilentlyContinue
    }
    $service = Get-Service -Name WinDefend
    if ($service.Status -ne 'Running') {
        Start-Service -Name WinDefend
    }
    Set-MpPreference -DisableArchiveScanning $false -DisableScriptScanning $false -MAPSReporting 0 -SubmitSamplesConsent 2
    $null = Assert-DefenderConfiguration
    Write-Host 'Configured ephemeral GitHub Actions runner Defender scan policy.'
    return
}

function Find-PositiveControlEvent([string] $Archive, [datetime] $Since) {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Windows Defender/Operational'
        Id = 1116
        StartTime = $Since
    } -ErrorAction SilentlyContinue)
    foreach ($event in $events) {
        if ($event.TimeCreated -lt $Since -or $event.Id -ne 1116) { continue }
        $xml = [xml]$event.ToXml()
        $fields = @{}
        foreach ($data in $xml.Event.EventData.Data) {
            $fields[$data.GetAttribute('Name')] = $data.InnerText
        }
        # Match this attempt's unique ZIP, not an old EICAR event or a loose TXT.
        if ($fields['Threat Name'] -match 'EICAR_Test_File' -and
            $fields.ContainsKey('Path') -and
            [regex]::IsMatch($fields['Path'], '(?i)(?:^|_)' + [regex]::Escape($Archive) + '(?=$|;|\||->)')) {
            return [ordered]@{ event_id = 1116; record_id = $event.RecordId;
                threat_name = $fields['Threat Name']; path = $fields['Path'] }
        }
    }
    return $null
}

if ($CheckConfiguration) {
    $null = Assert-DefenderConfiguration
    Write-Host 'Defender account and scan policy are ready.'
    return
}

$reportRoot = [IO.Path]::GetFullPath($ReportDirectory)
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$report = [ordered]@{
    schema = 1
    result = 'incomplete'
    started_utc = [DateTime]::UtcNow.ToString('o')
    finished_utc = $null
    scanner = $null
    positive_control = 'not_run'
    positive_control_event = $null
    files = @()
    commands = @()
    error = $null
}
$controlRoot = $null

function Save-Report {
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportRoot 'scan.json') -Encoding utf8
}

function Invoke-Defender([string] $Label, [string[]] $Arguments) {
    $output = @(& $script:scanner @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $log = "$Label.log"
    $output | Out-String | Set-Content -LiteralPath (Join-Path $reportRoot $log) -Encoding utf8
    $output | ForEach-Object { Write-Host $_ }
    $report.commands += [ordered]@{ name = $Label; exit_code = $exitCode; log = $log }
    Save-Report
    return [pscustomobject]@{ ExitCode = $exitCode; Text = ($output -join "`n") }
}

function Get-Inventory([string[]] $Targets) {
    for ($index = 0; $index -lt $Targets.Count; $index++) {
        $item = Get-Item -LiteralPath $Targets[$index] -Force
        $files = @(if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force | Sort-Object FullName
        } else { $item })
        if ($files.Count -eq 0) { throw "Scan target $index is empty." }
        foreach ($file in $files) {
            $name = if ($item.PSIsContainer) { [IO.Path]::GetRelativePath($item.FullName, $file.FullName) } else { $file.Name }
            [ordered]@{
                target = $index
                name = $name
                bytes = $file.Length
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
}

Save-Report
try {
    $preferences = Assert-DefenderConfiguration
    if ($Path.Count -eq 0) { throw 'At least one scan target is required.' }
    $targets = @($Path | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
    foreach ($target in $targets) {
        if ($reportRoot.Equals($target, [StringComparison]::OrdinalIgnoreCase) -or
            $reportRoot.StartsWith($target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Keep scan reports outside the scan targets.'
        }
    }
    $report.files = @(Get-Inventory $targets)
    $before = ConvertTo-Json -InputObject $report.files -Depth 4 -Compress
    Save-Report

    $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    # Recent platform installs expose a CurrentVersion junction alongside the
    # numbered directories. Prefer it and only version-sort parseable fallbacks.
    $script:scanner = Join-Path $platform 'CurrentVersion\MpCmdRun.exe'
    if (-not (Test-Path -LiteralPath $script:scanner -PathType Leaf)) {
        $candidates = @(Get-ChildItem -Path "$platform\*\MpCmdRun.exe" -ErrorAction SilentlyContinue |
            Where-Object {
                $platformVersion = $null
                [version]::TryParse($_.Directory.Name.Split('-')[0], [ref]$platformVersion)
            } | Sort-Object { [version]($_.Directory.Name.Split('-')[0]) } -Descending)
        $script:scanner = if ($candidates.Count -gt 0) { $candidates[0].FullName } else {
            Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
        }
    }
    if (-not (Test-Path -LiteralPath $script:scanner -PathType Leaf)) { throw 'Microsoft Defender scanner is unavailable.' }

    # Ignore exclusions for the explicit package scans, without weakening the
    # persistent VM's real-time protection or changing its preferences.
    $update = Invoke-Defender 'signature-update' @('-SignatureUpdate')
    if ($update.ExitCode -ne 0) { throw "Defender signature update failed (exit $($update.ExitCode))." }
    $status = Get-MpComputerStatus
    $signatureTime = $status.AntivirusSignatureLastUpdated.ToUniversalTime()
    $report.scanner = [ordered]@{
        engine = $status.AMEngineVersion
        platform = $status.AMProductVersion
        signature = $status.AntivirusSignatureVersion
        signature_updated_utc = $signatureTime.ToString('o')
        running_mode = $status.AMRunningMode
        cloud_reporting = [int]$preferences.MAPSReporting
        sample_submission = [int]$preferences.SubmitSamplesConsent
        custom_scan_ignores_exclusions = $true
        real_time_protection_enabled = $status.RealTimeProtectionEnabled
    }
    Save-Report
    if (-not $status.AMServiceEnabled -or [string]::IsNullOrWhiteSpace($status.AMEngineVersion)) {
        throw 'The Defender scanning service is not available.'
    }
    if (([DateTime]::UtcNow - $signatureTime).TotalHours -gt 48) { throw 'Defender signatures are more than 48 hours old.' }

    # Create the EICAR ZIP in memory: never write an unarchived positive control.
    # Real-time protection may quarantine the ZIP before the custom scan opens
    # it. Only a fresh Defender event naming this exact archive is acceptable
    # evidence in that case. Keep real-time protection enabled throughout.
    $controlRoot = Join-Path ([IO.Path]::GetTempPath()) ('micdrop-scan-control-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $controlRoot | Out-Null
    $controlZip = Join-Path $controlRoot 'scanner-positive-control.zip'
    $testString = 'X5O!P%@AP[4\PZX54(P^)7CC)7}' + '$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
    $memory = [IO.MemoryStream]::new()
    $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        $entry = $archive.CreateEntry('scanner-positive-control.txt')
        $stream = $entry.Open()
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes($testString)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    } finally { $archive.Dispose() }
    $controlStarted = Get-Date
    $controlError = $null
    try {
        [IO.File]::WriteAllBytes($controlZip, $memory.ToArray())
        $control = Invoke-Defender 'positive-control' @('-Scan', '-ScanType', '3', '-File', $controlZip, '-DisableRemediation')
        if ($control.ExitCode -eq 2 -and $control.Text -match 'EICAR_Test_File') {
            $report.positive_control = 'custom_scan_archive_detection_confirmed'
        }
    } catch {
        $controlError = $_.Exception.Message
    } finally { $memory.Dispose() }
    if ($report.positive_control -eq 'not_run') {
        $wait = [Diagnostics.Stopwatch]::StartNew()
        do {
            $evidence = Find-PositiveControlEvent $controlZip $controlStarted
            if ($null -ne $evidence) {
                $report.positive_control = 'defender_archive_detection_event_confirmed'
                $report.positive_control_event = $evidence
                break
            }
            Start-Sleep -Milliseconds 500
        } while ($wait.Elapsed.TotalSeconds -lt 15)
        if ($report.positive_control -eq 'not_run') {
            throw "Defender did not confirm EICAR in this attempt's ZIP; scan cannot be trusted. $controlError"
        }
    }
    Save-Report
    Remove-Item -LiteralPath $controlRoot -Recurse -Force
    $controlRoot = $null

    for ($index = 0; $index -lt $targets.Count; $index++) {
        $scan = Invoke-Defender "target-$index" @('-Scan', '-ScanType', '3', '-File', $targets[$index], '-DisableRemediation')
        if ($scan.ExitCode -ne 0) {
            throw "Defender detected a threat or could not complete target $index (exit $($scan.ExitCode)); see target-$index.log."
        }
    }
    $after = ConvertTo-Json -InputObject @(Get-Inventory $targets) -Depth 4 -Compress
    if ($before -cne $after) { throw 'Package files changed during scanning.' }
    $report.result = 'no_threats_detected'
} catch {
    $report.result = 'failed'
    $report.error = $_.Exception.Message
    throw
} finally {
    if ($null -ne $controlRoot) { Remove-Item -LiteralPath $controlRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $report.finished_utc = [DateTime]::UtcNow.ToString('o')
    Save-Report
    if ($env:GITHUB_STEP_SUMMARY) {
        @"
### Windows antivirus scan

Result: **$($report.result)**. Positive control: $($report.positive_control).

See the retained scan-report artifact for file SHA-256 hashes, Defender versions,
and command output. The positive-control detection is intentional and is not in
the distributed harness. A completed scan does not guarantee safety or change
Chrome's download verdict.
"@ | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }
}

