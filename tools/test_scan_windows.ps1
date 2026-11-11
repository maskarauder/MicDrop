# Pure event-correlation tests: no Defender settings, scans, or EICAR files.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$scriptPath = Join-Path $PSScriptRoot 'scan_windows.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$function = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Find-PositiveControlEvent'
}, $true)
if ($null -eq $function) { throw 'Positive-control event matcher was not found.' }
# Load just the matcher, so tests run without elevation and on non-Windows hosts.
Invoke-Expression $function.Extent.Text

$script:events = @()
function Get-WinEvent { param($FilterHashtable, $ErrorAction) return $script:events }
function New-TestEvent([string] $Threat, [string] $Resource, [datetime] $Time, [int] $Id = 1116) {
    $event = [pscustomobject]@{ Id = $Id; RecordId = 42; TimeCreated = $Time;
        Xml = "<Event><EventData><Data Name='Threat Name'>$Threat</Data><Data Name='Path'>$Resource</Data></EventData></Event>" }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { return $this.Xml }
    return $event
}

$since = [datetime]'2026-10-24T12:00:00Z'
$archive = 'C:\Temp\micdrop-scan-control-unique\scanner-positive-control.zip'
$fresh = $since.AddSeconds(1)
$script:events = @(New-TestEvent 'Virus:DOS/EICAR_Test_File' "containerfile:_$archive; file:_$archive->scanner-positive-control.txt" $fresh)
if ($null -eq (Find-PositiveControlEvent $archive $since)) { throw 'Fresh archive detection was rejected.' }

foreach ($event in @(
    (New-TestEvent 'Virus:DOS/EICAR_Test_File' "file:_$archive" $since.AddSeconds(-1)),
    (New-TestEvent 'Virus:DOS/EICAR_Test_File' 'file:_C:\Temp\other\scanner-positive-control.zip' $fresh),
    (New-TestEvent 'Virus:DOS/EICAR_Test_File' "file:_$archive.other" $fresh),
    (New-TestEvent 'Virus:DOS/EICAR_Test_File' 'file:_C:\Temp\scanner-positive-control.txt' $fresh),
    (New-TestEvent 'OtherThreat' "file:_$archive" $fresh),
    (New-TestEvent 'Virus:DOS/EICAR_Test_File' "file:_$archive" $fresh 1117)
)) {
    $script:events = @($event)
    if ($null -ne (Find-PositiveControlEvent $archive $since)) {
        throw "Unrelated/stale evidence was accepted: $($event.Xml)"
    }
}
$script:events = @()
if ($null -ne (Find-PositiveControlEvent $archive $since)) { throw 'Missing evidence was accepted.' }
Write-Host 'All 8 Defender event-correlation cases passed.'
