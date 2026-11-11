# Product requirements

> Design requirements and future scope, not a list of shipped features. See the
> [project overview](../../README.md), [current roadmap](../ROADMAP.md), and
> [beta guide](../BETA_TESTING.md) for the supported release.

Status: Windows and Android LAN and remote streaming have passed functional checks on tested hardware, and the beta iPhone client is implemented; see the [current roadmap](../ROADMAP.md). Requirement IDs below remain stable; physical latency, unavailable hardware and other deferred checks retain their documented limits.

## Purpose and audience

Turn a phone into a network audio endpoint for a computer: an output device for listening and, when enabled, an input source for speaking. The initial audience is a person using their own computer and phone, on home Wi-Fi or remotely, with speakers, wired audio, or a Bluetooth headset.

The differentiator is a measurable reduction in avoidable streaming delay, combined with usable microphone return. Success requires reliable routing and compatibility, not just fast packet delivery.

## User modes

| Mode | Computer to phone | Phone to computer | Intended behavior |
| --- | --- | --- | --- |
| Listen | Enabled | Off | Media playback using the phone's normal media route and volume |
| Microphone | Off | Enabled | Selected phone input appears through a computer recording endpoint |
| Talk and listen | Enabled | Enabled | Simultaneous playback and microphone return; route limitations shown before switching |

Listen is the default. Microphone activation is an explicit phone action. Push-to-talk is a later option; a clear mute control is required from the first microphone milestone.

## Functional requirements

| ID | Requirement | Acceptance evidence |
| --- | --- | --- |
| F01 | Capture the selected computer output mix. | Two ordinary applications are audible at the phone; endpoint changes have defined behavior. |
| F02 | Play received audio through a native phone audio output. | Phone volume and route controls work; speaker, wired/USB, and Bluetooth playback are exercised. |
| F03 | Capture the built-in phone microphone. | A computer recording application receives intelligible audio from the selected source. |
| F04 | Capture a connected headset microphone where the OS exposes a supported route. | Actual input is verified physically; unsupported combinations produce a useful explanation. |
| F05 | Deliver microphone audio through a selectable computer input. | A voice/chat application and a separate recording application can select and use it. |
| F06 | Operate both directions concurrently. | A duplex session continues without unbounded delay or accidental digital feedback. |
| F07 | Connect on a LAN without external services. | Pair and reconnect while internet access is disconnected; manual addressing works when discovery is unavailable. |
| F08 | Connect across different networks. | Direct internet and forced-relay tests pass; no consumer-router port forwarding is required in the supported flow. |
| F09 | Continue an explicitly started session with the phone screen off. | Screen-off and foreground/background tests pass under applicable OS lifecycle rules. |
| F10 | Recover from endpoint and network changes. | No stale audio is replayed after a reconnect; status explains any required user action. |
| F11 | Independently stop playback, mute microphone transmission, and disconnect. | Local controls work even if the remote peer or signaling service is unavailable. |
| F12 | Show actual route and connection quality. | Direct/relay status, negotiated format, loss, buffering, and route changes are observable. |
| F13 | Remember devices and non-sensitive preferences. | Restart preserves pairing and chosen settings; new sessions start with microphone off. |
| F14 | Revoke paired access. | A revoked peer cannot initiate a new session; active access can be stopped immediately. |

For F10, do not silently replace a disconnected headset microphone with the phone microphone. Stop the reverse path and request a new source choice. Pause output on private-output loss by default so headphone audio does not unexpectedly move to the loudspeaker.

## Quality requirements

