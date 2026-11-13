# Versioning and draft releases

This workflow assembles **unpublished development prereleases** from the exact
packages that passed the main-branch build. It never publishes a release or
replaces an existing asset. First-party source is licensed under
[MPL-2.0](LICENSING.md). Public delivery still requires accessible matching source
and notices, appropriate signing/distribution preparation, and documented
clean-system acceptance and security-review status.

## Shared version

Edit `internal/version/version.properties` and add matching notes at
`docs/releases/<version>.md`. Windows, Linux, macOS, the Windows installer,
Android and the draft package names read that same version; `MicDrop.app` uses
`tools/macos_app_bundle.py` and the iPhone build uses `tools/ios_version.py`.
Current metadata is `0.1.0-beta.3` with Android version code `4`.

Use `MAJOR.MINOR.PATCH`, optionally followed by `-alpha.N`, `-beta.N` or `-rc.N`.
Each numeric Windows component is at most 65535. Increase `android_version_code`
whenever the version changes; never decrease it. CI compares against the PR base
or preceding main commit. Ordinary development commits can retain the current
version and code until the next release candidate is chosen. After a draft has
been assembled, use a new version/code for a different source build rather than
reusing its tag.

```sh
python tools/release_version.py
```

`windows-host.exe version` and `micdrop-host version` print the embedded
version, Android version code, source revision, modified-tree flag and platform
as JSON. Desktop window titles and session log headers also include the app
version. Android and iPhone display their version and source revision in
reports.

These drafts retain `com.maskarauder.micdrop.dev` on Android with the existing
stable Android development signing secret so existing development APK
installations update in place without losing pairings or settings (it remains a
debuggable development APK rather than a Play Store release). Linux x64 packages
remain unsigned. On `main` and `workflow_dispatch` runs with Azure Artifact
Signing secrets configured, Windows x64 packages (`MicDrop.exe`,
`micdrop_rtc.dll`, `MicDrop-maintenance.exe`, `unins000.exe`, and
`MicDrop-<version>-windows-x64-setup.exe`) are Authenticode-signed and RFC 3161
timestamped via `tools/windows_signing.py` (see [WINDOWS_SECURITY.md](WINDOWS_SECURITY.md)),
while pull-request builds fall back to unsigned packages without exposing
secrets. Likewise, when Apple signing secrets are configured, macOS arm64
packages (`com.maskarauder.micdrop.mac`)
are signed with `Developer ID Application` + Hardened Runtime and notarized with
Apple (`MicDrop.app` includes a stapled notarization ticket), while pull-request
builds fall back to ad-hoc signing without exposing secrets. On iPhone, the app
uses the production bundle ID `com.maskarauder.micdrop`: GitHub Releases
optionally include the unsigned sideload `.ipa` (`MicDrop-<version>-ios-arm64-unsigned.ipa`),
while `ios.yml` also archives and verifies an `Apple Distribution` signed `.ipa`
and uploads it to App Store Connect / TestFlight when manually dispatched with
`upload_testflight: true`. No signing secret is needed inside `draft-release.yml`
itself, and private signing keys are never retained as artifacts. The Android
build retains its installable APK only when `MICDROP_DEBUG_KEYSTORE_BASE64` is
configured and verified.

## Assemble a draft

1. Merge the version/notes and desired changes to `main`.
2. Wait for **Build and audio contracts** on that `main` commit to pass all jobs
   (and optionally wait for **iPhone app** on that same `main` commit if you want
   to include the unsigned iPhone IPA). PR merge-test builds are not eligible. A
   manual build dispatched on `main` is also eligible. Copy the numeric workflow
   run ID(s) from GitHub Actions.
3. Open **Actions → Assemble draft release → Run workflow**, select **main**,
   enter `build_run_id` (and optional `ios_run_id`), and run the workflow.
4. The workflow validates the source run(s), commit SHA, version, notes and
   retained artifact manifests (`windows-x64-harness-retained`,
   `windows-x64-installer-retained`, `linux-x64-host-retained`,
   `macos-arm64-app-retained`, `macos-arm64-host-retained`,
   `android-apk-retained`, and optional `ios-ipa-retained`). It
   creates a draft marked **INCOMPLETE**, then the Windows, Linux, and macOS
   jobs verify and upload their packages directly to that draft.
5. The final job requires every selected package, checks GitHub's SHA-256 digests,
   adds `release-manifest.json` and `SHA256SUMS`, then marks the draft ready for
   human review. **It stays a draft and is not marked as Latest.** Do not publish
   it while assembly is running or while any job has failed.

Drafts are visible only to repository collaborators with write access until
manually published. Public publication is a separate manual decision after the
remaining release requirements are addressed.

