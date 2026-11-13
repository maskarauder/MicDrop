# MicDrop beta testing

MicDrop streams desktop audio (Windows, Linux, or macOS) to an Android phone or
iPhone and its headphones. It can also send the phone or a supported headset
microphone back to the computer.

This is an early volunteer beta. Windows and Linux packages are unsigned, macOS
packages are ad-hoc signed without Apple Developer ID notarization, Android is a
sideloaded development app, and the optional iPhone build is an unsigned IPA
sideloaded with your own Apple ID. Send installation blocks or security detections
to the maintainer; do not disable antivirus or Play Protect to install it.

## What you need

- A Windows 11 x64 PC, a Linux x64 PC (PulseAudio or PipeWire-Pulse, with GTK 3
  for the desktop GUI), or an Apple Silicon Mac running macOS 14.2+ (arm64), plus
  an Android 12+ arm64 phone or an iPhone running iOS 17+ (arm64).
- Both devices on the same trusted home network for the first test. The computer
  may use Ethernet; avoid guest Wi-Fi that isolates devices.
- The matching desktop host package and Android APK (or optional unsigned iPhone
  IPA) supplied by the maintainer.
- Optional headphones. Test the phone speaker first to establish a baseline.

No developer tools, USB debugging, account, or internet connection are needed
for local Android playback. Android may ask for permission to install from the
browser or file manager used to open the APK; allow that source only for
installation, then turn the permission off again. Sideloading on iPhone requires
Apple's web (non-Microsoft Store) iTunes/iCloud USB drivers (on Windows), an
Apple ID for 7-day free developer signing, and internet access once to trust the
developer certificate on the phone.

## Install and pair

1. Install or extract the desktop host for your platform:
   - **Windows**: Run `MicDrop-<version>-windows-x64-setup.exe` as your normal
     Windows user (`%LOCALAPPDATA%\Programs\MicDrop`), or extract
     `MicDrop-<version>-windows-x64-portable.zip` into a fresh folder and open
     `MicDrop.exe`.
   - **macOS (Apple Silicon, 14.2+)**: Extract
     `MicDrop-<version>-macos-arm64-app.zip` (for example with Finder or
     `ditto -x -k`) and open `MicDrop.app`, or extract
     `MicDrop-<version>-macos-arm64-host.tar.gz` for `./micdrop-host`.
   - **Linux (x64)**: Extract `MicDrop-<version>-linux-x64-host.tar.gz` (`tar -xzf`)
     and run `./micdrop-host desktop` (use `./micdrop-host desktop --install-launcher`
     for an application-menu entry).
2. Open **MicDrop**. Under **Audio**, choose the desktop playback device whose
   audio you want to send. Leave microphone return disabled.
3. Under **Connection**, select your physical home-network adapter and address,
   save, and choose **Start host**. Permit MicDrop on your trusted local network
   if your OS firewall or macOS Local Network / System Audio Recording prompt
   asks. Do not disable your firewall.
