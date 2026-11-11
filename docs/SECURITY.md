# Security and privacy design

This guide describes the Windows, Android, and beta iPhone implementation.
The desktop app uses durable paired identities for LAN and opt-in remote sessions.
Functional coverage and remaining device or physical-latency limits are summarized
in the [roadmap](ROADMAP.md); those checks are not an independent
security audit. The legacy development listener has a separate boundary,
described below.

For vulnerability reports, follow the root [security policy](../SECURITY.md).
Do not include sensitive reports or reproduction details in public issues.

Stop diagnostics retain one bounded stream report (and on Android, one bounded Java
exception record) in app-private, non-backed-up storage (`Application Support` with
`isExcludedFromBackup` on iPhone). Android's explicit Copy crash report action
reads only this package's exit history and a selective native symbolic stack; it
skips tombstone memory/log/command-line data. Exception messages are excluded.
These local reports do not enter automatic host telemetry or authorize media
resumption; keep copied crash evidence private.

## Legacy development listener

The console's unpaired development mode uses the [version-2 LAN protocol](PROTOCOL.md).
It is separate from the desktop app's durable paired listener. The legacy mode
uses an ephemeral TLS 1.3 host identity, an invitation-pinned certificate, a
bounded reusable connection credential, and fresh random per-stream credentials.
It uses standard Go TLS/cryptography, Android TLS, and WebRTC
DTLS-SRTP; it does not define a new encryption algorithm. Starting the host
command authorizes sequential access using that private link until shutdown or
expiry (12 hours by default, configurable from 1 minute to 23 hours). Only one
receiver is accepted at a time. Restarting the host resets its identity and token.
The invitation is sensitive: transfer it privately and exclude it from shared
logs. It is intentionally printed for setup; ordinary status omits tokens, raw
SDP, candidates, addresses, and recordings.

Control and media fingerprints are exchanged directly over the pinned HTTPS
connection. Capture begins after authenticated answer acceptance. Expiry/stale-session rejection,
message bounds, request limits, TLS-only handling, and receiver-loss stopping are
implemented and covered by host contracts. Passing Go tests alone do
not establish phone lifecycle or network behavior.

This legacy playback-only mode does not create an outgoing audio track. The
current Android app also supports explicitly authorized microphone modes,
described below. Android playback uses a Media3 library foreground service with
trusted media-controller checks,
local mute/stop before remote acknowledgement and session-scoped worker callbacks.
Its activity passes links through an in-process binder. Manual Play uses the same
media card; bounded transient-focus resumption requires existing playback intent.
The last successfully connected
v2 link is saved using Android Keystore AES-256-GCM and an atomic ciphertext file
excluded from backup. There is no plaintext fallback or playback merely from opening the app.
The saved certificate pin is always checked; host identity changes require its
new link. Forget deletes local saved authorization, but cannot revoke other copies
of the bearer link; stop/restart Windows to revoke it. Legacy v1 links are unsaved.
Process loss ends playback through the existing host watchdog.
A 10-second transient recovery window cannot renew a disconnected media deadline,
and duplicate report acknowledgments cannot renew the heartbeat deadline.
The legacy v2 development invitation is not durable pairing and does not
provide the current remote-session setup. The paired listener below has a
separate authorization boundary.

## Trust boundaries

Audio may include private conversations and computer notifications. Protect against an unpaired LAN peer, an internet observer, a replayed invitation, a stolen relay credential, and a signaling service that tries to substitute a peer. The phone OS, computer OS, and correctly installed audio drivers are trusted; a compromised endpoint is outside this initial threat model.

Do not treat a local network, a displayed hostname, or successful connectivity as authorization.

## Pairing and session identity

[Paired LAN playback](PAIRING.md) uses the persistent current-user DPAPI
Windows P-256 key, a non-exportable AndroidKeyStore P-256 signing key on
Android, and a Secure Enclave (or Keychain fallback) P-256 signing key
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable) with
NIOSSL mutual TLS 1.3 on iPhone. The `--paired` listener (also used by the
desktop app) requires TLS 1.3 client proof, explicit local approval, and a
current grant on each HTTP request. A fresh per-stream credential is also
bound to its client key. Grant/consumed-invitation receipts are protected and
atomically replaced under an exclusive listener lock. Revocation is durable,
interrupts active media, and is rechecked by the watchdog. Missing/corrupt identity
or grant state fails closed; there is no automatic trust reset or legacy fallback.
Phone Forget clears local identity/resume data and does not claim remote revoke.
The wire schema and negative tests are documented there.

