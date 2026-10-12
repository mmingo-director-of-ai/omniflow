import Darwin
import Foundation
import Testing
@testable import OmniFlowApp

/// Opt-in headless soak of the real ReaderController: plays a book through
/// the reader's own Siri helper and audio engine (muted) for
/// `READER_SOAK_MINUTES`, with pauses, an idle teardown, a route change, a
/// voice-setting change and a restart, and reports counts and timings only.
/// scripts/test-reader-soak.sh sets the environment. Never prints book text.
@MainActor @Test func readerSoak() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let assetID = env["READER_SOAK_ASSET"], let helper = env["READER_SOAK_HELPER"] else { return }
    let minutes = Double(env["READER_SOAK_MINUTES"] ?? "30") ?? 30
    let voice = SiriVoice(id: env["READER_SOAK_VOICE"] ?? "en-US:fmvoice:female:en-US-G:premium:0", name: "", language: "en-US")
    let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent("reader-soak-\(UUID().uuidString)/positions.json")
    defer { try? FileManager.default.removeItem(at: storeFile.deletingLastPathComponent()) }
    var rate = Double(env["READER_SOAK_RATE"] ?? "1.0") ?? 1.0
    func host() -> ReaderController.Host {
        ReaderController.Host(voice: { voice }, refreshVoice: {}, rate: { rate }, setRate: { rate = $0 }, pitch: { 1.0 },
                              setReaderSpeaking: { _ in }, helper: URL(fileURLWithPath: helper),
                              store: ReaderPositionStore(file: storeFile), integrates: false, muted: env["READER_SOAK_AUDIBLE"] == nil)
    }
    let book = try #require(try ReaderLibrary.books().first { $0.id == assetID })
    let reader = ReaderController(host: host())
    reader.open(book, autoplay: true)
    let start = Date()
    var playing = 0.0, lastTick = Date()
    var events: [String] = []
    // CPU seconds and resident memory from the kernel (no subprocess):
    // this process, and the reader's speech helper.
    var lastCPU: (mine: Double, helper: Double, at: Date) = (0, 0, Date())
    func usage(_ pid: Int32) -> (cpu: Double, rss: UInt64)? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        return (Double(info.ri_user_time + info.ri_system_time) / 1e9, info.ri_resident_size)
    }
    func cpu() -> String {
        let me = ProcessInfo.processInfo.processIdentifier
        var helperPID: Int32 = 0
        var pids = [Int32](repeating: 0, count: 64)
        let count = proc_listchildpids(me, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, 256)
            if String(cString: name).contains("NotchLeeSpeech") { helperPID = pid }
        }
        let now = Date(), mine = usage(me), helper = helperPID > 0 ? usage(helperPID) : nil
        let span = max(1, now.timeIntervalSince(lastCPU.at))
        defer { lastCPU = (mine?.cpu ?? 0, helper?.cpu ?? 0, now) }
        return String(format: "cpu_self=%.1f%% rss_self=%dMB cpu_helper=%.1f%% rss_helper=%dMB",
                      100 * ((mine?.cpu ?? 0) - lastCPU.mine) / span, Int((mine?.rss ?? 0) / 1_048_576),
                      100 * ((helper?.cpu ?? 0) - lastCPU.helper) / span, Int((helper?.rss ?? 0) / 1_048_576))
    }
    _ = cpu()
    var did = Set<String>()
    var lastReport = 0.0
    while Date().timeIntervalSince(start) < minutes * 60 {
        try await Task.sleep(for: .seconds(1))
        let now = Date(), t = now.timeIntervalSince(start)
        if reader.status == .playing { playing += now.timeIntervalSince(lastTick) }
        lastTick = now
        func once(_ name: String, at seconds: Double, _ action: () -> Void) {
            if t >= seconds, !did.contains(name) { did.insert(name); events.append(String(format: "%@@%.0fs idx=%d", name, t, reader.index)); action() }
        }
        once("dictation-pause", at: 120) { reader.pause(.dictation) }
        once("dictation-resume", at: 128) { reader.play() }
        once("rate-1.2", at: 240) { rate = 1.2 }
        once("rate-back", at: 360) { rate = Double(env["READER_SOAK_RATE"] ?? "1.0") ?? 1.0 }
        once("route-change", at: 480) { reader.routeChanged() }
        once("skip-back-paragraph", at: 540) { reader.skipParagraph(-1) }
        once("idle-pause", at: 600) { reader.pause(.user) }
        once("idle-resume", at: 680) { reader.play() }   // after the 60 s teardown
        if t - lastReport >= 120 {
            lastReport = t
            let s = reader.stats
            defer { fflush(stdout) }
            print(String(format: "SOAK t=%.0fs status=%@ idx=%d/%d sentences=%d underruns=%d wait=%.1fs audio=%.0fs playing=%.0fs drift=%.1fs %@",
                         t, "\(reader.status)", reader.index, reader.order.count, s.sentences, s.underruns, s.underrunSeconds, s.audioSeconds, playing,
                         playing - s.audioSeconds, cpu()))
        }
        if case .failed = reader.status { break }
    }
    let s = reader.stats
    let before = reader.index
    print(String(format: "SOAK end status=%@ sentences=%d underruns=%d wait=%.2fs audio=%.0fs playing=%.0fs drift=%.1fs (%.2f%%) events=%@",
                 "\(reader.status)", s.sentences, s.underruns, s.underrunSeconds, s.audioSeconds, playing, playing - s.audioSeconds,
                 100 * (playing - s.audioSeconds) / max(1, playing), events.joined(separator: ",")))
    // Restart: a new controller with the same store resumes at the same sentence.
    reader.pause(.user)
    reader.close()
    try await Task.sleep(for: .seconds(2))
    let again = ReaderController(host: host())
    again.open(book, autoplay: false)
    for _ in 0..<60 where again.status != .ready { try await Task.sleep(for: .milliseconds(250)) }
    let resumed = again.index
    print("SOAK restart resumed=\(resumed == before) index=\(resumed) expected=\(before) note=\(again.startNote ?? "-")")
    again.close()
    #expect(s.underruns <= max(2, s.sentences / 100))
    #expect(resumed == before)
}
