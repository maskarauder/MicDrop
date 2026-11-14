# Decision log

> Chronological design record. Earlier proposals describe their original context;
> use the [current guides](../README.md) and outstanding-decision table for today.

“Requested” records the product brief. “Proposed” records a starting point that
may change after evidence. M0 now has an implemented native WebRTC experiment;
hardware-route and physical-latency evidence remain incomplete.

[D048 — Licensing and funding](../LICENSING.md) records the 2026-10-25 decision to
use MPL-2.0, start with voluntary donations, and allow later paid official builds.

| ID | Status | Decision | Reason / revisit trigger |
| --- | --- | --- | --- |
| D001 | Requested | Computer audio to phone, with native routing to connected Bluetooth devices | Core listening use case |
| D002 | Requested | Optional phone/headset microphone return as a computer input | Core differentiator; must reach an OS endpoint |
| D003 | Requested | Local and remote connectivity; latency is a priority | Both environments are in scope |
| D004 | Accepted 2026-09-28 | Windows 11 x64 and Android 12+ MVP; iPhone later | User selected this scope; preserve platform boundaries for a future iOS adapter |
| D005 | Proposed | Native WebRTC/Opus for both LAN and internet | Reuses media/connectivity machinery; reconsider if B001/B004 show unacceptable limitations |
| D006 | Accepted 2026-09-28 | Go host management, shared C++ media boundary, Kotlin Android UI; tray framework deferred | Go handles control; native code owns audio callbacks. WebRTC itself remains a feasibility gate under D005 |
| D007 | Proposed | User-session background Windows host | Simpler user/device lifecycle; unattended pre-sign-in service is separate scope |
| D008 | Proposed | OS-managed media routing for Listen, explicit communication route for supported headset duplex | Reflects incompatible route capabilities; validate in B002 |
| D009 | Diagnostic implemented 2026-09-29; real consumer acceptance pending | User-installed virtual-cable bridge for developer preview | Explicit WASAPI render endpoint feeds the cable recording side; no bundled driver or default fallback. Validate two consumer apps before Android return; production endpoint choice remains open |
| D010 | Proposed | One computer/phone session, independent directions | Keeps initial state and measurements understandable |
| D011 | Proposed | Local operation without accounts or cloud services | Preserves LAN availability and avoids unnecessary remote dependency |
| D012 | Proposed | Remote access opt-in, authenticated signaling, direct media preferred, TURN available | Supports ordinary NAT/firewall conditions with visible fallback |
| D013 | Proposed | Instrument before optimizing; publish targets separately from measurements | Makes latency work evidence-based |
| D014 | Proposed | No recording or raw-audio telemetry by default | Audio transport does not require retention |
| D015 | Accepted 2026-09-28 | Go remote rendezvous service; gRPC is a control option | Language does not dictate media transport; select authenticated control before LAN sharing |
| D016 | Implemented 2026-09-28 | M0 begins with a shared generated-tone harness and build checks | Exercises C ABI/cgo/JNI builds; does not establish streaming, capture, route compatibility, or physical latency |
| D017 | Implemented 2026-09-28; one normal capture validated | Add a short WASAPI capture diagnostic before native WebRTC integration | Five-second 48 kHz/eight-channel PRO X 2 capture succeeded; remaining lifecycle checks stay open |
| D018 | Implemented experiment 2026-09-28 | Pin matching Shiguredo WebRTC Windows/Android artifacts; MSVC DLL C ABI on Windows, standard WebRTC AudioTrack module on Android | Isolates the MSVC/MinGW C++ ABI boundary; verifies real encoded/decoded stereo; preserves media/music output. Hardware routes and delay still decide B001/B002 |
| D019 | Implemented M0 only, 2026-09-28; lifecycle extended by D022, connection reuse by D023 | Ephemeral TLS 1.3 certificate pin plus 256-bit single-use LAN invitation; playback-only receiver | Enables controlled authenticated testing without an account; persistent identities, QR/discovery and remote support remain later protocol work |
| D020 | Implemented M0 measurement increment, 2026-09-28 | Compare routes with recent WebRTC counter deltas, safe snapshots, and an offline shared-timebase correlation tool before changing buffers | First phone playback sounds good but is subjectively 0.5–1 s behind the PC headset. Route prediction and RTT cannot establish physical delay; fixture calibration and repeated measurements remain open |
| D021 | Implemented at user request, 2026-09-28 | Upload typed Android snapshots with authenticated heartbeats and append both sides to one bounded Windows JSONL log per session | Removes manual report collection. Preserve the copy fallback, legacy polling, no-overwrite files, and playback when logging fails; keep secrets and audio out of the schema |
| D022 | Implemented increment 2026-09-29; initial Pixel 8 acceptance recorded | Android media foreground service owns WebRTC, focus, notification Stop and a scoped partial CPU wake lock; transient connection recovery is bounded | Allows screen-off/app-switch playback. Notify Windows before destroying media after local mute, report Stop acknowledgment and reason, and preserve host expiry. No automatic new session, microphone or new media queue; saved connections are added by D023. See the background acceptance matrix |
| D023 | Implemented at user request, 2026-09-29; initial repeat-session acceptance recorded | Keep one Windows listener alive across isolated streams, with unique per-session logs and an explicitly versioned reusable link valid for one host run | Fresh session credentials reject stale control requests; default link lifetime 12h, reset on host restart. Android saves only a successful v2 link with Keystore encryption and offers explicit Reconnect/Forget. Durable host identity and device pairing remain separate work |
| D024 | Implemented 2026-09-29; manual Pause/Play user-validated | Media3 library session wraps the existing WebRTC engine, retaining standard controls while paused and serializing reconnect after cleanup | Replaces the failed ordinary paused notification. Transient focus gain can resume within five minutes; permanent loss requires Play. Pause-on-duck remains a follow-up; see the device acceptance record |
| D025 | Identity foundation implemented and restart persistence user-validated 2026-09-29; extended by D026 | Persistent Windows P-256 identity protected by current-user DPAPI, with stable SHA-256 SPKI identifier; plan TLS 1.3 client-certificate pairing in separate increments | Establish protected storage, no silent key replacement and interoperability vectors before enabling durable network grants. V2 streaming stays ephemeral until approved phone enrollment/revocation is implemented. See [PAIRING.md](../PAIRING.md) |

