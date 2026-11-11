# Phone settings exchange, version 1

The paired phone remains the authority for its preferences, phone permissions,
and microphone consent. Windows may display reported settings. Changes require
the phone's **Allow Windows to change phone settings** option, off by default.
Pairing, credentials, permission grants, and beginning microphone capture remain
phone-local operations. Volume control affects Android's current media/voice
stream; mute changes apply only within an already authorized microphone session.

## Negotiation and transport

The phone's offer sends `X-MicDrop-Phone-Control: 1`. Supporting Windows hosts
reply with `phone_control_version: 1`. Only then does the phone include
`phone_control` in authenticated POST `/status` requests. The host records
whether the header was negotiated and the desktop device row carries that flag
in-process (`session.PhoneStatus.ControlNegotiated` to
`desktop.DeviceConnection.SettingsSupported`; no wire change), so the Windows
editor can tell a connected phone that needs a MicDrop update from one that
has not yet sent its first snapshot. Older phones see no difference. The
exchange uses the existing mutual TLS connection, including its opaque
rendezvous tunnel.
Telemetry transport remains available when connection-file logging is disabled.
In that case the report sequence is acknowledged with `report_log: "not_recorded"`;
this confirms receipt of live status without claiming it was saved. The same
value is used if logging becomes unavailable or full. Legacy clients retain
their previous report acknowledgments.

Negotiated phone-control `/status` requests and responses have a maximum 160 KiB
transport budget on LAN and rendezvous: the existing 96 KiB ICE/report budget
plus 64 KiB for phone control. The server retains a smaller diagnostics-only
budget when no ICE exchange is negotiated. Other requests and responses retain
their existing limits.

`phone_control` is a snapshot matching `internal/phonecontrol.Snapshot`:

```json
{
  "version": 1,
  "revision": "64-lowercase-hex-SHA256-of-current-fields-and-enabled-state",
  "enabled": false,
  "fields": [
    {"key":"audio.fast_recovery","label":"Fast buffer recovery","group":"Audio","kind":"bool","value":true,"effect":"next_connection"}
  ]
}
```

Field kinds are `bool`, `int`, and `choice`. Integers include inclusive `minimum`
and `maximum`. Choices include bounded `{value, label}` strings. Field effects
are `live` or `next_connection`. Routing changes that rebuild capture and all
Advanced connection settings are saved for the next explicit connection.
`audio.keep_microphone_active` is captured at the explicit microphone or duplex
Connect; input-switch replacements and duplex focus or manual resumes reuse the
captured value, so a Windows (or any saved) edit applies at the next explicit
Connect and never changes a running session. `audio.output` is `live` in
playback sessions and in duplex with a built-in, wired or USB microphone: it
applies at once through the same verified in-session switch as the phone's own
chooser and is saved like a local choice. A refused output (a session that is
connecting or changing audio device, or a Bluetooth output without Nearby
devices permission, which is rejected rather than prompted) rejects the whole
command before any other live change. It is `next_connection` in
microphone-only sessions (saved only) and in Bluetooth headset-microphone
duplex, where the choice is held for the session and saved, then used after a
switch to a phone, wired or USB microphone. The field's value is the session's
current output. On Android, a session output missing from the device list is
labelled `<kind> (in use)` while the effect is `live` and `<kind> (after
headset mic)` for the held headset-microphone choice, while saved entries keep
`(saved)` or `(saved; unavailable)`; the iPhone's `(in use)` label is narrower
and it has no `(after headset mic)` label (see below). Because the revision
covers the effect, an input switch to or from a headset microphone marks the
Windows editor stale, and it asks for Reload before the next change.
`live.output_enabled` edits and `live.microphone_muted = false` (Unmute) edits
are session-only on both phones; local and Windows Mute
(`live.microphone_muted = true`) is saved for the next Connect. Both phones
offer `live.microphone_muted` for Unmute only after the phone itself has
enabled microphone capture in that session and while microphone permission
remains granted (on Android `RECORD_AUDIO`, plus the Bluetooth permission for
a Bluetooth input); a Mute tapped while connecting withholds Windows Unmute
until one unmute on the phone, and the condition survives input switches and
duplex resumes and is cleared by Stop and by a new explicit Connect. The live
acknowledgment reads "Live settings requested." and the saved one "Saved.
Next-connection settings apply after Stop and Connect."
Labels and choices describe ordinary app preferences, never sensitive tokens.
Unchanged descriptors refresh every five seconds instead of adding their full
size to every media heartbeat. Preference/availability changes and command
acknowledgments are sent on the next existing status poll.

