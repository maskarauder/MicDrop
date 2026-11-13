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
- Sign the project's Windows executables, DLL, uninstaller and final installer
  consistently via Microsoft Azure Artifact Signing (`tools/windows_signing.py`)
  on `main` and `workflow_dispatch` builds:
  1. Sign `MicDrop.exe` and `micdrop_rtc.dll` in `build/host` before packaging so
     portable and installer copies share identical signed bytes.
  2. Sign `MicDrop-maintenance.exe` inside `tools/build_windows_installer.ps1`
     immediately after compilation and before `payload-manifest.json` SHA-256
     digests are recorded.
  3. Enable Inno Setup `SignedUninstaller=yes` and `SignTool=micdrop` so both
     `unins000.exe` and `MicDrop-<version>-<sha>-windows-x64-setup.exe` are
     signed and RFC 3161 timestamped (`http://timestamp.acs.microsoft.com`), while
     keeping isolated CI installer tests (`tools/test_windows_installer.ps1`)
     unsigned so test runs consume zero cloud-signing quota.
  4. Verify all Authenticode chains and timestamps (`signtool.exe verify /pa /tw`)
     before Microsoft Defender scanning and record signer provenance in
     `tools/draft_release.py`. Pull-request and fork builds receive no `AZURE_*`
     secrets and fall back cleanly to unsigned development packages.
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
Consistent signing identifies a verified publisher and satisfies Smart App
Control's trusted-signature check, though newly issued certificates still build
SmartScreen download reputation gradually and do not guarantee absence of
Antivirus or SmartScreen warnings. Self-signing does not establish a publicly
trusted publisher.

## CI Azure Artifact Signing configuration

`build.yml` reads repository secrets only on non-`pull_request` runs (`push` to
`main` and `workflow_dispatch`) and wipes ephemeral tokens/secrets under
`if: always()`:

| Secret | Required | Purpose |
| --- | --- | --- |
| `AZURE_TENANT_ID` | Yes | Microsoft Entra directory (tenant) UUID |
| `AZURE_CLIENT_ID` | Yes | Microsoft Entra app registration (client) UUID with **Artifact Signing Certificate Profile Signer** role |
| `AZURE_SIGNING_ENDPOINT` | Yes | Regional HTTPS Artifact Signing URI ending in `.codesigning.azure.net` (for example `https://eus.codesigning.azure.net`) |
| `AZURE_SIGNING_ACCOUNT` | Yes | Azure Artifact Signing account resource name |
| `AZURE_SIGNING_CERT_PROFILE` | Yes | Public Trust certificate profile name |
| `AZURE_CLIENT_SECRET` | Only without OIDC | Optional Entra client secret; omit when using a GitHub Actions OIDC federated credential (`repo:maskarauder/MicDrop:ref:refs/heads/main`) |
| `AZURE_SIGNING_PUBLISHER` | Optional | Display publisher name for Inno Setup `AppPublisher` / `VersionInfoCompany` (defaults to `Noah Seymour`) |

`tools/windows_signing.py` pins and SHA-256-verifies Microsoft's official
`Microsoft.Windows.SDK.BuildTools` (`10.0.28000.2957`) and
`Microsoft.ArtifactSigning.Client` (`1.0.146`) NuGet packages in `.deps/`.

## What CI establishes

`tools/scan_windows.ps1` records hashes and Defender versions, validates its
scanner with an EICAR archive, and scans the final (signed on `main`) package
using local intelligence.
The CI scan job intentionally disables cloud reporting and sample submission.
This check is useful evidence, not clearance for every download or installation
environment. The EICAR result belongs to the scanner positive control; target
scan logs cover MicDrop. Preserve that privacy boundary when improving checks.

## Microsoft references

- [Software developer FAQ and submission escalation](https://learn.microsoft.com/en-us/defender-xdr/developer-faq)
- [File submission guide](https://learn.microsoft.com/en-us/unified-secops/submission-guide)
- [Defender PowerShell cmdlets](https://learn.microsoft.com/en-us/defender-endpoint/use-powershell-cmdlets-microsoft-defender-antivirus)
- [Execution.A detection entry](https://www.microsoft.com/en-us/wdsi/threats/malware-encyclopedia-description?name=Behavior%3AWin32%2FExecution.A%21ml)
