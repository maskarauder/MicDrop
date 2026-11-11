# Android Advanced settings

**Advanced** contains connection, recovery and Windows host controls. Reports,
the local-output check, version details and notices are in **Diagnostics**.
Each connection-settings dialog has
**Save**, **Cancel** and **Defaults**. Defaults fills that dialog; Save commits it.
Values persist across app restarts and in-place APK updates. Each new session
captures its settings once. Stop and Connect to apply changes to an active session.

## Connection and recovery

Initial Connect (including the manual Reconnect button) and automatic recovery
have separate ordered choices: **LAN → rendezvous** or **Rendezvous → LAN**.
Defaults remain LAN first for Connect and rendezvous first for recovery.
LAN-only links always use LAN. Both choices retain authenticated LAN verification,
TLS checks, authorization and acknowledged cancellation before retrying an
ambiguous offer. Ordering affects signaling; it does not force Android's media
network, cellular handoff or TURN relay policy.

After healthy media is established, one LAN upgrade probe remains enabled when
the initial preference is LAN first. Choosing rendezvous first for initial
connections keeps that preference after recovery, without the healthy LAN probe.
Every recovery retry restores the configured recovery priority, including a
retry of an already prepared answer after its fallback transport failed.

| Setting | Default | Allowed seconds |
| --- | ---: | ---: |
| Media connection / recovery window | 30 s | 5–300 |
| Windows offer-to-answer window | 45 s | 10–120 |
| Wait for Windows to finish the previous session | 5 s | 0–30 |
| Delay before first ICE restart | 1 s | 0–10 |
| Interval between ICE restarts | 8 s | 5–60 |

**Maximum ICE restarts per interruption** defaults to **2**, with a range of
**1–10**. Retries of the same generation and answer do not consume another restart.
An observed network handoff can trigger the first restart immediately; the
interval and Windows' five-second offer guard still apply to subsequent restarts.
Waiting for a busy host applies only to an explicit reconnect/acknowledged Stop or
offer cancellation. A new unacknowledged offer is never replayed on a timer.

To investigate Wi-Fi fading before Android switches to cellular, try a **90 s**
recovery window and **6** maximum restarts, leaving the other defaults unchanged.
This is a test configuration, not evidence that the handoff issue is fixed.
A longer window keeps the existing session available longer; audio can remain
interrupted while neither route works. Retries, repeated failures and late network
callbacks cannot reset the interruption's original deadline.

## Windows coordination

Update **both Android and Windows** for extended session deadlines. Android sends
bounded timeout headers with the authenticated initial offer. Windows validates
them before allocating audio resources and acknowledges the effective values.
Its watchdog, incoming status requests, recovery offer/answer requests and initial
answer all enforce those values. Later requests cannot change or renew them.
Windows' missing-heartbeat limit follows the recovery window **plus 5 seconds**:
30/35 s by default, 90/95 s for the example above. Stop remains immediate locally;
the network acknowledgement uses its own short budget.

Older Windows hosts keep their existing limits: 30 s recovery for restart-capable
hosts, 10 s otherwise, and 45 s for setup. Android caps its effective settings to
those limits and labels them as legacy in the copied report. Shorter requested
values still apply. Settings cannot silently promise an extended window on an old
host. The VPS, pairing and native ABI do not change. Until Windows returns a
200 `/offer` body, the copied and terminal reports say instead that the
deadlines, terminal diagnostics and media recovery were not negotiated
(`not negotiated (no Windows offer reply)` and `not sent; no Windows offer
reply`); a reply that failed validation reads `Windows offer reply rejected`.
Neither is evidence of a Windows build mismatch, and the pre-offer numeric
budgets are unchanged. After an accepted reply from a Windows build that asked
for no terminal report, the report says `Windows terminal diagnostics: not
requested by Windows (older Windows or logging off)`; current Windows builds
ask whenever combined logging is on or phone settings exchange was negotiated.

## Request timeouts

| Setting | Default | Allowed seconds |
| --- | ---: | ---: |
| LAN verification | 1.5 s | 0.25–5 |
| LAN status request | 2 s | 0.25–15 |
| Other LAN control requests / connection establishment | 8 s | 1–30 |
| Rendezvous control request / connection establishment | 8 s | 1–30 |
| STUN / TURN configuration request | 8 s | 1–30 |
| LAN Stop / cancellation budget | 2 s | 0.5–10 |
| Remote Stop / cancellation budget | 5 s | 0.5–15 |
| Offer cancellation | 5 s | 0.5–15 |

Status has independent LAN and rendezvous limits. Initial and recovery offers
use their longer operation budgets below; transport connection establishment is
still capped by the corresponding control-request setting. Stop splits its total
budget between routes and verification, preserving bounded cleanup. Individual
operations are capped by the remaining setup/recovery window. Making every
request longer can leave less time to try the other route.

## WebRTC timeouts

| Setting | Default | Allowed seconds |
| --- | ---: | ---: |
| Initial offer request | 40 s | 1–60 |
| Initial ICE gathering | 15 s | 1–30 |
| Initial SDP operation | 15 s | 1–30 |
| Recovery ICE gathering | 8 s | 1–30 |
| Recovery offer request | 18 s | 1–30 |
| Recovery SDP / answer operation | 5 s | 1–30 |

