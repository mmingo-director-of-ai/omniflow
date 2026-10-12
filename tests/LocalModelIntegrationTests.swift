import AppKit
import FoundationModels

@main
enum LocalModelIntegrationTests {
    @MainActor static func main() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            print("On-device model unavailable; integration checks skipped.")
            return
        }
        UserDefaults.standard.setVolatileDomain(["localTelemetryEnabled": false], forName: UserDefaults.argumentDomain)
        // Standalone invocation: <image path> <bundled NotchLeeAtlas> <atlas-sdk.lock.json>.
        // The application resolves these from its bundle; a CLI test must supply them.
        let helper = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : AtlasBridge.helperURL
        let identity = CommandLine.arguments.count > 3
            ? try JSONDecoder().decode(AtlasBuildIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
            : AtlasBridge.buildIdentity
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchlee-model-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try Data("The release label is tangerine. The review has three pending checks.".utf8).write(to: file)
        let empty = VoiceSessionContext(sessions: [], focusedID: nil)
        var updates = 0
        let fileAnswer = try await AtlasAssistant.answer("Read the local text file \(file.path). What is the release label?", context: empty, cursorContext: nil,
            executable: helper, identity: identity) { _ in updates += 1 }
        precondition(fileAnswer.localizedCaseInsensitiveContains("tangerine"), "Local-file tool answer failed: \(fileAnswer)")
        precondition(updates > 0, "No streamed response arrived")
        print("Local model read a file through its tool and streamed the answer using the on-device model: passed")
        let cursor = CursorContext(capturedAt: .now, app: "Test", bundleID: "local.test", window: "Note", role: "AXTextArea", label: "Text", selectedText: "HTTP 404 means the requested resource could not be found.")
        let answer = try await AtlasAssistant.answer("Explain the text I selected.", context: empty, cursorContext: cursor.modelData(), executable: helper, identity: identity)
        precondition(answer.contains("404"), "Selected context was not used")
        print("Cursor selection answer: passed")
        if #available(macOS 27.0, *) {
            let image = await LocalImageDescription.read(path: CommandLine.arguments[1], question: "Describe the animals in this illustration.")
            precondition(image.contains("On-device image description"), "Image model unavailable: \(image)")
            precondition(image.localizedCaseInsensitiveContains("panda") || image.localizedCaseInsensitiveContains("fox"), "Unexpected image answer: \(image)")
            print("On-device image understanding using the on-device model: passed")
        }
    }
}