Windows queues at most one update for the currently authenticated device/session.
The next status response includes `phone_control_command`:

```json
{
  "id": "32-lowercase-hex-random-id",
  "base_revision": "revision-the-editor-loaded",
  "changes": {"audio.fast_recovery": false}
}
```

Windows refuses an edit before sending it when the snapshot reports the opt-in
off ("enable ‘Allow Windows to change phone settings’ on the phone first") or
when the editor's base revision is stale. The phone then validates its local
opt-in, current revision, all keys, types, ranges,
choices and current session capabilities before applying any change. It accepts
only its locally implemented allowlist, not arbitrary preference names. Live
controls run through service setters on the Android main thread; saved values
use the existing preferences stores. Changes reflect in the phone UI.

The next snapshot includes `ack: {id, status, message}`, where status is
`applied` or `rejected`, plus the resulting current settings/revision. Repeated
delivery of an ID returns the same acknowledgment without applying again. A
concurrent phone edit rejects a stale Windows revision instead of overwriting it.
The receiver retains at most 1024 processed IDs; after that it rejects new edits
until Stop/Connect rather than evicting replay protection. An `applied` live-control
acknowledgment confirms acceptance of the requested state; asynchronous audio
transitions remain visible in the subsequent stream status.
Windows expires an unacknowledged update after 15 seconds; it never replays it
into a new session or another phone. A timeout means confirmation was not received,
so the UI reloads the phone snapshot before permitting a fresh edit.

## Availability and status display

Pausing closes the media/control session. Windows keeps a clearly identified
last-known Paused row, disables remote settings, and marks old statistics stale.
Disconnected/offline changes are not queued. The list can hold multiple paired
devices; the current host still permits only one active audio session.

Network RTT, jitter-buffer time and output queue are measured/estimated counters,
not end-to-end speaker or microphone delay. The UI names them accordingly.

## Bounds

Snapshots are at most 64 KiB, with at most 64 unique fields and 32 choices per
field. Keys are at most 64 characters, labels at most 160, and choice values at
most 256. Group names are Audio, Advanced or Live. Revisions are SHA-256 hex.
Update patches are nonempty, contain at most 64 existing field keys, and are
validated against the last advertised schema before being sent. Android performs
its own authoritative validation again. No settings snapshots are written to
connection diagnostic logs.
The complete serialized command envelope (ID, base revision and changes) must
also fit within 64 KiB, even when JSON values use escape sequences.

## iPhone

The iPhone client (PR #40) implements this version with the same negotiation,
snapshot, command validation order, acknowledgments, revision checks and bounds
(D049). Its opt-in is **Advanced → Allow Windows to change phone settings**, as
on Android, off by default. It exposes 31 of Android's 33 keys: iOS has no
public API to set the system volume, so the iPhone omits `live.volume`, and it
omits Android-only `audio.le_stereo`. Windows can unmute the iPhone microphone
only after the iPhone itself has enabled microphone capture in that session,
while microphone permission remains granted, and while MicDrop is in the
foreground or its muted background capture is already running. `audio.input`
lists current-category inputs plus the saved entry without switching category.
Wired headphones and wired headset microphones are not offered as Windows
choices because iOS provides only a port-wide identifier; an active wired or
temporary-speaker session output is shown as `(in use)` and rejected if selected.
