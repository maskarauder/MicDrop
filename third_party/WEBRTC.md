# Pinned WebRTC dependency

MicDrop uses Shiguredo's **m155.8059.1.1** WebRTC distribution for Windows x64
and **m155.8059.2.0** for Linux x64, macOS arm64, Android arm64, and iPhone
arm64. These are third-party prebuilts, not binaries rebuilt from WebRTC source
by MicDrop CI. CI builds MicDrop's wrapper/application from source.

The machine-readable [lock file](webrtc.lock.json) records:

- Producer repository: <https://github.com/shiguredo-webrtc-build/webrtc-build>
- Windows producer commit: `a7e636937592dcec0f2e9a0e032795f776c031db`
- Windows WebRTC source commit: `c4f21b1f91386bae6d710540976dff5aae67b3c5`
- Linux, macOS, Android, and iOS producer commit: `5ef3d36e4562120cae0e597c3923b8532b0821ca`
- Linux, macOS, Android, and iOS WebRTC source commit: `f89edcb7be1f4be029ee7186e36b2b35ec03373e`
- Releases: [Windows](https://github.com/shiguredo-webrtc-build/webrtc-build/releases/tag/m155.8059.1.1),
  [Linux, macOS, Android, and iOS](https://github.com/shiguredo-webrtc-build/webrtc-build/releases/tag/m155.8059.2.0)

| Asset | SHA-256 |
| --- | --- |
| `webrtc.windows_x86_64.zip` | `8f1fa89b9b26623f309b79bb264b752814fa5f10bae129e8d4968db9e19e7200` |
| `webrtc.ubuntu-22.04_x86_64.tar.gz` | `6f082d9869bcfd34d31c7ba9a9a4734696fed56c81ee7e003bd6a488cb8a517d` |
| `webrtc.macos_arm64.tar.gz` | `cf5ecd2fbb2d812e568688ad7c2a61d9c28a9d2ce54cc20fc5f5a98644a5ea6f` |
| `libwebrtc.aar` | `33db9de4c6bca21f927b40e9a7319287c8adce1d8b734f15b42e5366bd1cc89a` |
| `webrtc.ios_sdk.tar.gz` | `1fcd96b58f671f0d67609d051947913b953e4873b99cf95d5811236cf22b2300` |

Because the Linux x64 and macOS arm64 `libwebrtc.a` archives compile against
Chromium's custom `std::__Cr` (`_LIBCPP_ABI_NAMESPACE=Cr`, `_LIBCPP_ABI_VERSION=2`)
headers from LLVM 24, `webrtc.lock.json` also pins the exact build-time Chromium
Clang (`llvmorg-24-init-7747-g62397f8b-27`) and `libc++` (`97b436da4c33663581d394f4ee0a5977fc38c2f4`,
`buildtools` `c202b4a9dac30e789ed6e3b2354efa94357a56f3`, Apache-2.0 WITH LLVM-exception)
inputs recorded in the WebRTC `DEPS`:

| Build-time toolchain input (`linux` / `macos`) | SHA-256 / tree digest |
| --- | --- |
| `clang-Linux_x64-llvmorg-24-init-7747-g62397f8b-27.tar.xz` | `83f4a4ea3292bfc236d85575fa7af27d39180d88534bc3117b73ad1df34bb959` |
| `clang-Mac_arm64-llvmorg-24-init-7747-g62397f8b-27.tar.xz` | `b1d5d53f8dba60834fc3287ff53276fbed4273eee6a8f31a1ff7825f91db77c1` |
| `clang-mac-runtime-library-llvmorg-24-init-7747-g62397f8b-27.tar.xz` | `dd5c1da410296c96792bae2c3b79127ae1e53a853521e241088a229fa9a20b3b` |
| `libcxx` `include/` tree (`97b436da4c33663581d394f4ee0a5977fc38c2f4`) | `94e9d2b12fa65372894f7839d904aefefdc9c2e22bdeb5bf58c8da8f986e7700` |
| `buildtools` `third_party/libc++/__config_site` | `fcac9dc8ea709997ab8b43af6c4e4e2a3674531c6f6303ca42eaf1e3fe189064` |
| `buildtools` `third_party/libc++/__assertion_handler` | `6f9934bea04c9e23f264a82725925354274af6ca2651a1056a737f96a73d0193` |

`python tools/fetch_webrtc.py windows`, `linux`, `macos`, `android` or `ios` downloads the selected
artifact, verifies its size (when the lock records one) and complete SHA-256 before
use, and places it under ignored `.deps/`. Asset-specific version/source metadata
overrides the shared defaults, so an Android or Unix update does not change the Windows
engine. Windows, Linux, and macOS extraction checks the selected source commit in `VERSIONS`;
Linux and macOS also verify the extracted `clang` archives, `libcxx/include` tree hash, and
`__config_site` / `__assertion_handler` digests, skipping unused `webrtc/include/build/linux`
and `webrtc/include/third_party/perfetto` relative symlinks.
For iOS the tarball is streamed; only `WebRTC.xcframework`, `NOTICE`, `VERSIONS`
and `DEPS` are installed under `.deps/webrtc/ios/`; headers are skipped; the
source commit is checked in both `VERSIONS` and the xcframework's
`build_info.json`; the deployment target must not exceed the app's iOS 17.0; the
xcframework must have exactly one iOS arm64 device slice with a Mach-O binary;
links, special files and unsafe paths are rejected. The one exception is the
skipped header tree: the m155.8059.2.0 archive contains 12 relative symbolic
links under `webrtc/include/third_party/perfetto/`, which are never read or
created. Reusing an installed Windows, Linux, macOS, or iOS dependency rechecks its source
metadata (and toolchain digests on Linux/macOS) against the current lock; iOS also repeats the deployment-target and
device-slice checks. A matching archive checksum stamp cannot bypass these checks.
Dependency-selection tests cover all five targets, checksum and size rejection,
source-revision rejection and cached-install validation.
Do not replace an asset without reviewing/updating the lock file and rerunning
the native round trip, Android hardware and iPhone device checks.

The Android increment repairs the native Stop crash in factory disposal. The
producer's [destruction-order fix](https://github.com/shiguredo-webrtc-build/webrtc-build/commit/dc65b08c747c74844cdb6bd5f0b849b2a9eea899)
releases `ConnectionContext` before its worker/network/signaling threads.
The previous Android proxy patch kept that context until after thread destruction,
then its destructor posted work through a freed worker. Crash traces
and the checksummed old binary identify this path. The selected release contains
the corrected [Android proxy patch](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/5ef3d36e4562120cae0e597c3923b8532b0821ca/patches/android_proxy.patch).
Short Stop/reconnect device regression remains required; CI cannot execute this
arm64 JNI engine in the x86_64 pairing emulator.

The output-diagnostics increment reads the pinned Android module's `audioOutput`
and `audioTrack` fields without modifying them, and the standalone AudioTrack
probe reuses its package-private buffer manager through `MicDropBufferTuner`.
The AAR is not patched or repackaged. Dependency upgrades must pass the Android
field-layout compatibility test and compile that bridge. Reflection failure at
runtime leaves diagnostics unavailable.

## Source and build record

The Windows producer's pinned [run.py](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/a7e636937592dcec0f2e9a0e032795f776c031db/run.py),
[VERSION](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/a7e636937592dcec0f2e9a0e032795f776c031db/VERSION),
[DEPS](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/a7e636937592dcec0f2e9a0e032795f776c031db/DEPS),
patches, and
[development instructions](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/a7e636937592dcec0f2e9a0e032795f776c031db/DEVELOPMENT.md)
define its source-fetch/build/package procedure. The Android equivalents are
[run.py](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/5ef3d36e4562120cae0e597c3923b8532b0821ca/run.py),
[VERSION](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/5ef3d36e4562120cae0e597c3923b8532b0821ca/VERSION),
[DEPS](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/5ef3d36e4562120cae0e597c3923b8532b0821ca/DEPS),
and [development instructions](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/5ef3d36e4562120cae0e597c3923b8532b0821ca/DEVELOPMENT.md).
In separate checkouts at each platform's recorded producer commit, the
source-build entry points are:

```text
python run.py build windows_x86_64
python run.py package windows_x86_64
python3 run.py build ubuntu-22.04_x86_64
python3 run.py package ubuntu-22.04_x86_64
python3 run.py build macos_arm64
python3 run.py package macos_arm64
python3 run.py build android_sdk
python3 run.py package android_sdk
python3 run.py build ios_sdk
python3 run.py package ios_sdk
```

Use the producer's required host/toolchain for each target. Its recipe pins the
upstream build/dependency revisions and applies its listed patches. Relevant
common GN settings disable tests, examples, H.264, component builds, and Perfetto;
RTTI is enabled. Windows disables custom libc++ and uses the static MSVC runtime;
Linux x64 and macOS arm64 compile `libwebrtc.a` with Chromium's custom `libc++`
statically embedded inside `libwebrtc.a`.
The Android SDK recipe builds the AAR with its native library; MicDrop packages
only arm64. Consult the pinned recipe for the full configuration, including
upstream Android tooling, rather than substituting MicDrop's NDK version.
The iOS SDK recipe runs on a macOS host with the producer's required Xcode. It
uses upstream `tools_webrtc/ios/build_ios_libs.sh` with `simulator:arm64
device:arm64`, `enable_dsyms=true` and stripping, and adds the producer's ios_sdk
patches, including `ios_stereo_audio_output`, `ios_manual_audio_input`,
`ios_ssl_certificate_verifier_chain`, `ios_audio_track_sink` and
`ios_audio_pause_resume`. Its `DEPS` records `IOS_DEPLOYMENT_TARGET=14.0`.

Each desktop archive's `VERSIONS`, `DEPS`, and aggregate `NOTICE` provide the
dependency/source/license record. Reproducing MicDrop from checksummed assets
has been exercised; an independent source rebuild and byte-for-byte reproduction
of the producer's archives have not been established.

## ABI and notices

The Windows WebRTC static library uses the MSVC C++ ABI and `/MT` runtime; CMake
links it into `micdrop_rtc.dll` in **Release**. On Linux x64 and macOS arm64,
CMake compiles the C++20 wrapper with the pinned Chromium Clang and `libc++`
headers and links `libwebrtc.a` privately into `libmicdrop_rtc.so` (Linux, with
`-Wl,--exclude-libs,ALL` and hidden symbol visibility) or `libmicdrop_rtc.dylib`
(macOS arm64, deployment target 14.2+, `@rpath` install name, `-Wl,-dead_strip`).
Only the `mdr_*` C ABI functions are exported. The Go host executable uses the
platform C/Objective-C compiler for cgo and loads the shared library (`LoadLibraryExW`
on Windows, `dlopen` with `RTLD_NOW | RTLD_LOCAL` beside the executable or inside
`../Frameworks` of a macOS `.app` bundle on Unix) through opaque handles and
caller-owned buffers. C++ objects never cross that boundary, and no Go callback
runs on a native audio thread.

The Windows, Linux, and macOS host artifacts carry `WEBRTC-NOTICE.txt` and `WEBRTC-VERSIONS.txt`
(which include the LLVM `libc++` notice embedded inside `libwebrtc.a`).
Android embeds the AAR's `META-INF/NOTICE` as `webrtc-notice.txt`, accessible from
**Open-source notices**. iOS embeds the dynamic `WebRTC.framework` (Objective-C
`RTC*` API) in `MicDrop.app/Frameworks`. The archive's `NOTICE` is bundled as
`webrtc-notice.txt` and shown under **Open-source notices**. dSYMs from the
xcframework are used only for symbolication and are never bundled. See
[IOS.md](IOS.md) for the iPhone app's other dependencies.
The upstream aggregate notices cover WebRTC and its
included dependencies. The producer repository's build-script license alone is
not the license for every linked component. MicDrop's own files use
[MPL-2.0](../LICENSE); dependency review, accessible matching source, production
signing and distribution remain release gates in [ROADMAP.md](../docs/ROADMAP.md).

## Remote renomination observation

The route-selection increment does not replace either pinned package. Although
the Android Java RTCConfiguration has no renomination field, upstream JNI
constructs a native `kAggressive` configuration which enables it. This is not
proof of behavior in an arbitrary binary: both apps inspect their actual active
audio SDP advertisements. Windows explicitly opts in before remote peer
creation. See [PROTOCOL.md](../docs/PROTOCOL.md).
