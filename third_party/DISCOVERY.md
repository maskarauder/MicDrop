# LAN discovery dependencies

Android uses the platform `NsdManager`; discovery adds no Android dependency.
Windows uses the following pinned, unmodified Go modules. `go.sum` records their
checksums and `go mod verify` checks the local cache. The Windows Actions artifact
includes `DISCOVERY-NOTICES.txt` beside the executable, containing each component's
license and applicable patent grant text.

| Module | Version | License / purpose |
| --- | --- | --- |
| [libp2p/zeroconf/v2](https://github.com/libp2p/zeroconf/tree/v2.2.0) | v2.2.0 | MIT; DNS-SD registration/responder, including Windows multicast-interface handling |
| [miekg/dns](https://github.com/miekg/dns/tree/v1.1.73) | v1.1.73 | BSD-3-Clause; DNS encoding/decoding |
| [golang.org/x/net](https://pkg.go.dev/golang.org/x/net@v0.59.0) | v0.59.0 | BSD-3-Clause plus patent grant; multicast packet connections |
| [golang.org/x/sys](https://pkg.go.dev/golang.org/x/sys@v0.48.0) | v0.48.0 | BSD-3-Clause plus patent grant; OS socket support |

The responder's older transitive versions are explicitly upgraded in `go.mod`.
This package serves public discovery hints only. It does not participate in TLS,
pairing trust or media transport. Registration is scoped to the selected adapter;
shutdown sends goodbye records and releases its sockets. Registration success
does not prove firewall passage or receiver visibility. See
[the discovery design and limitations](../docs/LAN_DISCOVERY.md).