| D026 | Implemented 2026-09-29; initial enrollment/reconnect/Forget/error-feedback acceptance recorded | Opt-in v3 mutually authenticated TLS with Android Keystore P-256 identity, five-minute single-use enrollment and explicit Windows console approval | Protected durable grants and consumed-secret receipts, fresh client-bound stream credentials, live revoke, saved paired reconnect/Forget/address changes. No legacy downgrade or automatic playback on enrollment. See [PAIRING.md](../PAIRING.md) |
| D027 | Implemented 2026-09-29; initial QR setup and camera-denied fallback user-accepted | Display the same pairing invitation as a compact terminal QR; bundle Android QR scanning with explicit Connect and manual fallback | Removes copying the long link without a new trust protocol, cloud scanner or stored QR image. Camera is optional and used only in the scanner. Windows approval remains required. LAN discovery follows separately; see [PAIRING.md](../PAIRING.md) |
| D028 | Implemented 2026-09-29; initial LAN/offline discovery and fallback user-accepted | Advertise paired Windows endpoints using mDNS/DNS-SD; Android explicitly searches for up to 30 seconds and reconnects with its saved pairing | Discovery supplies untrusted address hints, never new trust or enrollment secrets. Retain the saved host/phone keys, persist a new address only after authenticated playback, bind Windows advertisements to the selected interface, bound Android results/watchers and retain QR/manual fallback. iPhone reuses the wire schema; see [LAN_DISCOVERY.md](../LAN_DISCOVERY.md) |
| D029 | Accepted by user 2026-09-29 | Mark additional output-route coverage and calibrated physical measurements needs-review and continue development | Suitable equipment is unavailable. Preserve completed listening/offline/revocation evidence, retain deferred/unreported gates and make no physical latency claim |
| D030 | Diagnostic implemented 2026-09-29; initial recording/Discord and cancellation/reuse accepted | Prove the Windows cable-to-recording-app path with a known synthetic source before enabling Android microphone return | Explicit render ID, bounded event-driven shared WASAPI and no default fallback. Consumer delivery passed; endpoint invalidation and physical timing remain open. No driver bundling; see [VIRTUAL_AUDIO_CABLE.md](../VIRTUAL_AUDIO_CABLE.md) |
| D031 | Implemented 2026-09-30; initial device acceptance recorded | Add microphone-only sessions before duplex: visible Android enable, built-in input verification, separate microphone foreground service, local capture mute and authenticated Windows queue reset | Reuse v3 paired identities with an explicit per-session direction and opt-in cable destination. No desktop capture in mic mode, media-triggered mic start, persisted mic consent, implicit input fallback or application PCM queue |

