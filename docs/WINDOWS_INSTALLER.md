# Windows installer

Use the [beta guide](BETA_TESTING.md) for a first test session, or the
[desktop guide](WINDOWS_DESKTOP.md) for settings and controls.

## Install

1. Download the matching `MicDrop-<version>-windows-x64-setup.exe` from the
   candidate supplied by the maintainer. A portable ZIP is available separately.
2. Finish any connection you want to keep running. Setup closes running MicDrop
   copies owned by your Windows account before changing files. Closing a MicDrop
   window with X only hides it in the tray; setup also handles those copies.
3. Run the setup executable as your normal Windows user. It installs into
   `%LOCALAPPDATA%\Programs\MicDrop` by default and creates a Start menu shortcut
   and a Windows uninstall entry. The optional desktop shortcut is off by default.
   It does not require a machine service or
   administrator installation.
4. Open **MicDrop** from Start. Use the [desktop guide](WINDOWS_DESKTOP.md) to choose
   your adapter/audio devices and start the host. An existing paired phone can
   reconnect using the same Windows user account; no new pairing is required.
5. Allow the installed `MicDrop.exe` on your trusted **Private** network when
   Windows asks. A firewall rule for the old portable executable path does not
   cover its new installed location. The installer does not change firewall
   policy automatically.

Setup includes `MicDrop.exe`, its media DLL, the maintenance helper, MPL-2.0
`LICENSE`, `NOTICE`, dependency notices, `README.md`, and `BETA_TESTING.md`.
The developer console executable and milestone reports are not installed. It does not start a stream, enable sign-in startup, install a virtual
audio driver, or change the VPS. Phone microphone return still requires a
separately installed virtual cable. Standard installer icons and the existing
MicDrop text branding are placeholders; no generated artwork is included.

Official `main`-branch and release packages (`setup.exe`, `unins000.exe`,
`MicDrop-maintenance.exe`, `MicDrop.exe`, and `micdrop_rtc.dll`) are
Authenticode-signed and timestamped via Microsoft Azure Artifact Signing, while
local developer and pull-request builds remain unsigned. Authenticode signing
establishes publisher identity and satisfies Smart App Control signature checks,
though newly issued certificates still build Windows SmartScreen download
reputation gradually. For a reported malware detection, follow the
[Windows security guide](WINDOWS_SECURITY.md); code signing or a clean CI file
scan cannot guarantee that another PC will accept installation.
MicDrop is licensed under [MPL-2.0](../LICENSE); public distribution also requires
[accessible matching source and reviewed dependency notices](LICENSING.md).

## Existing settings and portable installations

Application files and personal data are separate:

| Location | Contents |
| --- | --- |
| `%LOCALAPPDATA%\Programs\MicDrop` | Installed application and uninstaller |
| `%LOCALAPPDATA%\MicDrop\desktop-v1.json` | Saved desktop choices |
| `%LOCALAPPDATA%\MicDrop\identity` | Protected host identity, phone approvals and remote configuration |
| `%LOCALAPPDATA%\MicDrop\logs` | Desktop session logs |

Setup never imports, rewrites or deletes the existing personal data. Its reuse
depends on running under the same Windows account, because the identity and
remote credentials use that account's DPAPI protection. A CLI configuration
created with a custom identity directory is not moved into the default store.
Logs beside a previous portable installation remain in that folder.

If sign-in startup previously pointed to the portable copy, open the installed
app and enable **Options → Start host when I sign in to Windows** again. Setup
does not silently redirect a portable startup entry. You can then remove the old
portable application files if you no longer need them; retain any logs you want.
Do not run the portable and installed hosts simultaneously against the same
identity store.

## Upgrade, modify and repair

Rerunning setup detects the current account's installation and offers three buttons:

- **Upgrade / reinstall this package** replaces application files with the package
  you launched and keeps your existing shortcut choice and saved preferences.
- **Modify shortcuts / repair installation** reinstalls the package and lets you
  enable or remove its optional desktop shortcut. App settings remain in MicDrop.
- **Uninstall MicDrop** removes the installed application while retaining personal data.

Setup uses the fixed per-user installation location. An enabled startup entry for
that installed path stays valid across upgrade/repair; startup remains off if it
was off. An old startup entry for the installed `windows-host.exe` is redirected to
`MicDrop.exe` to preserve that existing opt-in. A portable startup entry is not
redirected. Upgrade/repair deletes only named files from the older package,
including its console executable, old guides and latency scripts. User-added
files are preserved, and the old tools directory is removed only when empty.

