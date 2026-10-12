import AppKit
import Foundation
@preconcurrency import MediaPlayer
import Testing
@testable import OmniFlowApp

// MediaPlayer, Foundation and AVFoundation call these handlers on their own
// queues. Each must run there without Swift 6 trapping on main-actor isolation.

private func onBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

@MainActor private final class Flag { var value = false }

@MainActor @Test func readerRemoteCommandHandlersRunOffMain() async throws {
    let flag = Flag()
    let handler = ReaderController.remoteCommandHandler { flag.value = true }
    // MediaPlayer forbids creating events; the handler ignores its event.
    nonisolated(unsafe) let event = unsafeBitCast(NSObject(), to: MPRemoteCommandEvent.self)
    let status = await onBackground { handler(event) }
    #expect(status == .success)
    for _ in 0..<50 where !flag.value { try await Task.sleep(for: .milliseconds(10)) }
    #expect(flag.value)
}

@MainActor @Test func readerArtworkIsRequestableOffMain() async {
    let image = NSImage(size: NSSize(width: 4, height: 4))
    nonisolated(unsafe) let artwork = ReaderController.artwork(image)
    let size = await onBackground { artwork.image(at: CGSize(width: 2, height: 2))?.size }
    #expect(size != nil)
}

#if !APPSTORE
@MainActor @Test func readerSpeechPipeHandlersRunOffMain() async throws {
    let speech = ReaderSpeech(helper: nil)
    var answers: [(UInt32, Int?)] = []
    speech.onSentence = { id, samples in answers.append((id, samples?.count)) }
    let collector = ReaderSpeech.Collector()
    collector.begin(7)
    let reader = ReaderSpeech.pipeReader(owner: speech, child: Process(), collector: collector)
    // One audio frame (two samples) and a done frame for request 7, as the helper writes them.
    func frame(_ kind: Character, _ payload: [UInt8]) -> Data {
        var data = Data([kind.asciiValue!])
        withUnsafeBytes(of: UInt32(7).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        return data + Data(payload)
    }
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: frame("A", [0, 64, 0, 192]) + frame("D", []))
    let handle = pipe.fileHandleForReading
    await onBackground { reader(handle) }
    let ended = ReaderSpeech.terminationHandler(owner: speech)
    await onBackground { ended(Process()) }
    for _ in 0..<50 where answers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(answers.count == 1 && answers[0].0 == 7 && answers[0].1 == 2)
}
#endif

/// The old shape: a handler written inline in a main-actor context inherits
/// its isolation (this is how the iOS Reader crashed).
@MainActor private func inlineArtwork(_ image: NSImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}

/// Negative control: the old shape traps when MediaPlayer asks for the image
/// off the main thread, which is what the factories above prevent.
@Test func readerInlineHandlerCalledOffMainTraps() async {
    await #expect(processExitsWith: .failure) {
        nonisolated(unsafe) let artwork = await inlineArtwork(NSImage(size: NSSize(width: 4, height: 4)))
        DispatchQueue.global().sync { _ = artwork.image(at: CGSize(width: 2, height: 2)) }
    }
}