| D032 | Requested and implemented 2026-10-02; initial device acceptance recorded | Continue the same visible Connect once approved pairing is durably saved | Use current audio/microphone options and normal permissions. Stop/Cancel/Forget/new actions/backgrounding cancel continuation; loading, scanning and discovery do not create intent |
| D033 | Implemented; focused device regression accepted | Interrupt only registered session-worker Java waits; keep native creation/disposal on the owner and checkpoint published resources after Stop | The pinned producer repair fixes native factory/context destruction order. Repeated cancellation, active microphone Stop/reconnect, retained reports and the in-place APK upgrade/launch check passed |
| D034 | M3 service and app integration implemented; UDP/cellular baseline accepted | Self-hosted Go WSS rendezvous carrying existing paired TLS, with operator-scoped role tokens and short-lived coturn credentials | Preserve peer identity/fingerprint binding through an untrusted signaling relay using standard TLS. Resource credentials do not authorize audio. LAN remains independent; see [REMOTE_ACCESS.md](../REMOTE_ACCESS.md) |
| D035 | Device accepted; corrected handoff reaccepted 2026-10-12 | Use Android default-network events to restart ICE on an established remote session, preserving devices and user gates | Reuse saved remote credentials and the same session; coalesce callbacks, retain the 30-second deadline and host restart throttle, and keep Stop/revocation authoritative. Remote restart deadline candidates require renewed ICE credentials and current candidate evidence. Separate known stream EOF from fatal certificate/handshake/protocol errors. No implicit remote upgrade of LAN invitations, process network binding or zero-gap claim; see [REMOTE_ACCESS.md](../REMOTE_ACCESS.md) |

| D036 | Deployment accepted 2026-10-11; natural certificate renewal observation pending | Run rendezvous as an unprivileged systemd service and reload validated certificate pairs for new TLS handshakes without restarting | Caddy owns renewal. A narrowly scoped root timer repairs read ACLs on the selected files after replacement; it never grants writes or recursive read access. Retain the last valid pair through partial replacement and reject expired cache use. Route config changes still require restart. One-time group/default-ACL changes do not guarantee effective permissions on renewed mode-0600 files; see [SERVICE_DEPLOYMENT.md](../SERVICE_DEPLOYMENT.md) |

| D037 | Device accepted 2026-10-11 | Submit an initial forced-relay description after 500 ms of eligible candidates when exactly one UDP TURN URL is configured | Avoid the unconditional initial adapter-gathering wait without dropping a configured alternate transport. Full deadlines remain for missing candidates and other policies; restarts retain generation-proof rules. Negotiate the new fixed diagnostic result before sending it to Windows. General trickle ICE is separate; see [PROTOCOL.md](../PROTOCOL.md) |
| D038 | Device accepted 2026-10-11 | Identify each offer attempt with a private random nonce so Stop can cancel it before receiving a session credential | Authenticate cancellation with the existing phone identity or reusable invitation, match only that attempt, and retain a bounded short-lived cancellation record for reordered requests. Native teardown still owns the session slot until complete; known sessions keep ordinary Stop. See [PROTOCOL.md](../PROTOCOL.md) |
| D039 | Device accepted 2026-10-12 | Enable Windows ICE renomination at remote peer creation and verify actual SDP advertisements on both endpoints | Android's missing Java toggle does not imply missing native support: upstream JNI uses aggressive native defaults. Keep the pinned SDK, require actual local/remote capability, preserve LAN defaults and relay policy, and let the SDK select routes. Bounded private-ID comparisons report observed switches without confusing restart generations. Continuous gathering is separate; see [PROTOCOL.md](../PROTOCOL.md) |

