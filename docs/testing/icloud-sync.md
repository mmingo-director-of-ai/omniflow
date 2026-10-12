# iCloud sync verification

The source contains an opt-in CloudKit implementation. This checklist does not certify a provisioned public build or successful cross-device operation. See [development requirements](../public/development.md#distribution-boundaries) before enabling it.

## Implemented scope

- Private CloudKit payloads shared by the configured Mac/iPhone/iPad app identifiers.
- Encrypted local cache/outbox, transcript tombstones and modification-time conflict handling.
- Completed transcript originals and outputs, Reader positions, selected library preferences and voice selections.
- Content-derived book identity and migration when an existing book is reopened.
- Active-process polling, foreground sync and manual status controls.
- Account-change detection and retention of local records after network failures.

## Required checks

Record the commit, devices, OS versions, target configuration and actual result for each check. Compilation and unit tests do not replace device tests.

1. Provision your paid developer team's app IDs with the same CloudKit container. Forks should use their own registered identifiers.
2. Create the development schema and deploy the production schema before distributing a production build.
3. Sync transcript text and reading positions between Mac, iPhone and iPad, including books with changed filenames.
4. Edit and delete offline, reconnect, and verify there are no duplicates or resurrected transcripts.
5. Test sign-out/account changes, termination during upload, rate limiting, unavailable keys, quota exhaustion and device lock.
6. Reopen the app and verify preferences. Confirm remote updates do not seek an actively narrated book.
7. Disable sync and confirm local copies remain; test deletion separately.

## Limits

Book binaries, conversations, notes, model downloads, audio and credentials are outside the implemented sync scope. Import the same EPUB on each device to test content identity. Oversize transcript records remain local with an error; chunked records are not implemented. Sync runs when the app can execute, not as a guaranteed background push service.

Device clocks influence edit ordering. Transcript tombstones take precedence over stale edits. Account changes require explicit handling rather than automatic merging of data from different accounts. Do not use an unverified development build as the only copy of important work.
