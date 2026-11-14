# MicDrop for Windows

Start with **BETA_TESTING.md** for Windows, Android, and optional beta
iPhone installation, pairing, background settings, and the volunteer test
checklist. Use Windows and phone packages from the same release candidate.
Windows 11 x64 is the supported host platform.

## Install or run portable

Run `MicDrop-<version>-windows-x64-setup.exe` as your normal Windows user, then
open **MicDrop** from Start. Setup installs to `%LOCALAPPDATA%\Programs\MicDrop`.
It does not require an administrator, install a driver, enable startup, or change
firewall policy. The optional desktop shortcut is off by default.

Alternatively, extract the entire `windows-x64-portable.zip` to a writable folder
and open **MicDrop.exe**. Keep its DLL and notices together. Extract each update
to a fresh folder so files from old portable packages do not linger. The
developer console program `windows-host.exe` is not needed for normal use.

Closing the app window leaves it running in the tray. Use **Exit** to stop it.
Only one host may use the same identity store at a time. On a trusted home
network, allow `MicDrop.exe` through Windows Firewall for the **Private** profile
when prompted. A rule for an old portable path does not cover the installed app.

## Audio and phone controls

- Under **Audio**, select the Windows playback device to capture.
- Under **Connection**, select your home-network adapter/address, save, and
  choose **Start host**. Start host waits for a phone; it does not start capture.
- Under **Phones → Pair a phone**, show the private invitation, scan/paste it on
  the phone (Android or iPhone), and approve the matching request ID on Windows.
  Keep the invitation private.
- On the phone, enable **Play desktop audio** and choose **Connect**. Enable
  **Send microphone** only when you intend to use the phone microphone.
- Microphone return needs a separately installed virtual audio cable. Select its
  playback endpoint in MicDrop (usually **CABLE Input**) and its recording
  endpoint in the receiving app (usually **CABLE Output**). Test with headphones
  and keep Windows input monitoring off to avoid feedback.

One phone may stream at a time. Bluetooth microphone use may reduce playback
quality. Remote access requires separate rendezvous/TURN setup; it is optional
and is not needed for LAN playback. There is no automatic updater.

Windows **Device settings** requires the phone's **Advanced → Allow Windows to
change phone settings** opt-in. Controls cannot grant phone OS permissions or
start an unauthorized microphone session, and iOS does not expose remote
system-volume control. Settings marked for the next connection require
Stop/Connect. RTT/jitter/buffer figures are diagnostics, not physical
speaker-to-microphone latency measurements.

## Settings, logs, upgrades, and removal

| Location | Contents |
| --- | --- |
| `%LOCALAPPDATA%\Programs\MicDrop` | Installed application and uninstaller |
| `%LOCALAPPDATA%\MicDrop\desktop-v1.json` | Desktop preferences |
| `%LOCALAPPDATA%\MicDrop\identity` | Protected host identity, pairings, and remote configuration |
| `%LOCALAPPDATA%\MicDrop\logs` | Connection logs; also available through **Open logs** |

Save host settings while the host is stopped. **Options** controls sign-in
startup, notifications, logging, and log retention. Startup is opt-in. Turning
logging off retains existing logs. A positive retention count removes older
MicDrop session logs; 0 keeps all.

Rerun setup to upgrade, repair/modify shortcuts, or uninstall. After confirmation,
setup closes verified MicDrop processes owned by your Windows account before
replacing files. It requests a clean exit, then stops remaining verified hosts
if necessary. Finish any session first. If another program keeps files locked,
close it and retry.

Upgrades remove the old packaged console executable, milestone guides and
latency scripts from the installation folder. They preserve preferences,
pairings, logs and unrelated files. An existing startup entry for the removed
installed console is redirected to `MicDrop.exe`; startup remains off if it was
off. A separate portable startup entry is left alone.

Uninstall through Windows **Settings → Apps → Installed apps**, or through setup.
Personal data remains available for reinstall under the same Windows account.
The virtual audio cable is managed separately. An intentional full reset
requires exiting/uninstalling MicDrop and manually removing
`%LOCALAPPDATA%\MicDrop`; this deletes identities and requires pairing again.

## Security detections and reports

When Azure Artifact Signing credentials are configured, official `main`-branch
and release packages are Authenticode-signed and timestamped (unconfigured,
local developer, and pull-request builds remain unsigned; see the release notes
and `MicDrop-<version>-windows-build.json` for verified status). Newly
issued code-signing certificates still build Windows SmartScreen download
reputation gradually, and a SmartScreen reputation prompt and an antivirus
malware detection are different checks. If a file is flagged as malware, stop
and send the maintainer the exact detection, affected file, time, and whether
it happened during download, setup, upgrade, or launch. Check Windows
Security's **Protection history** and update its protection intelligence. Do not
disable protection or create an exclusion to make a beta install work.

For other problems, use the report checklist in **BETA_TESTING.md**. Review logs
before sharing and remove pairing links, credentials, and private audio.

## Package contents and license

Normal operation uses `MicDrop.exe` and `micdrop_rtc.dll`. The portable package
also contains this README, BETA_TESTING.md, LICENSE, NOTICE, and dependency
notices/provenance. Setup adds its maintenance helper, installer notice,
payload manifest, and uninstaller. Developer tools and milestone reports belong
in the source checkout, not this app directory.

First-party code is MPL-2.0; see LICENSE and NOTICE. Recipients must have
access to the matching source and required dependency notices for the exact
binary revision.