| D040 | Device accepted 2026-10-12; second Windows interface unavailable | Negotiate continual gathering at remote peer creation and exchange bounded current candidate sets throughout each ICE generation | Replace acknowledged snapshots instead of retaining an ever-growing event log; relay removed candidates to the SDK. Candidates require current credential evidence. Restart offers/answers are early and renew the exchange only after the authenticated answer; keep existing recovery deadlines and audio gates. Native ABI 8, no SDK or VPS change. Credentials still refresh on setup/recovery, and controlled default-network upgrades remain follow-up work; see [PROTOCOL.md](../PROTOCOL.md) |

| D041 | Basic active/muted handoffs accepted 2026-10-25; isolated priorities still unverified | Prefer verified LAN for a fresh Connect and rendezvous for automatic recovery; upgrade healthy rendezvous signaling to LAN | User-selected ordering minimizes explicit local setup dependency while preserving the established recovery path. Share paired identity, authorization and one session across two Windows listeners; authenticate a bounded TLS-only probe, retain forced relay, and cancel ambiguous offers before replacement. No request header chooses ICE policy or authorizes a subnet scan. Temporary signaling failures retry only within the original recovery deadline. See [ADVANCED_SETTINGS.md](../ADVANCED_SETTINGS.md) |

Android follow-up (2026-10-24): carry the iPhone review's device identity and
bounded Bluetooth recovery decisions into Android. Save only stable Bluetooth
identity/profile in private, backup-excluded storage, rebind current ports
uniquely, and retain unavailable choices rather than selecting a different
device. Keep the Bluetooth recovery window separate from network recovery,
initial verification and explicit input-switch teardown (20 s default; 5–120 s).
Android's optional keep-capture-on-mute behavior defaults **off**: already verified
capture may remain active with transmission gated, but Stop, pause and route/
network recovery still release it. It confers no startup consent or background
survival guarantee. See [Advanced settings](../ADVANCED_SETTINGS.md).

### D042 — Public device-picker fallback (2026-10-25)

Implemented; affected-device acceptance pending. When Android omits an inactive
Bluetooth audio port, offer the foreground system output picker (Android 14+)
or Bluetooth settings. A session requires an explicit Stop and open action;
Cancel preserves it, and a changed session invalidates the action. Do not erase
saved identity/profile, silently switch to Android default output, select by a
name, use hidden address APIs, or start capture when the activity returns.
Public media-route visibility does not establish microphone support.

### D043 — Windows desktop delivery and first-release scope (2026-10-25)

Accepted by the user; desktop implementation/device acceptance passed and is
described in [WINDOWS_DESKTOP.md](../WINDOWS_DESKTOP.md). Continue the existing Go/C++ host in the signed-in
user's session, adding native Win32 tray/settings controls and opt-in sign-in
startup. Reuse the existing identity and remote-configuration stores. Commands
and events are typed in-process operations, not parsed console output or a new
network management API. Actual media connection, approval requests and meaningful
failure/recovery transitions receive Windows notifications, without secrets or
repeated poll alerts.

The first release continues to require a separately installed virtual cable;
neither a bundled third-party driver nor a product-owned driver is required for
this increment. Artwork must not be generated: use placeholders/standard Windows
icons, a text wordmark, gold/darker yellow and dark slate gray. High-contrast
Windows preferences override the custom palette. Installer work follows D044;
signing and release identity/license decisions remain later M4 work.

### D044 — Per-user Windows installation and manual upgrades (2026-10-25)

Accepted scope: install the complete desktop/CLI/media package for the current
Windows user, retain the portable package, and preserve the existing settings,
pairings, remote configuration and logs. Use a pinned, checksum-verified Inno
Setup compiler and a stable application location. After the initial installer
acceptance, the user requested maintenance buttons and automatic shutdown. Setup
now offers upgrade/reinstall, modify/repair with shortcut choices, and uninstall.
After confirmation it requests desktop Exit, then terminates remaining verified
MicDrop processes owned by the same account before acquiring replacement locks.

