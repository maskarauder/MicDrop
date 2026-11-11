# Primary references

Checked on 2026-09-28. These sources support platform constraints and protocol facts. Product scope, proposed stack, milestones, numeric budgets, and acceptance targets are this project's design proposals. Recheck version-sensitive requirements when pinning dependencies and before release.

| ID | Source | Relevant subject |
| --- | --- | --- |
| S01 | [SoundWire help — GeorgieLabs](https://georgielabs.altervista.org/SoundWireHelp.html) | Reference product, buffering, computer-to-Android audio |
| S02 | [Loopback recording — Microsoft](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) | WASAPI shared-mode loopback, events, protected audio, session behavior |
| S03 | [SYSVAD virtual audio driver sample — Microsoft](https://learn.microsoft.com/en-us/samples/microsoft/windows-driver-samples/sysvad-virtual-audio-device-driver-sample/) | Virtual-device implementation reference |
| S04 | [Low-latency audio — Android Developers](https://developer.android.com/games/sdk/oboe/low-latency-audio) | Native audio requests, callbacks, formats, buffering |
| S05 | [Audio Manager self-managed call guide — Android Developers](https://developer.android.com/develop/connectivity/bluetooth/ble-audio/audio-manager) | Communication routing and route-change confirmation |
| S06 | [Bluetooth Audio technical note — Google Oboe](https://github.com/google/oboe/wiki/TechNote_BluetoothAudio) | A2DP versus voice routes and headset buffering |
| S07 | [Foreground service types — Android Developers](https://developer.android.com/develop/background-work/services/fgs/service-types) | Media/microphone services and microphone-start restrictions |
| S08 | [Manage audio focus — Android Developers](https://developer.android.com/media/optimize/audio-focus) | Audio focus and lifecycle requirements |
| S09 | [Getting started with peer connections — WebRTC](https://webrtc.org/getting-started/peer-connections) | Media negotiation and application-owned signaling |
| S10 | [NetEq design — WebRTC source documentation](https://chromium.googlesource.com/external/webrtc/+/master/modules/audio_coding/neteq/g3doc/index.md) | Adaptive receive jitter buffering and concealment; verify APIs against the selected revision |
| S11 | [RFC 8445 — IETF](https://www.rfc-editor.org/rfc/rfc8445) | ICE connectivity establishment |
| S12 | [RFC 8656 — IETF](https://www.rfc-editor.org/rfc/rfc8656) | TURN relay behavior |
| S13 | [RFC 8827 — IETF](https://www.rfc-editor.org/rfc/rfc8827) | WebRTC security and identity/fingerprint binding |
| S14 | [Driver signing policy — Microsoft](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/kernel-mode-code-signing-policy--windows-vista-and-later-) | Distribution requirements for Windows drivers |
| S15 | [RFC 7587 — IETF](https://www.rfc-editor.org/rfc/rfc7587) | Opus RTP clock, packet duration, and codec signaling |
| S16 | [Android 17 background audio hardening — Android Developers](https://developer.android.com/about/versions/17/changes/bg-audio) | Background playback/focus lifecycle enforcement |
| S17 | [Local network permission — Android Developers](https://developer.android.com/privacy-and-security/local-network-permission) | LAN access and Android 17 target-SDK requirements |
| S18 | [IAudioClient::Initialize — Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize) | Shared-mode event handling, default period, buffer requests |
| S19 | [IAudioCaptureClient::GetBuffer — Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudiocaptureclient-getbuffer) | Packet lifetime, silence/discontinuity flags, timestamps in 100 ns units |
| S20 | [WAVEFORMATEXTENSIBLE — Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatextensible) | Valid bits, channel masks, PCM containers |
| S21 | [WebRTC statistics — W3C](https://www.w3.org/TR/webrtc-stats/) | Selected candidate-pair RTT, cumulative jitter-buffer delay/count, concealment and time stretching |
| S22 | [AudioManager route prediction — Android Developers](https://developer.android.com/reference/android/media/AudioManager#getAudioDevicesForAttributes(android.media.AudioAttributes)) | API 33+ anticipated media devices, not proof of the actual AudioTrack route |
| S23 | [Correlation — NumPy](https://numpy.org/doc/stable/reference/generated/numpy.correlate.html) | Correlation lag/sign convention; the offline tool uses zero-padded FFTs and local normalization |
| S24 | [Background media — Android Developers](https://developer.android.com/media/platform/mediaplayer/background) | Worker-thread setup, scoped wake locks and service cleanup; checked 2026-09-29 |

No third-party implementation or branding is bundled with this documentation. Dependency versions and license notices will be added when dependencies are selected.
