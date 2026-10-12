import AppKit
import Foundation
import Testing
@testable import OmniFlowApp

@MainActor @Test func staleMusicHelperCannotClearOrOverwriteItsReplacement() throws {
    let service = NowPlayingService(observeWorkspace: false)
    let old = Process(), current = Process()
    let oldPipe = Pipe(), currentPipe = Pipe()
    service.adopt(old, input: oldPipe.fileHandleForWriting)
    service.adopt(current, input: currentPipe.fileHandleForWriting)
    service.receive(Data(#"{"title":"Current"}"#.utf8) + Data([10]), from: current)
    service.receive(Data(#"{"title":"Stale"}"#.utf8) + Data([10]), from: old)
    service.helperEnded(old, status: 1)
    #expect(service.track?.title == "Current")
    #expect(!service.unavailable)
    service.send(.pause)
    #expect(try currentPipe.fileHandleForReading.read(upToCount: 6) == Data("pause\n".utf8))
    service.helperEnded(current, status: 1)
    #expect(service.unavailable)
}

@MainActor @Test func musicPipeCallbackRunsOffMain() async throws {
    let service = NowPlayingService(observeWorkspace: false)
    let child = Process(), input = Pipe(), output = Pipe()
    service.adopt(child, input: input.fileHandleForWriting)
    let callback = NowPlayingService.pipeReader(owner: service, child: child)
    try output.fileHandleForWriting.write(contentsOf: Data("{\"title\":\"Background\"}\n".utf8))
    let handle = output.fileHandleForReading
    await Task.detached { callback(handle) }.value
    for _ in 0..<50 where service.track == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(service.track?.title == "Background")
    service.helperEnded(child, status: 0)
}

@MainActor @Test func voiceInventoryLargerThanPipeCapacityCompletes() async throws {
    let result = try await SpeechProcess().run(URL(fileURLWithPath: "/usr/bin/head"),
        arguments: ["-c", "262144", "/dev/zero"], timeout: 3)
    #expect(result.count == 262_144)
}

@MainActor @Test func oversizedVoiceInventoryFails() async {
    await #expect(throws: (any Error).self) {
        _ = try await SpeechProcess().run(URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "1100000", "/dev/zero"], timeout: 3)
    }
}

#if !APPSTORE
@Test func readerCollectorPreservesFramesAndRejectsOversizedSentences() {
    let collector = ReaderSpeech.Collector()
    collector.begin(1)
    for _ in 0..<100 { collector.append(1, Data(repeating: 0x42, count: 1024)) }
    #expect(collector.finish(1) == Data(repeating: 0x42, count: 102_400))
    collector.begin(2)
    collector.append(2, Data(repeating: 0, count: 24_000_000))
    collector.append(2, Data([1]))
    collector.append(2, Data([2]))
    #expect(collector.finish(2) == nil)
    collector.begin(3)
    collector.discard(3)
    collector.append(3, Data([1]))
    #expect(collector.finish(3) == nil)
}
#endif

@MainActor @Test func metricsCacheTracksHistoryEditsAndCalendarRollover() {
    let model = AppModel()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = Date(timeIntervalSince1970: 1_780_272_000)
    model.entries = [DictationEntry(date: day, raw: "one two", text: "", note: "",
                                    destination: "", state: .delivered)]
    #expect(model.metrics(at: day, calendar: calendar).words == 2)
    model.entries[0].raw = "one two three"
    #expect(model.metrics(at: day, calendar: calendar).words == 3)
    #expect(model.metrics(at: day, calendar: calendar).days.last?.words == 3)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
    #expect(model.metrics(at: tomorrow, calendar: calendar).days.last?.words == 0)
    model.entries.removeAll()
    #expect(model.metrics(at: tomorrow, calendar: calendar).dictations == 0)
}

@MainActor @Test func metricsCacheAvoidsRepeatedHistoryTokenization() {
    let model = AppModel()
    let now = Date()
    model.entries = (0..<100).map { _ in DictationEntry(date: now,
        raw: String(repeating: "sample words for the metrics benchmark ", count: 5),
        text: "", note: "", destination: "", state: .delivered) }
    let start = ContinuousClock.now
    var uncachedWords = 0
    for _ in 0..<20 { uncachedWords += UsageMetrics(entries: model.entries, now: now).words }
    let uncached = start.duration(to: .now)
    let cachedStart = ContinuousClock.now
    var cachedWords = 0
    for _ in 0..<20 { cachedWords += model.metrics(at: now).words }
    let cached = cachedStart.duration(to: .now)
    #expect(cachedWords == uncachedWords)
    print("Metrics benchmark (100 entries, 20 reads): uncached \(uncached), cached \(cached)")
}

@Test func hookPayloadLimitAppliesToCompleteJSON() throws {
    let normal = Data(#"{"hook_event_name":"Stop"}"#.utf8)
    #expect(HookServer.decodePayload(normal)?["hook_event_name"] as? String == "Stop")
    let oversized = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 1_048_576)])
    #expect(HookServer.decodePayload(oversized) == nil)
    #expect(HookServer.decodePayload(Data("[]".utf8)) == nil)
    #expect(HookServer.decodePayload(Data()) == nil)
}
