# Security policy

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/mmingo-director-of-ai/omniflow/security/advisories/new). Include the affected commit, prerequisites, impact and a minimal reproduction using synthetic data. Do not post credentials, personal files, transcripts or exploitable details in public issues.

The maintained branch is `main`. There are no supported historical release lines or response-time guarantees yet. This experimental software has not received an independent security audit.

## Contribution and automation boundaries

Public read access does not grant repository write access. External changes arrive through forks and pull requests. Main-branch protection, CODEOWNERS and required checks are configured on GitHub; those settings are separate from files in this repository. Fork workflows require maintainer approval. Workflows use read-only tokens, pinned actions and GitHub-hosted runners. No automatic merge or deployment is configured.

Review dependency updates and GitHub workflow changes as code. Never add repository secrets to workflows that execute untrusted pull-request code. Signing credentials and local app data must stay outside this repository.

## Application boundaries

Approve only operations you understand. Agent approval requests are bound to unique request IDs; stale notifications cannot authorize replacements. Persistent “Always allow” grants are unavailable until their scope can be presented for review. Oversized or unavailable arguments cannot be approved from OmniFlow.

Agent relays use a private local socket and same-user checks. Remote MCP servers are explicitly configured and can receive approved tool arguments. Returned content is untrusted; model output must still pass host permissions. OAuth tokens use the Keychain. An on-device model does not make remote tools or downloaded files trustworthy. Microphone, Accessibility, Automation and optional capture permissions increase what the app can access; enable only features you need. Local same-user malware, a compromised OS and malicious model/tool dependencies remain outside this boundary.

Administrators can bypass the review requirement only when merging a pull request, so a sole maintainer can submit their own fixes. Required CI checks and the main-branch force-push/deletion protections have no bypass actors. Administrators retain the ability to change repository settings.
