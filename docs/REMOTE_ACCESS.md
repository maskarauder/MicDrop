# Remote access and rendezvous

Remote mode is opt-in and uses the existing paired identity. Ordinary LAN mode
makes no rendezvous or public STUN requests. The host accepts one active phone
media session. Configure infrastructure only when remote access is needed.

Functional Windows/Android coverage includes direct and forced-relay media,
TURN TCP/TLS fallback, handoffs, credential renewal and relay outage recovery on
tested hardware; the iPhone client implements the same rendezvous and TURN
contracts, with broader physical cellular/handoff device checks still open.
Those results are not universal Bluetooth or physical-latency acceptance.

## Trust and connection layers

Both endpoints make outbound WSS connections to the public rendezvous service.
The outer certificate uses ordinary HTTPS trust. A distinct random bearer token
selects each route and role: `host_token` or `client_token`. These tokens admit
bounded relay/ICE resource use; they do not approve a phone for playback or capture.

After matching a host and client socket on the same configured route, the service
forwards opaque binary bytes. The endpoints establish the existing TLS 1.3 paired
connection inside that byte stream. The phone still pins the Windows host key;
Windows still requires phone key proof and checks the current pairing grant on
each request. The service holds neither endpoint's identity private key and cannot
substitute SDP/media fingerprints inside a successfully authenticated inner TLS
connection. Outer TLS alone is not peer authentication.

`internal/rendezvous.Dial` supplies a Go `net.Conn`; the caller must wrap it in
the paired TLS client/server configuration. It rejects plaintext endpoints,
URL credentials/query strings, redirects, unsupported subprotocols and unexpected
ready frames. The caller's context bounds the stream; read/write deadline failure
closes it. The Windows remote listener feeds these streams to the same paired
TLS/HTTP server used on LAN. Android uses platform `SSLEngine` with its Keystore
client key, and iPhone uses `NIOSSL` with its Secure Enclave/Keychain client key;
both enforce pinned Windows SPKI, TLS 1.3 and explicit certificate IP SAN validation.
Each phone request uses a fresh tunnel and bounded HTTP/1.0 response; a failed
session-creating offer is never transparently retried.

WebRTC media remains DTLS-SRTP, direct when ICE succeeds and through TURN when
needed. No audio is decoded, mixed or deliberately carried over the signaling
WebSocket. The opaque relay cannot inspect/enforce the inner protocol; endpoint
code must only place the paired signaling connection on it. The rendezvous service
never dials an arbitrary client-supplied destination or opens the Windows LAN port
to the internet.

## Service wire contract: version 1

All requests require TLS 1.3 and exactly one `Authorization: Bearer <token>` header.
Tokens are canonical, unpadded base64url encodings of 32 random bytes. Browser
Origin headers, request bodies, query parameters and unknown paths are rejected.
Responses use `Cache-Control: no-store`; tokens must never appear in URLs or logs.

| Request | Behavior |
| --- | --- |
| `GET /v1/tunnel`, WebSocket subprotocol `micdrop-tls-v1` | Match opposite roles on the token's route; same-role sockets and different routes cannot match |
| First server frame after matching | Text frame exactly `micdrop-tls-v1 ready` to each endpoint, before any forwarded bytes |
| Subsequent frames | Nonempty binary messages carrying the inner TLS byte stream; frame boundaries have no inner protocol meaning |
| `GET /v1/ice` | JSON `version: 1`, Unix-second `expires_at`, and `ice_servers` containing configured STUN/TURN URLs and temporary TURN username/credential |

Disconnect, timeout, shutdown or a protocol/limit violation closes both matched
sockets. There is no retained queue for reconnecting clients. The host adapter
uses bounded reconnect/backoff for idle registration and at most four accepted
or pending tunnels. Stop closes local audio immediately and uses a separate,
bounded authenticated request to Windows.

## Fixed resource limits

