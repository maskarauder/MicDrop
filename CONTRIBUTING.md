# Contributing

The project has Windows, Linux, and macOS desktop and CLI hosts, a Kotlin
Android app, and a Swift iPhone client for paired LAN/remote playback,
microphone return and duplex audio.
Start with [Development](docs/DEVELOPMENT.md) for local toolchains, builds, and
automated checks, and the [documentation index](docs/README.md) for user guides,
technical contracts, and design records. [Releasing](docs/RELEASING.md) covers
development packages and immutable GitHub draft-release assembly, while the
[roadmap](docs/ROADMAP.md) tracks verified scope and remaining hardware or
physical-latency limits.

## Implementation workflow

1. Identify the requirement or feasibility issue being addressed.
2. Keep the change small enough to measure: one audio boundary, route behavior, or connection behavior at a time.
3. Update the relevant design document when behavior changes. Record architecture changes in [DECISIONS.md](docs/design/DECISIONS.md).
4. Verify the risk the change introduces: contract tests for protocol changes, real-device checks for routing, benchmarks for buffering/latency, and negative tests for authorization.
5. Explain the result, known limitations, and reproduction commands in the change description.

Routine documentation changes need link and consistency checks, not artificial application tests. An audio change needs actual audio-path evidence; a green unit-test run cannot establish Bluetooth compatibility or physical latency.

Run the automated checks relevant to the affected code. Record hardware-dependent
checks as passed, failed, blocked, or skipped, including the device/OS and the
reason for any gap. Do not report unavailable hardware as a pass. Keep useful
regression tests; remove a test only when its covered behavior is deliberately
retired or another check demonstrably replaces it.

Report vulnerabilities through the [security policy](SECURITY.md), not a public
issue containing sensitive reproduction details. In ordinary bug reports, include
the app version/source revision, platform, audio route, and reproduction steps;
review logs before sharing them and never include pairing links, relay
credentials, private recordings, or signing material.

## Contribution licensing

Submit first-party contributions under [MPL-2.0](LICENSE), as described in
[NOTICE](NOTICE). You retain your copyright; contributions do not assign it to
the project. Only submit material you have the right to contribute under these
terms. Identify third-party material and preserve its license and notices.

Add `SPDX-License-Identifier: MPL-2.0` in an appropriate comment near the top of
new first-party source files. Do not replace an existing third-party license
header. Repository-wide coverage and binary/source distribution requirements
are explained in [licensing and funding](docs/LICENSING.md).

## Engineering conventions

- Keep audio callbacks bounded and allocation-free where required by the selected API. Move logs, UI work, blocking I/O, and expensive setup off the audio thread.
- Separate requested settings from actual negotiated/device settings.
- Use monotonic timestamps with explicit units and boundaries. Do not subtract unrelated clocks.
- Keep queues bounded and define what happens on overflow, underrun, disconnect, and format change.
- Keep desktop media processing separate from microphone voice processing.
- Default microphone state to off for new sessions; preserve local stop/mute authority.
- Pin native dependencies and record provenance. Do not add an opaque binary dependency without a reproducible source/version/license record.
- Never commit pairing secrets, relay credentials, private recordings, signing keys, or unsanitized diagnostic exports.

## Definition of done

The intended behavior is implemented, failure behavior is explicit, relevant verification is recorded, and documentation matches reality. Performance claims include hardware, route, network, measurement method, and uncertainty. Supported routes are backed by a compatibility report.

Public distribution also requires accessible matching MPL-covered source and
reviewed third-party notices. Do not assume a reference sample or a separately
installed virtual cable grants redistribution rights.