| ID | Requirement | Acceptance evidence |
| --- | --- | --- |
| Q01 | Keep avoidable latency low. | Reports use the boundaries and provisional targets in [LATENCY.md](../LATENCY.md). |
| Q02 | Bound buffering under stress. | Overload and clock-drift tests show recovery toward live audio instead of growing delay. |
| Q03 | Preserve music and desktop audio in Listen mode. | Stereo survives the full path; voice noise suppression and automatic gain do not alter desktop audio. |
| Q04 | Encrypt audio and authenticate paired peers. | Pairing, revocation, expired-session, and modified-signaling tests pass. |
| Q05 | Expose microphone use clearly. | Phone and computer display current capture/transmission state; mute prevents new source audio leaving the phone. |
| Q06 | Keep streaming work independent of the UI. | Opening screens and diagnostics does not block audio callbacks. |
| Q07 | Measure resource consumption. | CPU, memory, bandwidth, battery, and thermal conditions accompany latency reports. |

## First usable release scope

The first usable release includes all three modes on Windows/Android, one computer and one phone per active session, LAN and remote paths, a documented computer-input installation path, and background operation. A LAN playback prototype alone is an intermediate milestone.

A separately installed, appropriately licensed virtual cable is the accepted
computer-input prerequisite for the first release ([D043](DECISIONS.md#d043--windows-desktop-delivery-and-first-release-scope-2026-10-25)).
MicDrop's installer packages the application, not a virtual audio driver. A
licensed bundled endpoint or a maintained product driver can be evaluated later;
neither is required for this release scope.

Not scheduled for the initial release: multiple simultaneous phones per host,
synchronized multi-phone playback, phone-hosted or phone-to-phone sessions,
chained audio tunnels, surround sound, remote desktop video, application remote
control, call recording, phone-system-audio capture, a cloud recording service,
audio before computer sign-in, or professional zero-latency monitoring. These are
scope boundaries, not permanent exclusions.

## Post-release direction

The requested long-term goal is separate client and server apps that can run
simultaneously on a supported device. Begin by evaluating multiple phones
connected to one host, then an Android server app and phone-to-phone sessions.
An intermediate device could explicitly bridge its client and server apps to
form a chain of audio tunnels. Each app session connects and authenticates only
with its immediate peer; playback and microphone return use the same duplex
client/server connection at each hop.

For example, phone 1's client connects to phone 2's server while phone 2's client
connects to the Windows server. Phone 2 bridges playback toward phone 1 and
microphone return toward Windows. Phone 1 needs to know only phone 2; it does not
need a direct connection, pairing or knowledge of the Windows endpoint.

These are goals to investigate after the first release, not promised platform
capabilities or additional MVP acceptance requirements. Running both apps at once,
local bridging, source capture, background hosting and exposing received microphone
audio to other mobile apps each need platform feasibility work. See the
[current roadmap](../ROADMAP.md).

## Core user journeys

**Local listening:** start the desktop host; choose an output source; pair the phone using a QR code or authenticated manual flow; tap Listen; select the desired route through supported phone controls. Internet connectivity is unnecessary.

**Microphone return:** select an available phone input; enable microphone transmission; select the project's or configured virtual recording endpoint in the computer application. Muting on the phone immediately stops sending new microphone content.

**Remote use:** explicitly enable remote access on the host, pair while local or using an out-of-band invitation, then connect from another network. Show whether media is direct or relayed. The computer must remain reachable, awake, and signed in for the initial implementation.

**Bluetooth duplex:** explain the expected route change before enabling the headset microphone, wait for OS confirmation, then show the actual input/output and format. If unsupported, offer a supported mode or let the user choose the phone microphone; never claim the headset mic is active without confirmation.

## Product questions to settle during development

- Which Windows and Android devices form the initial supported hardware matrix?
- Is installing a third-party endpoint acceptable beyond the developer preview?
- Should remote hosting be self-hosted, managed, or both, and who pays relay bandwidth?
- Which iPhone routes and devices should be supported after the Windows/Android MVP? iPhone is deferred from the initial release.
- What measurable improvement over a tuned SoundWire setup justifies a public latency comparison?

These questions do not prevent the initial feasibility work. Record decisions in [DECISIONS.md](DECISIONS.md).
