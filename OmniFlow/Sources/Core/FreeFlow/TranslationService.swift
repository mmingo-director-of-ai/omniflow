import Foundation
import SwiftUI
// Apple's TranslationSession SDK reference predates Sendable annotations.
// Keep session ownership within this service and use its supported cancel API.
@preconcurrency import Translation
import Combine
import os

/// User-facing wording shared across platforms.
#if os(macOS)
private let deviceName = "Mac"
#else
private let deviceName = "device"
#endif

struct TranslationLanguage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct TranslationResult {
    let text: String
    let note: String
    let didTranslate: Bool
}

/// The plain-string Translation API cannot promise preservation of code or chart payloads.
/// Reject the whole request before querying Apple or creating a session.
enum TranslationInputPolicy {
    static let maximumCharacters = 5000
    static func preservationReason(for text: String) -> String? {
        if text.count > maximumCharacters { return "Original preserved · translation is limited to 5,000 characters" }
        if text.contains("`") || text.contains("~~~") {
            return "Original preserved · translation skips code and chart markup to protect exact content"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Nothing to translate" }
        return nil
    }
}

@MainActor
final class TranslationService {
    nonisolated func supportedLanguages() async -> [TranslationLanguage] {
        await LanguageAvailability().supportedLanguages.map {
            TranslationLanguage(id: $0.minimalIdentifier, name: Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    enum Status: Equatable {
        case sameLanguage, installed, needsDownload, unsupported
        var message: String {
            switch self {
            case .sameLanguage: "Source and output language are the same"
            case .installed: "Translation ready on this " + deviceName
            case .needsDownload: "Prepare these languages before translating"
            case .unsupported: "Apple Translation does not support this language pair"
            }
        }
    }
    func status(source: Locale.Language, target: Locale.Language) async -> Status {
        if source.isEquivalent(to: target) { return .sameLanguage }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
    func translate(_ original: String, source: Locale.Language, target: Locale.Language) async -> TranslationResult {
        func preserved(_ note: String) -> TranslationResult { .init(text: original, note: note, didTranslate: false) }
        guard !Task.isCancelled else { return preserved("Original preserved · translation cancelled") }
        if let reason = TranslationInputPolicy.preservationReason(for: original) { return preserved(reason) }
        let availability = await status(source: source, target: target)
        guard availability == .installed else { return preserved("Original preserved · " + availability.message) }
        // This initializer cannot prompt or download. Setup happens only in TranslationSetupView.
        let session = TranslationSession(installedSource: source, target: target)
        let warm = await TranslationWarmup.shared.isWarm(source: source, target: target)
        let started = Date()
        let interval = TranslationWarmup.signposter.beginInterval("Translate", id: TranslationWarmup.signposter.makeSignpostID())
        defer { TranslationWarmup.signposter.endInterval("Translate", interval) }
        do {
            try Task.checkCancellation()
            let response = try await withTaskCancellationHandler {
                try await session.translate(original)
            } onCancel: {
                session.cancel()
            }
            await TranslationWarmup.shared.markWarm(source: source, target: target)
            let milliseconds = String(Int(Date().timeIntervalSince(started) * 1000))
            Task { await LocalTelemetry.shared.span("translation.translate", start: started,
                                                     attributes: ["warm": String(warm), "duration.ms": milliseconds]) }
            try Task.checkCancellation()
            guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return preserved("Original preserved · translation returned no text")
            }
            return .init(text: response.targetText, note: "Translated on your " + deviceName, didTranslate: true)
        } catch {
            session.cancel()
            return preserved(Task.isCancelled ? "Original preserved · translation cancelled" : "Original preserved · translation failed; check language setup")
        }
    }
}

/// Apple loads a translation model on a process's first translation (~3.5 s
/// measured), after which new sessions are fast. Warm installed pairs in the
/// background with a throwaway sentence. Never downloads: only installed pairs
/// are touched, through the installed-only session initializer. Requests are
/// coalesced; only the latest pair is warmed after the one in flight.
actor TranslationWarmup {
    static let shared = TranslationWarmup()
    nonisolated static let signposter = OSSignposter(subsystem: "com.mengohlabs.NotchLee", category: "TranslationLatency")
    private var warmed = Set<String>()
    private var pending: (source: Locale.Language, target: Locale.Language)?
    private var running = false

    private static func key(_ source: Locale.Language, _ target: Locale.Language) -> String {
        source.minimalIdentifier + ">" + target.minimalIdentifier
    }

    func isWarm(source: Locale.Language, target: Locale.Language) -> Bool { warmed.contains(Self.key(source, target)) }
    func markWarm(source: Locale.Language, target: Locale.Language) { warmed.insert(Self.key(source, target)) }

    nonisolated func request(source: Locale.Language, target: Locale.Language) {
        Task(priority: .utility) { await self.enqueue(source, target) }
    }

    private func enqueue(_ source: Locale.Language, _ target: Locale.Language) async {
        pending = (source, target)
        guard !running else { return }
        running = true
        while let next = pending {
            pending = nil
            await warm(next.source, next.target)
        }
        running = false
    }

    private func warm(_ source: Locale.Language, _ target: Locale.Language) async {
        guard !source.isEquivalent(to: target), !warmed.contains(Self.key(source, target)),
              await LanguageAvailability().status(from: source, to: target) == .installed else { return }
        let started = Date()
        let interval = Self.signposter.beginInterval("Translation warm-up", id: Self.signposter.makeSignpostID())
        let session = TranslationSession(installedSource: source, target: target)
        let succeeded = (try? await session.translate("Hello.")) != nil
        Self.signposter.endInterval("Translation warm-up", interval)
        if succeeded { warmed.insert(Self.key(source, target)) }
        await LocalTelemetry.shared.span("translation.warmup", start: started, success: succeeded,
            attributes: ["duration.ms": String(Int(Date().timeIntervalSince(started) * 1000))])
    }
}

/// Attaching this view does not request a download; only its explicit button does.
struct TranslationSetupView: View {
    let sourceIdentifier: String
    let targetIdentifier: String
    @StateObject private var state = SetupState()
    @MainActor private final class SetupState: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
        @Published var status: TranslationService.Status?
        @Published var note = "Checking language availability…"
        @Published var preparing = false
        var generation = UUID()
    }
    private var pair: String { sourceIdentifier + ">" + targetIdentifier }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.note).font(.caption).foregroundStyle(.secondary)
            if state.status == .needsDownload {
                Button(state.preparing ? "Preparing…" : "Prepare translation languages") {
                    state.preparing = true
                    state.configuration = .init(source: Locale.Language(identifier: sourceIdentifier), target: Locale.Language(identifier: targetIdentifier))
                }.disabled(state.preparing)
            }
            Text("Translations run on this " + deviceName + ". Preparing languages may require an Apple download.").font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: pair) {
            state.generation = UUID()
            state.configuration = nil; state.preparing = false
            let result = await TranslationService().status(source: Locale.Language(identifier: sourceIdentifier), target: Locale.Language(identifier: targetIdentifier))
            guard !Task.isCancelled else { return }
            state.status = result; state.note = result.message
        }
        .translationTask(state.configuration) { session in
            let token = state.generation
            do {
                try await session.prepareTranslation()
                guard !Task.isCancelled, state.generation == token else { return }
                state.status = .installed; state.note = "Translation ready on this " + deviceName
            } catch {
                guard state.generation == token else { return }
                state.note = "Language preparation did not finish. You can try again."
            }
            guard state.generation == token else { return }
            state.preparing = false; state.configuration = nil
        }
    }
}
