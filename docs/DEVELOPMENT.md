# Development and build instructions

MicDrop provides Windows x64, Linux x64, and macOS arm64 desktop hosts with
Android and iPhone WebRTC/Opus playback, microphone return and duplex audio
over paired LAN or remote connections. The Windows desktop app owns GUI host
settings, pairing approval and logs, while `micdrop-host` provides full CLI
host support on Linux x64 and macOS arm64 (macOS 14.2+); Android foreground
services and iOS background audio sessions own screen-off playback/capture. The
[roadmap](ROADMAP.md) summarizes completed functional checks and the hardware or
physical-measurement limits that remain. [Release preparation](RELEASING.md)
covers versioned development packages and unpublished drafts.

Both mobile interfaces match the Windows slate/gold palette. **Diagnostics**
contains reports, notices and a local output check. Desktop capture/WAV and
shared C++ tone diagnostics remain available across Windows, Linux, and macOS.

## Toolchain

| Component | Version / requirement |
| --- | --- |
| Go | 1.26.7, pinned in `go.mod` |
| Host C++ | C++20; Windows: MinGW-w64 GCC/G++ for cgo and MSVC 2022 x64 for `micdrop_rtc.dll`; Linux x64 / macOS arm64: system GCC or Xcode Clang for cgo and pinned Chromium Clang/libc++ for `libmicdrop_rtc.{so,dylib}` |
| Host CMake | 3.22 or newer |
| macOS host | macOS 14.2+ (Sonoma or newer) on Apple Silicon (`arm64`) with Xcode Command Line Tools / SDK |
| Linux host | x86\_64 Linux with glibc 2.35+ (`ubuntu-22.04` / `ubuntu-24.04`+) and PipeWire (`pipewire-pulse`) or PulseAudio (`libpulse.so.0`) |
| Android | Android 12 / API 31+, arm64-v8a app |
| JDK | 17 |
| Gradle | 8.13, wrapper with distribution SHA-256 verification |
| Android Gradle plugin | 8.13.2 |
| Kotlin plugin | 2.2.21 |
| Android compile / target SDK | 36 |
| Android Build Tools | 35.0.0 |
| Android NDK | 27.0.12077973, for packaging prebuilt native libraries |
| iPhone | iOS 17.0+, arm64 iPhone; unsigned development IPA, sideloaded |
| Xcode | 26.6 (17F113) on GitHub-hosted `macos-26`; iOS SDK 26.5 |
| Swift | 6.3 toolchain (Xcode 26.6; Linux `swift:6.3.3-noble` by digest); Swift 5 language mode |
| XcodeGen | 2.46.0 release zip, SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` |
| SwiftPM packages | Exact versions in `apps/ios/MicDropKit/Package.swift`; pins in its `Package.resolved`; see [iPhone provenance](../third_party/IOS.md) |
| WebRTC distribution | Shiguredo m155.8059.1.1 Windows / m155.8059.2.0 Linux, macOS, Android, and iPhone; checksummed assets in the lock file |
| Dependency fetcher | Python 3.11+ |

These are selected compatible versions, not a claim that they are the newest.
The Gradle/AGP/JDK/SDK combination follows the
[AGP compatibility table](https://developer.android.com/build/releases/agp-8-13-0-release-notes).
The target SDK may change before distribution. Version-specific permission
work in [PLATFORM_AUDIO.md](PLATFORM_AUDIO.md) still applies when networking and
background microphone capture are changed.

The host uses Go's standard library, cgo and pinned QR/discovery dependencies
recorded in `go.mod`/`go.sum`. [QR provenance and notices](../third_party/QR.md)
also cover the bundled Android scanner; [discovery provenance](../third_party/DISCOVERY.md)
covers the mDNS responder and its Go dependencies. cgo compiles `native/media/tone.cc` directly; CMake
compiles that same file for native tests. Keeping the Go binding and
C++ source together also avoids stale Go build-cache entries for externally
included C++ implementations.

The desktop capture bindings likewise live beside `capture_windows.cc`,
`capture_linux.cc`, and `capture_darwin.cc` / `tap_darwin.m` in
`native/platform/windows`. Platform headers and system libraries are isolated
from the Android build; other architectures use an explicit unsupported-platform stub.

This host is not a pure-Go cross-compilation target: cgo requires a native C/C++
toolchain for the destination. On Windows, the Go build uses MinGW-w64 GCC/G++
and MSVC builds `micdrop_rtc.dll` separately with the matching static C++
runtime. On Linux x64 and macOS arm64, cgo uses GCC or Xcode Clang while CMake
compiles `libmicdrop_rtc.so` / `libmicdrop_rtc.dylib` with the pinned Chromium
Clang and `libc++` headers fetched by `tools/fetch_webrtc.py`. The Go executable
loads the WebRTC shared library through a pure C ABI; C++ objects never cross
into cgo. See [the WebRTC build record](../third_party/WEBRTC.md).

## Microphone return and endpoint diagnostics

Use [virtual cable setup](VIRTUAL_AUDIO_CABLE.md) and the [Android guide](ANDROID.md)
for current controls. Developers can use `bridge-devices` to list active render
and recording endpoints and `bridge-check --render-device <id> --duration 10s`
to send a quiet known synthetic signal through the selected cable. It does not
activate phone capture or install a driver.

A paired console listener with `--microphone-device <cable render ID>` accepts
explicit microphone or duplex sessions. A missing/invalid cable fails closed.
Automated contracts do not establish real phone/cable routing; record focused
hardware results and any skipped combinations.

## Windows host harness

The [paired listener](PAIRING.md) uses a persistent current-user DPAPI host
identity and approved phone database in LocalAppData. Start
`windows-host stream --host <private IPv4> --paired --pair`, scan the displayed QR
or paste its invitation into Android, tap Connect, and approve its matching request
ID in the same console. Scanning works offline; camera permission is optional for
manual entry. Maximize the console to keep the QR and its border visible.
Later host starts need only `--paired`; Android Reconnect uses its saved identity.
The paired listener advertises on the interface selected by `--host` by default.
Android **Find Windows on LAN** can locate a saved host after an address change;
`--no-discovery` disables advertisements. See [discovery setup and firewall notes](LAN_DISCOVERY.md).
Use `devices` / `revoke <full-phone-key>` to remove approval. Existing
`identity init` / `identity status` commands expose public identity information;
repeated Init keeps the same fingerprint. The commands below without `--paired`
exercise the legacy ephemeral listener.

Install Go 1.26.7 and a MinGW-w64 toolchain whose `gcc` and `g++` are on PATH.
From the repository root in PowerShell:

```powershell
$env:CGO_ENABLED = '1'
$env:CC = 'gcc'
$env:CXX = 'g++'
go test ./...
go vet ./...
go build -trimpath -o build/host/windows-host.exe ./apps/windows-host
./build/host/windows-host.exe doctor
./build/host/windows-host.exe tone --output build/tone.wav --duration 1s
```

`doctor` reports the loaded tone ABI and implemented platform capabilities.
It does not test DLL presence or open an audio device. `tone` creates a new
48 kHz, stereo, 16-bit PCM WAV
with a 440 Hz tone at amplitude 0.05 (about -26 dBFS peak). It does not play the
file or record anything. Existing files are never overwritten; choose a new
filename for another run. Duration is limited to 1 ms through 1 minute.

The console executable statically links the MinGW C++ runtime. It is retained
for developer/CI diagnostics and is excluded from tester installers and ZIPs.

### Windows desktop app

The same package also builds `MicDrop.exe` with the Windows GUI subsystem. It
starts a native tray/settings app and reuses the current user's protected pairing
state. The CI harness contains both executables and the shared media DLL. See
[Windows desktop](WINDOWS_DESKTOP.md) for manifest/build steps, saved settings, migration
from the console host and the focused device checks. The CLI remains available
and accepts `windows-host.exe desktop` for development.

### Build the streaming runtime

Install the Visual Studio 2022 C++ x64 build tools and Windows SDK as well as the
Go/MinGW toolchain above. From the repository root, use **Release** for the pinned
WebRTC library's C++ ABI/runtime:

```powershell
python tools/fetch_webrtc.py windows
cmake -S . -B build/native -G "Visual Studio 17 2022" -A x64 -DMICDROP_BUILD_RTC=ON
cmake --build build/native --config Release
ctest --test-dir build/native -C Release --output-on-failure
Copy-Item build/native/native/rtc/Release/micdrop_rtc.dll build/host/
Copy-Item LICENSE, NOTICE build/host/
Copy-Item .deps/webrtc/windows/webrtc/NOTICE build/host/WEBRTC-NOTICE.txt
Copy-Item .deps/webrtc/windows/webrtc/VERSIONS build/host/WEBRTC-VERSIONS.txt
./build/host/windows-host.exe rtc-check
./build/host/windows-host.exe stream --host 192.168.1.10 --probe
```

Replace the example IP with this PC's private LAN IPv4 address. `rtc-check`
exercises the installed DLL through Go, generates/discards an offer, and verifies
that PCM has not started before authorization. It does not open an audio endpoint.
`stream` uses a reusable connection link valid for this host run; remove `--probe` to capture desktop audio.
Use `--device` for an explicit output and `--port` for a different control port.
An authenticated connection creates a combined Windows/Android log in
`diagnostics-private`; the console prints its path at initialization and completion.
Stop finalizes that log and releases media while Windows keeps accepting new
connections with the same link. No peer or log is created while idle. Use
`--log-dir <directory>` or `--no-log`; the old `--log <file>` flag now reports an
error. Files are unique and never replaced. The default link lifetime is 12 hours;
`--invitation-ttl 1m` through `23h` changes it. Expiry or Ctrl+C ends the host.
Restarting generates a new identity/link. This is the existing console host,
not a registered Windows Service. See [pairing](PAIRING.md) and the
[beta guide](BETA_TESTING.md) for pairing, firewall scope, stopping, route checks,
metrics, and current limitations.

### Capture real Windows playback

Run these commands on Windows 11 while playing audio through the desired output:

```powershell
./build/host/windows-host.exe devices
./build/host/windows-host.exe capture --duration 5s
./build/host/windows-host.exe capture --duration 5s --output build/loopback.wav
./build/host/windows-host.exe capture --device '<id from devices>' --duration 10s --output build/selected.wav
```

With the downloaded CI executable, use `.\windows-host.exe` instead. `devices`
lists active render endpoints as JSON; `default_multimedia` identifies the default
for the multimedia role. Copy the entire `id` and quote it. A capture without
`--device` selects that default once at startup. The run stays on that endpoint
even if the default changes. An invalidated/disconnected endpoint fails with the
operation and HRESULT; run `devices` again and explicitly start another capture.
Automatic default following and reconnection belong to the streaming milestone.

The default duration is 5 seconds; allowed durations are 100 ms to 1 minute in
whole milliseconds. Ctrl+C cancels and discards an incomplete recording. No PCM
recording is retained without `--output`. When requested, a new filename is
reserved before opening the device; existing files are never overwritten. All
file writes happen after capture stops. Native PCM16 recording storage is
preallocated and capped at 64 MiB, then copied to Go after capture (up to roughly
128 MiB combined PCM storage during that copy). Very long multichannel/high-rate
recordings fail before starting; choose a shorter duration. Capacity exhaustion
during capture is an explicit error and discards the recording.

The capture requests the shared mix format with event-driven loopback and the
engine's default period. It handles float32 and signed PCM16/24/32, including
valid bits left aligned in larger containers. It preserves sample rate, channel
count/order, and channel mask. WAV output is 16-bit PCM with a
WAVEFORMATEXTENSIBLE header; there is no resampling or downmixing. Nonfinite
samples become zero and values beyond full scale saturate when written to PCM16.
Levels describe the source before saturation. [S18–S20](REFERENCES.md)

Capture diagnostics go to stdout as JSON; progress/errors go to stderr. To keep
a report locally, redirect stdout, for example `capture --duration 5s > report.json`.
Recordings and reports can contain private audio or endpoint names/IDs; review
them before sharing. Do not commit recordings.

| Field | Interpretation |
| --- | --- |
| `format`, `endpoint_buffer_frames` | Actual mix format and allocated endpoint buffer; not an end-to-end latency result |
| `default_device_period_ms`, `minimum_device_period_ms` | Device-reported periods; the minimum does not mean this shared stream is running at that period |
| `elapsed_ms`, `delivered_audio_ms` | Wall capture time and duration of delivered frames; they can differ during idle output or packet gaps |
| `channel_levels` | Per-channel linear peak/RMS; 1.0 is full scale, 0 is silence |
| `silent_flag_frames` | Frames explicitly flagged silent by WASAPI; zero-valued ordinary packets need not carry that flag |
| `discontinuities_after_first_packet` | Glitch flags after startup; the first packet's flag is reported separately |
| `position_gap_frames`, `position_regressions` | Gaps/backward movement between consecutive valid positions; idle gaps are not necessarily glitches |
| `timestamp_errors`, `valid_timestamps` | Timestamp validity; invalid packets break continuity comparisons |
| `first/last_device_frame`, `first/last_qpc_100ns` | First-frame positions of valid packets; QPC is already in 100 ns units, not raw ticks or another device's clock |

Idle playback may produce no packets. In that case the command prints a report,
exits nonzero, and leaves no WAV. Silence packets produce a warning but a valid
recording. WAVs concatenate the delivered packets without padding missing time;
their duration can be shorter than the requested wall time. These recordings
are for audibility/format checks, not continuous timing or physical-latency tests.
Protected content and sources outside the shared output mix may be absent.
Start playback before capture, and do not play the saved WAV until capture ends.

For C ABI tests, install CMake and either MSVC Build Tools or a C++20 GCC toolchain:

```powershell
cmake -S . -B build/native -DCMAKE_BUILD_TYPE=Release
cmake --build build/native --config Release
ctest --test-dir build/native -C Release --output-on-failure
```

### Linux and macOS CLI host

On Linux x64 (`ubuntu-22.04` / `ubuntu-24.04`+) or macOS arm64 (macOS 14.2+ with Xcode Command Line Tools), fetch the verified WebRTC archive and matching Chromium Clang/`libc++` toolchain, build `libmicdrop_rtc.so` or `libmicdrop_rtc.dylib` in **Release**, and build `micdrop-host`:

```sh
# Replace 'linux' with 'macos' on Apple Silicon macOS:
python3 tools/fetch_webrtc.py linux
cmake -S . -B build/native -DCMAKE_BUILD_TYPE=Release -DMICDROP_BUILD_RTC=ON
cmake --build build/native --config Release --parallel 4
ctest --test-dir build/native -C Release --output-on-failure

