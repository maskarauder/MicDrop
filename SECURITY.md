# Security policy

## Reporting a vulnerability

Please report suspected authorization, pairing, microphone-consent, credential,
or data-exposure vulnerabilities privately.

Use **Security → Report a vulnerability** in this repository when that option
is available. GitHub private vulnerability reporting must be enabled by a
maintainer; this file alone does not enable it. If the option is unavailable,
contact a maintainer through an existing private channel, or open an issue
asking only for a private security contact. Do not put vulnerability details,
proofs of concept, credentials, or diagnostic attachments in that public request.

A private report should include the affected version or source revision,
platform, reproduction steps, and expected versus observed behavior. Use test
identities and redact pairing invitations, keys, relay credentials, and private
audio or network data. Maintainers can request additional evidence privately.

See [GitHub's private reporting instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).
Maintainers must enable and verify that reporting route before public launch.

## Development status

MicDrop is preparing its first beta. There is no established long-term support
or security-response timetable. Report issues in older builds with their exact
revision; fixes are developed against the current code.

The [security and privacy guide](docs/SECURITY.md) describes the implementation's
trust boundaries, microphone controls, and diagnostic handling. Functional tests,
antivirus scans, and this policy do not constitute an independent security audit.
