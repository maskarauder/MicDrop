# Windows release detections

This guide is for maintainers investigating a reported block. Record the exact
product, detection name, affected resource, and time before changing the package.
A Defender Antivirus detection, a SmartScreen reputation warning, and a firewall
prompt are different checks and require different evidence.

## After Microsoft confirms a false positive

1. Keep the submission ID and **final** determination. Confirm that the affected
   installer's SHA-256 matches the file Microsoft reviewed. A rebuild changes
   its identity; a verdict on one file does not clear every future version.
2. On the affected PC, open Windows Security → Virus & threat protection →
   Protection updates → Check for updates. Retry the exact reviewed candidate
   only after the correction is available; follow any specific instructions in
   Microsoft's response.
3. If detection persists, use the developer contact form attached to the
   submission result. Include the current engine/platform/intelligence versions,
   exact file hash, detection time, affected resource, and reproduction steps.
   Distinguish download, extraction, fresh install, upgrade, launch and uninstall.
   An extracted maintenance helper or DLL can be the detected resource even when
   the notification names setup. Provide the relevant file through the case
   if Microsoft requests it.
4. Preserve the affected files and reports privately. Do not upload private
   build material to public scanning services without the owner's authorization.
   Do not ask testers to disable antivirus, SmartScreen, or add exclusions.

To collect the candidate hash in PowerShell:

```powershell
$MicDropInstaller = 'C:\path\to\MicDrop-<version>-windows-x64-setup.exe'
Get-FileHash -LiteralPath $MicDropInstaller -Algorithm SHA256
```

To update and record Defender versions, run Windows PowerShell as administrator:

```powershell
Update-MpSignature
Get-MpComputerStatus | Select-Object AMProductVersion, AMEngineVersion,
    AntivirusSignatureVersion, AntivirusSignatureLastUpdated
```

Use Protection history for the exact resource and detection text. Redact account
names and unrelated paths before sharing. The name `Behavior:Win32/Execution.A!ml`
does not identify which installer action caused a detection.

## Reduce avoidable release surprises

- Keep the installer per-user with clear consent and stable publisher/product
  metadata. Ship only the allowlisted runtime, notices and current guides.
- Use consistent Authenticode signing with a trusted signing identity for the
  project's Windows executables, DLL and final installer when signing is ready.
  Timestamp signatures, verify them, and generate manifests/checksums from the
  final signed bytes. Integrate signed-uninstaller support with the installer
  tooling as part of that work. Current development builds remain unsigned.
- Retain the exact tested installer for distribution. Do not rebuild or modify
  it after approval and keep the portable/runtime bytes tied to that candidate.
- Test fresh install, upgrade with the app running, launch, repair and uninstall
  on a normal Windows test account with its usual protection enabled. A passing
  file scan does not exercise behavior-based detection during those operations.
- If a repeatable detection remains, collect evidence before changing installer
  behavior. Standard compression or the verified same-user shutdown helper could
  be investigated, but neither is established as the cause. Do not remove process
  ownership checks or disguise binaries to influence detection.

Microsoft does not provide a blanket false-positive prevention program.
Consistent signing can help identify a publisher; it does not guarantee absence
of Antivirus or SmartScreen warnings. Self-signing does not establish a publicly
trusted publisher.

## What CI establishes

`tools/scan_windows.ps1` records hashes and Defender versions, validates its
scanner with an EICAR archive, and scans the package using local intelligence.
The CI scan job intentionally disables cloud reporting and sample submission.
This check is useful evidence, not clearance for every download or installation
environment. The EICAR result belongs to the scanner positive control; target
scan logs cover MicDrop. Preserve that privacy boundary when improving checks.

## Microsoft references

- [Software developer FAQ and submission escalation](https://learn.microsoft.com/en-us/defender-xdr/developer-faq)
- [File submission guide](https://learn.microsoft.com/en-us/unified-secops/submission-guide)
- [Defender PowerShell cmdlets](https://learn.microsoft.com/en-us/defender-endpoint/use-powershell-cmdlets-microsoft-defender-antivirus)
- [Execution.A detection entry](https://www.microsoft.com/en-us/wdsi/threats/malware-encyclopedia-description?name=Behavior%3AWin32%2FExecution.A%21ml)
