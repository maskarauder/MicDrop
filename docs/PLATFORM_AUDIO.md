# Platform audio and routing

This guide distinguishes the implemented Windows, Linux, macOS, Android, and iPhone audio paths from
hardware-dependent behavior and future platform work. See [beta testing](BETA_TESTING.md)
for supported setup and the [roadmap](ROADMAP.md) for current coverage and remaining checks.

## Windows host

Use shared-mode WASAPI loopback capture on the selected render endpoint. Event-driven loopback is supported on the proposed Windows target; exclusive-mode loopback is not. Capture formats, protected audio, and applications outside the ordinary shared output mix can affect what is available. [S02](REFERENCES.md)

Enumerate endpoints by stable identity where available. Offer “follow default output” and “use this endpoint” as distinct choices. Track invalidation and default-device changes; flush stale samples when rebuilding the path.

The capture path implements default-at-start and explicit endpoint selection.
It keeps the selected endpoint for the run; a default-device change is not a live
migration promise. Native streaming, format adaptation and bounded network
recovery are implemented. Device invalidation and route changes still require
focused hardware testing.

Do not promise that lowering or muting the PC speaker endpoint preserves captured audio on every system. Test actual behavior. A later virtual render endpoint can let the user send application audio to the phone without requiring the physical PC speakers to play it. Per-application capture is also a later extension.

### Making the phone a computer microphone

WASAPI capture and packet reception alone do not register a new system recording device. The release needs a real endpoint strategy:

| Strategy | Good for | Work and limits |
| --- | --- | --- |
| User-installed virtual cable | Fast proof of the complete reverse path | Document the paired render/capture endpoints; validate buffers and licensing; installation is a prerequisite. |
| Licensed bundled endpoint | Potential product distribution | Confirm redistribution terms, installation behavior, support, and measured latency before choosing a vendor. |
| Product-owned virtual driver | Controlled installation and endpoint identity | Dedicated driver engineering, lifecycle tests, signing, update and uninstall support. |

Microsoft's SYSVAD sample demonstrates virtual audio-driver concepts. Treat it as a starting reference; samples still require adaptation, validation, and distribution work. [S03](REFERENCES.md) Production driver distribution must follow the applicable Microsoft signing process. Do not ask end users to disable Secure Boot or enable test-signing as a normal install step. [S14](REFERENCES.md)

The beta uses a [separately installed virtual cable](VIRTUAL_AUDIO_CABLE.md).
Endpoint selection remains behind the native adapter. Bundling or writing a
driver is deferred.

## Linux host

On Linux x64, `capture_linux.cc` loads `libpulse.so.0` dynamically at runtime
(`dlopen`) so `micdrop-host` works across PipeWire (`pipewire-pulse`) and
PulseAudio desktop sessions without requiring `libpulse` on headless contract
or rendezvous runners.

- **Desktop playback capture:** Enumerates active PulseAudio/PipeWire sinks by
  sink name (with server `default_sink_name` flagged `default_multimedia`) and
  records `PA_SAMPLE_FLOAT32NE` audio from `<sink_name>.monitor` using
  `PA_STREAM_ADJUST_LATENCY`. An explicit sink selection never falls back to the
  default sink if missing.
- **Microphone return cable:** No kernel module is required on PipeWire or
  PulseAudio. Create a user-session null sink whose monitor acts as a virtual
  microphone input for conferencing/recording apps:
  `pactl load-module module-null-sink sink_name=MicDropMic sink_properties=device.description=MicDrop_Microphone`
  Then pass `--microphone-device MicDropMic` to `micdrop-host stream` and choose
  **Monitor of MicDrop_Microphone** (or use `pw-link` / `pactl load-module module-remap-source`)
  inside the consuming application. Passing the same sink for desktop capture
  and microphone return is rejected before opening audio.

## macOS host

On macOS arm64 (macOS 14.2 Sonoma or newer), `tap_darwin.m` and
`capture_darwin.cc` use CoreAudio Hardware Process Taps and `HALOutput`
AudioUnits without kernel extensions:

- **Desktop playback capture:** Enumerates output `AudioDeviceID` endpoints by
  persistent CoreAudio `kAudioDevicePropertyDeviceUID`, creates a private
  unmuted `CATapDescription` (`initWithProcesses:@[] andDeviceUID:withStream:0`)
  and private aggregate device (`AudioHardwareCreateProcessTap` +
  `AudioHardwareCreateAggregateDevice`), and pulls non-allocating `Float32`
  frames on a real-time input `HALOutput` AudioUnit callback. macOS prompts for
  System Audio Recording permission on first capture.
- **Microphone return cable:** Renders returned `Float32` PCM into an explicitly
  selected output device UID (for example a user-space CoreAudio AudioServerPlugIn
  virtual cable such as BlackHole 2ch). Missing or duplicate explicit UIDs fail
  closed without falling back to the Mac's speakers.

## Android playback

Listen mode is ordinary local **media playback**: use media usage/content attributes, media volume, and a media session/control surface. It does not make the phone advertise itself as a Bluetooth sink to the computer. The app receives audio over IP; Android then routes its output to an attached audio device.