mkdir -p build/host
CGO_ENABLED=1 go build -trimpath -o build/host/micdrop-host ./apps/windows-host
# On Linux:
cp build/native/native/rtc/libmicdrop_rtc.so build/host/
# On macOS:
# cp build/native/native/rtc/libmicdrop_rtc.dylib build/host/
# codesign --force --sign - build/host/libmicdrop_rtc.dylib build/host/micdrop-host

./build/host/micdrop-host doctor
./build/host/micdrop-host rtc-check
./build/host/micdrop-host devices
./build/host/micdrop-host bridge-devices
./build/host/micdrop-host stream --host 192.168.1.10 --paired --pair
```

All CLI subcommands (`version`, `doctor`, `rtc-check`, `devices`, `bridge-devices`,
`bridge-check`, `capture`, `tone`, `identity init|status`, `remote import|status|forget`,
and `stream`) work identically to `windows-host.exe`. Host identity, paired phone
records, and remote settings are stored under `os.UserConfigDir()/MicDrop`
(`~/.config/MicDrop` on Linux, `~/Library/Application Support/MicDrop` on macOS)
encrypted with a user-only (`0600`) AES-256-GCM master key and guarded by `flock`.
See [PLATFORM_AUDIO.md](PLATFORM_AUDIO.md) for PipeWire/PulseAudio `module-null-sink`
and macOS CoreAudio Process Tap / BlackHole virtual cable setup.

### Linux desktop app (`micdrop-host desktop`)

On x86\_64 Linux, the same `micdrop-host` binary includes the native GTK3 desktop
UI (`internal/desktop/gtk_linux_amd64.c`, `ui_linux_amd64.go`) with full feature
parity to `MicDrop.exe` and `MicDrop.app`. Because GTK3, GDK3, Cairo, GIO, and
optional AppIndicator libraries are loaded at runtime via `dlopen`, compiling
`micdrop-host` does not require `-dev` GTK headers and headless servers/containers
do not need GUI packages installed to run CLI subcommands.

```sh
# Launch the Linux desktop UI (requires an active Wayland or X11 session + libgtk-3-0 / libgtk-3-0t64):
./build/host/micdrop-host desktop