After you confirm an action, setup requests the desktop app's **Exit** operation
and allows up to ten seconds for cleanup. It then terminates any remaining verified
MicDrop processes owned by the same Windows account, including old portable/CLI
copies. Executable names alone are not sufficient: the helper also checks the
embedded Go application identity and process owner. Other users' processes and
unrelated same-name programs are not terminated. A forced shutdown may omit the
last log records. It never force-closes an arbitrary program just because that
program holds an installer file open.

The installer waits for processes and file locks to be released before replacing
files. If an elevated copy or another program keeps files locked, exit it and
retry. No replacement is deferred until reboot. Cancelling before the action's
confirmation does not stop the host.

Silent automation uses `/MAINTENANCE=upgrade`, `/MAINTENANCE=modify`, or
`/MAINTENANCE=uninstall` together with the usual Inno silent flags. The default is
upgrade/reinstall. Modify can use `/TASKS=desktopicon` or `/TASKS=`. Removal requires
an existing installation and does not install this package afterward.

Versioned draft bundles are assembled from successful main builds as described
in [RELEASING.md](RELEASING.md). Updates use manual downloads and installation. It adds no automatic
update checker or background update service.

## Uninstall and reinstall

Choose **Uninstall** in setup or use Windows **Settings → Apps → Installed apps**.
After confirmation, running MicDrop copies are closed automatically. Uninstall removes its application files, owned shortcuts and uninstall
entry. It removes the MicDrop sign-in entry only when that entry points to this
installation; a startup command for another portable copy is left alone.

Personal data is always retained. Reinstalling under the same Windows account
reuses the existing settings and pairings. Sign-in startup must be enabled again
after uninstall/reinstall if desired. The separately installed virtual cable is
not removed.

For an intentional complete reset, first exit every MicDrop host and uninstall
the application, then manually remove `%LOCALAPPDATA%\MicDrop`. This deletes the
saved configuration, logs, host identity and approvals; phones must pair again.
Uninstall itself never performs that reset.

## Validation

`tools/test_windows_installer.ps1` builds an isolated test product and exercises
fresh install, blocked file replacement, upgrade, repair, shortcuts, automatic
shutdown, removal of old package files, startup migration, and uninstall. It
checks that personal data and unrelated files/processes survive. These tests do
not use real pairing credentials or stop the developer's normal host.

Before distributing a candidate, test the exact setup under a normal Windows
account with the usual Defender protection enabled: fresh install, upgrade with
the app running, launch/reconnect, repair and uninstall. Confirm Start menu and
firewall behavior, settings/pairing reuse, and the absence of old packaged files.
A headless runner cannot establish all user-visible or behavior-based outcomes.

## Build and provenance

Build the complete Windows harness as described in [DEVELOPMENT.md](DEVELOPMENT.md),
then run from the repository root:

```powershell
python tools/windows_payload.py
if ($LASTEXITCODE -ne 0) { throw 'Windows payload preparation failed.' }
./tools/build_windows_installer.ps1 `
    -PayloadDirectory build/host `
    -OutputDirectory build/windows-installer
```

On non-PR CI runs when the Azure Artifact Signing secrets are configured, CI signs
`build/host/MicDrop.exe` and `build/host/micdrop_rtc.dll` beforehand via
`tools/windows_signing.py` and passes `-SignInstaller` to
`build_windows_installer.ps1` so `MicDrop-maintenance.exe` (before
`payload-manifest.json` hashing), `unins000.exe`, and the outer setup executable
are Authenticode-signed and RFC 3161 timestamped. Local developer builds omit
`-SignInstaller` and compile cleanly unsigned.

The build uses a pinned, checksum-verified **Inno Setup 7.1.0** compiler. Its source,
release downloads and license are maintained by
[Inno Setup](https://jrsoftware.org/isinfo.php). The compiler's license does not
select a license for MicDrop or grant redistribution rights to its dependencies.
The package keeps the project license, source information, and existing
dependency notices.

CI retains `windows-x64-installer` alongside `windows-x64-harness`, with build
identity and hashes in the retained artifact manifest. GitHub artifact uploads
remain opt-in; this does not require more hosted Actions storage. The installer
and portable build are development artifacts, not a public release declaration.

The shared allowlist in `tools/windows_payload.json` controls installer and
portable contents. The installer adds its helper and Inno notice; release
staging rejects missing, duplicate or unexpected manifest entries. Existing
released/draft assets are immutable; build a new version for the cleaned package.
