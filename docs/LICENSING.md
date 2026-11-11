# Licensing and funding

Decision D048, accepted 2026-10-25: license first-party MicDrop code under the
**Mozilla Public License 2.0 (MPL-2.0)**. Start with open source and voluntary
donations via [Ko-fi](https://ko-fi.com/maskarauder); official paid downloads may
follow as a convenient way to install and support the project. No in-app payment
integration is bundled.

## Scope

The root [LICENSE](../LICENSE) contains the unmodified MPL-2.0 text.
[NOTICE](../NOTICE) applies it to all first-party repository files, including
code, tests, scripts, configuration, and documentation, unless a file or its
accompanying notices say otherwise. Third-party material keeps its own license;
this includes the Gradle wrapper and the dependencies documented in
[third_party](../third_party). Preserve their notices and provenance.

MPL uses file-level copyleft: when distributing modified MPL-covered files,
their source remains available under MPL. Separate files in a larger work can
use other licenses, subject to the licenses of any code they contain. Private
changes do not have to be published merely because they were made.

Both free and paid binaries are allowed. Selling a build does not remove its
source obligations or the recipient's rights to modify and redistribute the
MPL-covered code. The license does not grant trademark rights to the MicDrop
name or branding. The [MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)
explains the license; the license text controls.

## Distributing a build

- Include `LICENSE` and `NOTICE`, plus the relevant third-party notices.
  Windows portable/installer payloads and the rendezvous package carry them
  beside the executable. Android copies the root files into APK assets and
  displays them in **Open-source notices**. The iPhone app bundles them as
  resources, shows them first in its **Open-source notices**, and the CI IPA
  check rejects a bundle without them.
- Make the corresponding MPL-covered source, including any modifications,
  available to recipients under MPL, and provide a working source location.
  Use the release tag or exact Git revision that produced the binary. Include
  the build scripts and configuration needed to modify that source.
- Before distributing a binary or submitting to a store, verify that recipients
  can access the exact matching source tag, commit, or source archive. Unreachable
  or restricted links do not satisfy source-access obligations; publish the
  matching source or provide an accessible source archive alongside the build.
- Review each dependency's redistribution requirements. MicDrop's MPL choice
  does not settle third-party licensing, production signing, or store policies.

Contributions follow [CONTRIBUTING.md](../CONTRIBUTING.md). Contributors retain
their copyrights; accepting a contribution does not assign them to the project.