Main-branch builds automatically upload `*-retained` artifact bundles with 14-day
GitHub Actions retention so ephemeral GitHub-hosted runners (`ubuntu-24.04`,
`windows-2022`, `macos-26`) can verify and promote exact build outputs without
rebuilding. Release assets are uploaded through the GitHub Releases API using the
job's short-lived `GITHUB_TOKEN`; no personal token is required. Write access is
scoped to the draft workflow, while normal CI builds retain read-only permissions.

## Contents

| Asset | Purpose |
| --- | --- |
| `MicDrop-<version>-windows-x64-setup.exe` | Authenticode-signed per-user Windows installer (with signed uninstaller and maintenance helper) |
| `MicDrop-<version>-windows-x64-portable.zip` | Authenticode-signed `MicDrop.exe` and `micdrop_rtc.dll`, required notices, README and beta guide |
| `MicDrop-<version>-windows-build.json` | Windows source/build identity, Authenticode signer metadata, and package hashes |
| `MicDrop-<version>-linux-x64-host.tar.gz` | Linux x64 CLI + GTK3 desktop host, WebRTC `.so`, and notices |
| `MicDrop-<version>-linux-build.json` | Linux source/build identity and archive hash |
| `MicDrop-<version>-macos-arm64-app.zip` | Developer ID signed, Apple-notarized macOS 14.2+ arm64 `MicDrop.app` desktop bundle |
| `MicDrop-<version>-macos-arm64-host.tar.gz` | Developer ID signed, Apple-notarized macOS 14.2+ arm64 CLI host, WebRTC `.dylib`, and notices |
| `MicDrop-<version>-macos-build.json` | macOS bundle/source identity, Developer ID signing and notarization status, minimum OS, and package hashes |
| `MicDrop-<version>-android-arm64-dev.apk` | Existing development identity, with the new version code |
| `MicDrop-<version>-android-build.json` | Android identity, public signer fingerprint and package hash |
| `MicDrop-<version>-ios-arm64-unsigned.ipa` | Optional unsigned iPhone bundle (`com.maskarauder.micdrop`) for Apple ID sideloading |
| `MicDrop-<version>-ios-build.json` | Optional iPhone bundle identity, minimum iOS version and IPA hash |
| `release-manifest.json` | Complete package/build-manifest inventory with SHA-256 hashes |
| `SHA256SUMS` | Hashes for all assets except the checksum file itself |

The portable archive is built from the installer's curated payload list, not a
live installation or user profile. Windows, Linux, and macOS executables,
`MicDrop.app` metadata/signatures/stapled notarization ticket, and installer
metadata must match the selected version and source revision. Android package
name, version name/code and APK signature are inspected before upload. The
normal CI build exercises this staging path across Windows, Linux, macOS, and
Android without creating a release or uploading release assets.

### Include an optional iPhone IPA

To include the optional iPhone assets in **Assemble draft release**, supply the
`ios_run_id` input from a successful **iPhone app** (`ios.yml`) run on the
**exact same `main` commit** as `build_run_id` (leave `ios_run_id` blank for a
desktop + Android draft). A PR merge-build IPA or a run from another commit
is rejected before creating or modifying the draft.

The workflow downloads `ios-ipa-retained` from that Apple run and verifies the
unsigned `MicDrop.ipa` through `tools/check_ios_bundle.py`: executable and
framework contracts, unsigned state, bundle ID, minimum iOS version, embedded
source revision and all three version fields must match the selected `main`
build. New iPhone assets are refused once `release-manifest.json` or `SHA256SUMS`
exists; exact retries of already included assets remain allowed.

To inspect an unsigned IPA locally without GitHub access or creating a draft,
run `stage` from a checkout of the matching source commit:

```sh
python3 tools/draft_release.py stage \
  --platform ios \
  --ios-ipa /path/to/MicDrop.ipa \
  --run-id "$BUILD_RUN_ID" \
  --sha "$FULL_SOURCE_SHA" \
  --output build/draft-ios-preview
```

Offline staging checks local bundle identity, while workflow `upload` additionally
verifies that the source build passed on GitHub. `finish` includes both optional
iPhone assets in `release-manifest.json` and `SHA256SUMS`.

The Windows allowlist is `tools/windows_payload.json`. Both installer and
portable ZIP require `MicDrop.exe`, `micdrop_rtc.dll`, LICENSE, NOTICE, WebRTC
notice/version provenance, QR/discovery/WebSocket notices, `README.md` and
`BETA_TESTING.md`. Setup additionally installs its maintenance helper, Inno
notice, payload manifest and uninstaller. `windows-host.exe`, developer ADB
instructions and latency tools stay in developer/source artifacts.

