# Current roadmap

The immediate release is a volunteer beta across Windows and Android, with
optional unsigned-IPA sideloading for iPhone: desktop playback, phone microphone
return and duplex, paired LAN, opt-in remote access, native Windows controls,
and phone diagnostics screens. Windows/Android LAN and remote streaming have
passed functional checks on tested hardware, and the iPhone client has passed
automated CI/simulator checks plus a basic LAN duplex/mute control check;
calibrated physical latency, broader iPhone route/background/remote device
coverage, and broad headset compatibility are not established by those results.

## Before the next beta candidate

1. Validate the cleaned installer and portable package, including upgrade from
   the previous package, preserved settings/pairings, and removal of old files.
2. Resolve reported Defender detections for the exact candidate and test normal
   install/upgrade/launch behavior. Follow [Windows security](WINDOWS_SECURITY.md).
3. Choose a new version/code and matching release notes; never replace an
   assembled candidate with different bytes under the same tag.
4. Deliver matching Windows, Android APK, and optional unsigned iPhone IPA
   files, notices, accessible matching source, and the [beta guide](BETA_TESTING.md).
   Have volunteers test their own hardware.
5. Record defects and unavailable hardware checks honestly. Retest the behavior
   affected by fixes rather than assuming untested routes pass.

## Separate preparation

- Complete physical iPhone route, locked-screen, remote/handoff, and Windows
  phone-settings device checks, plus wired/USB route validation across both
  mobile clients.
- Add trusted Windows Authenticode signing and production mobile signing/store
  distribution when publisher accounts and release identities are ready.
- Obtain independent security review and broader device/latency measurements
  before making wider compatibility or performance claims.

Multiple simultaneous phones, desktop hosts on other operating systems, a
bundled audio driver, automatic updates and paid convenience downloads remain
future decisions. First-party licensing is MPL-2.0; the project starts with
open source and voluntary donations.

The [product requirements](design/PRODUCT.md) and
[decision log](design/DECISIONS.md) retain design context.
