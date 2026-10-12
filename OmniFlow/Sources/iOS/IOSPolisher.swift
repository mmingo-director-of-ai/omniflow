import Foundation

/// The Mac's dictation cleanup on iOS: phrase replacements first, then the
/// shared on-device DictationCleanup with the same polish mode, writing style
/// and output style preferences (same keys as the Mac), under a deadline that
/// falls back to basic cleanup so the user always gets their words.
@MainActor
final class IOSPolisher {
    private let cleanup = DictationCleanup.onDevice()

    var mode: PolishMode {
        PolishMode(rawValue: UserDefaults.standard.string(forKey: "polishMode") ?? "") ?? .polished
    }
    private var writingStyle: WritingStyle {
        WritingStyle(rawValue: UserDefaults.standard.string(forKey: "writingStyle") ?? "apa") ?? .apa
    }
    private var structured: Bool { (UserDefaults.standard.string(forKey: "outputStyle") ?? "natural") == "markdown" }

    /// Loads the model while the user is still speaking.
    func prewarm(locale: Locale) {
        cleanup.prewarm(locale: locale, structured: structured, writingStyle: writingStyle, mode: mode)
    }

    /// Mac deadline: 25 s plus 1 s per 25 words (10 s base for light cleanup), capped.
    static func deadline(words: Int, mode: PolishMode) -> Duration {
        .seconds((mode == .polished ? 25 : 10) + min(35, words / 25))
    }

    /// `styles`: style preferences learned from the user's edits.
    func polish(_ raw: String, locale: Locale, styles: [String] = [], onPreview: @escaping (String) -> Void = { _ in }) async -> CleanupResult {
        cleanup.stylePreferences = styles
        let vocabulary = DictationVocabulary.current()
        let replaced = PhraseReplacements.apply(raw, rules: vocabulary.replacementRules)
        let mode = self.mode
        guard mode != .verbatim else {
            return CleanupResult(text: replaced, note: replaced == raw ? "Original transcript · verbatim" : "Verbatim · custom replacements applied")
        }
        let words = raw.split(whereSeparator: \.isWhitespace).count
        let fallback = DictationCleanup.fallback(replaced, locale: locale, reason: "cleanup timed out", mode: mode)
        // Whichever finishes first wins; a late cleanup is cancelled and ignored.
        return await withCheckedContinuation { (continuation: CheckedContinuation<CleanupResult, Never>) in
            var resumed = false
            func finish(_ result: CleanupResult) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            let cleaning = Task { @MainActor in
                let result = await cleanup.clean(replaced, locale: locale, vocabulary: vocabulary.text, structured: structured,
                                                 writingStyle: writingStyle, mode: mode, onPreview: onPreview)
                finish(result)
            }
            Task { @MainActor in
                try? await Task.sleep(for: Self.deadline(words: words, mode: mode))
                cleaning.cancel()
                finish(fallback)
            }
        }
    }
}