The installer creates a Start menu shortcut and uninstall registration, with an
optional desktop shortcut. Sign-in
startup stays opt-in through the app. Existing installed-path startup survives
upgrades; migrating from a portable location requires explicitly enabling startup
from the installed app. Uninstall removes only the startup entry belonging to its
installation and always preserves personal data. Complete data removal remains
a separate, explicit manual action.

Manual download/install upgrades are sufficient for this increment. No automatic
updater, background service, bundled driver, firewall policy change or generated
artwork is introduced. The development installer does not settle public-release
licensing, production signing or identifiers. Details are in
[WINDOWS_INSTALLER.md](../WINDOWS_INSTALLER.md).

### D045 — Configurable Windows connection logs (2026-10-25)

Windows Options exposes **Save connection logs** and **Keep most recent connections**.
Logging stays on by default; 0 keeps all existing logs, so upgrading alone never
prunes history. A positive limit (1–10000) explicitly permits removing older
recognized session logs. One file represents one connection, including ICE
recovery; a fresh connection creates another file. Active files are protected.
A single background worker coalesces pruning requests; errors never stop audio.
Turning logging off leaves existing files untouched. CLI equivalents are
`--no-log` and `--log-retention N`. Android's copied report remains available.

### D046 — Persistent device status and opt-in phone settings (2026-10-25)

The user accepted a persistent Windows connection area with room for multiple
device rows and confirmed both Audio and Advanced phone settings, with a local
phone opt-in for Windows control. Keep the current single-stream limit explicit;
this UI does not add concurrent receivers. Paused state is last reported because
pause closes transport, and stale counters are not current latency measurements.
Show measured network/buffer statistics without claiming physical audio/mic delay.

Negotiate settings over the existing authenticated paired control connection.
The phone remains authoritative: validate its opt-in, session, revision, keys and
values; acknowledge changes; reject stale editors; never carry commands into a
new connection. Live volume affects Android system volume. Mute applies only to
an already authorized microphone session. Other audio/routing and Advanced
preferences apply on the next explicit connection. Permissions, pairing and
microphone consent remain local. No new VPS service or unpaired management API.

File logging and live telemetry are independent. The phone truthfully reports
when Windows receives statistics without recording them. Intentional same-phone
Play/resume is distinguished from explicit Stop/Connect for Windows notifications.
Older clients continue streaming; these new controls require updated clients.