# Optional: register or remove a per-user XDG application launcher (~/.local/share/applications/micdrop.desktop):
./build/host/micdrop-host desktop --install-launcher
./build/host/micdrop-host desktop --uninstall-launcher

# Run the automated GTK3 desktop UI contract checks on a headless machine using Xvfb:
xvfb-run -a -s "-screen 0 1280x960x24" go test -count=1 -v ./internal/desktop
```

See [Linux desktop](LINUX_DESKTOP.md) for XDG autostart, optional AppIndicator
panel tray behavior, and PipeWire/PulseAudio virtual microphone setup.

### macOS desktop app (`MicDrop.app`)

On Apple Silicon macOS (macOS 14.2+), the same `apps/windows-host` package also
compiles the native AppKit desktop app (`MicDrop.app`) sharing `internal/desktop`
with full feature parity to `MicDrop.exe` (audio routing, LAN/remote config, QR
pairing, phone settings editor, SF Symbols menu bar item, and per-user
`LaunchAgents` login startup). Assemble and verify the bundle with
`tools/macos_app_bundle.py`:

```sh
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
```

See [macOS desktop](MACOS_DESKTOP.md) for bundle details, TCC privacy keys, and
menu-bar / LaunchAgent behavior.

## Android app

Use JDK 17 and the Android SDK. Install the SDK and NDK versions in the
table using Android Studio's SDK Manager. Set `ANDROID_HOME` or create an
untracked `apps/android/local.properties` containing your `sdk.dir`. The app uses
the prebuilt WebRTC AAR and no longer has a separate CMake/JNI audio target.

Fetch the checksummed AAR from the repository root first:

```powershell
python tools/fetch_webrtc.py android
```

Then, from `apps/android`:

```powershell
./gradlew.bat --no-daemon :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

