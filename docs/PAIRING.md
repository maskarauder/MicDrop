# Pairing and trust

New phones enroll using a private invitation and explicit Windows approval.
Saved connections authenticate the existing host/phone identities; they never
fall back to the legacy diagnostic protocol. For normal desktop setup, use
[the beta guide](BETA_TESTING.md). This guide also documents the developer console
and protocol.

## Try it

For these console commands, use the developer harness from [Development](DEVELOPMENT.md),
with its matching Android APK. The Windows desktop app provides the same
approval and removal under **Phones → Pair a phone**, **Approve** and
**Remove selected phone**; since 2026-10-27 both phones' pairing and
not-approved messages name those controls rather than console commands, while
the console host's own text is unchanged. Start the Windows host in an
interactive PowerShell window, using this PC's private IPv4 address:

```powershell
.\windows-host.exe stream --host 192.168.1.20 --paired --pair
```

1. Maximize the Windows console. On Android tap **Scan pairing QR**, allow camera
   access, and point at the entire code including its border. The scanned invitation
   fills the input; tap **Connect**. Alternatively, paste the complete
   `micdrop://pair/v1/` line and tap **Connect** without camera permission.
   Connect selects enrollment from the link type. Keep the app open while approving.
2. Compare the request ID shown on both devices. In the same Windows console,
   enter `approve <request-id>` (in the desktop app, open Phones, check the ID
   and select **Approve**). The phone name is only an unverified label.
3. Android shows **Paired Windows** after saving. If MicDrop remains open, the
   original Connect continues once with the current audio/microphone options and
   their normal permissions. If you left or rotated the app, tap **Reconnect**.
   Scanning, discovery and saved enrollment alone never start capture or playback.
4. Use the normal Pause/Play/Stop controls. Each stream still has a separate
   combined log, finalized when that stream ends. The listener stays available.
5. After restarting Windows, use `stream --host <IP> --paired` without `--pair`.
   Android's saved Reconnect continues to work. App updates preserve the pairing;
   uninstalling or clearing app data does not.

If you tried the first Android pairing build (`f0106a4`), tap **Forget saved
connection** once after updating, then enter `pair` in Windows and connect with
its new invitation. That build created a phone key without the permission needed
for TLS's prehashed signature operation, causing `TLS_IDENTITY` before Windows
could show an approval request. The corrected app detects the old immutable key
policy and reports `PAIRING_KEY_UPDATE`; it never silently replaces an identity.
The Windows host identity does not need resetting. If Windows already lists the
old phone key, it can be removed separately with `devices` and `revoke`.

`--probe`, `--device`, `--log-dir` and `--no-log` still work. Paired mode has no
invitation lifetime for already approved devices; `--invitation-ttl` is rejected
in this mode. New enrollment windows always last five minutes. This is still a
console host, not an installed Windows Service.

| Console command | Result |
| --- | --- |
| `pair` | Print a new private five-minute invitation and matching QR; invalidate any prior pending request |
| `approve <request-id>` | Durably approve the matching live request for playback |
| `reject <request-id>` | Reject it and close that enrollment window |
| `devices` | List approved phone labels and full public-key fingerprints |
| `revoke <full-phone-key>` | Remove approval, close enrollment and stop that phone's active stream |
| `revoke-all` | Remove all phone approvals, close enrollment and stop the active stream; keep listening with the same Windows identity |
| `quit` or Ctrl+C | Stop the listener; retain approved identities |

There is no network approval/revocation API. Commands belong to the running
Windows console, and the desktop app's Phones page performs the same approvals
and removals in-process. Closed/redirected standard input cannot provide local approval;
previously paired devices can still connect.

To free all 16 pairing slots without knowing the phone fingerprints, enter
`revoke-all` in the running server console, then `pair` to open a fresh approval
window. Windows prints the number of approvals removed. The active session ends
with `device_revoked` and its combined log finalizes. All previously approved
phones need a fresh invitation and explicit Windows approval.

Alternatively, add `--revoke-all --pair` to your existing
`stream --host <IP> --paired` command at startup. Keep your other options,
including `--microphone-device`, if you use microphone return or duplex. The
reset happens before connections are accepted and before `--pair` opens its new
window. Omit `--revoke-all` on subsequent starts to preserve newly approved phones.
This switch requires `--paired`; it preserves the Windows host key and removes
only phone grants and enrollment receipts. Old invitations and pending requests
cannot restore approval after the reset. Android does not need an update or a
new Windows host pin; use the fresh pairing invitation to obtain approval again.

The `devices` console command above lists phone fingerprints. The separate
`windows-host.exe devices` command lists Windows audio endpoints.

