import AVFoundation
import Foundation
import Speech
import Testing
@testable import OmniFlowApp

/// Opt-in check that the Siri voice actually says what the reader intends:
/// acronyms as words or letters, numbers, links and units. Runs only when
/// `READER_HARNESS_HELPER` points at the Siri speech helper
/// (scripts/test-reader-pronunciation.sh sets it). No book text is used.
///
/// Acronyms: a spoken word is much shorter than the same letters spelled out,
/// so each term's duration is compared with a forced letter-by-letter reading
/// inside the same carrier sentence. Numbers and links: on-device
/// transcription must contain the expected words.
@MainActor @Test func readerPronunciationHarness() async throws {
    guard let helper = ProcessInfo.processInfo.environment["READER_HARNESS_HELPER"] else { return }
    let voice = ProcessInfo.processInfo.environment["READER_HARNESS_VOICE"] ?? "en-US:fmvoice:female:en-US-G:premium:0"
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-harness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pronunciation = ReaderPronunciation()

    func duration(_ text: String) throws -> Double {
        let file = folder.appendingPathComponent("\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["speak", voice, file.path, "1", "1"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        let audio = try AVAudioFile(forReading: file)
        // Speech span only: trim silence at both ends.
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
        try audio.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        let first = samples.firstIndex { abs($0) > 0.0056 } ?? 0, last = samples.lastIndex { abs($0) > 0.0056 } ?? 0
        return Double(last - first) / audio.processingFormat.sampleRate
    }

    // Intended readings for the most frequent capitalised terms in a technical library.
    let terms = ["IP", "API", "TCP", "HTTP", "DNS", "CPU", "AWS", "URL", "HTML", "SQL", "SSH", "XML", "DLL", "UDP", "TLS", "DHCP",
                 "XSS", "USB", "FTP", "PDF", "RSA", "ICMP", "SNMP", "CVE", "AES", "PID", "ARP", "BSD", "NFS", "GDB", "MBR", "CSRF",
                 "IEEE", "PHP", "SDK", "WMI", "UEFI", "IAM", "VPN", "BGP", "IOC", "EDR", "XDR", "TTP", "KQL", "SOC", "LDAP", "SMB",
                 "RDP", "NTLM", "JWT", "SAML", "CI", "PCA", "SVM", "ROC", "AUC", "MD5", "EC2", "S3",
                 "NASA", "SCUBA", "UNIX", "GNU", "JSON", "ASCII", "POSIX", "YARA", "SIEM", "NIST", "BIOS", "NAT", "RAM", "ROM",
                 "ARM", "ELF", "NULL", "OWASP", "CAPTCHA", "SCADA", "MNIST", "LASSO", "ZIP", "GIMP", "SOAR", "REST", "AJAX", "NATO",
                 "NOTE", "WARNING", "AND", "THE"]
    let carrier = "The next term is %@ in this sentence."
    let base = try duration(String(format: carrier, "it"))
    var passed = 0, failed: [String] = []
    for term in terms {
        let reading = pronunciation.reading(term) ?? term
        let ok: Bool
        var detail = ""
        if ReaderPronunciation.isLetters(reading) || reading == term {
            // Spelled out: the transcript's letters, with letter-name words
            // ("a", "are", "bee") mapped back, give the term again.
            let spoken = ProcessInfo.processInfo.environment["READER_HARNESS_MODE"] == "raw" ? term : reading
            let heard = try await transcribe(String(format: carrier, spoken), helper: helper, voice: voice, folder: folder)
            ok = lettersHeard(heard).contains(term.uppercased())
            let raw = ProcessInfo.processInfo.environment["READER_HARNESS_RAW"] != nil
                ? lettersHeard(try await transcribe(String(format: carrier, term), helper: helper, voice: voice, folder: folder)).contains(term.uppercased()) : nil
            detail = heard + (raw.map { " raw=\($0)" } ?? "")
        } else {
            // Said as a word: transcribed back as that word ("SIEM" read "sim"
            // comes back as "SIM"), or much shorter than its spelling.
            let heard = try await transcribe(String(format: carrier, reading), helper: helper, voice: voice, folder: folder)
            let squeeze = { (text: String) in text.lowercased().filter(\.isLetter) }
            let ours = try duration(String(format: carrier, reading)) - base
            let spelled = try duration(String(format: carrier, ReaderPronunciation.letters(term))) - base
            let ratio = ours / max(0.05, spelled)
            ok = squeeze(heard).contains(squeeze(reading)) || squeeze(heard).contains(squeeze(term)) && ratio <= 1 || ratio <= 0.85
            detail = String(format: "%.2f ", ratio) + heard
        }
        if ok { passed += 1 } else { failed.append("\(term)→\(reading) [\(detail)]") }
    }

    // Numbers, links, units: the transcript must contain these words.
    let phrases: [(String, [String])] = [
        ("Visit https://www.example.com/docs/start today.", ["link", "example"]),
        ("Send it to ops@corp.example.org now.", ["email", "example"]),
        ("Ping 192.168.1.10/24 first.", ["dot", "slash"]),
        ("Upgrade to 3.2.1 now.", ["3.2.1|point"]),
        ("Install v2 today.", ["version"]),
        ("It ran 1990–1995 in total.", ["1990", "1995"]),
        ("See pp. 12–15 for more.", ["pages", "12", "15"]),
        ("Latency was 5 ms at peak.", ["millisecond"]),
        ("The CPU runs at 3.2 GHz.", ["gigahertz"]),
        ("Copy 16 GB of data.", ["gigabyte"]),
        ("Read Chapter IV next.", ["chapter", "4"]),
        ("Henry VIII ruled England.", ["eighth|viii"]),
        ("World War II ended.", ["two|ii|2"]),
        ("Edit /etc/passwd carefully.", ["slash"]),
        ("Pass --verbose to it.", ["dash"]),
        ("Value 0x1F was set.", ["hex"]),
        ("Use it, e.g. today.", ["example"]),
        ("Call getUserName() first.", ["user"]),
        ("Store it in load_config files.", ["config"]),
        ("The hash 9f86d081884c7d659a2feaa0c55ad015 matched.", ["hash"])
    ]
    var phrasePassed = 0
    for (raw, expected) in phrases {
        let spoken = pronunciation.spoken(raw)
        let transcript = try await transcribe(spoken, helper: helper, voice: voice, folder: folder).lowercased()
        // Each expected item may list alternatives ("a|b"): on-device
        // transcription writes "World War Two" back as "World War II".
        let ok = expected.allSatisfy { item in item.split(separator: "|").contains { transcript.contains($0) } }
        if ok { phrasePassed += 1 } else { failed.append("phrase[\(raw.prefix(18))…]→\(transcript)") }
    }
    let total = terms.count + phrases.count, score = Double(passed + phrasePassed) / Double(total)
    print("HARNESS acronyms \(passed)/\(terms.count) phrases \(phrasePassed)/\(phrases.count) score \(String(format: "%.1f%%", score * 100))")
    if !failed.isEmpty { print("HARNESS misses: \(failed.joined(separator: "; "))") }
    #expect(score >= 0.95)
}

/// Letters heard in a transcript: single letters, capitals and letter-name
/// words ("a", "are", "bee", "see", "you") joined up.
private func lettersHeard(_ transcript: String) -> String {
    let names: [String: String] = ["a": "A", "are": "R", "our": "R", "r": "R", "be": "B", "bee": "B", "see": "C", "sea": "C",
        "you": "U", "eye": "I", "i": "I", "why": "Y", "ex": "X", "x": "X", "oh": "O", "o": "O", "pee": "P", "tee": "T", "tea": "T",
        "ess": "S", "em": "M", "en": "N", "el": "L", "ef": "F", "dee": "D", "gee": "G", "jay": "J", "kay": "K", "cue": "Q", "queue": "Q",
        "vee": "V", "zee": "Z", "aitch": "H", "ay": "A"]
    return transcript.split(whereSeparator: { " ,.-".contains($0) }).map { word -> String in
        let w = String(word)
        if let letter = names[w.lowercased()], w.count <= 5 { return letter }
        if w.count == 1, w.first!.isLetter { return w.uppercased() }
        return w.allSatisfy { $0.isUppercase || $0.isNumber } ? w : "·"
    }.joined()
}

/// Letter names, an unambiguous spelled-out reference ("eye oh see").
private func spelledOut(_ token: String) -> String {
    let names: [Character: String] = ["A": "ay", "B": "bee", "C": "see", "D": "dee", "E": "ee", "F": "ef", "G": "jee", "H": "aitch",
        "I": "eye", "J": "jay", "K": "kay", "L": "el", "M": "em", "N": "en", "O": "oh", "P": "pee", "Q": "cue", "R": "ar", "S": "ess",
        "T": "tee", "U": "you", "V": "vee", "W": "double you", "X": "ex", "Y": "why", "Z": "zee"]
    return token.map { names[$0] ?? String($0) }.joined(separator: " ")
}

@MainActor private func transcribe(_ text: String, helper: String, voice: String, folder: URL) async throws -> String {
    let file = folder.appendingPathComponent("\(UUID().uuidString).wav")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helper)
    process.arguments = ["speak", voice, file.path, "1", "1"]
    let input = Pipe()
    process.standardInput = input
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return "" }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let results = Task { () -> String in
        var text = ""
        for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) + " " }
        return text
    }
    let audio = try AVAudioFile(forReading: file)
    try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
    return try await results.value
}
