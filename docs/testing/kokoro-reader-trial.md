# Kokoro Reader device checks

Reader and assistant speech use FluidAudio's Core ML Kokoro integration. Model assets download separately. Legacy system-speech types remain in the codebase for compatibility; their presence does not mean Reader offers those voices as a fallback. See [third-party notices](../../THIRD-PARTY-NOTICES.md) for runtime, model and pronunciation-resource licenses.

This is a test checklist, not a claim that the current public checkout has passed a device trial. Record the commit, OS, device, selected model/language/voice and configuration with each result.

## Before listening

1. Build the intended Mac or iOS target and run relevant Reader regression tests.
2. Prepare the desired voice while foregrounded and connected to the network.
3. Confirm an installed model works without network access.
4. Import a representative EPUB using synthetic or redistributable content.
5. Confirm failures produce visible errors rather than silently skipping text or switching voices.

## Device acceptance

Listen to a real book for at least 75 minutes. On mobile, include screen-lock playback; on Mac, distinguish display sleep from full system sleep. Verify:

- Voice consistency, sentence continuity and pronunciation.
- Pause/resume, interruption recovery and lock-screen or media controls.
- Speed changes, sentence/paragraph seeking and restored reading position.
- Rapid cancellation/restart and switching between assistant replies and Reader.
- Language/model changes, unavailable assets and bounded memory behavior.
- Heat, battery consumption and crash or interruption times.

The engine uses bounded lookahead and serialized inference; these mechanisms do not establish long-duration stability on every device or voice. A short fixture test or a disabled optional soak harness is not a sustained synthesis test. Test each supported language and device class independently before claiming parity.