Upgrades remove the known old package files from the installed app folder.
Portable users should extract to a fresh folder. Do not manually remove required
notices from a candidate or ZIP the entire developer harness. Release staging
rejects extra/missing/duplicate installer-manifest paths and mismatched bytes.

A Defender file-scan pass does not establish behavior-based installation
acceptance. Follow [Windows security detections](WINDOWS_SECURITY.md), retain the
exact candidate hashes and Microsoft submission outcome, and smoke-test install,
running-app upgrade, launch, repair and uninstall with normal protection enabled.

## Retries and troubleshooting

- Rerun **Assemble draft release** with the same `build_run_id` (and same
  `ios_run_id`, if used) after a transient upload failure. Matching uploaded
  assets are reused. Different or incomplete assets are rejected and never
  overwritten or automatically deleted.
- A published release, an unrelated draft, a moved tag, or a draft for another
  build/attempt is rejected. A human can inspect/remove an incomplete draft or
  choose a new version; the workflow does neither automatically.
- Do not edit the generated release notes until assembly finishes. Finalization
  refuses to overwrite notes edited by a reviewer.
- Retained `*-retained` Actions artifacts expire after 14 days on GitHub. Missing
  or checksum-mismatched files fail the workflow; it does not fall back to a newer
  or older package.
- Windows and Android packages must come from the same build attempt. If only
  failed build jobs were rerun, rerun **all** build jobs before selecting that
  run, or dispatch a fresh `main` build. Optional iPhone packages come from a
  separate **iPhone app** run of the same `main` commit. Do not reuse a completed
  draft for different bits.
- Manual dispatch requires the workflow on the default branch. Local contract
  tests and CI package staging do not substitute for checking the actual draft
  and its uploaded assets.

## Focused validation

For each new release candidate, verify the version/source shown by the
applications, an in-place APK update from the previous installed development
build (and same-Apple-ID sideload refresh when testing iPhone), and the draft's
complete matching asset set and notices. Confirm that existing settings and
pairings survive the update. After changes to the draft workflow, retry the same
draft to check that assets are reused and it stays unpublished.

Carry forward documented device checks only where the relevant behavior has not
changed. Runtime changes still need their own focused regression checks;
assembling a draft does not validate audio, handoffs, or new hardware.

## Volunteer beta

A Windows/Linux/macOS/Android/iPhone beta can use these packages. Tell testers
that Windows is Authenticode-signed (though newly issued certificates may still
show a SmartScreen reputation prompt until download reputation builds), macOS is
Developer ID signed and Apple-notarized, Linux is unsigned, Android is a
debuggable development APK, and iPhone can be
installed via TestFlight or sideloaded from the unsigned IPA with their own
Apple ID. Preserve the stable Android signer (`MICDROP_DEBUG_KEYSTORE_BASE64`);
replacing it prevents in-place updates.

Choose a new version/code and notes before the build. A draft already tied to one
source build cannot be reused for a different build, and App Store Connect /
TestFlight rejects duplicate `(MARKETING_VERSION, CFBundleVersion)` uploads.

### Build and assemble from PowerShell

After merging the candidate changes to `main`, use the push-triggered `main`
workflow runs or dispatch fresh `main` builds:

```powershell
$ErrorActionPreference = 'Stop'
$MicDropRepo = 'maskarauder/MicDrop'
$MicDropVersion = '0.1.0-beta.3'
$MicDropTag = "v$MicDropVersion"

gh workflow run build.yml --repo $MicDropRepo --ref main
if ($LASTEXITCODE -ne 0) { throw 'Could not dispatch the build.' }
gh run list --repo $MicDropRepo --workflow build.yml --branch main --limit 5
```

Optionally dispatch `ios.yml` on `main` if it did not already run for that commit
(add `-f upload_testflight=true` when submitting a new version/build number to
App Store Connect / TestFlight):

```powershell
gh workflow run ios.yml --repo $MicDropRepo --ref main
gh run list --repo $MicDropRepo --workflow ios.yml --branch main --limit 5
```

Wait for the `main` build run(s) to succeed, then dispatch draft assembly (omit
`-f "ios_run_id=..."` if assembling Windows and Android only):

```powershell
$MicDropBuildRun = Read-Host 'Main build.yml run ID'
gh run watch $MicDropBuildRun --repo $MicDropRepo --exit-status
if ($LASTEXITCODE -ne 0) { throw 'Build failed; inspect it before assembling.' }

$MicDropIosRun = Read-Host 'Optional main ios.yml run ID (press Enter to skip)'
$DraftArgs = @('workflow', 'run', 'draft-release.yml', '--repo', $MicDropRepo, '--ref', 'main', '-f', "build_run_id=$MicDropBuildRun")
if ($MicDropIosRun) {
    gh run watch $MicDropIosRun --repo $MicDropRepo --exit-status
    if ($LASTEXITCODE -ne 0) { throw 'iPhone build failed; inspect it before assembling.' }
    $DraftArgs += @('-f', "ios_run_id=$MicDropIosRun")
}
& gh @DraftArgs
if ($LASTEXITCODE -ne 0) { throw 'Could not dispatch draft assembly.' }

$MicDropAssemblyRun = Read-Host 'Draft assembly run ID'
gh run watch $MicDropAssemblyRun --repo $MicDropRepo --exit-status
if ($LASTEXITCODE -ne 0) { throw 'Draft assembly failed; inspect it before sharing.' }
```

