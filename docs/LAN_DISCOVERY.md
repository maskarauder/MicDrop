# LAN discovery

Discovery locates a host endpoint; [pairing](PAIRING.md) establishes trust and
authorizes sessions. It does not automatically enroll a phone or start audio.

## Use

In the desktop app, select the home-network adapter/address and Start host.
For developer console testing, use the [harness](DEVELOPMENT.md) with its current
private IPv4:

```powershell
.\windows-host.exe stream --host 192.168.1.20 --paired
```

Windows prints `LAN discovery: MicDrop-…`. On the same LAN, tap **Find Windows on
LAN** in Android. Select the saved Windows candidate and confirm **Connect**.
Android checks the saved host identity through the existing TLS connection. A
new address is remembered only after playback connects successfully. Ordinary
Reconnect and notification Play then use that address. Neither restarting nor
discovery requires Forget or another approval for an existing valid pairing.

An unfamiliar host opens pairing instructions. Enter `pair` in that Windows
console, scan its QR or paste the private invitation, tap Connect, then approve
the matching request. A discovered host cannot pair itself or start audio.

The CLI requires `--host`. Neither host mode follows an address change while
the listener is running. After the PC's address changes, restart
with the new address and the same protected identity/state directory. On Android,
Find can locate it without manually editing the saved address. The existing
manual **Change Windows address** action and QR/paste flow remain available.

## Scope and network requirements

- Only the opt-in `--paired` listener advertises, by default. Add `--no-discovery`
  to disable advertisements. Legacy v2 links remain manual.
- The responder joins mDNS on the active multicast-capable adapter that owns the
  exact `--host` address. It advertises only that private IPv4 and the listening
  HTTPS port. It does not fall back to broadcasting on every adapter.
- The HTTPS listener and WebRTC media still need their existing firewall access.
  mDNS additionally uses UDP 5353 multicast. Allow the executable on the Windows
  **Private** network profile for a trusted LAN. No automatic firewall rules,
  router forwarding, public-network allowance or firewall disabling are added.
- Guest Wi-Fi, client isolation, VPNs and multicast filtering can hide hosts.
  A zero-result search cannot distinguish those conditions from no host running.
  The timeout message gives LAN/firewall and QR/paste recovery steps. If Windows
  cannot start its responder, it prints a warning and keeps the listener usable.
- Discovery needs no internet, DNS server, STUN, cloud account or external scanner.
  Complete offline LAN operation still needs the device check in the matrix.

## Discovery version 1

| Record | Value |
| --- | --- |
| DNS-SD service | `_micdrop._tcp.local.` |
| Instance | `MicDrop-` plus the first 12 lowercase hex characters of the public host key hash |
| SRV target | `micdrop-<same 12 characters>.local.` |
| SRV port | Current HTTPS port, 1–65535 |
| Address | Selected canonical RFC1918 IPv4 A record; no advertised IPv6 endpoint |
| TXT `v` | `1`, discovery schema version |
| TXT `p` | `3`, paired signaling protocol |
| TXT `id` | 64 lowercase hex characters: SHA-256 of the host's P-256 SPKI DER |
| Lifetime | 120-second TTL; graceful shutdown sends goodbye records |

No enrollment secret, invitation, phone identity, OS hostname/username, media or
session credential is advertised. The public key hint is stable and lets LAN
observers recognize this host over time. `--no-discovery` opts out. An abrupt
kill can leave a cached result until its TTL expires; a stale result never makes
TLS or authorization optional.

Android accepts exactly these TXT fields and supported versions. It rejects null
or oversized values, malformed keys, noncanonical/private IPv4 violations and
invalid ports. Names are not trusted labels. Results show a public key prefix
and address; a saved-key match is explicitly called a **candidate** until TLS
succeeds. Duplicate endpoints are collapsed. The saved host key and client key
are reused unchanged; an advertised key is never installed as trust. A forged
matching hint can cause a failed connection attempt, but cannot authorize a
different host or overwrite the saved endpoint on failure. There is no automatic
fallback to a weaker protocol, new grant, or replacement identity.

## Android lifecycle

Find explicitly starts a 30-second search while the activity is visible. Stop
searching releases it early. Starting a connection, opening the scanner, leaving
the activity or locking the screen stops discovery. Playback itself remains in
the existing media service; discovery adds no background service or wake lock.

API 34+ uses `NsdManager.registerServiceInfoCallback` for address updates and
withdrawals. API 31–33 uses serialized legacy resolution. One process-wide owner
prevents rotations from starting overlapping legacy resolves. Generation and
service tokens discard late callbacks after cancellation or loss/reappearance.
At most 8 services are tracked/resolved, 4 addresses per service are retained,
and 16 distinct endpoints are displayed. A platform stop failure reserves the
old browser instead of accumulating searches; another Find or activity stop
retries cleanup. QR/manual connection stays available.

Results remain selectable after a timeout or explicit Stop; Find refreshes them.
Leaving the activity clears them. Only the current scan updates the UI. The app
uses Android's NSD service, with no added library or raw multicast socket. Current
min/target SDKs remain 31/36. Target 37's local-network permission migration and
system picker are future work, not a new permission prompt in this build.

The iPhone client reuses this `_micdrop._tcp` DNS-SD schema and untrusted-hint rule through `NWBrowser` (`NSBonjourServices` and `NSLocalNetworkUsageDescription`, requiring no multicast entitlement under free provisioning) and bounded IPv4 service resolution, verifying the saved host identity over TLS before updating any address; physical Local Network permission and multi-subnet behavior still require device verification.

## Validation and references

Go tests check the public-only wire record, endpoint/key rejection and exact
interface selection. Android JVM tests check type/TXT/address filtering, bounds,
deduplication, stale callbacks and preservation of saved keys. Existing real
TLS/wrong-key, approval, revocation and Android Keystore tests remain required.
CI builds/lints the app and packages the responder on Windows. These checks do
not establish multicast visibility, firewall behavior or OEM NSD cleanup on the
actual LAN. Record those separately in the acceptance matrix.

Sources: [Android NSD](https://developer.android.com/develop/connectivity/wifi/use-nsd),
[NsdManager](https://developer.android.com/reference/android/net/nsd/NsdManager),
[ServiceInfoCallback](https://developer.android.com/reference/android/net/nsd/NsdManager.ServiceInfoCallback),
[local-network permissions](https://developer.android.com/privacy-and-security/local-network-permission),
[DNS-SD RFC 6763](https://www.rfc-editor.org/rfc/rfc6763.html),
[mDNS RFC 6762](https://www.rfc-editor.org/rfc/rfc6762.html),
and [dependency provenance](../third_party/DISCOVERY.md).