On Linux/macOS, use `./gradlew` instead. Output:
`app/build/outputs/apk/debug/app-debug.apk`.

For the Android Keystore/Conscrypt regression contracts, run an API 35 x86_64
emulator and `./gradlew --no-daemon -PmicdropPairingOnly=true :pairing-check:connectedDebugAndroidTest`.
The property excludes the main app and its prebuilt WebRTC dependency from
the test-only security APK. This separate
test APK compiles the app's security/link sources into its own UID, needs no
WebRTC AAR or native audio build, and never touches the installed app's keys.
It tests the old signing-policy failure, explicit Forget recovery, non-exportable
prehashed signing, a TLS 1.3 mutual-authentication handshake and link routing.

Install on an arm64 Android 12+ device using Android Studio or:

```powershell
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The provisional debug application ID is `com.maskarauder.micdrop.dev`.
Updates require the same signing certificate as the installed APK. A replacement
with that certificate preserves app data, settings and Android Keystore pairing
identity. `adb install -r` does not bypass a certificate mismatch.

### Stable CI development signing

Set the repository Actions secret **`MICDROP_DEBUG_KEYSTORE_BASE64`** once.
CI restores that private development keystore on the `ubuntu-24.04` runner, uses
it for the `.dev` debug APK, and checks the APK's certificate against the
keystore before publishing `app-debug.apk`. Release signing is separate.

On pushes to `main` and manual runs with `upload_artifacts` enabled (the default),
CI uploads `android-apk` directly as `app-debug.apk` (with no outer ZIP wrapper)
for 14 days and includes **Download app-debug.apk** in the job summary. Main-branch
builds also upload `android-apk-retained` for 14 days so
[draft release assembly](RELEASING.md) can verify and promote the exact build
output across ephemeral runners. Sign in to GitHub to download Actions artifacts
within their retention window. An uploaded rerun replaces that run's APK artifact
and creates a new download link.

Use JDK `keytool` to create a dedicated development key on your own computer.
Android Studio also includes `keytool` in its `jbr/bin` directory. In PowerShell:

```powershell
$micdropKeystore = Join-Path $env:USERPROFILE 'micdrop-debug.keystore'
if (!(Test-Path $micdropKeystore)) {
  keytool -genkeypair -keystore $micdropKeystore -storetype JKS `
    -alias androiddebugkey -storepass android -keypass android `
    -keyalg RSA -keysize 2048 -validity 10000 `
    -dname 'CN=MicDrop Development,O=MicDrop,C=US' -noprompt
  if ($LASTEXITCODE -ne 0) { throw 'Keystore generation failed.' }
}
[Convert]::ToBase64String([IO.File]::ReadAllBytes($micdropKeystore)) | Set-Clipboard
```

In [repository Actions secrets](https://github.com/maskarauder/MicDrop/settings/secrets/actions),
choose **New repository secret**, name it `MICDROP_DEBUG_KEYSTORE_BASE64`, and paste
the clipboard value. Keep a private backup of the keystore; reuse the same file
for future builds. The conventional `android` passwords and `androiddebugkey`
alias are development settings; the keystore itself must stay private. Its
contents are not committed, logged, cached or included in an artifact. Base64
is an encoding for the secret store, not encryption by itself.

Rerun the Android job after adding the secret. Without the secret (including on
fork pull requests, which run without access to repository secrets), CI still
builds, tests and verifies APK signing using a disposable fixture key, and skips
publishing an installable APK or retained release bundle. A configured but invalid
keystore fails instead of falling back to another signer. CI removes runner signing
files after the job; only the public certificate fingerprint is printed.

If you replace an older development keystore on a device that already has MicDrop
installed, `adb install -r` cannot migrate across different signing certificates:
uninstall once (which clears app settings and pairing), install the APK signed with
the permanent key, and re-pair. Subsequent updates signed with the same secret
install in place with `adb install -r`. APK certificates alone cannot recover a
signing key.

For local builds that should update the CI installation, set the same keystore
before running Gradle:

```powershell
$env:MICDROP_DEBUG_KEYSTORE = Join-Path $env:USERPROFILE 'micdrop-debug.keystore'
```

Without that variable, local builds retain the ordinary machine-local debug key.
Sources: [Android app signing](https://developer.android.com/studio/publish/app-signing)
and [GitHub binary secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets).

### Android audio paths and measurements

The [Android guide](ANDROID.md), [platform audio reference](PLATFORM_AUDIO.md),
and [Advanced settings](ADVANCED_SETTINGS.md) describe current modes, route
limits, permissions, recovery and optional processing. Use Diagnostics for a
local AudioTrack output check or a stream report. The original AAudio tone/JNI
harness is retired; its old instructions are historical evidence only.

Source-only [latency tools](../tools/latency/README.md) provide a non-periodic
probe generator and shared-timebase WAV analysis. They are not included in tester
packages, and Python is not needed to run MicDrop. Validate the tools with:

```sh
python -m pip install -r tools/latency/requirements.txt
python -m unittest discover -s tools/latency -p 'test_*.py' -v
```

## iPhone app

The iPhone client is native Swift/SwiftUI for iOS 17+ (iPhone only).
GitHub Actions builds an **unsigned** `MicDrop.ipa` on GitHub-hosted `macos-26`
runners with Xcode 26+; sign and install it from Windows with Sideloadly or
iloader and your Apple ID. See [iPhone provenance](../third_party/IOS.md) and
the [WebRTC record](../third_party/WEBRTC.md).

In the app, **Advanced > Connection settings** controls the initial/recovery
transport order, request deadlines and ICE restart limits. Changes apply to the
next session. A remote link can use direct LAN only after pinned TLS verification
of the saved Windows host. Custom setup/recovery windows require an exact host
capability reply; older hosts retain their watchdog limits. The stream report
shows requested and effective timing. **Advanced > Allow Windows to change phone
settings** (off by default, saved at once) lets the Windows desktop app change
the iPhone's Audio and Advanced preferences for the next connection, switch
**Audio output** live during playback and non-Bluetooth duplex sessions (and save
it for the next connection in microphone-only and Bluetooth headset-mic duplex
sessions), and change **Play desktop audio** and microphone mute within an
authorized session ([phone settings exchange v1](PHONE_CONTROL_V1.md)). Both
phones allow Windows to unmute only after the phone itself has enabled microphone
capture in that session and while microphone permission remains granted, and keep
Windows `live.output_enabled` and Unmute changes session-only (only a Mute is
also saved for the next Connect). The iPhone offers Windows no volume or LE
stereo setting and no wired device; pairing, permissions and microphone consent
stay on the phone.

Matching Android, the iPhone app has Connection setup, Audio output, Microphone,
**Advanced** and **Diagnostics** sections and uses the Windows desktop's dark
slate and gold palette regardless of the system appearance. **Advanced** holds
the Windows opt-in above, **Connection settings** and **Faster recovery after
audio interruptions**. **Diagnostics** holds the build, both report copies,
**Start local output test** (its **Play click** button appears only while the
test runs), the diagnostics text and **Open-source notices**. Automated SwiftPM
and iOS simulator checks run in CI; physical iPhone hardware validation remains
tracked in the [roadmap](ROADMAP.md).

The portable Swift package `apps/ios/MicDropKit` (protocol, identity and TLS transport) builds and
tests on Linux. With Docker Desktop on Windows, from the repository root:

```powershell
docker run --rm -v "${PWD}:/src" -w /src `
  swift:6.3.3-noble@sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c `
  swift test --package-path apps/ios/MicDropKit --force-resolved-versions
```

`--force-resolved-versions` fails if `Package.resolved` no longer matches `Package.swift`; regenerate
it in the same image and commit it (see `third_party/IOS.md` for the dependency process).

The Apple-only app target lives in `apps/ios/MicDrop/`; `apps/ios/project.yml` is the XcodeGen spec
from which CI generates the (git-ignored) Xcode project. Portable code goes into the MicDropKit
targets `MicDropCore` (Foundation and swift-crypto only), `MicDropIdentity` (X.509) and
`MicDropTransport` (SwiftNIO/NIOSSL); code that needs WebRTC, AVFoundation, Keychain, Secure Enclave,
Network.framework browsing, the camera or SwiftUI stays in the app target.

### Swift package updates

`apps/ios/MicDropKit/Package.resolved` pins every Swift package, including the transitive
swift-atomics, swift-collections and swift-system releases. The committed file is required by CI;
missing pins fail the build. Linux uses `--force-resolved-versions`, macOS copies the file into the
generated project and fails if Xcode's resolution differs, and the host job checks the pins against
`third_party/ios-assets/ios-notices.txt` with `tools/check_swiftpm_pins.py`.

When changing a dependency, update its exact version in `Package.swift`, regenerate
`Package.resolved` with SwiftPM in the pinned Linux image, and update its provenance and notices
in the same change. Never write the resolved file by hand. Follow the commands and review steps in
[iPhone provenance](../third_party/IOS.md#adding-or-upgrading-a-swift-package), then commit the
manifest, generated pins and notices together and require both Linux and macOS checks to pass.

### iPhone CI build

The **iPhone app** workflow (`.github/workflows/ios.yml`) runs on GitHub-hosted `macos-26` runners for
pushes to `main` and pull requests (including fork pull requests, because the build needs no secrets)
that change `apps/ios/`, `third_party/`, the fetcher or the iPhone check scripts, and on demand for any
branch (**Actions > iPhone app > Run workflow**; choose `main` for an IPA of the default branch). It
fetches the checksummed WebRTC xcframework (`python3 tools/fetch_webrtc.py ios`), generates the Xcode
project with the pinned XcodeGen, resolves only the committed package pins, builds Release for
`generic/platform=iOS` without code signing, and checks the app and WebRTC framework metadata, Mach-O
targets, embedding, notices and unsigned state before publishing the IPA. The framework's executable,
package type and minimum OS must match the embedded binary; version checks include patch releases. The
app's versions come from the shared `internal/version/version.properties` (`python3 tools/ios_version.py`):
the numeric `MAJOR.MINOR.PATCH` as `CFBundleShortVersionString`, the Android version code as
`CFBundleVersion`, and the full version name in reports. On pushes to `main` and manual runs with
`upload_artifacts` enabled (the default), CI uploads `ios-ipa` directly as `MicDrop.ipa` for 14 days
and writes **Download MicDrop.ipa** and the SHA-256 to the job summary; `main` builds also upload
`ios-ipa-retained` for 14 days for [draft release assembly](RELEASING.md). Keep your downloaded copy
for 7-day re-signing.

A failed build lists the unique compiler errors at the end of the **Build unsigned iPhone app**
step, annotates the first ones on the affected files, and uploads the quiet `xcodebuild` log as
`ios-xcodebuild-log` for 7 days. The job turns on Xcode's "Continue building after errors", so one
failed run reports the errors of every module that can still be compiled. Ephemeral macOS and Linux
runners keep dependency archives, package checkouts and scratch build products inside `$RUNNER_TEMP`
for the duration of the job. The **iPhone Swift formatting** job runs `swift format lint --strict`
with `apps/ios/.swift-format`; when it fails it uploads `swift-format-patch` (`swift-format.patch`,
retained for 7 days), which `git apply` applies; findings that swift-format cannot fix automatically
remain in its log.

Pushes and pull-request Apple checks always run the simulator integration suite, selecting the newest
available iPhone simulator runtime via `xcrun simctl`. Manual runs default **simulator_tests** to true;
turn it off only for an explicit compile-only check. The `MicDropAppTests` target uses fake control
transports to exercise the actual session worker's routing, cancellation and deadline plumbing,
plus local-output Stop lifetime, protected settings storage, the TURN/TLS platform-trust
verifier (`SecTrust` with in-memory test anchors and public-only test certificates) and phone
settings exchange v1 (the settings adapter, its negotiation and `/status` wiring, the controllers'
live bindings, the opt-in and the Connection settings merge, with temporary stores and fixed device
lists). It does not create a native media engine or establish real audio acceptance. The
`ios-simulator-results` artifact uploads the summary JSON, test log and Xcode result bundle for 7 days
on pushes, manual runs with `upload_artifacts` enabled, or test failures. On Intel Macs,
architecture-scoped WebRTC linker stand-ins allow the fake-engine tests to run because the pinned
framework has no x86_64 simulator slice. They do not test native WebRTC media; arm64 device builds
use the real framework. Portable Swift tests continue to run on Linux.

### Install on iPhone

One-time Windows setup: install Sideloadly from <https://sideloadly.io/> and the **web**
(non-Microsoft Store) versions of iTunes and iCloud from apple.com; uninstall Store versions first
and reboot. Store versions cause `NP_E_CONN_FAILED`, `AFC_E_MUX_ERROR` or "no devices detected"; if
detection still fails, also remove Apple's Store "Apple Devices" app. A dedicated secondary Apple ID
with two-factor authentication is recommended: Sideloadly is closed-source software that signs in to
Apple's developer services with these credentials. With its default Remote Anisette option, your IP
address, OS and Sideloadly version go to Sideloadly's server; Local Anisette (Advanced Options)
avoids that.

1. Download `MicDrop.ipa` from the run summary and keep it; optionally compare
   `Get-FileHash .\MicDrop.ipa -Algorithm SHA256` with the summary.
2. Connect the iPhone (iOS 17+) by USB, unlock it, tap **Trust** for this computer and enter the
   passcode.
3. In Sideloadly, drop the IPA, enter your Apple ID, keep the default Advanced Options (do not change
   the bundle ID) and click **Start**; enter the password and two-factor code when asked and wait for
   "Done".
4. On the iPhone: **Settings > Privacy & Security > Developer Mode** → On → **Restart** → after
   unlocking, **Turn On** and enter the passcode. The switch appears only after the first
   sideloaded install.
5. **Settings > General > VPN & Device Management** → under Developer App, your Apple ID → **Trust**.
   The phone needs internet access to verify the app.
6. Open MicDrop and allow **Local Network** (needed for LAN connection and discovery; denying it
   breaks LAN use until it is enabled again in Settings > MicDrop). Camera and microphone are
   requested only when you scan a pairing QR code or send the microphone.

**If Sideloadly cannot sign in.** Since about 2026-10-21, Apple rejects many free-account sideloading
sign-ins (`Login failed (-80046)` or HTTP 503); Sideloadly 0.71.1 failed this way, its Local Anisette
reported "not available" even after a reboot, and its Remote Anisette is Patreon-only. Stop retrying:
repeated attempts can get an Apple ID blocked from sideloading. On 2026-10-24 the open-source
[iloader](https://github.com/nab138/iloader) 2.4.0 (MIT; Windows `.msi` from its GitHub releases, which
publish SHA-256 digests) signed in with the same free Apple ID using its default **Jkcoxson (Mac)**
anisette server and installed the IPA: log in, select the iPhone, **Import IPA**. It uses the same
iTunes device drivers and the same 7-day free signing, and its anisette server operator sees your
sign-in requests. Steps 4–6 above still apply.

A free Apple ID signs for **7 days**: re-sideload the same (or a newer) IPA with the same Apple ID
before or after expiry. An expired app does not open, but its data stays on the phone. Sideloadly's
optional auto-refresh daemon can re-sign while the PC is on and the phone is reachable by USB or the
same Wi-Fi (Bonjour, installed with iTunes, is required for Wi-Fi). A free account can have at most
**3** sideloaded apps installed and create **10** App IDs per 7 days. Use the normal Apple ID
password; app-specific passwords only partly work, and only with a paid developer account.

The provisional bundle ID is `com.maskarauder.micdrop.dev`. Re-sideload with the same Apple ID and
bundle ID to refresh or update in place; this keeps settings, the saved connection and the pairing
identity, so Windows needs no new approval. A different Apple ID or a changed bundle ID needs
**Forget saved connection** and re-pairing, and the old phone key should be removed on Windows
(`Phones → Remove selected phone` in the desktop app, or `devices`, then `revoke <full-phone-key>`
in the console). Deleting the app removes its data; the next install
starts without the old pairing, and Windows still needs removal for the old key.

Never put an Apple ID, app-specific password, certificate, provisioning profile or App Store
Connect key into repository secrets or files; CI stays secret-free. Fork pull requests also build
unsigned IPAs from their own code: sideload only builds of `main` or your own branches. CI does not
malware-scan the IPA; your own Apple ID's signing at install time is the integrity boundary, so
verify the SHA-256 shown in the summary.

A periodic sine, RTT or output-buffer counter is not a physical latency result.
Follow [measurement requirements](LATENCY.md), record the actual route and
hardware, and retain failure evidence rather than inferring a pass from logs.

## Prepare the Windows package

Build the runtime into `build/native` as above and build the desktop executable
with its manifest using [the desktop build steps](WINDOWS_DESKTOP.md#build).
Then prepare notices and the two current user guides from the repository root:

```powershell
python tools/windows_payload.py
if ($LASTEXITCODE -ne 0) { throw 'Windows payload preparation failed.' }
./tools/build_windows_installer.ps1 -PayloadDirectory build/host -OutputDirectory build/windows-installer
```

`tools/windows_payload.json` is the shared release allowlist. The working
`build/host` directory and internal `windows-x64-harness` artifact may also
contain the console program; never ZIP that whole directory for testers.
[Draft assembly](RELEASING.md) creates the curated portable ZIP and verifies
its runtime, notices and guides against the installer manifest. Neither package
contains internal reports, ADB commands or latency tooling.

## CI and dependency provenance

`.github/workflows/build.yml` runs native WebRTC and C/C++ contracts, Go tests and vet on
GitHub-hosted `ubuntu-24.04`, `windows-2022`, and `macos-26` runners (`persist-credentials: false`),
including PCM conversion, recording, ICE gathering, TURN TLS certificate verification, and
encoded/decoded stereo and duplex WebRTC round trips across all three desktop OSes, plus
standalone rendezvous service and systemd verification and the Android arm64 APK build,
lint and JVM contracts.
A separate API 35 KVM emulator job on `ubuntu-24.04` checks Android Keystore signing
and Conscrypt mutual TLS. Linux checks the known-offset measurement fixtures in an
isolated Python virtual environment. Windows, Linux (`linux-x64-host`:
`MicDrop-linux-x64-host.tar.gz`), and macOS (`macos-arm64-host`:
`MicDrop-macos-arm64-host.tar.gz`) jobs also package, extract, and smoke-test the
Go CLI host with its native WebRTC shared library (`doctor`, `rtc-check`, and
`tone`) without requiring a physical audio endpoint.

On pushes to `main` and manual workflow runs (`upload_artifacts` defaults to `true`),
CI uploads build outputs and verification reports to GitHub Actions for 14 days
(30 days for `windows-defender-scan`), and uploads diagnostic/test reports on failure.
When the stable Android development signer is configured, `android-apk` uses
`upload-artifact` single-file mode (`archive: false`) so its download URL appears
directly in the job summary. Main-branch builds also upload 14-day `*-retained`
release bundles (`windows-x64-harness-retained`, `windows-x64-installer-retained`,
`android-apk-retained`, and `ios-ipa-retained`) containing `manifest.json` and
`SHA256SUMS` so [draft release assembly](RELEASING.md) can promote exact verified
packages across ephemeral GitHub-hosted VMs.

Device playback and physical latency checks remain manual. Workflow actions are
pinned to immutable commits. Runner compiler and CMake versions are recorded in
job logs rather than treated as a fully hermetic toolchain.

The **iPhone portable Swift contracts** job builds and tests `MicDropKit` on `ubuntu-24.04`
in the digest-pinned Swift image, and the **iPhone Swift formatting** job checks Swift
formatting. The path-filtered **iPhone app** workflow runs on GitHub-hosted `macos-26`
runners and publishes the unarchived `MicDrop.ipa` after the pin, bundle, Mach-O and
unsigned checks. Device behavior (background audio, routes, Secure Enclave, Local Network,
and Sideloadly/iloader re-signing) remains manual.

Before publishing the Windows harness, CI configures the ephemeral runner with
`./tools/scan_windows.ps1 -ConfigureEphemeralRunner` (disabling cloud MAPS reporting
and automatic sample submission while keeping real-time/local scanning active) and runs
[`tools/scan_windows.ps1`](../tools/scan_windows.ps1) on the complete package,
including the executables, native WebRTC DLL, setup and packaged notices/guides. It
updates Microsoft Defender signatures and requires an engine with signatures no
more than 48 hours old. A harmless EICAR test archive, created only in runner
temporary storage, must produce the expected detection before the real scan.
The test file is never executed or included in an artifact. The custom scan uses
`-DisableRemediation` to ignore drive exclusions for this scan and preserve
evidence; any detection, scan error, unavailable scanner, failed update or failed
positive control blocks the harness upload. Package SHA-256 hashes must also
remain unchanged throughout the scan.

The separate `windows-defender-scan` artifact retains the JSON result, file hashes,
engine/platform/signature versions and scanner output for 30 days on `main` pushes,
manual uploads and scan failures. Its positive-control log deliberately records an
EICAR detection; the `target-*.log` files cover the distributed package. Cloud
reporting and automatic sample submission remain disabled during the scan. This is
a local Defender scan, not a guarantee of safety, a public multi-engine analysis,
code signing, or a replacement for download reputation or behavior-based installation
checks. See [Windows security detections](WINDOWS_SECURITY.md) for investigation and
normal-account install/upgrade acceptance. Do not bypass a browser/antivirus block
on the strength of CI alone; investigate the exact reported file and detection.
See [Microsoft's command reference](https://learn.microsoft.com/en-us/defender-endpoint/command-line-arguments-microsoft-defender-antivirus)
and the [EICAR test-file description](https://www.eicar.org/download-anti-malware-testfile/).

Before APK publication, CI checks every packaged native library's
LOAD alignment, mapping congruence and RELRO end, then runs SDK `zipalign` with
`-P 16`. The prebuilt WebRTC library remains subject to these checks after removal
of the AAudio JNI target. A misaligned prebuilt must be replaced or rebuilt. The checks
cover binary/package alignment, not runtime behavior on a physical 16 KB device.
See [Android 16 KB page sizes](https://developer.android.com/guide/practices/page-sizes).

The Gradle wrapper is generated by Gradle 8.13 from its official binary
distribution, under the Apache-2.0 license. The distribution checksum is
`20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78`.
Wrapper JAR validation is also performed by the Gradle setup action. Sources:
[Gradle 8.13](https://docs.gradle.org/8.13/release-notes.html),
[wrapper verification](https://docs.gradle.org/8.13/userguide/gradle_wrapper.html#sec:verification),
and [Gradle license](https://github.com/gradle/gradle/blob/v8.13.0/LICENSE).
Kotlin/AGP come from their declared official Maven repositories. The WebRTC
assets are pinned by source/build revision and archive SHA-256; their provenance,
producer build recipe, C++ ABI, and notice packaging are recorded in
[third_party/WEBRTC.md](../third_party/WEBRTC.md). No third-party virtual audio
driver is bundled. Windows CI also runs an encoded/decoded stereo round trip
and the packaged Go/DLL runtime check; these do not establish Android hardware
routing or physical latency.

## Current validation and beta preparation

See the [roadmap](ROADMAP.md) for verified capabilities, open physical-device
checks, and known platform limitations.

Run the automated checks relevant to a change and record its source revision,
commands, and results. Audio-routing and lifecycle changes need focused device
checks. Mark unavailable hardware as blocked or skipped with a reason; do not
infer acoustic performance from unit tests, network RTT, or buffer counters.
Use the [latency tools](../tools/latency/README.md) for physical measurements.

For beta delivery, verify matching package versions and source, notices, an
in-place Android update with the stable signer, and Windows install/upgrade
behavior. [Releasing](RELEASING.md) covers the draft release workflow.
Production code signing and store delivery remain separate milestones.

## Versioned draft packages

Windows, Windows Setup, Android and iPhone versions share
`internal/version/version.properties`. See [RELEASING.md](RELEASING.md) for
version-code ordering, main-branch `*-retained` artifact promotion into an
unpublished GitHub draft, checksums and retry behavior.