Android **Change paired Windows address** updates only the private IPv4/port.
The saved Windows key stays pinned; this does not authorize a different computer.
Android **Forget saved connection** clears its saved host, phone signing identity
and paused-resume ticket. Windows may still list the old public key; remove it
with `devices` and `revoke`. Forget cannot claim remote revocation. One saved host
is supported on Android in this increment; Windows accepts up to 16 approved
phones and one active stream at a time.

## QR setup and manual fallback

Both `--pair` and the running console's `pair` command print a compact QR made
from the **same exact invitation** as the manual link. Maximize the terminal and
keep the whole code visible without wrapping; the output states the required
column count. A standard monospace font and normal light/dark contrast work best.
Pasting remains available if the console font, zoom, color theme or camera makes
scanning difficult. No QR image file or local web server is created.

Android's bundled scanner works offline without Google Play services or a model
download. Camera permission is requested only after **Scan pairing QR**. Denying
permission, cancelling, or an unavailable camera leaves manual entry available.
Only `micdrop://pair/v1/` invitations are accepted by the scanner; it never opens
web links, imports saved pairing records or starts audio. Malformed/unrelated
codes and expired invitations show a brief notice plus inline recovery text.
Connect rechecks expiry, so a QR that expires after scanning is still rejected.

Camera preview stops when scanning ends or the scanner goes into the background.
Scanned frames are not saved. The QR and its text are private enrollment material:
do not share screenshots or console transcripts. Old codes remain in scrollback
but cannot open a new enrollment after renewal, consumption or expiry. Explicit
Windows approval and the existing TLS host-key check are still required.

See [dependency provenance](../third_party/QR.md).

## Protocol and trust

Enrollment uses TLS 1.3 mutual authentication with P-256 keys. Standard TLS
CertificateVerify proves private-key possession. Android verifies the host SPKI
pin, certificate validity/use/signature and the platform's normal hostname/IP
check. Windows checks the client certificate's key type, validity/use/signature,
then authorizes its SPKI against the current playback grant on every request.
An unknown key can reach `/pair`, but cannot create a media peer, log or offer.
TLS tickets/resumption are disabled for this increment; no early data is used.

Pins are SHA-256 of canonical X.509 SubjectPublicKeyInfo DER, encoded as 64
lowercase hexadecimal characters. The v2 leaf-certificate fingerprint is a
different trust format; there is no implicit migration between the two.

`micdrop://pair/v1/` is followed by unpadded base64url UTF-8 JSON:

| Field | Value |
| --- | --- |
| `host` | Canonical private IPv4 address |
| `port` | Integer 1–65535 |
| `host_key` | Host SPKI pin |
| `secret` | 32 random bytes, unpadded base64url, 43 characters |
| `expires_at` | Unix seconds; end of the five-minute approval window |

Over pinned mutually authenticated HTTPS, `POST /pair` sends exactly
`{"version":1,"secret":"...","label":"Pixel 8"}`. Labels are 1–64 ASCII letters,
digits, spaces or `._()-`; they cannot insert console controls. Requests are
bounded to 1 KiB and share the listener's 120 requests/minute and four-in-flight
limits. One pending key is allowed per window. A secret does not grant playback.
Windows prints a fresh 12-hex-character request ID for explicit local approval.

A successful HTTP response is
`{"version":1,"state":"pending","request_id":"<12 hex characters>"}` or
`{"version":1,"state":"approved","request_id":""}`. Wrong/expired/consumed
invitations return 410; competing keys 409; invalid shapes/versions 400;
unavailable storage 503. Android polls every three seconds, retries temporary
network errors within the window, and supports cancellation across rotation.
It never displays raw network exceptions, URLs or secrets in diagnostics.

Approval persists the client pin, label, time and SHA-256 receipt of the consumed
secret as one protected record before acknowledging success. Repeating that
secret can only acknowledge its already approved TLS-proven key, even after host
restart. Another key cannot reuse it. Revocation removes both grant and receipt.
If a response is lost, retry the same invitation while it remains valid on the
phone; after expiry open a new window. Cancelling on Android cannot undo an
approval already committed on Windows.

Android saves an encrypted local record `micdrop://paired/v1/` containing only
`host`, `port`, `host_key`, and `client_key`. It contains no enrollment secret or
stream credential and is bound to the actual Keystore key. It is not a shareable
pairing invitation. Pairing never automatically plays audio.

Paired streaming uses protocol **3**. `/offer` sends `{"version":3}` without a
bearer header and requires a current paired client identity. Its response retains
the existing SDP/diagnostic/lifecycle fields and issues a fresh random stream
credential. `/answer`, `/status` and `/stop` use that credential **and** the same
TLS client key. An approved second phone cannot take over a stream using its
credential. Existing size limits, deadlines, one-stream reservation and cleanup
rules in [PROTOCOL.md](PROTOCOL.md) remain in force. SDP/media fingerprints are
exchanged directly through this authenticated control connection; WebRTC owns
DTLS-SRTP media encryption. Microphone permission and outgoing tracks remain off.