Amendment 2026-10-27: on Android as on the iPhone, Windows Unmute and Play
desktop audio edits last only for the current phone session; a Windows
keep-alive edit applies at the next explicit microphone Connect, not at an
input switch or duplex resume; Windows may unmute only after the phone enabled
capture in that session and while permission is granted; and a Windows
media-output choice applies to the running session through the phone's verified
output switch. Resume presentation may carry an optional reason header
(`manual`, `automatic`, `focus_regain`) beside the unchanged resume hint, and
the Windows desktop words a quiet resume by it. Live volume stays Android-only.
See the [Windows desktop guide](../WINDOWS_DESKTOP.md#persistent-device-status-and-phone-settings),
the [phone settings exchange](../PHONE_CONTROL_V1.md) and the
[protocol](../PROTOCOL.md).

### D047 — Shared version identity and unpublished release assembly (2026-10-25)

The user requested versioning and draft releases next. A single version metadata
file feeds Windows, the installer, Android and iPhone; Android version codes
(and iPhone `CFBundleVersion`) increase with named versions. Draft assembly
promotes exact successful `main`-build outputs from retained CI artifact
bundles, verifies source/version/file hashes, and uploads directly to GitHub
Releases. Only the workflow-owned draft for that exact build can be resumed;
published releases and different assets are never replaced. Completion adds
checksums and keeps the release unpublished. Publication remains a separate
manual decision.

This increment preserves the current Android development app ID and stable
signer so existing development installations can update in place. The APK,
unsigned Windows packages, and optional unsigned iPhone IPA remain clearly
identified as development builds. Production signing is not decided by this
work. See [RELEASING.md](../RELEASING.md) for operation and validation.

### D049 — iPhone client (2026-10-13)

Implemented in native Swift/SwiftUI (iOS 17+, iPhone only), built in GitHub Actions on `macos-26` (Xcode 26.6, XcodeGen 2.46.0) as an unsigned IPA and sideloaded with an Apple ID through Sideloadly or iloader; WebRTC from the same Shiguredo m155.8059.2.0 release/source as Android; portable Swift (`MicDropKit`: SwiftNIO/NIOSSL, `swift-certificates`) tested on Linux. Passed Apple CI (unsigned IPA bundle verification and simulator test suite), verified sideload installation on physical iPhone hardware, and passed the basic LAN duplex/mute control check; broader physical route, locked-screen, remote/handoff, and phone-settings device checks remain open (see [ROADMAP.md](../ROADMAP.md)). Free provisioning allows background audio, microphone, camera and local network, without push, App Groups, multicast or VoIP entitlements, and requires 7-day re-signing. Revisit distribution with a paid developer account or TestFlight. Three iPhone audio behaviors are intentionally distinct from Android defaults: **Keep microphone active while muted in background** is on by default (gated capture that keeps a background microphone-only session alive), input/output devices are remembered by route `uid` (never wired ports, never substituted), and the Bluetooth route recovery window is configurable (20 s default, 5–120 s). The iPhone follows D042 through the **AirPlay & Bluetooth output…** row and an explicit Stop for sessions with a pinned output or a Bluetooth headset microphone; iOS has no public Bluetooth-settings link and no programmatic picker. The iPhone follows D046 (opt-in phone settings, live status without a Windows log, quiet same-phone resume) with 31 of Android's 33 keys: no live volume or LE stereo setting (iOS exposes no public system-volume setter or LE Audio input API) and no wired device persistence; Windows Unmute and **Play desktop audio** edits last only for the current phone session, while a Windows Mute is saved like the phone's own Mute. TURN/TLS and rendezvous TLS trust use Apple's `SecTrust` and the iOS trust store, keeping host SPKI pinning and DTLS fingerprints unchanged. Bundle ID stays `com.maskarauder.micdrop.dev` to preserve Keychain pairing across re-sideloads.

### D050 — Linux x64 and macOS arm64 desktop and CLI hosts (2026-11-12)

Extended the Go host engine (`apps/windows-host`, `internal/desktop`, `internal/identity`, `internal/pairing`, `internal/session`, `internal/rendezvous`, `internal/phonecontrol`) to Linux x64 (`linux/amd64`) and Apple Silicon macOS (`darwin/arm64`, macOS 14.2+) with both CLI (`micdrop-host`) and native desktop GUIs (`micdrop-host desktop` on Linux, `MicDrop.app` on macOS), preserving 100% Windows compatibility.

- **Audio boundaries:** Linux captures desktop sinks via `.monitor` streams and renders phone microphone return via PulseAudio/PipeWire (`libpulse.so.0` loaded dynamically with `dlopen`); macOS 14.2+ captures desktop output via CoreAudio Process Tap (`CATapDescription` + `AudioHardwareCreateProcessTap` private aggregate device) and renders return audio via a non-allocating `HALOutput` `AudioUnit`. Missing explicit endpoints fail closed on all platforms.
- **Native desktop UIs without custom icon artwork:** macOS uses native AppKit (`NSStatusItem` menu bar item with standard SF Symbols `mic` / `mic.fill` / `waveform`, `UNUserNotificationCenter`, per-user `~/Library/LaunchAgents` login startup, and `NSTerminateLater` graceful logout/shutdown). Linux uses native GTK3 (`libgtk-3.so.0`, GDK3, Cairo, GIO, and optional `libayatana-appindicator3` / `libappindicator3` loaded at runtime via `dlopen` so headless servers/containers retain zero hard GUI `DT_NEEDED` dependencies), standard freedesktop themed icons (`audio-input-microphone`, `audio-input-microphone-symbolic`), D-Bus `org.freedesktop.Notifications`, HighContrast theme compatibility, and XDG autostart (`~/.config/autostart/micdrop.desktop`) / launcher (`--install-launcher`) entries.
- **Identity, state, and TURN TLS verification:** Unix host identity, pairing grants, remote config, `desktop-v1.json`, `desktop.lock`, and logs live under persistent `os.UserConfigDir()/MicDrop` (`~/.config/MicDrop` on Linux, `~/Library/Application Support/MicDrop` on macOS) protected by mode-`0700` directories, `0600` AES-256-GCM master-key envelopes (`O_NOFOLLOW` + UID checks), and `flock` locking so cache cleanups never reset host identity. Native WebRTC uses Shiguredo `m155.8059.2.0` (`libmicdrop_rtc.{so,dylib}`), verifying TURN TLS certificates through `SecTrust` + `SecPolicyCreateSSL` on macOS (honoring per-certificate Keychain distrust) and BoringSSL `X509_STORE` + system CA bundle on Linux.
- **Verification and open hardware gap:** Automated CI verifies permission-preserving `.tar.gz` / `.app.zip` distributions, live Linux PulseAudio loopback, Xvfb GTK3 UI contracts (`linux-desktop-preview`), macOS Mach-O/ad-hoc `codesign` + AppKit UI contracts (`macos-desktop-preview`), and native WebRTC loopback; physical Apple Silicon Mac hardware verification remains open (see [MACOS_DESKTOP.md](../MACOS_DESKTOP.md) and [LINUX_DESKTOP.md](../LINUX_DESKTOP.md)).

### D051 — Apple Developer ID signing/notarization, iOS App Store/TestFlight pipeline, and Apple app icons (2026-11-13)

Wired headless Apple signing, notarization, app icons, and TestFlight delivery in GitHub Actions (`macos-26`) via `tools/apple_signing.py` and `tools/generate_apple_icons.py` without requiring maintainer Apple hardware:

- **macOS Developer ID & notarization (`com.maskarauder.micdrop.mac`):** Non-PR `build.yml` runs import `Developer ID Application` into an ephemeral `$RUNNER_TEMP` keychain, sign `libmicdrop_rtc.dylib`, `micdrop-host`, and `MicDrop.app` with Hardened Runtime (`--options runtime --timestamp`, zero entitlement exceptions), submit both CLI binaries and `MicDrop.app` to `xcrun notarytool`, staple the notarization ticket onto `MicDrop.app`, and verify with `xcrun stapler validate` and `spctl --assess --type execute`. Pull-request and fork runs receive no signing secrets and automatically fall back to ad-hoc signing.
- **iPhone production bundle ID & TestFlight (`com.maskarauder.micdrop`):** Switched the iPhone target from `com.maskarauder.micdrop.dev` to `com.maskarauder.micdrop`, added `ITSAppUsesNonExemptEncryption = false` and `PrivacyInfo.xcprivacy` (declaring `CA92.1`, `35F9.1`, `C617.1` Required Reason APIs with zero tracking/collection), and scoped manual signing settings (`MICDROP_DEVELOPMENT_TEAM`, `MICDROP_CODE_SIGN_IDENTITY`, `MICDROP_PROVISIONING_PROFILE_SPECIFIER`) to the `MicDrop` application target so SwiftPM static package targets build cleanly during `xcodebuild archive`. Non-PR `ios.yml` runs build and verify both the unsigned sideload `.ipa` (retained for GitHub Releases) and the `Apple Distribution` signed `.ipa`, uploading to App Store Connect / TestFlight via `xcrun altool` only when `workflow_dispatch` sets `upload_testflight: true` (avoiding duplicate build-number rejections between `version.properties` bumps).
- **Approved Apple app icons:** Reused the Android slate-and-gold microphone motif (`tools/generate_apple_icons.py`, pure stdlib renderer + pixel-decoded `check` gate) to generate opaque 24-bit RGB `AppIcon.png` (`1024×1024` in `apps/ios/MicDrop/Assets.xcassets`) and multi-resolution `AppIcon.icns` (`apps/windows-host/resources/AppIcon.icns`, bundled into `MicDrop.app/Contents/Resources/AppIcon.icns`), while preserving standard template SF Symbols for the macOS menu bar `NSStatusItem`.

### D052 — Windows Authenticode cloud signing via Microsoft Azure Artifact Signing (2026-11-13)

Wired four-stage Windows Authenticode signing and RFC 3161 timestamping (`http://timestamp.acs.microsoft.com`) into `build.yml`, `tools/windows_signing.py`, `tools/build_windows_installer.ps1`, `deploy/windows/MicDrop.iss`, and `tools/draft_release.py`:

- **Pinned Microsoft signing tools & dual Entra authentication:** `tools/windows_signing.py` downloads and SHA-256-verifies official NuGet packages `Microsoft.Windows.SDK.BuildTools` (`10.0.28000.2957`, `signtool.exe`) and `Microsoft.ArtifactSigning.Client` (`1.0.146`, `Azure.CodeSigning.Dlib.dll`) into `.deps/`. Supports both secretless GitHub Actions OIDC (`WorkloadIdentityCredential` via `permissions: id-token: write`, refreshing short-lived JWTs before each `signtool.exe` invocation) and Microsoft Entra client secrets (`EnvironmentCredential` when `AZURE_CLIENT_SECRET` is configured), scoping `ExcludeCredentials` in `metadata.json` to the single active credential type and scrubbing ephemeral workspace files under `if: always()`.
- **Byte-identical portable/installer payload & signed uninstaller:** Non-PR `build.yml` runs sign `build/host/MicDrop.exe` and `build/host/micdrop_rtc.dll` before installer staging, sign `MicDrop-maintenance.exe` inside `build_windows_installer.ps1` before computing `payload-manifest.json` SHA-256 digests, and compile `MicDrop.iss` with `/DSignInstaller` (`SignedUninstaller=yes`, `SignTool=micdrop`, `AppPublisher` / `VersionInfoCompany`) so `unins000.exe` and `MicDrop-<version>-<sha>-windows-x64-setup.exe` are signed and verified before Microsoft Defender scanning (`5` signatures per build). Isolated CI lifecycle tests (`test_windows_installer.ps1`) omit `-SignInstaller` to preserve signing quota, and pull-request/fork runs receive no `AZURE_*` secrets and fall back cleanly to unsigned packages.

## Alternatives considered

| Alternative | Why it is not the initial baseline | When to reconsider |
| --- | --- | --- |
| Custom UDP audio protocol | Would also need secure sessions, loss/congestion handling, jitter control, NAT traversal, and clock management | A benchmark demonstrates a specific benefit worth the additional maintenance |
| PCM over WebSocket/TCP | Reliable ordered delivery can delay newer audio behind older data | Control signaling remains suitable; a constrained media experiment needs explicit latency evidence |
| Browser-only phone app | Does not provide the intended native route/lifecycle control across devices | A limited compatibility client, after native behavior is proven |
| Cross-platform UI first | UI reuse does not resolve native audio and endpoint risks | Once the working audio boundary and supported platforms are clear |
| Own Windows driver first | Delays proving the media system and adds distribution work | Existing endpoints cannot meet measured requirements or packaging goals |
| Separate fast LAN and internet transports immediately | Doubles transport behavior to implement and debug | Only after comparing a validated alternative with the same security and quality conditions |

## Outstanding decisions

| Question | Status |
| --- | --- |
| Additional reference devices and calibrated measurement fixture | Beta hardware coverage; physical latency claims remain unverified |
| Independent authentication review and key rotation/recovery UI | Before wider public distribution |
| Bundled virtual endpoint or product driver | Deferred; beta uses a user-installed cable or user-space sink |
| Production Android Play signing (`com.maskarauder.micdrop`) | Before Google Play Store distribution; Apple Developer ID notarization, iOS App Store/TestFlight signing (D051), and Windows Azure Artifact Signing (D052) are active in CI |
| Physical Apple Silicon Mac and broader iPhone device coverage | `macos-26` CI passes; physical Mac Process Tap / BlackHole / sleep-wake checks and broader iPhone route/locked-screen/remote checks remain open |

The native WebRTC revisions/audio module, Go rendezvous/control transport,
virtual-cable beta strategy, MPL-2.0 license and donation-first model are already
selected. See [licensing](../LICENSING.md), [architecture](../ARCHITECTURE.md) and
[dependency provenance](../../third_party/). Earlier entries below/above retain
their decision-time context; they do not reopen resolved choices.

Record future changes with the decision ID, date, evidence, rejected alternatives, and migration implications. Requirement changes belong in [PRODUCT.md](PRODUCT.md); measured findings belong in benchmark reports.