| Resource | Limit |
| --- | --- |
| Configuration | 64 KiB; 1–16 routes; all host/client tokens distinct |
| Accepted TCP connections | 160, including TLS handshakes and ordinary requests |
| HTTP headers | 4 KiB configured maximum; five-second header deadline |
| Requests | Global 60/second with burst 120; per token 5/second with burst 10 |
| WebSockets per route | Four host and four client sockets, including waiters |
| Waiting for opposite role | 25 seconds |
| Active socket | 30 seconds without application data; five-second write deadline; one-hour absolute lifetime |
| Frame and queue | 64 KiB per binary message; one queued message per direction, with bounded in-flight reads/writes |
| Traffic per direction | 64 KiB/second with 256 KiB burst; 64 MiB total per socket |
| Frame rate per direction | 64/second with burst 128 |
| ICE credential requests | Two/minute per token, burst two |
| STUN/TURN URLs | At most four of each; explicit hostname/IP, port and supported transport |
| TURN credential lifetime | Ten minutes |

These are control-plane limits, not an audio bitrate budget. An expired signaling
socket is not a new microphone authorization. App adapters reconnect
within the existing 30-second recovery policy and preserve immediate local mute/Stop. Service
shutdown explicitly drains hijacked WebSockets, which HTTP shutdown alone does
not close. Internet ingress still needs operator-level connection/traffic limits;
the application does not claim to withstand a distributed denial of service.

## Self-hosted service setup

Use a server with a public hostname, a valid TLS certificate and known egress
pricing. Nothing in the application provisions infrastructure, opens router ports
or deploys a public service automatically. Use matching Windows and phone packages.
Use the current rendezvous binary for private configuration export and certificate reload.

Build with the repository's pinned Go version (no native audio dependency):

```sh
CGO_ENABLED=0 go build -trimpath -o build/micdrop-rendezvous ./services/signaling
./build/micdrop-rendezvous init --config rendezvous-private/config.json
./build/micdrop-rendezvous check --config rendezvous-private/config.json
```

CI also publishes `rendezvous-linux-x64` with the binary, this guide and dependency
notices. `init` creates a private configuration with one route and independent
random role tokens. It never overwrites an existing file or prints those tokens.
On POSIX, new directories use mode 0700 and the file 0600. Protect existing parent
directories and use appropriate ACLs on Windows. `rendezvous-private/` is ignored
by Git. Do not commit or upload your generated configuration.

The initial configuration has no public STUN/TURN defaults. Add `stun_urls` and an
optional `turn` object to the private JSON file for infrastructure you operate:

```json
{
  "stun_urls": ["stun:relay.example.com:3478"],
  "turn": {
    "urls": [
      "turn:relay.example.com:3478?transport=udp",
      "turn:relay.example.com:3478?transport=tcp",
      "turns:relay.example.com:5349?transport=tcp"
    ],
    "shared_secret": "REPLACE_WITH_A_SEPARATE_RANDOM_32_BYTE_BASE64URL_SECRET"
  }
}
```

This fragment is merged into the generated file; retain `version` and `routes`.
The placeholder intentionally fails validation. Generate the shared secret
separately from either role token; for example, Python's `secrets.token_urlsafe(32)`
produces the required format. Transfer it privately to coturn. Clients receive
temporary credentials only, never this master secret.

Run the service using your certificate/key paths:

```sh
./build/micdrop-rendezvous serve \
  --config rendezvous-private/config.json \
  --listen 0.0.0.0:8443 \
  --tls-cert /protected/fullchain.pem \
  --tls-key /protected/privkey.pem
```

Without `--listen`, it binds loopback only. Plain HTTP/TLS-terminating reverse-proxy
deployment is not supported; the application verifies the
actual TLS connection, never a forwarded header. Use TLS passthrough if an ingress
is required. Certificate files are rechecked once a minute; a valid replacement
is used for new TLS handshakes without closing existing tunnels. Use `--tls-name`
to require the public hostname. Invalid replacements retain the last valid pair
until expiry and are retried. Restart for configuration changes or
rotation of a compromised resource token; active tunnels close. Windows device
revocation remains a separate, immediate inner-protocol operation.

For boot startup, an unprivileged service account and automatic read access to
renewed Caddy certificates, follow [the systemd installation guide](SERVICE_DEPLOYMENT.md)
(included as `SERVICE_DEPLOYMENT.md` in the rendezvous artifact).

## Connect the apps

