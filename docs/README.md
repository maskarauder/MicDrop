# MicDrop documentation

These guides describe the Windows, Linux, macOS, Android, and beta iPhone
implementations, along with each platform's verified scope and remaining checks.

## Use MicDrop

| Guide | Purpose |
| --- | --- |
| [Beta testing](BETA_TESTING.md) | Install, pair, adjust background battery settings, test and report |
| [Windows package README](WINDOWS_PACKAGE.md) | Self-contained guide shipped as README.md |
| [Windows installer](WINDOWS_INSTALLER.md) | Install location, upgrades, removal and preserved data |
| [Windows desktop](WINDOWS_DESKTOP.md) | Audio/network choices, phones, settings, startup and logs |
| [Linux desktop](LINUX_DESKTOP.md) | GTK3 `micdrop-host desktop` UI, XDG launcher/autostart, tray, and virtual mic setup |
| [macOS desktop](MACOS_DESKTOP.md) | Experimental Apple Silicon `MicDrop.app`, permissions, startup, and hardware feedback |
| [Android](ANDROID.md) | Modes, routes, permissions, diagnostics and updates |
| [iPhone app](DEVELOPMENT.md#iphone-app) | Building, sideloading, platform differences, and device scope |
| [Virtual audio cable](VIRTUAL_AUDIO_CABLE.md) | Phone microphone return and duplex setup |
| [Advanced settings](ADVANCED_SETTINGS.md) | Connection policy, timeouts and microphone options |
| [Remote access](REMOTE_ACCESS.md) | Optional rendezvous/TURN configuration and trust |
| [Service deployment](SERVICE_DEPLOYMENT.md) | Linux systemd installation and certificate renewal |

## Develop and distribute

- [Development](DEVELOPMENT.md): toolchains, source builds, CI workflows, developer harness and checks.
- [Releasing](RELEASING.md): versioning, package contents, immutable drafts and tester delivery.
- [Windows security detections](WINDOWS_SECURITY.md): false-positive evidence, signing and scan limits.
- [Licensing](LICENSING.md): MPL-2.0, source availability, notices and funding.
- [Contributing](../CONTRIBUTING.md): contribution workflow, checks and engineering conventions.
- [Roadmap](ROADMAP.md): current beta priorities and deferred work.

## Technical references

[Architecture](ARCHITECTURE.md), [protocol](PROTOCOL.md), [pairing](PAIRING.md),
[LAN discovery](LAN_DISCOVERY.md), [phone settings exchange](PHONE_CONTROL_V1.md),
and [security/privacy](SECURITY.md) describe component and trust boundaries.
Report vulnerabilities using the root [security policy](../SECURITY.md).

[Platform audio](PLATFORM_AUDIO.md), [latency](LATENCY.md),
[measurement tools](../tools/latency/README.md), and the
[benchmark template](BENCHMARK_TEMPLATE.md) support device measurements.
[ADB controls](ANDROID_ADB_TESTING.md) are developer-only.
[Dependency records](../third_party/) preserve versions, provenance and notices.

## Design

[Product requirements](design/PRODUCT.md) describe design scope, including future
features. The [decision log](design/DECISIONS.md) preserves architectural and
protocol decision context. These records stay in source and are not bundled with
the Windows app.
