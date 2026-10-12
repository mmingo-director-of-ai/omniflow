# Developing OmniFlow

OmniFlow is an experimental native Swift application. The public source is intended for inspection, local builds and contributions. Treat a successful build as compilation evidence, not as proof that every integration works on your device.

## Requirements and targets

The deployment targets in `OmniFlow/project.yml` and `Package.swift` are macOS 27 and iOS 27. Use Xcode 27 with those SDKs, an Apple silicon Mac, XcodeGen, Python 3 and Go 1.27+. The Swift package declares tools version 6.2 and Swift language mode 6. Model features additionally depend on supported hardware and locally available assets.

Generate the Xcode project from the repository root:

```sh
xcodegen generate --spec OmniFlow/project.yml
```

The generated project is not the configuration source of truth; edit `OmniFlow/project.yml` instead.

| Scheme | Purpose |
| --- | --- |
| `OmniFlow` | Direct Mac application, with desktop integrations and local helper processes. |
| `OmniFlowAppStore` | Separate sandboxed Mac target; validate its capabilities independently. |
| `OmniFlowiOS` | iPhone/iPad application with keyboard and widget extensions. |
| `OmniFlowiOSAppStore` | iOS AppStore configuration with private API compilation disabled. |

For a compilation check without signing:

```sh
xcodebuild -project OmniFlow/OmniFlow.xcodeproj \
  -scheme OmniFlow -configuration Debug \
  -derivedDataPath .build/xcode-macos CODE_SIGNING_ALLOWED=NO build

xcodebuild -project OmniFlow/OmniFlow.xcodeproj \
  -scheme OmniFlowiOSAppStore -configuration AppStore \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode-ios CODE_SIGNING_ALLOWED=NO build
```

Resolve packages using the checked-in pins. Do not update dependencies as an incidental part of a bug fix. Xcode and SwiftPM may download package sources on the first build.

For a runnable development installation, select your own team and identity. Stable signing helps macOS associate privacy grants with successive builds. Extension app groups and CloudKit require matching entitlements and provisioning. A fork generally needs its own registered bundle identifiers and container. Release builds require explicit distribution identity settings (`OMNIFLOW_RELEASE_TEAM` or `OMNIFLOW_APP_STORE_TEAM`); unsigned builds are not distributable releases.

## Architecture

| Location | Responsibility |
| --- | --- |
| `OmniFlow/Sources/App` | Mac shell, island, permissions, agent integrations and desktop behavior. |
| `OmniFlow/Sources/Core` | Shared processing, memory, MCP configuration, Reader, sync and dictation support. |
| `OmniFlow/Sources/Core/AtlasRuntime` | Native Swift agent runtime. |
| `OmniFlow/Sources/iOS` | iPhone/iPad presentation, capture, Reader and assistant integration. |
| `OmniFlow/Keyboard`, `OmniFlow/Widgets`, `OmniFlow/WidgetsiOS` | Keyboard and widget extensions. |
| `OmniFlow/Helpers/Atlas` | Go helper and bounded host/tool protocol. |
| `Vendor/AtlasSDK` | Licensed SDK source pinned for the helper build. |
| `tests`, `scripts` | SwiftPM suites, standalone integration checks and build tooling. |

The Mac island is an AppKit panel with SwiftUI content. Its presentation is optional; the main shell and voice controls are separate entry points. The original red panda artwork is rendered and animated in native UI code. Original bundled artwork and icons are reusable under [CC BY 4.0 with attribution](../../LICENSE-ASSETS.md); trademark rights are separate. Drawing code remains MIT, and bundled fonts retain their OFL terms.

Agent hooks use the `nb-hook` relay and a per-user Unix socket. Approval responses depend on the upstream agent's actual event contract. Verify the installed agent version and a real permission round trip before claiming compatibility. Historical names in bundle identifiers, helper binaries and data directories are compatibility details, not separate products.

The assistant has several evolving paths. Apple's Foundation Models provide a local model; Mac also has an optional MLX backend. The Go Atlas helper dispatches native tools and approved MCP operations through a host callback protocol. The native Swift runtime has its own tests. Changes to one path do not automatically validate another.

### Bounded context and source processing

The helper stores large tool results as task-scoped payloads rather than putting whole responses in a model prompt. Retrieval exposes source offsets, chunk search and coverage. Host-side limits bound frames, expanded payloads, stored data and execution time. Text and compressed responses are decoded with limits; binary storage does not imply the language model can interpret arbitrary media.

The Apple adapter budgets instructions, schemas and response space before inference. Earlier messages may leave the working context while the original request, source index, notes and retrieval tools remain available. A tool schema must still fit the available context.