1. Confirm that an unauthenticated request from Windows reaches the service:
   `curl.exe --http1.1 -i --max-time 10 https://signal.example.com:8443/v1/ice`.
   **401 Unauthorized is the expected pass** for DNS, TCP, outer TLS and admission.
   It does not prove TURN or audio delivery. If TCP times out, allow the chosen
   TCP port in UFW and any provider firewall. If the service cannot read Caddy's
   certificate directory, use the narrowly scoped, renewal-aware read ACL setup
   in [service deployment](SERVICE_DEPLOYMENT.md). Protected copies also work (0700 directory,
   0600 files) but need their own automated refresh after renewal; a stale copy
   cannot be fixed by the binary's automatic reload.
2. Export one route from the existing VPS config; do not run `init` again:

   ```sh
   ./micdrop-rendezvous export --config rendezvous-private/config.json \
     --route host-1 --url https://signal.example.com:8443 \
     --output rendezvous-private/windows-remote.json
   ```

   The export contains that route's host/client tokens, never the TURN master
   secret or other routes. An existing output file is not overwritten. Transfer
   this file privately to Windows, then import it while the Windows host is stopped:

   In the desktop app, use **Connection** to import the private file while the
   host is stopped. The developer console equivalent is:

   ```powershell
   .\windows-host.exe remote import --config .\windows-remote.json
   .\windows-host.exe remote status
   ```

   Import stores the settings under the current Windows user's DPAPI protection.
   Remove the plaintext transfer copy after import. `remote forget` removes these
   settings without removing paired phones. Use the same `--state-dir` on these
   commands and `stream` if using a custom identity location.
3. Enable remote connections in the desktop app, save and start the host; use
   **Phones → Pair a phone** for its remote invitation. For console development,
   start Windows in explicit remote mode. `--host` is the PC's private IP
   for the pinned certificate and optional direct HTTPS listener. Remote links
   choose LAN or rendezvous signaling: initial Connect tries LAN first, automatic
   recovery tries rendezvous first, and a healthy rendezvous session can switch
   to verified LAN. LAN discovery stays disabled:

   ```powershell
   .\windows-host.exe stream --paired --remote --pair --host <PC-LAN-IPv4>
   ```

   Add the existing `--microphone-device "<CABLE-render-ID>"` for microphone or
   duplex. Scan or paste the `micdrop://remote/v1/...` invitation on Android or
   iPhone and Connect. Approve the displayed request on Windows. An
   already-approved phone can reuse its existing identity; no Forget is needed.
   The phone saves the remote URL/resource token in its protected saved
   connection, then automatically connects using the selected audio/mic options.
4. First test remote signaling with both devices still on the same Wi-Fi. This
   works without TURN because ICE can select the LAN path. Signaling can select
   LAN or the VPS independently of the media path. The reported media path may
   correctly remain **direct**.
   Then configure STUN/TURN as below and test the phone on cellular or another
   Wi-Fi. A successful pairing alone does not prove that the media path works.
5. For a forced TURN test, export a new configuration with `--force-relay` after
   TURN is configured, stop Windows, import it, restart and paste a fresh remote
   invitation. Both peers require relay candidates; they fail if no TURN servers
   were supplied. The flag is saved in the phone invitation, so importing on
   Windows alone does not update an older saved connection on the phone.

Both endpoints cache issued credentials in memory and refresh before subsequent
ICE gathering/restarts when less than a minute remains. Refresh failures do not
fall back to expired credentials or public default servers. Coturn allocation
renewal beyond the ten-minute credential lifetime and fresh-allocation recovery
after a coturn interruption have been verified on Android; credential values are
not logged. Deterministic contracts cover bounded credential validation and
rejection. The original LAN path remains available by starting Windows without
`--remote` and using a LAN pairing invitation or explicit LAN discovery selection.
Selecting a discovered LAN host intentionally replaces the saved remote route.

## Connection diagnostics and validation

Connection reports distinguish signaling transport from the selected ICE media
path. A relay candidate, an open TLS listener, or a successful invitation alone
does not prove audible media delivery. Report actual transport, candidate type,
route changes, recovery result and mute/Stop behavior. RTT is not physical latency.

Current policies include initial incremental gathering, negotiated route
improvements and continuous gathering. Their wire fields and bounds are in the
[protocol](PROTOCOL.md). Use [Advanced settings](ADVANCED_SETTINGS.md) for
supported connection preferences.

## coturn credential and deployment boundary

