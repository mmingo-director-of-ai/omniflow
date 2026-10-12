import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Speech recognition seam for the iOS app. The shared recognizer lives in
/// Core; the iOS adapter owns AVAudioSession capture and feeds it.
@MainActor
protocol DictationEngine: AnyObject {
    /// Installs the speech model for `locale` if needed. Throws a user-facing message.
    func prepare(locale: Locale) async throws
    /// Starts recording. `onText` receives the running transcript, `onLevel` 0...1 input level.
    func start(locale: Locale, vocabulary: String, onText: @escaping @MainActor (String) -> Void,
               onLevel: @escaping @MainActor (Float) -> Void) async throws
    /// Stops recording and returns the final transcript.
    func finish() async throws -> String
    func cancel()
}

/// iOS capture → review → Copy/Share workflow (launch plan §9) and its history.
/// Clipboard copies are local-only and expire. Optional iCloud sync shares completed history, which is
/// sealed by the OmniFlow vault in the app container.
@MainActor
final class IOSFlowModel: ObservableObject {
    enum Phase: Equatable { case idle, preparing, recording, finishing, review }

    @Published private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { mirrorToLiveActivity(from: oldValue) } }
    }

    /// Keeps the Lock Screen / Dynamic Island in step with a dictation:
    /// listening → cleaning up → done (with the word count).
    private func mirrorToLiveActivity(from old: Phase) {
        // A keyboard session owns the activity while it's on.
        guard !IOSMicrophone.shared.heldForKeyboard else { return }
        switch phase {
        case .recording:
            OmniFlowLiveActivity.shared.start(translationTargetID.isEmpty ? .dictate : .translate)
        case .finishing:
            OmniFlowLiveActivity.shared.update(.cleaning)
        case .review, .idle:
            guard old == .recording || old == .finishing || old == .preparing else { return }
            let words = UsageMetrics.countWords(polished?.text ?? transcript)
            OmniFlowLiveActivity.shared.end(words: words > 0 ? words : nil)
        case .preparing:
            break
        }
    }
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var message: String?
    @Published private(set) var entries: [DictationEntry] = []
    @Published private(set) var translated: TranslationResult?
    /// The cleaned-up dictation (nil while polishing or when nothing was heard).
    @Published private(set) var polished: CleanupResult?
    /// Streaming cleanup preview shown while polishing.
    @Published private(set) var polishing: String?
    let polisher = IOSPolisher()
    /// Learns from the user's edits of dictation results (same model and store as the Mac).
    lazy var learning = CorrectionLearningModel { [locale] word in UIKitSpellingHints().isKnownWord(word, locale: locale) }
    /// Where a note dictation goes instead of the review screen.
    private var noteSink: ((_ text: String) -> Void)?
    /// True while the current dictation will be added to a note.
    @Published private(set) var dictatingIntoNote = false

    /// Dictates, polishes and hands the text to `deliver` (a note) instead of opening review.
    func dictateIntoNote(_ deliver: @escaping (_ text: String) -> Void) { dictate(destination: "Note", deliver) }

    /// Dictates for another part of the app (a note, the assistant): the polished
    /// text goes to `deliver` and history records `destination`.
    func dictate(destination: String, _ deliver: @escaping (_ text: String) -> Void) {
        noteSink = deliver
        sinkDestination = destination
        dictatingIntoNote = true
        startRecording()
    }
    private var sinkDestination = "Note"
    @Published private(set) var translating = false
    @Published var translationTargetID = UserDefaults.standard.string(forKey: "translationTarget") ?? "" {
        didSet { UserDefaults.standard.set(translationTargetID, forKey: "translationTarget") }
    }
    @Published private(set) var languages: [TranslationLanguage] = []
    /// Same keys as the Mac app.
    @Published var vocabulary = UserDefaults.standard.string(forKey: "vocabulary") ?? "" {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }
    @Published var securityVocabulary = UserDefaults.standard.bool(forKey: VocabularyPack.security.preferenceKey) {
        didSet { UserDefaults.standard.set(securityVocabulary, forKey: VocabularyPack.security.preferenceKey) }
    }
    /// The user's terms plus enabled packs, as on the Mac.
    var effectiveVocabulary: String { DictationVocabulary.current().text }
    @Published var retention = HistoryRetention(rawValue: UserDefaults.standard.object(forKey: "historyRetention") as? Int ?? 30) ?? .thirtyDays {
        didSet {
            UserDefaults.standard.set(retention.rawValue, forKey: "historyRetention")
            Task { await reloadHistory(applyingRetention: true) }
        }
    }

    private let engine: DictationEngine
    private let history: HistoryStore
    private let translation = TranslationService()
    private var current: DictationEntry?
    @Published private(set) var started: Date?
    private var work: Task<Void, Never>?

    /// Copies stay on this device and clear themselves after ten minutes.
    static let copyLifetime: TimeInterval = 600

    init(engine: DictationEngine,
         history: HistoryStore = HistoryStore(directory: NotchLeeStorage.root.appendingPathComponent("Dictations", isDirectory: true))) {
        self.engine = engine
        self.history = history
        Task { await reloadHistory(applyingRetention: true) }
        Task { languages = await translation.supportedLanguages() }
        #if DEBUG
        // Screenshots: `-OmniFlowDemoRecord <seconds>` records the demo passage, stopping after that long.
        let demoSeconds = UserDefaults.standard.double(forKey: "OmniFlowDemoRecord")
        if engine is DemoEngineMarker, demoSeconds > 0 {
            Task {
                try? await Task.sleep(for: .seconds(1))
                startRecording()
                try? await Task.sleep(for: .seconds(demoSeconds))
                stopRecording()
            }
        }
        #endif
    }

    var locale: Locale { Locale.current }

    // MARK: Capture

    func toggleRecording() {
        switch phase {
        case .idle, .review: startRecording()
        case .recording: stopRecording()
        case .preparing, .finishing: break
        }
    }

    func startRecording() {
        guard phase == .idle || phase == .review else { return }
        work?.cancel()
        message = nil; transcript = ""; translated = nil; polished = nil; polishing = nil; level = 0
        phase = .preparing
        work = Task {
            do {
                try await engine.prepare(locale: locale)
                if !IOSMicrophone.shared.heldForKeyboard && !(engine is DemoEngineMarker) { try await AudioSessionController.activateForDictation() }
                try await engine.start(locale: locale, vocabulary: effectiveVocabulary,
                                       onText: { [weak self] text in self?.transcript = text },
                                       onLevel: { [weak self] value in self?.level = value })
                guard !Task.isCancelled else { return }
                started = .now
                polisher.prewarm(locale: locale)
                let entry = DictationEntry(raw: "", text: "", note: "", destination: "", state: .recording)
                current = entry
                phase = .recording
            } catch {
                engine.cancel()
                AudioSessionController.deactivateUnlessHeld()
                phase = .idle
                message = Self.describe(error)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        phase = .finishing
        work = Task {
            let final: String
            do { final = try await engine.finish() } catch { final = transcript; message = Self.describe(error) }
            AudioSessionController.deactivateUnlessHeld()
            level = 0
            transcript = final.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                noteSink = nil; dictatingIntoNote = false
                phase = .idle
                message = message ?? "Nothing was heard. Check the microphone and try again."
                current = nil
                return
            }
            let raw = transcript
            polishing = ""
            let result = await polisher.polish(raw, locale: locale, styles: learning.learnedStyles) { [weak self] preview in self?.polishing = preview }
            polishing = nil
            polished = result
            if let sink = noteSink {
                noteSink = nil; dictatingIntoNote = false
                sink(result.text)
                if var entry = current {
                    entry.raw = raw; entry.text = result.text; entry.note = result.note
                    entry.state = .delivered; entry.destination = sinkDestination
                    entry.durationSeconds = started.map { Date.now.timeIntervalSince($0) }
                    entry.revision += 1
                    await persist(entry)
                }
                current = nil; transcript = ""; polished = nil
                phase = .idle
                return
            }
            if var entry = current {
                entry.raw = raw; entry.text = result.text; entry.note = result.note
                entry.state = .needsCopy
                entry.durationSeconds = started.map { Date.now.timeIntervalSince($0) }
                entry.revision += 1
                current = entry
                await persist(entry)
            }
            phase = .review
            if !translationTargetID.isEmpty { translateTranscript() }
        }
    }

    /// Interrupted or abandoned: keep what was heard so far as a recoverable entry.
    func cancelRecording() {
        noteSink = nil; dictatingIntoNote = false
        work?.cancel()
        engine.cancel()
        AudioSessionController.deactivateUnlessHeld()
        if var entry = current, !transcript.isEmpty {
            entry.raw = transcript; entry.text = transcript; entry.state = .cancelled; entry.revision += 1
            entry.note = "Recording stopped before it finished"
            Task { await persist(entry) }
        }
        current = nil; level = 0
        phase = transcript.isEmpty ? .idle : .review
    }

    func discardReview() {
        phase = .idle; transcript = ""; translated = nil; polished = nil; polishing = nil; current = nil
    }

    // MARK: Translation

    func translateTranscript() {
        guard !translationTargetID.isEmpty, !cleanedText.isEmpty else { translated = nil; return }
        let text = cleanedText, target = translationTargetID
        translating = true
        Task {
            let result = await translate(text, to: target)
            translating = false
            guard text == cleanedText else { return }
            translated = result
            if var entry = current, result.didTranslate {
                entry.text = result.text; entry.note = result.note; entry.revision += 1
                current = entry
                await persist(entry)
            }
        }
    }

    func translate(_ text: String, to target: String) async -> TranslationResult {
        let source = Locale.Language(identifier: PremiumSpeechVoices.language(of: text) ?? locale.language.minimalIdentifier)
        return await translation.translate(text, source: source, target: Locale.Language(identifier: target))
    }

    /// Text the review shows and Copy/Share send: the translation when there is one.
    /// The polished text, or the raw transcript until/unless cleanup produced one.
    var cleanedText: String { polished?.text ?? transcript }

    var output: String { translated?.didTranslate == true ? translated!.text : cleanedText }

    // MARK: Output

    func copy(_ text: String, entryID: UUID? = nil) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(Self.copyLifetime)])
        message = "Copied. Paste it where you need it within ten minutes."
        markDelivered(entryID ?? current?.id, destination: "Copied")
    }

    func markDelivered(_ id: UUID?, destination: String) {
        guard let id else { return }
        let entry = current?.id == id ? current : entries.first { $0.id == id }
        guard var entry else { return }
        entry.state = .delivered; entry.destination = destination; entry.revision += 1
        if current?.id == id { current = entry }
        Task { await persist(entry) }
    }

    func clearMessage() { message = nil }

    /// The dictation on the review screen, for editing.
    var currentEntryID: UUID? { current?.id }

    /// Saves a dictation made from the OmniFlow keyboard.
    func recordKeyboardDictation(raw: String, text: String, duration: TimeInterval?) {
        let entry = DictationEntry(raw: raw, text: text, note: "", destination: "Keyboard",
                                   state: .delivered, revision: 1, durationSeconds: duration)
        Task { await persist(entry) }
    }

    /// True while an in-app dictation owns the recognizer.
    var isDictating: Bool { phase == .preparing || phase == .recording || phase == .finishing }

    // MARK: History

    func reloadHistory(applyingRetention: Bool = false) async {
        if applyingRetention {
            if retention != .forever {
                learning.removePairs(olderThan: Date().addingTimeInterval(-Double(retention.rawValue) * 86_400))
            }
            _ = try? await history.applyRetention(retention, excludingIDs: Set([current?.id].compactMap { $0 }))
        }
        do {
            let loaded = try await history.load()
            entries = loaded.entries
            if loaded.unreadableCount > 0 {
                message = "\(loaded.unreadableCount) saved \(loaded.unreadableCount == 1 ? "dictation" : "dictations") couldn't be opened. They're kept on disk unchanged."
            }
        } catch {
            message = "History couldn't be loaded: " + error.localizedDescription
        }
    }

    /// Saves the user's correction of a dictation result; learning sees raw, cleaned and final text.
    func edit(_ id: UUID, to text: String) {
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty, var entry = current?.id == id ? current : entries.first(where: { $0.id == id }),
              final != entry.displayText else { return }
        learning.record(entryID: id, raw: entry.raw, cleaned: entry.displayText, final: final)
        entry.text = final; entry.note = "Edited"; entry.revision += 1
        if current?.id == id {
            current = entry
            polished = CleanupResult(text: final, note: "Edited")
            translated = nil
            if !translationTargetID.isEmpty { translateTranscript() }
        }
        Task { await persist(entry) }
    }

    func delete(_ ids: [UUID]) {
        ids.forEach { learning.removePair(entryID: $0) }
        entries.removeAll { ids.contains($0.id) }
        Task { try? await history.moveToTrash(ids: ids) }
    }

    private func persist(_ entry: DictationEntry) async {
        do { try await history.save(entry) } catch { message = "This dictation couldn't be saved to history." }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else if entry.state != .recording { entries.insert(entry, at: 0) }
    }

    private static func describe(_ error: Error) -> String {
        if case AudioSessionController.Failure.microphoneDenied = error {
            return "OmniFlow needs the microphone. Allow it in Settings › Privacy & Security › Microphone."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension HistoryRetention {
    var title: String {
        switch self {
        case .forever: "Keep forever"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        }
    }
}
