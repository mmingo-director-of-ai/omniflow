#if DEBUG
import Foundation

/// Debug-only engine for screenshots and UI work without a microphone:
/// launch with `-OmniFlowDemo YES`. It "hears" a fixed passage word by word and
/// drives a synthetic voice spectrum. Never compiled into Release.
@MainActor
final class DemoDictationEngine: DictationEngine, DemoEngineMarker {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "OmniFlowDemo") }
    private static let passage = "Let's move the design review to Thursday afternoon, and ask Priya to bring the new onboarding flow. I want the dictation screen to feel alive while people talk, not static."
    private var task: Task<Void, Never>?
    private var heard = ""

    func prepare(locale: Locale) async throws {}

    func start(locale: Locale, vocabulary: String, onText: @escaping @MainActor (String) -> Void,
               onLevel: @escaping @MainActor (Float) -> Void) async throws {
        heard = ""
        IOSMicrophone.shared.demoActive = true
        task = Task {
            for word in Self.passage.split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 180...420)))
                guard !Task.isCancelled else { return }
                heard += (heard.isEmpty ? "" : " ") + word
                onText(heard)
            }
        }
    }

    func finish() async throws -> String {
        task?.cancel(); IOSMicrophone.shared.demoActive = false
        try? await Task.sleep(for: .milliseconds(400))
        return heard
    }

    func cancel() { task?.cancel(); IOSMicrophone.shared.demoActive = false }
}
#endif

/// Engines that don't use the real microphone (the debug demo).
protocol DemoEngineMarker {}