Use a separately maintained coturn installation. The issuer implements its
documented TURN REST convention: the username starts with the Unix expiration
time followed by a random identifier; the password is standard Base64 of
HMAC-SHA1 over that username using the shared secret's **text** as the key.
This uses coturn's existing construction, not a MicDrop cryptographic handshake.

Configure coturn's `use-auth-secret` and matching `static-auth-secret`, an explicit
realm, its own TLS certificate and the public/relay addresses and ports appropriate
to your deployment. Windows, Android and iPhone validate `turns:` server certificate
chains against the operating system's platform trust store without validation
bypass; coturn certificate renewal and service permissions must be maintained
separately from the rendezvous service. Keep anonymous authentication disabled. Set nonzero
`user-quota`, `total-quota`, `max-bps` and `bps-capacity`; issuance rate limits alone
do not bound TURN bandwidth. Review and block loopback, link-local, private and
multicast peer destinations for an internet-only relay. Restrict the relay port
range and expose only the chosen TURN listeners/range through the server firewall.
Do not enable coturn's loopback-peer exception for public deployment.

### IPv4-only coturn 4.6.1 configuration correction

Do not use `denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff` to
disable IPv6 peers on coturn 4.6.1. Its range matcher treats the all-zero lower
endpoint as a wildcard and orders different address families, so this rule also
denies public IPv4 peers. Allocation can succeed while subsequent
`CREATE_PERMISSION` or `CHANNEL_BIND` requests fail with `403 Forbidden IP`.
An isolated check compiled from the upstream 4.6.1 address-matching functions
reproduced this public-IPv4 match. It also confirmed that removing this rule
leaves the existing nine IPv4 deny ranges matching their boundary addresses.
See the [4.6.1 implementation](https://github.com/coturn/coturn/blob/4.6.1/src/client/ns_turn_ioaddr.c)
and the [original researcher's warning about zero-address deny rules](https://www.enablesecurity.com/blog/cve-2020-26262-bypass-of-coturns-access-control-protection/).

For the current IPv4-only deployment, remove only that broad IPv6 deny line and
restart coturn. Keep `listening-ip` and `relay-ip` explicitly set to the public
IPv4 address, with no wildcard or additional IPv6 relay addresses. Keep the
existing IPv4 deny rules, authentication, quotas, multicast protection and
firewall restrictions. This correction is scoped to that IPv4-only setup;
enabling IPv6 later requires its own peer-range review and connectivity checks.
No new APK, Windows binary, pairing, shared secret or rendezvous configuration
is required for this correction.

Retry forced-relay playback, Stop and Reconnect, saving the combined log. If it
still fails, collect coturn's logs for that attempt, especially allocation,
permission/channel results and peer traffic counters. Candidate counts alone
cannot distinguish permission rejection from a blocked relay packet path.

Credential expiry does not itself prove that every existing allocation has ended.
Validate coturn allocation/refresh behavior, renewal before subsequent ICE
gathering, aggregate quotas, denied peer ranges and UDP/TCP/TLS connectivity in
the deployed environment. Client-token holders can consume configured relay
resources even if Windows rejects their inner pairing; protect and rotate those
tokens independently. Remote access will remain opt-in at the Windows host.

The binary emits startup/configuration/shutdown results, not request access logs,
tokens, payloads, SDP, candidates or audio. Route/socket state and credentials are
kept in memory; configuration stays on the operator's disk. The operator can still
observe peer addresses, connection timing and traffic volume. Hosters, TLS ingress
and coturn may keep their own logs: document retention and disable unnecessary
request/credential logging before release. Measure billed egress on both relay
directions; no free-hosting or fixed-cost claim is made.

## Checks before remote use

Test TLS reachability, pairing, playback, microphone/duplex as needed, explicit
Stop, a fresh reconnect and the configured relay transports on your deployment.
Automated rendezvous/inner-TLS contracts cannot establish physical audio delivery
or the reliability of a particular provider/network. Protect configuration and
role tokens; export from the existing configuration instead of recreating it.

References: [coder/websocket](https://github.com/coder/websocket),
[coturn configuration](https://github.com/coturn/coturn/blob/master/README.turnserver),
and the [dependency record](../third_party/RENDEZVOUS.md).