### Download and verify

Use a fresh output folder, then download every release asset from the draft:

```powershell
$MicDropBetaFolder = Join-Path ([Environment]::GetFolderPath('Desktop')) "MicDrop-$MicDropVersion-beta"
if (Test-Path -LiteralPath $MicDropBetaFolder) { throw 'Choose a fresh beta folder.' }
New-Item -ItemType Directory -Path $MicDropBetaFolder | Out-Null

gh release download $MicDropTag --repo $MicDropRepo --dir $MicDropBetaFolder
if ($LASTEXITCODE -ne 0) { throw 'Release download failed.' }

Get-Content -LiteralPath (Join-Path $MicDropBetaFolder 'SHA256SUMS') | ForEach-Object {
    if ($_ -notmatch '^([0-9a-fA-F]{64})  ([^/\\]+)$') { throw 'Invalid checksum entry.' }
    $expectedHash = $Matches[1]
    $assetName = $Matches[2]
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $MicDropBetaFolder $assetName)).Hash
    if ($actualHash -ne $expectedHash) { throw "Checksum mismatch: $assetName" }
    Write-Host "Verified $assetName"
}

$MicDropManifest = Get-Content -LiteralPath (Join-Path $MicDropBetaFolder 'release-manifest.json') -Raw | ConvertFrom-Json
$MicDropSourceSha = $MicDropManifest.source_sha
if ($MicDropManifest.version -ne $MicDropVersion -or
    $MicDropManifest.build_run_id -ne $MicDropBuildRun -or
    $MicDropSourceSha -notmatch '^[0-9a-f]{40}$') {
    throw 'Downloaded release does not match the selected candidate/build.'
}
```

### Include source and the tester guide

Keep the matching MPL-covered source and notices accessible to recipients.
The [MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) explains distribution
to recipients; see also [Licensing](LICENSING.md).

When sharing an unpublished draft bundle outside GitHub Releases, include a
source archive from the exact commit recorded in `release-manifest.json` along
with `BETA_TESTING.md`, `LICENSE`, and `NOTICE`:

```powershell
$MicDropSourceFolder = Join-Path ([IO.Path]::GetTempPath()) ("MicDrop-source-" + [guid]::NewGuid().ToString('N'))
gh repo clone $MicDropRepo $MicDropSourceFolder -- --no-checkout --depth 1
if ($LASTEXITCODE -ne 0) { throw 'Source clone failed.' }
git -C $MicDropSourceFolder fetch --depth 1 origin $MicDropSourceSha
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch the matching source commit.' }
git -C $MicDropSourceFolder checkout --detach $MicDropSourceSha
if ($LASTEXITCODE -ne 0) { throw 'Could not check out the matching source.' }

$MicDropSourceZip = Join-Path $MicDropBetaFolder "MicDrop-$MicDropVersion-source.zip"
git -C $MicDropSourceFolder archive --format=zip `
    "--prefix=MicDrop-$MicDropVersion-source/" `
    "--output=$MicDropSourceZip" `
    $MicDropSourceSha
if ($LASTEXITCODE -ne 0) { throw 'Source archive failed.' }

Copy-Item -LiteralPath (Join-Path $MicDropSourceFolder 'docs/BETA_TESTING.md') `
    -Destination (Join-Path $MicDropBetaFolder 'BETA_TESTING.md')
Copy-Item -LiteralPath (Join-Path $MicDropSourceFolder 'LICENSE'), (Join-Path $MicDropSourceFolder 'NOTICE') `
    -Destination $MicDropBetaFolder
```

Keep the build scripts/configuration and required notices intact. The extra
source ZIP and standalone tester guide are separate from the workflow-generated
binary inventory in `SHA256SUMS` and `release-manifest.json`.

Smoke-test the exact installer and phone build(s) yourself: install/update,
confirm versions, pair/reconnect, and play audio. Check retained settings and
pairings for your existing installation before sharing with volunteers.

The [tester guide](BETA_TESTING.md) covers setup, basic checks, optional microphone
testing, known limits, and useful reports. Have testers complete the basic
checks on their own hardware and record unavailable hardware checks as skipped.