4. Install the matching phone build:
   - **Android**: Open `MicDrop-<version>-android-arm64-dev.apk` on the phone and
     install it. For an existing development installation, update it in place. If
     Android reports an incompatible signature, stop and report it before
     uninstalling; uninstalling removes saved app data and pairing.
   - **iPhone (optional beta)**: Connect the iPhone over USB and sign/install
     `MicDrop-<version>-ios-arm64-unsigned.ipa` with your Apple ID using
     [iloader](https://github.com/nab138/iloader) or [Sideloadly](https://sideloadly.io/)
     (keep the default bundle ID `com.maskarauder.micdrop.dev`). On first sideload,
     enable **Settings → Privacy & Security → Developer Mode** (requires restart),
     trust your Apple ID under **Settings → General → VPN & Device Management**,
     then open MicDrop and allow **Local Network** access when prompted. Free Apple ID
     signatures expire after 7 days; re-sideload with the same Apple ID to keep saved
     pairings and settings.
5. On Windows, choose **Phones → Pair a phone**. On the phone, scan the QR or
   paste the pairing link and tap **Connect**. Camera permission is needed only
   for scanning. Compare the request ID and approve the phone on Windows.
6. Play familiar audio on Windows and check the phone speaker. Keep pairing
   links and QR images private.

Only one phone can stream from a Windows host at a time. Closing the Windows
window leaves MicDrop in the tray; use **Exit** when you want to shut it down.

## Background battery and permission settings

Before the locked-screen test on **Android**, check MicDrop's battery settings.
Menu names vary by phone and Android version. (On **iPhone**, iOS manages
background audio without per-app battery-optimization menus; record whether
**Low Power Mode** is on and verify **Settings → MicDrop → Local Network** is
enabled if LAN connections fail.)

1. Open **Settings → Apps → MicDrop → App battery usage** (sometimes **Battery**).
   On Pixel, use **See all apps** if MicDrop is not listed.
2. Record the current setting. If **Allow background usage** is off, turn it on.
   On phones with a **Restricted** choice, switch to **Optimized** for the first
   test. Leave an existing **Optimized** setting unchanged.
3. If audio stops after switching apps or locking the screen, note the time and
   copy the available reports. Then try **Unrestricted** for MicDrop and repeat
   the same test. On some Pixels, tap the **Allow background usage** row to open
   the optimization choices. Some phones call the exemption **Don't optimize**.
4. On Samsung, also check **Settings → Battery → Background usage limits**
   (older versions put Battery under **Battery and device care**). If MicDrop is
   in **Sleeping apps** or **Deep sleeping apps**, record that and remove it.
   If interruptions continue, try adding MicDrop to **Never sleeping apps**.
5. Record whether **Battery Saver / Power saving** (or iOS **Low Power Mode**) is
   on. If an interruption occurs with it enabled, repeat with it off and report
   both results.
6. Report the original settings, each change, and whether it helped. Keep the
   original failure in the report even if the workaround succeeds.

Unrestricted background use may increase battery consumption and does not
guarantee uninterrupted playback or microphone capture. Change MicDrop's
per-app settings only; there is no need to disable Adaptive Battery globally.
If the default settings work, keep them.

Manufacturer references: [Pixel battery settings](https://support.google.com/pixelphone/answer/7015477?hl=en),
[Android background restrictions](https://developer.android.com/topic/performance/background-optimization),
and [Samsung sleeping apps](https://www.samsung.com/us/support/answer/ANS10003442/).

## First test session

Record the app version, phone model and Android/iOS version, Windows version, and
headphone model. Volunteers should try the basic checks on their own hardware
rather than splitting all coverage between them.

| Check | What to report |
| --- | --- |
| Installation and first pairing | Confusing steps, prompts, failures, or missing audio |
| Phone-speaker playback for 10 minutes | Dropouts, distortion, or noticeable delay |
| Headphone playback | Model, connection type, sound quality, and delay compared with the speaker |
| Pause, resume, Stop, and reconnect | Whether controls and status agree and audio resumes correctly |
| Background and locked screen for 20–30 minutes | Battery/power settings, interruptions, and whether returning to the app changes playback |
| Brief Wi-Fi interruption, then restore it | Recovery message, audio recovery, or whether explicit reconnect is needed |
| Stop from the phone and exit Windows | Audio ends and the apps remain responsive |

Do not interpret RTT or buffer counters as end-to-end audible latency. Bluetooth
can add substantial delay outside MicDrop's network path.

## Optional second session

- Test phone microphone return or duplex only after setting up a virtual audio
  cable on Windows. MicDrop does not include the driver. Select its playback
  endpoint in MicDrop (usually **CABLE Input**) and its recording endpoint in
  the receiving app (usually **CABLE Output**). Enable **Send microphone** on the
  phone and grant microphone permission there. Use headphones and a private
  microphone test to avoid feedback or broadcasting test audio.
- Check that microphone mute and Stop silence the receiving app. Try the
  built-in phone microphone before a Bluetooth headset microphone.
- Try Windows phone settings only after enabling the phone's
  **Advanced → Allow Windows to change phone settings**. This is off by default.
  Settings marked for the next connection require Stop/Connect. On iPhone, iOS
  does not expose remote system-volume control or LE Audio microphone input, and
  wired device selections without persistent OS identifiers are not saved across
  app relaunches.
- Test remote access only with separate setup instructions from the maintainer.
  Local-network playback does not need it.

Hardware you do not have can be marked skipped. Classic Bluetooth microphone
use may reduce playback to voice quality; hearing-aid and LE Audio support
varies by device and operating system.

## Reporting a problem

Send the maintainer:

- For a security detection: exact product/detection text, affected file, time,
  and whether it happened during download, installation, upgrade or launch.

- App version/source revision, phone model/OS, Windows version, and audio devices.
- The exact steps, expected result, actual result, and approximate time.
- Whether the problem happens every time and whether reconnecting fixes it.
- MicDrop's background battery setting (Android) or Low Power Mode / Local Network
  state (iPhone), and any before/after results from changing those settings.
- Phone **Diagnostics → Copy last stream report** (and on Android, **Copy crash
  report** after a crash), when available.
- The corresponding Windows connection log from **Open logs**, if logging was
  enabled. Logging can be configured under Options before starting the host.

Review reports before sharing. Send them privately; do not include pairing
links, QR images, credentials, or private audio recordings. A screenshot is
helpful for layout or unclear wording, with private information removed.

## Updates, removal, and source

Future beta updates are manual: install the matching Windows setup and Android
APK (or re-sideload the matching iPhone IPA with the same Apple ID) provided by
the maintainer. Keep Windows and the phone app on the same candidate. There is
no automatic updater.

Windows uninstall retains settings and pairings. Deleting the phone app removes
its saved app data and pairing; an in-place update with the same signer (or same
Apple ID and bundle ID on iPhone) is the preferred update path.

MicDrop's first-party code is MPL-2.0. The beta download should include
`MicDrop-<version>-source.zip` from the exact binary source revision, or another
working source location accessible to you. License and dependency notices are
included in the Windows package and each phone app's **Open-source notices**.
