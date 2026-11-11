# iPhone app dependencies

The portable Swift package `apps/ios/MicDropKit` builds on Linux using the pinned
Swift image below, either locally (including WSL2) or in GitHub Actions. The
iPhone app workflow runs on GitHub-hosted `macos-26` runners with the pinned
Xcode below; see [iPhone CI build](../docs/DEVELOPMENT.md#iphone-ci-build). The
IPA is unsigned; signing happens on the user's computer (Sideloadly or iloader with the
user's Apple ID, see [DEVELOPMENT.md](../docs/DEVELOPMENT.md#install-on-iphone)).
WebRTC is recorded in [WEBRTC.md](WEBRTC.md).

| Component | Pinned source / package | License and packaging |
| --- | --- | --- |
| SwiftNIO | [swift-nio 2.103.0](https://github.com/apple/swift-nio/tree/2.103.0), revision `21de5f08c1a166a6dd293d0e587ad977bf8dac5d` | Apache-2.0, with embedded llhttp (MIT), FreeBSD `sha1.c` (BSD-3-Clause) and uSHET `cpp_magic.h` (MIT); linked into the app (NIOCore, NIOPosix, NIOHTTP1, NIOWebSocket) |
| SwiftNIO SSL | [swift-nio-ssl 2.37.5](https://github.com/apple/swift-nio-ssl/tree/2.37.5), revision `322f3c2a4a21df31c84ca416bf65ee5e9059e440` | Apache-2.0, with vendored BoringSSL `817ab07ebb53da35afea409ab9328f578492832d` (its own license text); linked |
| SwiftNIO Transport Services | [swift-nio-transport-services 1.28.0](https://github.com/apple/swift-nio-transport-services/tree/1.28.0), revision `67787bb645a5e67d2edcdfbe48a216cc549222d5` | Apache-2.0; linked on Apple platforms only |
| Swift Certificates | [swift-certificates 1.21.0](https://github.com/apple/swift-certificates/tree/1.21.0), revision `ff86b924ead66f853b8baf91f3c41926a8f36177` | Apache-2.0, with musl-derived time conversion (MIT); linked (X509) |
| Swift Crypto | [swift-crypto 4.5.2](https://github.com/apple/swift-crypto/tree/4.5.2), revision `da9d28d69ebe3894b18376c8f2395c2f37b8448f` | Apache-2.0, with vendored BoringSSL `0226f30467f540a3f62ef48d453f93927da199b6`; linked (`Crypto` re-exports CryptoKit on Apple platforms; `_CryptoExtras` links BoringSSL) |
| Swift ASN.1 | [swift-asn1 1.7.3](https://github.com/apple/swift-asn1/tree/1.7.3), revision `3b6410f7dee09eb33cdd26260c5fd47fda19b0e2` | Apache-2.0; linked |
| Swift Atomics | [swift-atomics 1.3.1](https://github.com/apple/swift-atomics/tree/1.3.1), revision `0442cb5a3f98ab802acb777929fdb446bda11a34` | Apache-2.0 with the Swift Runtime Library Exception; linked through SwiftNIO |
| Swift Collections | [swift-collections 1.7.1](https://github.com/apple/swift-collections/tree/1.7.1), revision `98ef3c98609a1e31b7e157b5b619579001a789d6` | Apache-2.0 with the Swift Runtime Library Exception; linked through SwiftNIO |
| Swift System | [swift-system 1.8.1](https://github.com/apple/swift-system/tree/1.8.1), revision `869129b7bf4ecc57b97d0193ad29690ca2134750` | Apache-2.0 with the Swift Runtime Library Exception; linked through SwiftNIO |
| XcodeGen (build tool) | [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0), release asset `xcodegen.zip`, 4,278,764 bytes, SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` | MIT; build-time only, never bundled |
| Swift toolchain, Linux (build tool) | `swift:6.3.3-noble@sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c` | build-time only |
| Xcode (build tool) | Xcode 26.6, build 17F113, iOS SDK 26.5, on GitHub-hosted `macos-26` | build-time only |

These are pinned compatible releases, not a claim that all are the newest. Each
was at least two weeks old on 2026-10-13. swift-crypto stays on 4.x: 5.0 needs
Swift 6.2 and aligns with the CryptoKit of Xcode 27, so it moves together with a
later Xcode update. Portable code uses `derRepresentation`, never the removed
`derBytes`, to keep that upgrade mechanical.

No package is modified. The six direct dependencies are declared with `exact:`
versions in `apps/ios/MicDropKit/Package.swift`; transitive versions (swift-atomics,
swift-collections, swift-system) are pinned by the committed
`apps/ios/MicDropKit/Package.resolved`. Resolution sources are restricted to
github.com/apple and checked by tools/check_swiftpm_pins.py: every pin must be a
remote source-control pin at an exact release with a 40-hex revision, and must
have exactly one matching header in the notices. The host, portable Swift and
macOS jobs require the committed resolved file; a missing file fails instead of
generating new pins. The macOS job also checks that Xcode resolved exactly the
committed pins.

System frameworks (AVFoundation, AVFAudio, MediaPlayer, Network, Security,
CryptoKit, Vision, VisionKit, MetricKit) are not third-party components. Android's
ZXing notices have no iOS counterpart.

Notices are bundled as `ios-notices.txt` (from
[ios-assets/ios-notices.txt](ios-assets/ios-notices.txt)) and `webrtc-notice.txt`
(the pinned WebRTC archive's `NOTICE`) and shown in Open-source notices. The
iPhone bundle check fails if either is missing. These notices satisfy attribution
for a sideloaded development build; they are not a distribution-license decision
(see the release status in [README.md](../README.md)).

## Adding or upgrading a Swift package

1. Change the `exact:` version (or add the package) in `Package.swift`.
2. Regenerate `Package.resolved` in the pinned Linux image (below). Pin transitive
   versions explicitly, choosing versions at least two weeks old.
3. Update `ios-assets/ios-notices.txt`: the `== <identity> <version> (<revision>) ==`
   header for each changed package and the verbatim LICENSE/NOTICE texts from the
   pinned tag, including any newly embedded third-party code.
4. Update the table above (version, revision, license, purpose).
5. Run `python tools/check_swiftpm_pins.py lock apps/ios/MicDropKit/Package.resolved third_party/ios-assets/ios-notices.txt`,
   commit the manifest, generated pins, provenance and notices together, then push
   and let both the Linux and macOS jobs pass.
6. Mention any new license type in the pull request description.

With Docker Desktop, from the repository root in PowerShell:

```powershell
docker run --rm -v "${PWD}:/src" -w /src/apps/ios/MicDropKit `
  swift:6.3.3-noble@sha256:cd45c27b3abc42310c33cfaf3008b18156cbdc9187834c9617e8f43a26d2675c `
  bash -c "swift package resolve && swift package resolve swift-atomics --version 1.3.1 && swift package resolve swift-collections --version 1.7.1 && swift package resolve swift-system --version 1.8.1"
```

Generate the file with SwiftPM, never by hand. If Docker is unavailable, use the
same pinned image on another Linux machine. CI validates the committed file and
does not generate or publish replacement pins.

## Updating a pinned build input

| Input | Change | Then |
| --- | --- | --- |
| Xcode / runner image | `DEVELOPER_DIR`, the two version assertions and the cache key prefix in `.github/workflows/ios.yml` | update DEVELOPMENT.md and this file in the same change |
| Swift Linux image | tag and digest in `.github/workflows/build.yml` (both iPhone jobs) and the cache key | keep major.minor equal to Xcode's Swift |
| XcodeGen | `XCODEGEN_VERSION` and `XCODEGEN_SHA256` in `ios.yml` (GitHub release asset digest), `minimumXcodeGenVersion` in `apps/ios/project.yml` | this file |
| WebRTC | the `ios` entry of `webrtc.lock.json` (`build_version`, `builder_commit`, `webrtc_commit`, `sha256`, `size`) | WEBRTC.md; iPhone device audio checks (stereo playback, microphone, duplex, Stop/reconnect) |
| Actions | SHA and version comment | the same SHA everywhere it appears |
