import AVFoundation
import Foundation
import Speech

public struct DictationRecognizerError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// The platform-neutral half of dictation: Apple's SpeechTranscriber, its on-device assets,
/// the analyzer lifecycle and the transcript. A platform adapter owns the microphone and
/// feeds `Input.continuation` with buffers already converted to `Input.format`.
@MainActor
public final class DictationRecognizer {
    /// Where the platform capture adapter sends audio.
    public struct Input: Sendable {
        public let format: AVAudioFormat
        public let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: (any SpeechModule)?
    public enum Backend: String, Sendable { case speech, dictationFallback }
    public private(set) var backend: Backend?
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var generation = UUID()
    private var preparation = UUID()
    private var buffer = TranscriptBuffer()
    public private(set) var locale = Locale(identifier: "en-US")
    public private(set) var isPrepared = false
    public var text: String { buffer.text }
    /// The analyzer's audio format, known after `prepare`, so capture can open
    /// before the analyzer is ready.
    public private(set) var inputFormat: AVAudioFormat?
    private var pendingStream: AsyncThrowingStream<AnalyzerInput, Error>?

    public init() {}

    /// Match FreeFlow's progressive, on-device recognition backend.
    public nonisolated static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    private nonisolated static func makeFallback(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [],
                             transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    /// Contextual strings for recognition: the user's dictionary plus product names.
    public nonisolated static func contextualStrings(vocabulary: String) -> [String] {
        let builtIn = ["OmniFlow", "Omni", "Claude Code", "Codex", "Gemini CLI", "Antigravity", "MCP", "Atlas", "SpeechTranscriber", "DictationTranscriber"]
        let user = vocabulary.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 60 }
        var seen = Set<String>()
        return (user + builtIn).filter { seen.insert($0.lowercased()).inserted }.prefix(200).map { $0 }
    }

    public func prepare(locale: Locale, download: Bool) async throws {
        guard analyzer == nil, pendingStream == nil else { throw DictationRecognizerError("Stop recording before changing the speech language.") }
        let requestToken = UUID(); preparation = requestToken
        isPrepared = false
        let supported: Locale
        let selectedBackend: Backend
        let module: any SpeechModule
        if SpeechTranscriber.isAvailable,
           let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            supported = speechLocale; selectedBackend = .speech
            module = Self.makeTranscriber(locale: supported)
        } else if let fallbackLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            supported = fallbackLocale; selectedBackend = .dictationFallback
            module = Self.makeFallback(locale: supported)
        } else {
            throw DictationRecognizerError("Apple speech recognition does not support this language on this device.")
        }
        let status = await AssetInventory.status(forModules: [module])
        if status != .installed {
            guard download else { throw DictationRecognizerError("Download the speech model in Setup first.") }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw DictationRecognizerError("The speech model is not ready yet. Try Prepare again.")
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        try Task.checkCancellation()
        guard preparation == requestToken else { throw CancellationError() }
        guard let format else { throw DictationRecognizerError("No compatible speech audio format is available.") }
        self.locale = supported; backend = selectedBackend; inputFormat = format; isPrepared = true
    }

    /// Starts the analyzer and returns where to send audio. `cancel()` from another task
    /// makes a pending start throw `CancellationError`.
    public func start(vocabulary: String = "",
                      onText: @escaping @MainActor (String) -> Void,
                      onError: @escaping @MainActor (String) -> Void) async throws -> Input {
        let input = try await makeInput()
        try await startAnalyzer(vocabulary: vocabulary, onText: onText, onError: onError)
        return input
    }

    /// Where to send audio, available at once when `prepare` has run: the capture
    /// adapter can open the microphone while `startAnalyzer` prepares in parallel.
    /// Audio is buffered (about 20 s) until the analyzer consumes it, so no words are lost.
    public func makeInput() async throws -> Input {
        guard isPrepared else { throw DictationRecognizerError("Prepare a speech language in Setup first.") }
        guard analyzer == nil, pendingStream == nil else { throw DictationRecognizerError("A recording is already active.") }
        try Task.checkCancellation()
        guard let format = inputFormat else { throw DictationRecognizerError("No compatible speech audio format is available. Prepare the language again.") }
        generation = UUID(); buffer = TranscriptBuffer()
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        self.continuation = continuation; pendingStream = stream
        return Input(format: format, continuation: continuation)
    }

    /// Prepares and starts the analyzer on the stream from `makeInput`.
    public func startAnalyzer(vocabulary: String = "",
                              onText: @escaping @MainActor (String) -> Void,
                              onError: @escaping @MainActor (String) -> Void) async throws {
        guard let stream = pendingStream, let format = inputFormat, let backend else { throw DictationRecognizerError("Open the input first.") }
        pendingStream = nil
        let token = generation
        let module: any SpeechModule
        let readResults: @MainActor () -> Task<Void, Error>
        switch backend {
        case .speech:
            let speech = Self.makeTranscriber(locale: locale)
            module = speech
            readResults = { [weak self] in
                Task { [weak self] in
                    do {
                        for try await result in speech.results {
                            guard let self, self.generation == token, !Task.isCancelled else { return }
                            self.buffer.receive(String(result.text.characters), isFinal: result.isFinal)
                            onText(self.buffer.text)
                        }
                    } catch {
                        if let self, self.generation == token, !Task.isCancelled { onError(error.localizedDescription) }
                        throw error
                    }
                }
            }
        case .dictationFallback:
            let fallback = Self.makeFallback(locale: locale)
            module = fallback
            readResults = { [weak self] in
                Task { [weak self] in
                    do {
                        for try await result in fallback.results {
                            guard let self, self.generation == token, !Task.isCancelled else { return }
                            self.buffer.receive(String(result.text.characters), isFinal: result.isFinal)
                            onText(self.buffer.text)
                        }
                    } catch {
                        if let self, self.generation == token, !Task.isCancelled { onError(error.localizedDescription) }
                        throw error
                    }
                }
            }
        }
        let session = SpeechAnalyzer(modules: [module])
        let context = AnalysisContext()
        context.contextualStrings[.general] = Self.contextualStrings(vocabulary: vocabulary)
        // Publish ownership before suspending: cancellation must see this analyzer,
        // and a stale setContext completion must not replace a newer session.
        transcriber = module; analyzer = session
        try await session.setContext(context)
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        try await session.prepareToAnalyze(in: format)
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        resultsTask = readResults()
        try await session.start(inputSequence: stream)
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }

    /// Ends the input and returns the final transcript. Stop the capture adapter first.
    public func finish() async throws -> String {
        let token = generation
        let finishingAnalyzer = analyzer, finishingResults = resultsTask
        continuation?.finish(); continuation = nil
        if let finishingAnalyzer { try await finishingAnalyzer.finalizeAndFinishThroughEndOfInput() }
        try await finishingResults?.value
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        resultsTask = nil; analyzer = nil; transcriber = nil
        return buffer.text
    }

    /// Abandons the session at once. Returns the analyzer teardown, which the caller runs
    /// after releasing its microphone.
    public func cancel() -> @Sendable () async -> Void {
        generation = UUID()
        continuation?.finish(); continuation = nil; pendingStream = nil
        resultsTask?.cancel(); resultsTask = nil
        let old = analyzer
        analyzer = nil; transcriber = nil
        return { await old?.cancelAndFinishNow() }
    }
}
