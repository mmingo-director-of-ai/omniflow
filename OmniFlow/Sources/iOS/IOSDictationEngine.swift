import AVFoundation

/// iOS dictation: Core's shared DictationRecognizer (the same engine as the
/// Mac) fed by the iOS microphone.
@MainActor
final class IOSDictationEngine: DictationEngine {
    private let recognizer = DictationRecognizer()
    private var preparedLocale: Locale?

    func prepare(locale: Locale) async throws {
        if recognizer.isPrepared, preparedLocale == locale { return }
        try await recognizer.prepare(locale: locale, download: true)
        preparedLocale = locale
    }

    func start(locale: Locale, vocabulary: String, onText: @escaping @MainActor (String) -> Void,
               onLevel: @escaping @MainActor (Float) -> Void) async throws {
        try await prepare(locale: locale)
        let input = try await recognizer.start(vocabulary: vocabulary, onText: onText, onError: { _ in })
        do {
            try IOSMicrophone.shared.open()
            try IOSMicrophone.shared.attach(format: input.format, continuation: input.continuation) { value in
                Task { @MainActor in onLevel(value) }
            }
        } catch {
            await recognizer.cancel()()
            throw error
        }
    }

    func finish() async throws -> String {
        IOSMicrophone.shared.releaseIfUnheld()
        return try await recognizer.finish()
    }

    func cancel() {
        IOSMicrophone.shared.releaseIfUnheld()
        let teardown = recognizer.cancel()
        Task { await teardown() }
    }
}
