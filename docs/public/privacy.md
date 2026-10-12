# Privacy and permissions

OmniFlow combines local processing with optional network features. This document describes the source implementation and its boundaries; it is not a security certification or a promise that every platform path behaves identically.

## What can leave the device

| Feature | Network boundary |
| --- | --- |
| Apple speech / Foundation Models | Local processing paths; platform assets and availability are managed by Apple. |
| MLX and Kokoro | Inference is local after models are installed. Downloading models contacts their hosting services. |
| Remote MCP | Requests and tool arguments go to the endpoint you configure. The server may access other services and retain data under its own policies. |
| Local MCP | Runs an installed program. That program may access files, launch processes or make its own network requests. |
| iCloud sync | When enabled and provisioned, selected data is sent to your CloudKit private container. |
| Widgets and optional lookups | Weather, feeds, public-IP lookups and other enabled network-backed features may contact external providers. |
| Development tools | Package resolution and model installation download dependencies. Tests may contact services when explicitly configured. |

Do not equate an on-device model with an offline application. A local assistant can still send sensitive content as arguments to a tool you have enabled. Allow only the tools and resources needed for your task, and review their effects.

## Permissions by feature

Grant permissions only for features you intend to use. Availability differs between the direct Mac, sandboxed Mac and iOS targets.

| Permission or access | Why a feature may request it |
| --- | --- |
| Microphone / speech | Dictation, voice questions and optional wake listening. Continuous listening uses additional power. |
| Accessibility | Text insertion, selected-text or pointer context, focus-following and desktop interaction. |
| Screen Recording | Features that inspect visible screen or window content. |
| Automation | Reading supported app context, such as a browser tab, when requested. |
| Full Disk Access | Optional local Mail and Messages cache readers. Cached content may be incomplete or unavailable. |
| Calendar / location | Optional calendar or local-weather features. |
| Files and folders | Documents you import or make accessible to the app or tools. |
| Keyboard extension access | Communication between the iOS keyboard and host app for dictation; extension capabilities depend on system settings. |
| Biometrics | Optional app-lock behavior on supported devices. |

Permissions expose real data. Screen content, mail previews and agent events can contain secrets even when you did not type them into a chat. A third-party tool has its own trust boundary; the app's allowlist is not a sandbox for arbitrary local programs.

## Local data

History may retain original dictation and transformed output. Saved assistant work may retain questions, answers and source evidence. Reader maintains imported documents and reading state. Diagnostics record local application events. Retention controls vary by store; disabling a feature is not equivalent to deleting its existing records.

Mac installations retain historical paths, including `~/Library/Application Support/NotchLee/LocalData/` and the `NotchBuddy` relay directory. Credentials use Keychain. These internal names are preserved for compatibility. App-container and app-group storage differ on iOS and sandboxed targets.

Use the app's history and memory deletion controls before sharing a device or collecting a support bundle. Review exported JSON, logs and screenshots manually before attaching them to an issue. File permissions and encrypted stores do not make data safe from an already compromised user account, every backup mechanism or a process to which you grant access.

## iCloud

Sync is optional and requires working provisioning. Its implemented scope is selected transcript text, Reader positions and preferences, not microphone recordings or book binaries. Turning it off retains downloaded copies. Cross-device behavior and account transitions need device testing in your provisioned environment; do not rely on an unverified development build as your only copy of important work.

## Reporting a problem

Follow [SECURITY.md](../../SECURITY.md) for vulnerability reports. Do not publish credentials, token values, personal transcripts, private endpoints or unredacted tool responses in an issue. For ordinary bugs, a synthetic input and minimal reproduction are usually enough.