Trickle ICE still submits a usable description early; these are maximum waits.
Heartbeat/report cadence, network callback debounce, certificate and invitation
expiry, pairing approval, SDK-internal timers, initial audio verification and
input-switch teardown remain implementation/protocol limits. They are not
extended by these settings.

The copied stream report includes both connection orders, every selected timeout,
the restart limit and the requested/effective Windows deadlines. Use the existing
[ADB commands](ANDROID_ADB_TESTING.md) to install, launch, connect and retrieve that
report; automated connections use the same saved Advanced settings.

## Bluetooth recovery and remembered devices

**Bluetooth recovery** has one saved input/output recovery window: **20 seconds**
by default, **5–120 seconds** allowed, including decimal seconds. It applies on
the next connection. It covers an already selected Bluetooth microphone/headset
and an explicitly selected Bluetooth media output; it does not govern default
Android output policy. Repeated callbacks, port rebinding and playout recreation
cannot renew an episode's deadline. Initial route verification and the separate
20-second input-switch teardown budget are unchanged. Reports include the
effective Bluetooth window; timeout messages use that value.

Explicit Bluetooth choices with a usable stable address are remembered across
process restarts. The app stores only identity/profile and kind in private,
backup-excluded app preferences, never a transient Android port ID or display
name. Private identities are excluded from exported options and reports. Current
ports must match the same identity and profile; missing, ambiguous or redacted
identity, a changed profile, or missing Nearby devices permission leaves the
choice unavailable. The selection survives recovery expiry for a later explicit
Connect/Resume. Restoring it does not grant microphone consent or start audio.

Phone/default choices also restore. Wired/USB ports without a verified persistent
physical identity still require reselection after process death. This
does not enumerate inactive Bluetooth devices that Android omits from its audio
device lists; when an inactive headset is omitted, use the foreground system
output picker or Bluetooth settings fallback.

## Keep microphone capture active while muted

This checkbox is **off by default**, preserving Android's existing stop-capture
behavior. Enable it before the next microphone-only or duplex connection to keep
an already verified capture running when muted. The value is captured at that
explicit Connect: an input-switch replacement and a duplex focus or manual
resume reuse the captured value, so a change made here, or by Windows through
**Device settings**, applies at the next explicit Connect and never to the
running session. The copied report's **Muted capture option** shows the
session's captured value. It can reduce unmute startup
delay and communication-route churn. The ADM supplies silence, the outgoing audio
track is disabled, and the authenticated Windows microphone gate is closed.
Unmute reuses capture only after the selected route remains verified and the
host gate acknowledges the change. No application PCM queue is introduced.

The Android microphone indicator stays on and battery use may increase. Stop,
pause/interruption, route loss and network recovery still stop capture. A session
that starts muted does not start capture because of this option; after recovery
while muted it stays stopped until Unmute. Route monitoring remains active for
retained capture. This is an Android unmute/route experiment, not a promise of
iOS-style background survival. Reports distinguish the saved option from actual
retained capture. It does not enable the microphone for a playback-only session.

iPhone: this section describes Android only, and "iOS-style background survival"
above is no statement about the iPhone app. The iPhone's corresponding setting is
**Keep microphone active while muted in background**. It is on by default
and applies only to microphone-only sessions in the
background, where gated capture keeps iOS from suspending the session; duplex
never keeps a muted capture. iPhone **Bluetooth route recovery** has the same 20 s
default and 5–120 s bounds under **Advanced audio** in the sheet opened by
**Advanced > Connection settings**, but its copy report prints it on its own line
rather than in `Connection timing (ms)`. iPhone remembered devices
use the route's `AVAudioSessionPortDescription.uid`, and wired ports are not
remembered. See the [iPhone app guide](DEVELOPMENT.md#iphone-app).

## Allow Windows to change phone settings

This **Advanced** checkbox is **off by default** and stays a phone-local choice.
While it is off, Windows still sees the phone's current settings and live
statistics, but its editor is read-only and tells the user to enable the option
on the phone. While it is on, Windows may change the settings the app
advertises; the phone validates the opt-in, revision, keys, ranges and current
session capabilities before applying anything, and Windows cannot grant
permissions, change pairing or start microphone capture. Windows Unmute,
**Play desktop audio** and media-output edits follow the rules in the
[Android guide](ANDROID.md#settings-and-diagnostics); the protocol is in the
[phone settings exchange](PHONE_CONTROL_V1.md).

## Validation

Unit coverage checks defaults, saved-value validation, decimal/range validation,
all four priority combinations, legacy host caps, deadline acknowledgement,
90-second no-callback recovery, retained answers and original-deadline expiry.
Windows tests cover validation before resource allocation, custom media/setup/
heartbeat deadlines, late requests, immediate Stop and unchanged legacy defaults.
The Android platform TLS test checks timeout headers on offers only through the
real WSS/inner-TLS transport. Bluetooth regressions cover custom fixed deadlines,
invalid saved values, stale callbacks, identity/profile restoration on recreated
ports, and unavailable/ambiguous identity. Preference tests cover the opt-in
capture default without enabling microphone transmission or granting consent.
Actual capture lifetime, mute privacy, route selection and handoff behavior still
require focused physical-device checks across target routes and networks.