## Protected state and failure behavior

Windows uses the identity introduced in the previous increment:

```powershell
.\windows-host.exe identity init
.\windows-host.exe identity status
```

Default files are under `%LOCALAPPDATA%\MicDrop\identity`:
`host-identity-v1.dpapi` and `paired-devices-v1.dpapi`. Identity output now reports
`pairing_available:true`, a build capability, without claiming a listener is
running. `--state-dir <absolute directory>` is supported for isolated tests.
Use a local NTFS volume. Identity creation uses a flushed, atomic no-replace hard
link. Grant updates use flushed same-directory files and Windows replacement with
write-through. An exclusive OS file handle allows one paired listener per state
directory, even on different ports; a process crash releases it.

Both records use current-user DPAPI with distinct application/version bindings.
The host key is decrypted in the process when needed; it is not a hardware-backed
non-exportable key. Same-user malicious code, administrators and compromised OSes
are outside the boundary. Writes are not a backup or an absolute power-loss
guarantee. Invalid/foreign/corrupt state fails closed. An existing grant database
prevents silently recreating a missing host identity. Approval/revocation write
failure disables live authorization and reports failure, rather than claiming a
durable change. Preserve state and investigate; no automatic reset/export exists.

The host renews its 24-hour IP certificate from the same key while running.
Android generates a P-256 signing key in AndroidKeyStore permitting SHA-256 and
`DIGEST_NONE`, with no biometric prompt requirement and a ten-year self-signed
certificate. Conscrypt hashes TLS CertificateVerify internally and uses
`NONEwithECDSA` to sign that digest through Keystore; allowing `DIGEST_NONE` does
not remove TLS's hashing or certificate checks. The private key is
non-exportable through the app; hardware backing depends on the device. Keystore
and disk/network operations stay off the main thread. The saved host record uses
the existing AES-256-GCM envelope and AtomicFile in no-backup storage. Missing or
mismatched paired keys require explicit Forget/re-pair, never silent replacement.
Android's same paused media card and resume ticket bind to the full saved record.
Changing/forgetting it invalidates the old resume action.

Revocation rejects subsequent requests, interrupts an active stream, and is also
checked every two seconds by the watchdog. An in-progress peer factory rechecks
its grant before returning an offer. Host restarts retain grants, never active
stream tokens. These grants authorize playback only, not future microphone return.
Key rotation and backup/recovery UI are later work. Discovery is specified in
[LAN_DISCOVERY.md](LAN_DISCOVERY.md). The iPhone client implements this same
TLS 1.3 / SPKI wire contract with a device-only Secure Enclave P-256 signing key
(software Keychain fallback in the simulator) and non-synchronizable Keychain
storage (`AfterFirstUnlockThisDeviceOnly`).

## Validation

Automated tests cover
real TLS 1.3 client authentication, pre-approval refusal, competing keys, approval
expiry/rejection, same-key lost-response recovery, consumed-secret replay,
cross-client stream tokens, live revocation, restart grants, failed persistence,
bulk removal at capacity, invalidated receipts/pending approval, log finalization
and revocation during session initialization, corrupt state and identity
replacement guards. Windows CI additionally exercises
actual DPAPI grant replacement/purpose separation and the exclusive listener lock.
Bulk removal is checked against real protected storage while the host identity
file remains unchanged.
Android JVM tests check P-256 encoding against the shared public fixture and
certificate renewal, wrong pins and expiry against independently generated public
certificates. A separate test-only `pairing-check` APK compiles the production
identity/link code and runs on an API 35 x86_64 emulator without the arm64 WebRTC
engine. It checks rejection and explicit replacement of the old key policy,
non-exportable prehashed signing, a real Conscrypt mutual-TLS 1.3 handshake with
the protected key, and case-preserving pairing-link routing. Existing
media/lifecycle tests remain required.

The emulator contract does not establish phone-to-Windows acceptance on every
Android provider, OEM lifecycle behavior or physical audio latency. Test the
actual phone/Windows builds before considering this increment accepted. The public fixtures in
`internal/identity/testdata` contain no live identities or private keys.

Primary references: [TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446.html),
[Go TLS](https://pkg.go.dev/crypto/tls),
[Android Keystore](https://developer.android.com/privacy-and-security/keystore),
[KeyGenParameterSpec](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec.Builder),
[DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata),
[Windows replacement](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).
