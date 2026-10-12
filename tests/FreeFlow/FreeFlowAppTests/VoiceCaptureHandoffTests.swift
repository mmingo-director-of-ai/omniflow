import Testing
@testable import OmniFlowApp

@Test @MainActor func microphoneHandoffWaitsForAllQueuedHardwareReleases() async {
    let releases = VoiceCaptureRelease()
    let (firstGate, finishFirst) = AsyncStream<Void>.makeStream()
    let (secondGate, finishSecond) = AsyncStream<Void>.makeStream()
    let (started, signalStarted) = AsyncStream<Int>.makeStream()
    var events: [String] = []
    releases.enqueue {
        events.append("wake stopping")
        signalStarted.yield(1)
        for await _ in firstGate { break }
        events.append("wake released")
    }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    let nextRecording = Task { @MainActor in
        await releases.wait()
        events.append("dictation may start")
    }
    // An assistant cancellation can join while a wake-session stop is pending.
    releases.enqueue {
        events.append("assistant stopping")
        signalStarted.yield(2)
        for await _ in secondGate { break }
        events.append("assistant released")
    }
    #expect(events == ["wake stopping"])
    finishFirst.yield(())
    _ = await starts.next()
    #expect(events == ["wake stopping", "wake released", "assistant stopping"])
    finishSecond.yield(())
    await nextRecording.value
    #expect(events == ["wake stopping", "wake released", "assistant stopping", "assistant released", "dictation may start"])
    finishFirst.finish(); finishSecond.finish(); signalStarted.finish()
    // A later recording must not wait forever on the previous completed stop.
    await releases.wait()
}

@Test func microphoneMuteDiagnosticsDoNotMistakeUnknownForUnmuted() {
    #expect(VoiceMicrophone.Health(name: "Input", hardwareMuted: true, processMuted: false).error == .hardwareMuted)
    #expect(VoiceMicrophone.Health(name: "Input", hardwareMuted: false, processMuted: true).error == .processMuted)
    let unknown = VoiceMicrophone.Health(name: "Input", hardwareMuted: nil, processMuted: nil)
    #expect(unknown.error == nil)
    #expect(unknown.description.contains("unreported"))
    #expect(!unknown.muteDescription.contains("Input"), "Technical format telemetry must not include a user-named device")
}
