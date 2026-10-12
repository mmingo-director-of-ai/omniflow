# Contributing to omniflow

Start with the [README](README.md) and [security policy](SECURITY.md). This is an experimental project; small, reproducible fixes and focused tests are welcome.

## Development workflow

1. Fork the repository and create a branch from `main`.
2. Keep each pull request focused. Describe the problem and changed behavior.
3. Run the documented checks on supported hardware. State which checks you could not run; compilation is not visual or device verification.
4. Include tests for security boundaries and behavior changes. For UI changes, attach a sanitized screenshot or recording.
5. Submit a pull request. Maintainer review and required checks control merging; opening an issue or pull request grants no write access.

Never commit credentials, personal transcripts, browser profiles, diagnostics, customer data, signing material, build products or model weights. Use synthetic fixtures. Dependency changes must include license/provenance review, pinned versions and required notices. Do not enable CI secrets, privileged pull-request workflows or self-hosted runners for untrusted contributions.

Contributions to source code are accepted under [MIT](LICENSE); preserve upstream notices and follow [asset terms](LICENSE-ASSETS.md). Do not submit material you cannot license. Be respectful, discuss behavior rather than people, and avoid posting private information.

Security fixes should use GitHub's private reporting workflow linked in SECURITY.md rather than public issues.