Request the low-latency native path where supported, then inspect the obtained configuration. Oboe/AAudio low-latency or exclusive requests are not guarantees, especially for Bluetooth routes. Do not label the stream as a game solely to chase a faster path; its usage must reflect the product's selected mode. [S04](REFERENCES.md)

The current WebRTC module uses media-configured AudioTrack for playback-only
streams and exposes a matching local output check in Diagnostics. Communication
routes for headset microphones have different format/quality constraints. A
custom Oboe/AAudio module is not part of the current app.

## Input/output combinations

| Requested combination | Intended handling |
| --- | --- |
| Speaker or wired/USB output, no microphone | Primary baseline for measuring the network/audio engine |
| Bluetooth media output, no microphone | Normal media route; report device-dependent total delay |
| Phone microphone with speaker or wired output | Duplex with tested echo-control policy |
| Phone microphone with Bluetooth media output | Experimental until verified per device; do not assume input/output can always be selected independently |
| Classic Bluetooth headset input and output | Communication mode; expect route/format changes and explain playback-quality tradeoffs |
| LE Audio headset input and output | Capability-based support; verify both directions and actual route; no universal latency promise |

Classic Bluetooth generally offers a music-oriented A2DP path and a voice-oriented HFP/HSP path using SCO. Activating the headset microphone commonly moves the session to the voice path. The exact quality and delay depend on the phone, headset, OS, and supported codecs. [S06](REFERENCES.md)

For Android communication routing, use available communication-device APIs and observe successful route changes, rather than assuming a request is applied immediately. Clear the communication-device selection when leaving that mode. Modern guidance uses `setCommunicationDevice()` for compatible HFP and LE Audio routes. This is a communication API, not a general A2DP media-output switch. [S05](REFERENCES.md)

The product initially manages its own audio session. If a later version adopts Android Telecom, use Telecom's endpoint management for that session instead of competing route controllers. Revisit the decision with the platform guidance.

## Lifecycle and permissions

- Request microphone permission only when the user enables microphone functionality. Playback alone must not require microphone access.
- Use the appropriate foreground-service types and notifications for active media playback and, when enabled, microphone capture. Start capture from an eligible user-visible action; background microphone-start restrictions apply. [S07](REFERENCES.md)
- Handle audio-focus denial, loss, calls, and interruption recovery. Android can enforce focus behavior, and applications targeting Android 15 or later need the appropriate visible/foreground state to request focus. [S08](REFERENCES.md)
- Test Android 17 background audio hardening as well: a valid foreground-service lifecycle matters even for native audio libraries. Start the session from visible user intent and stop its lifecycle when the user ends playback. [S16](REFERENCES.md)
- Account for LAN access permissions. Android 17 / target SDK 37 introduces `ACCESS_LOCAL_NETWORK` or eligible system-mediated discovery alternatives. Permission denial can affect native sockets as well as discovery. Version-gate implementation and recheck requirements when pinning the target SDK. [S17](REFERENCES.md)
- Audit Bluetooth, notification, camera-for-QR, and discovery permissions for the APIs actually used. Manual pairing should remain available without camera permission. Avoid broad scanning or location permission when unnecessary.
  QR scanning requests camera only when opened, marks camera hardware optional,
  closes preview while backgrounded and preserves manual entry. Microphone and
  Nearby devices permission requests belong to their respective audio features.

Test screen-off, battery saver, notification controls, activity recreation, app termination, permission revocation, and network changes. The current custom WebRTC service holds a partial CPU wake lock during its active session to keep signaling and native playback serviced while the screen is off. It uses timed acquisition, active-session renewal, and release on all terminal paths; it does not keep the screen on. Measure battery impact in the background acceptance run. No Wi-Fi lock or battery-optimization exemption is requested; add either only if hardware evidence justifies it. [S24](REFERENCES.md)

## Route transition procedure

1. Record the user's requested mode and show any relevant quality change.
2. Stop accepting new samples on the changing path; mute transmission if its source is changing.
3. Request the OS route, wait for confirmation with a bounded timeout, and inspect the actual device and format.
4. Recreate native streams if required, reset affected format adapters, and drop old queued audio.
5. Resume playback or microphone transmission only when the local state still authorizes it.

A rejected or lost input must not silently fall back to another microphone. Preserve playback if its route remains valid. On headphone output loss, pause by default and let the user select a new destination.

## Future platforms

The native transport boundary supports distinct platform adapters without assuming identical OS routing. The iPhone client uses its own `AVAudioSession`, background keep-alive, and route-recovery adapter (system output route picker, identifiable route-UID persistence, and no programmatic system-volume or LE Audio input APIs); its verified scope and remaining physical-device checks are summarized in the [roadmap](ROADMAP.md), and no iOS route behavior is assumed from Android results. Linux x64 (`micdrop-host`) and macOS arm64 (`MicDrop.app` and `micdrop-host`) desktop hosts implement desktop capture, virtual-cable microphone return, and WebRTC streaming; native Linux GUI packaging and physical multi-OS latency validation remain follow-up work.