- Each device has a persistent identity held in platform-protected storage where available. A friendly device name is only a label.
- [LAN discovery](LAN_DISCOVERY.md) advertises only the selected endpoint, protocol versions and public host-key hint. Advertisements are unauthenticated and may be forged. Neither Android nor iPhone (`NWBrowser`) ever uses a discovery key as a TLS pin: each retains the saved host/phone keys, requires an explicit Connect and remembers a changed address only after authenticated playback. New hosts still need QR/manual enrollment and approval. The stable key hint makes a host recognizable to LAN observers; `--no-discovery` opts out. Foreground searches and result/watch counts are bounded.
- First pairing uses a private invitation, displayed as both text and a terminal QR, containing a host identity fingerprint and a high-entropy, single-use secret. QR scanning and manual entry convey the exact same authenticated information; a bare address or guessable short PIN is insufficient. The bundled Android and iPhone (`AVCaptureSession`) scanners accept only pairing invitations and fill the input for explicit Connect. Camera permission is optional for manual entry, frames are not saved, and QR contents must not be included in reports or screenshots. Scanning does not approve a phone or start playback.
- Enrollment invitation lifetime: five minutes, with rate limits, explicit host approval, and immediate invalidation after successful pairing. A remotely conveyed invitation requires the same identity validation.
- Paired keys are stored locally; revocation removes authorization and can terminate an active session. Changed identity requires re-pairing, not silent acceptance.
- Bind each fresh session, requested directions, negotiation generation, and media certificate fingerprints to the paired identity. Reject replays and altered negotiation data.

Use maintained cryptographic libraries and a reviewed authentication construction. The direct-LAN construction, encodings and replay protections are specified in [PAIRING.md](PAIRING.md); key rotation, backup/recovery UI and independent review remain open. These bullets are not permission to invent encryption or ship an unreviewed custom handshake.

WebRTC protects media transport, but authenticated signaling and identity binding still matter. TLS to a rendezvous service by itself does not prove that the negotiated media peer is the previously paired device. The WebRTC security architecture explicitly discusses fingerprint/identity binding. [S13](REFERENCES.md)

## Transport and remote operation

Require DTLS-SRTP through the selected WebRTC implementation; do not add plaintext LAN mode. Authenticate local signaling using the verified pairing identity and TLS. Validate normal server certificates for remote HTTPS/WSS and TURN TLS (including Apple `SecTrust` platform trust evaluation on iPhone); no global “accept any certificate” switch.

Remote signaling must carry authenticated peer-bound negotiation. A relay forwards encrypted packets; it must not terminate or transcode the audio session. A compromised signaling service must not be able to substitute a media fingerprint without detection. Validate that property before calling the product end-to-end authenticated.

The [implemented rendezvous foundation](REMOTE_ACCESS.md) accepts outbound WSS sockets
using distinct operator-provisioned route/role tokens, then forwards only bounded
opaque bytes between opposite roles on the same route. Existing paired TLS runs
inside that stream. Resource tokens are not media authorization; a stolen token
may consume limited service resources but cannot replace an endpoint's paired
identity. The service dials no client-supplied network destination. The Windows
remote host also binds its explicitly configured private LAN address/port with
the same paired TLS and session owner. A TLS-only pinned reachability probe sends
no offer or bearer credential. See [Advanced settings](ADVANCED_SETTINGS.md)
for route order, cancellation and fallback limits. No public bind, router mapping
or automatic firewall exception is added. Pairing grants and local controls
remain authoritative on both transports.

TURN uses scoped, short-lived credentials, allocation quotas, and bandwidth limits. Never embed reusable administrative or unlimited relay credentials in a client. The service operator can still observe metadata such as addresses, traffic timing, and volume; do not imply anonymity.

Remote access is disabled until the host user enables it. Access is limited to approved devices and audio functions. No shell execution, arbitrary file access, or remote computer-control feature is part of this protocol.

## Microphone consent and controls

Capture starts only after the phone user selects/enables an input and grants required OS permission. The computer cannot secretly turn it on. Playback permission and microphone permission are independent.

Ordinary playback sessions keep the microphone disabled. Enabling Send microphone and choosing Connect is explicit visible activity
consent for a new v3 session,
after RECORD_AUDIO (Android) or iOS microphone permission. Capture begins with local transmission and Windows
rendering gated; only the verified selected input route and authenticated enable
release those gates. Media Play, discovery, pairing and process restart cannot grant that
consent. It is not persisted. An existing, explicitly started session may continue
through bounded network recovery under [PROTOCOL.md](PROTOCOL.md). Actual input
loss/change or capture failure gates return audio while the applicable recovery
policy runs. It never silently selects another microphone.

