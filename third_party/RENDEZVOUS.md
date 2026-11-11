# Remote signaling dependency

`github.com/coder/websocket` is pinned to **v1.8.15**, upstream commit
`9c8faadccd1b679e811a79ce506f8a10237251ad`. `go.sum` records the module/archive
checksums. It has no additional module dependencies and is maintained by Coder.
The upstream ISC notice is copied unchanged to `WEBSOCKET-NOTICE.txt` and included
with the service artifact. The service's existing `golang.org/x/net/netutil`
dependency is covered by `DISCOVERY-NOTICES.txt`, also included in that artifact.

Use the library's supported WebSocket protocol and `net.Conn` adapter. Compression
is disabled. Restore the message-size bound after `NetConn`, which disables it by
default; chunk writes to TLS-sized messages and abort closes promptly. HTTP
redirects are rejected before forwarding resource credentials.

coturn is separately installed and is not bundled. Its version, package updates,
license, quotas, denied peer destinations and deployment security need review by
the deployment owner before public use. See [remote access](../docs/REMOTE_ACCESS.md).

Android uses `org.java-websocket:Java-WebSocket:1.6.0` (MIT), with its
`org.slf4j:slf4j-api:2.0.6` dependency and the pinned `slf4j-nop:2.0.6` provider
(MIT) to prevent transport payload logging. Notices are packaged in
`assets/remote-notices.txt`. Compression is disabled; upgrade headers are bounded
at 8 KiB and whole/fragmented messages at 64 KiB. The phone queues at most eight
messages and drains one 16 KiB outbound chunk at a time. It owns the outer TLS
socket before connect so cancellation can release pending handshakes. Inner TLS
uses Android's standard `SSLEngine`, with the existing Keystore identity and
pinned-host trust manager; no private identity key is exported.

Sources: [Java-WebSocket 1.6.0](https://github.com/TooTallNate/Java-WebSocket/tree/v1.6.0),
[SLF4J 2.0.6](https://github.com/qos-ch/slf4j/tree/v_2.0.6).
