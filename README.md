# MicDrop

Use your Android phone or iPhone—and its connected headphones or headset—as a
wireless speaker, microphone, or two-way headset for your Windows 11 PC.

**Status: public beta.** Windows and Android LAN/remote streaming have passed
functional acceptance on tested hardware; the iPhone app has passed Apple CI and
initial LAN duplex/mute checks, with broader physical route, locked-screen, and
remote device testing still underway.

## Features

- **Listen, talk, or both:** Stream desktop audio to your phone, send your phone
  or headset microphone back to Windows apps, or run full duplex over WebRTC/Opus.
- **No account or cloud required:** Works directly over your local Wi-Fi/LAN
  with automatic host discovery and no internet dependency.
- **Private pairing:** Scan a QR code or paste an invitation link on your phone
  and approve the device on Windows. Revoke paired phones anytime.
- **Built for daily use:** Choose audio outputs and inputs from the phone, mute,
  pause/resume, keep streaming with the screen off, and recover automatically
  from brief Wi-Fi or headset interruptions.
- **Optional remote access:** Connect away from home through a self-hosted
  rendezvous and TURN relay service when you need it.

## Download & Quick Start

Download matching Windows and phone packages from the latest release on the
**[Releases page](https://github.com/maskarauder/MicDrop/releases)**:

| Platform | Download | Notes |
| --- | --- | --- |
| **Windows 11 (x64)** | `MicDrop-Setup-*-windows-x64.exe` or `MicDrop-*-windows-x64.zip` | Per-user installer ([guide](docs/WINDOWS_INSTALLER.md)) or portable ZIP |
| **Android 12+ (arm64)** | `MicDrop-*-android-arm64.apk` | Sideload APK ([guide](docs/ANDROID.md)); same-key updates keep your pairing |
| **iPhone (iOS 17+ arm64)** | `MicDrop-*-ios-arm64-unsigned.ipa` | Sideload with your Apple ID via AltStore, SideStore, Sideloadly, or Xcode ([guide](docs/DEVELOPMENT.md#install-on-iphone)) |
| **Linux (optional)** | Built from source / CI artifact | Self-hosted remote rendezvous service ([guide](docs/SERVICE_DEPLOYMENT.md)) |

### Setup in 4 Steps

1. **Install on Windows:** Run the setup installer (or extract the portable ZIP)
   and launch **MicDrop** from the Start menu or system tray
   ([desktop guide](docs/WINDOWS_DESKTOP.md)).
2. **Install on your phone:** Install the matching Android `.apk` or sideload
   the iPhone `.ipa` from the same release version.
3. **Pair your phone:** Click **Pair phone** in the Windows app, scan the QR
   code (or paste the link) on your phone, and click **Approve** on Windows.
4. **Connect:** Tap **Connect** on your phone to start listening to desktop
   audio.
   - **Using your phone as a PC microphone?** Install a separate Windows
     [virtual audio cable](docs/VIRTUAL_AUDIO_CABLE.md), select its input in
     MicDrop on Windows, and enable the microphone mode on your phone.
   - **Connecting outside your home Wi-Fi?** See the optional
     [remote access guide](docs/REMOTE_ACCESS.md).

## Things to Know

- **Unsigned beta builds:** Windows packages are not code-signed yet, so
  Windows SmartScreen may prompt on first run (*More info → Run anyway*). The
  Android APK is sideloaded rather than from Google Play, and the iPhone IPA is
  unsigned—signing with a free Apple ID requires refreshing every 7 days.
- **Bluetooth audio behavior:** Bluetooth headphones add device buffering delay,
  and using a classic Bluetooth headset's microphone can switch headphone
  playback to voice call quality depending on the headset and OS.
- **Virtual cable not bundled:** Microphone return requires a separately
  installed Windows virtual audio cable; MicDrop does not install kernel audio
  drivers.
- **One active stream at a time:** The Windows host runs while you are signed in
  and awake, and accepts one active phone audio session at a time.
- **Latency stats vs. physical delay:** In-app RTT and buffer counters show
  network/pipeline health, not acoustic speaker-to-ear latency
  (see [latency measurement](docs/LATENCY.md) and the [roadmap](docs/ROADMAP.md)).

For step-by-step testing tips, battery/background settings, and full user
guides, see the [beta testing guide](docs/BETA_TESTING.md) and the
[documentation index](docs/README.md).

## Support MicDrop

MicDrop is free and open source. If you find it useful and want to support
ongoing development, code-signing certificates, and store releases, you can
chip in on Ko-fi:

- **[Support MicDrop on Ko-fi (ko-fi.com/maskarauder)](https://ko-fi.com/maskarauder)**

## Report Issues & Contribute

- **Bug reports:** Open an [Issue](https://github.com/maskarauder/MicDrop/issues)
  with your app version, Windows/phone OS version, audio route (speaker, wired,
  or Bluetooth model), and steps to reproduce. Review diagnostic reports before
  sharing and never post pairing links, relay credentials, or private audio.
- **Security vulnerabilities:** Please report privately via
  [SECURITY.md](SECURITY.md) rather than a public issue
  (see also the [security and privacy guide](docs/SECURITY.md)).
- **Building from source & contributing:** Developers looking to build locally,
  run contract checks, or submit pull requests should start with
  [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

First-party MicDrop code and documentation are licensed under the
[Mozilla Public License 2.0](LICENSE). [NOTICE](NOTICE) describes repository
coverage, and third-party components retain their own licenses and notices. See
[licensing and funding](docs/LICENSING.md) for details.
