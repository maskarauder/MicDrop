# macOS Desktop App (`MicDrop.app`)

`MicDrop.app` is the native Apple Silicon (`arm64`, macOS 14.2+) desktop host UI. It shares the same Go host controller, settings file schema (`desktop-v1.json`), pairing keystore, LAN discovery, remote rendezvous transport, and phone settings editor as the Windows desktop app (`MicDrop.exe`) and the CLI host (`micdrop-host`).

## Hardware Testing Status & Feedback Wanted

> [!IMPORTANT]
> **Apple Silicon hardware feedback requested:** `MicDrop.app` and `micdrop-host` are built and verified in GitHub Actions on `macos-26` (`arm64` Mach-O & ad-hoc `codesign` validation, live AppKit window/control contracts with rendered tab screenshots, and native C++ WebRTC Opus/DTLS-SRTP loopback), **but maintainer testing does not yet include physical Apple Silicon Mac hardware.**
>
> If you test `MicDrop.app` or `micdrop-host` on an M-series Mac (macOS 14.2+), please share what works or fails in a [GitHub Issue](https://github.com/maskarauder/MicDrop/issues):
> - Your macOS version, Mac chip model, and phone OS/model.
> - Whether the macOS **System Audio Recording** and **Local Network** permission prompts appear and capture desktop playback across built-in speakers, USB/wired DACs, or AirPods/Bluetooth outputs.
> - Optional phone microphone return through a user-space virtual audio cable (such as BlackHole 2ch) into Discord, Zoom, or QuickTime/Voice Memos.
> - Menu bar (`NSStatusItem`), Notification Center alerts, and optional login `LaunchAgent` startup behavior.
> - Never attach pairing invitations, QR screenshots containing live tokens, or relay credentials.

## Capabilities and Design

- **Native AppKit UI (`internal/desktop/appkit_darwin_arm64.m`, `ui_darwin_arm64.go`, `phone_settings_darwin_arm64.go`):**
  - Persistent header with host state, Start/Stop controls, connected device summary, live transport metrics (`Network RTT`, `RTP jitter`, `Playback buffer`, `Output queue`), and `Device settings…`.
  - **Audio:** Select `Default macOS output` or a specific CoreAudio output endpoint for desktop playback capture, and select `Disabled — desktop playback only` or a user-space virtual audio cable (such as BlackHole 2ch) for phone microphone return.
  - **Connection:** Explicit private IPv4 LAN adapter picker, control port (`9844` default), opt-in remote connections toggle, `Import remote config…` (`NSOpenPanel`), `Forget remote config`, and `macOS Firewall…` shortcut.
  - **Phones:** Approved phone list with revocation, private one-time QR code invitation (rendered with nearest-neighbor Retina crispness), `Copy pairing link`, and request-ID verification (`Approve` / `Reject`).
  - **Options:** Opt-in per-user login startup (`~/Library/LaunchAgents/com.maskarauder.micdrop.host.plist` running `MicDrop desktop --background` in the `Aqua` session), macOS Notification Center alerts (`UNUserNotificationCenter`), and connection log retention controls.
  - **Phone Settings Editor:** Live/Audio/Advanced remote phone settings editing with revision locking and explicit `Reload` protection on concurrent phone-side changes.
- **Menu Bar (`NSStatusItem`) & System Icons:**
  - Uses standard macOS SF Symbols (`mic`, `mic.fill`, `waveform`) in template mode with `Open MicDrop`, `Start host` / `Stop host`, and `Quit MicDrop`. No custom generated icon artwork is bundled.
  - Closing the window hides it to the menu bar while `NSStatusItem` is active; clicking `MicDrop` in Finder/Dock or launching a second instance brings the existing window forward (`desktop.lock` + `SIGUSR1` / `applicationShouldHandleReopen:`).

## Files and State Locations

- **Desktop preferences, lock & logs:** `~/Library/Application Support/MicDrop/desktop-v1.json`, `desktop.lock`, and `~/Library/Application Support/MicDrop/logs/`.
- **Host identity, paired phones & remote config:** `~/Library/Application Support/MicDrop/identity/` and `~/Library/Application Support/MicDrop/keystore/` (mode `0700` directories, `0600` AES-256-GCM keystore envelope + `flock`).
- **Optional login LaunchAgent:** `~/Library/LaunchAgents/com.maskarauder.micdrop.host.plist` (created only when `Start host when I sign in to macOS` is enabled; removed when unchecked).

## Permissions on macOS 14.2+

1. **System Audio Recording (`NSAudioCaptureUsageDescription`):** CoreAudio Process Tap (`CATapDescription`) prompts for `Screen & System Audio Recording` -> **System Audio Recording Only** when an authenticated phone starts desktop playback capture. Capture never opens at app launch or during pairing.
2. **Local Network (`NSLocalNetworkUsageDescription` & `_micdrop._tcp`):** macOS 15+ prompts for Local Network access when starting the paired LAN listener and Bonjour/mDNS advertisement.
3. **Notifications:** Requested via `UNUserNotificationCenter` only when running inside `MicDrop.app` with notifications enabled.

## Building and Verifying `MicDrop.app` Locally

```sh
python3 tools/fetch_webrtc.py macos
cmake -S . -B build/native -DCMAKE_BUILD_TYPE=Release -DMICDROP_BUILD_RTC=ON
cmake --build build/native --config Release --parallel 4

MACOSX_DEPLOYMENT_TARGET=14.2 CGO_ENABLED=1 go build -trimpath -o build/macos-app/MicDrop-bin ./apps/windows-host
python3 tools/macos_app_bundle.py build \
  --executable build/macos-app/MicDrop-bin \
  --rtc-dylib build/native/native/rtc/libmicdrop_rtc.dylib \
  --webrtc-notice .deps/webrtc/macos/webrtc/NOTICE \
  --webrtc-versions .deps/webrtc/macos/webrtc/VERSIONS \
  --output-app build/macos-app/MicDrop.app
rm -f build/macos-app/MicDrop-bin

codesign --force --sign - build/macos-app/MicDrop.app/Contents/Frameworks/libmicdrop_rtc.dylib
codesign --force --sign - build/macos-app/MicDrop.app
codesign --verify --deep --strict --verbose=2 build/macos-app/MicDrop.app

# Launch the GUI:
open build/macos-app/MicDrop.app

# Or run CLI diagnostics directly from the app bundle executable:
./build/macos-app/MicDrop.app/Contents/MacOS/MicDrop doctor
./build/macos-app/MicDrop.app/Contents/MacOS/MicDrop rtc-check
```