Whole-source analysis uses bounded slices and evidence-linked notes, with committed checkpoints for recovery. A resumed analysis reads saved material; it must not be confused with replaying an external transaction. Summaries can omit or misinterpret information. Exact answers should be checked against the retained source.

### MCP connections

Use **Settings → MCP connections** to add a local executable with literal arguments, or a remote HTTPS endpoint. Discover tools, select the specific tools to allow, and then enable the connection. Resource access is separately configurable. Local programs are not installed automatically.

Remote OAuth supports browser sign-in with PKCE and a temporary loopback callback. Some servers require a preregistered public client ID. Credentials are stored separately from ordinary settings in Keychain. Sign-in and permission to invoke a tool are distinct operations. Server compatibility is not universal; authentication success alone is not a tool-call test.

A failed remote action may have executed even when no response arrives. Confirm the remote state before repeating a consequential operation. Treat all returned server content as untrusted data.

### Memory and retention

Selected memory notes and saved task work serve different purposes. Notes can hold preferences or project facts; saved work can include original questions, answers, source evidence and analysis checkpoints. Recall uses bounded local matching. Saved content is historical evidence, not authorization for future actions.

Turning retention or recall off does not necessarily delete existing data. Use the app's deletion controls and inspect the relevant store when testing deletion semantics. Dictation history, conversation history, assistant memory, Reader data and diagnostics are distinct stores. Avoid committing any of them as fixtures.

### Reader and speech

Reader imports EPUBs and maintains its own library state, search and reading positions. Mac can inspect a local Apple Books library; iOS uses imported documents. Some books or protected content may be unsupported. Kokoro narration and assistant speech use FluidAudio/Core ML with separately downloaded models. Legacy Siri/system-speech code does not establish the active production speech path.

Model downloads and their licenses are separate from package dependencies. Verify offline behavior only after required assets are installed. Live audio routing, interruption handling, long-book behavior and pronunciation require testing beyond unit fixtures.

## Verification

Start with the production-source SwiftPM tests and static platform checks:

```sh
swift test -j 4
bash scripts/check-ios-private-apis.sh
bash scripts/check-ios-private-apis.sh --self-test
bash scripts/check-core-portability.sh
bash scripts/check-reader-offmain.sh
```

Then run checks appropriate to your change. Examples:

```sh
bash scripts/test-atlas.sh
bash scripts/test-local-assistant.sh
bash scripts/test-speech-pipeline.sh
bash scripts/test-keyboard-bridge.sh
bash scripts/test-safe-links.sh
```

These commands are a development checklist, not a statement that every gate passed for the current checkout. Several scripts compile standalone sources; some depend on installed speech assets or host capabilities. Record the exact command, SDK, target, result and any skipped cases. Do not describe an unavailable hardware-dependent test as a pass.

Tests with live microphones, models, system cursors, agent hooks or remote servers can change local state or invoke tools. Read a script before running it. In particular, the `--system` cursor test temporarily changes system cursors and requires the running app to be stopped. Remote MCP tests require endpoints you are authorized to use; use fixtures for routine development.

Before a release, separately validate live dictation and insertion in real editors, keyboard extension behavior, speech and Reader interruptions, sleep/lock transitions, permission denial/revocation, multi-display/Spaces behavior, accessibility, and energy use. Simulator and source checks do not replace these checks.

## Distribution boundaries

The direct Mac build includes behavior that is unavailable or restricted in sandboxed applications. Some development/direct-distribution code uses private interfaces. The iOS AppStore configuration excludes guarded private APIs, but a source scan cannot prove compliance with every store rule.

CloudKit sync is opt-in and needs matching app IDs, a provisioned private container and a deployed schema. Its implemented scope includes completed transcript text, Reader positions and selected preferences; it does not provide a complete app backup. Validate account changes, offline recovery, conflict/deletion behavior and actual cross-device operation before advertising it as working in a distributed build. The current implementation reports oversize records instead of chunking them.

Signing, notarization, entitlements and App Store review are separate release steps. Never claim a signed or reviewed release based on a local compilation check.

Mac desktop widgets require the app and extension to use the same signing team.
Their App Group entitlement and `OmniFlowWidgetAppGroup` Info.plist value both
resolve `$(TeamIdentifierPrefix)com.mengohlabs.omniflow` at build time. Unsigned
or unresolved configurations do not open a shared widget container.

For a connected iPhone/iPad, `bash scripts/install-ios-device.sh <device-udid> <team-id>` requires your explicit development team; its build output stays in
`.build/ios-device`.
