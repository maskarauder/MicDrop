# Current roadmap

The immediate release is a volunteer beta across Windows x64, Linux x64, and
Apple Silicon macOS 14.2+ desktop/CLI hosts with Android and optional
unsigned-IPA iPhone clients: desktop playback, phone microphone return and
duplex, paired LAN, opt-in remote access, native desktop controls (`MicDrop.exe`,
Linux GTK3 `micdrop-host desktop`, and macOS AppKit `MicDrop.app`), and phone
diagnostics screens. Windows/Android LAN and remote streaming have passed
functional checks on tested hardware, the Linux host has passed live
PulseAudio/PipeWire loopback and Xvfb GTK3 UI contracts in CI, the macOS host
has passed `macos-26` AppKit/bundle/signing and WebRTC loopback contracts in CI,
and the iPhone client has passed automated CI/simulator checks plus a basic LAN
duplex/mute control check; calibrated physical latency, physical Apple Silicon
Mac hardware validation, broader iPhone route/background/remote device coverage,
and broad headset compatibility are not established by those results.

## Before the next beta candidate

1. Validate the cleaned installer and portable package, including upgrade from
   the previous package, preserved settings/pairings, and removal of old files.
2. Resolve reported Defender detections for the exact candidate and test normal
   install/upgrade/launch behavior. Follow [Windows security](WINDOWS_SECURITY.md).
3. Choose a new version/code and matching release notes; never replace an
   assembled candidate with different bytes under the same tag.
4. Deliver matching desktop host packages, Android APK, and optional unsigned
   iPhone IPA files, notices, accessible matching source, and the
   [beta guide](BETA_TESTING.md). Have volunteers test their own hardware.
5. Record defects and unavailable hardware checks honestly. Retest the behavior
   affected by fixes rather than assuming untested routes pass.

## Separate preparation

- Complete physical Apple Silicon Mac validation (`Screen & System Audio
  Recording` Process Tap permission, built-in/USB/AirPods output capture,
  BlackHole microphone return, sleep/wake, and `NSStatusItem` / `LaunchAgent`
  behavior; see [macOS desktop](MACOS_DESKTOP.md#hardware-testing-status--feedback-wanted)).
- Complete physical iPhone route, locked-screen, remote/handoff, and desktop
  phone-settings device checks, plus wired/USB route validation across both
  mobile clients.
- Add trusted Windows Authenticode signing, Apple Developer ID signing and
  notarization, and production mobile signing/store distribution when publisher
  accounts and release identities are ready.
- Obtain independent security review and broader device/latency measurements
  before making wider compatibility or performance claims.

Multiple simultaneous phones, Intel macOS or Linux arm64 desktop targets, a
bundled audio driver, automatic updates and paid convenience downloads remain
future decisions. First-party licensing is MPL-2.0; the project starts with
open source and voluntary donations.

The [product requirements](design/PRODUCT.md) and
[decision log](design/DECISIONS.md) retain design context.