The nonexported microphone service promotes to the microphone foreground type
before creating capture. Duplex additionally uses the media-playback foreground
type and requests focus only after promotion. Its exact paired capability/direction
must be confirmed before capture; media Play/automatic resumption never selects
duplex. Focus, route and network interruptions use the bounded pause/recovery
policies; recovery does not grant new microphone consent.

By default, Mute immediately gates the ADM and stops AudioRecord (or iOS input capture). The optional
[keep-capture-active setting](ADVANCED_SETTINGS.md#keep-microphone-capture-active-while-muted)
can retain an already authorized, verified capture while muted. In that mode
the ADM supplies silence, the outgoing audio track is disabled, and Windows'
authenticated microphone gate remains closed. The OS microphone indicator
may remain on. The option does not start capture for a session that began muted,
and Stop, pause/interruption, route loss, and network recovery still stop capture.

The paired/session-authenticated `/microphone` control resets Windows playout
before acknowledgment. Unmute re-verifies input and releases the local gate only
after that acknowledgment, serialized with cancellation. Stop closes capture
before `/stop` and native teardown. Capture, permissions and background behavior
still require focused device verification across target hardware.

Windows phone-setting changes require the phone-local **Allow Windows to change
phone settings** opt-in, which is off by default. Commands are bounded, tied to
the current session and settings revision, and expire without confirmation.
Windows cannot grant phone permissions or start a new microphone session.
The phone validates each allowed setting; offline changes are not queued or
replayed into later sessions. See [phone control](PHONE_CONTROL_V1.md).

Provide an always-accessible mute/stop control during an active microphone session. Mute stops new microphone content before encoding/transmission and clears pending unsent microphone data. Already delivered audio cannot be recalled; flush pending receiver playout on receipt of the mute state where practical. Show mute state separately from network activity, since transport keepalives may continue.

## Stored data and diagnostics

Do not record or retain audio by default, on endpoints or servers. Pairing material, tokens, raw SDP/ICE details, and private network addresses must not enter ordinary logs.

When connection logging is enabled, the Windows host writes a bounded combined
diagnostics log per stream session. Android and iPhone send only a defined metrics
schema through the existing pinned/authenticated status heartbeat; there is no
unauthenticated upload or arbitrary file/text field. It includes phone model,
OS/build, route categories and counters, and sanitized Windows status. No audio,
device serials or Bluetooth names are included. Each file is created exclusively
when an authenticated session initializes and capped at 16 MiB. An idle listener
creates no log. Stopping a session finalizes its log and releases media while
keeping the listener available.

The [Windows Options settings](WINDOWS_DESKTOP.md) control **Save connection logs** and
**Keep newest connection logs**. A positive retention count (1–10000) prunes the
oldest recognizable MicDrop session files; 0 keeps all and is the default.
Active logs are protected and may temporarily exceed the count. Disabling
logging prevents new files, keeps existing files, and skips pruning. These
settings apply on the next host Start. The CLI provides `--no-log`,
`--log-retention N`, and `--log-dir`; its default directory is
`diagnostics-private`.

Disabling file logging does not disable authenticated live statistics or phone
controls. The phone-control protocol acknowledges received reports as
`not_recorded` when they were not saved; settings snapshots are not written to
connection logs. Logging failure does not authorize capture, extend
unauthenticated sessions, or stop working playback.

Keep configuration and pairing identity across routine app upgrades; version migrations must not silently broaden access. Redact diagnostic exports by default and let the user deliberately export richer data for debugging. Synthetic benchmark recordings are allowed when clearly identified as test artifacts.

For remote operation, document the service's metadata, retention duration, deployment owner, and relay bandwidth costs before release. The LAN feature remains usable without that service.

## Required negative tests

- Unpaired and revoked peers cannot receive computer audio or inject microphone audio.
- Expired links, reused legacy v1 invitations and stale session messages fail without starting capture.
- Valid v2 reuse creates a fresh isolated stream only after the previous peer and log close.
- Modified media fingerprints or unauthorized direction changes are rejected.
- Malformed signaling and oversized messages fail within bounded memory/CPU use.
- Loss of the phone input never silently activates another microphone.
- Missing relay credentials and invalid TLS certificates produce clear failures.
- Stop/mute work while signaling is unavailable; reconnection does not replay queued audio.

Release packaging must also address app signing, dependency updates, and any Windows driver signing. Product operation must not depend on weakening the user's operating-system security configuration.

Windows harness publication requires the [CI antivirus scan](DEVELOPMENT.md#ci-and-dependency-provenance)
to complete without detections using current Defender signatures. Its report
identifies the exact package files by SHA-256. A passing scan is one check, not
proof of safety or evidence that a separate browser warning is a false positive.
