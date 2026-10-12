import AppKit
import SwiftUI

/// The FreeFlow interface runs inside the existing OmniFlow app and identity.
@MainActor
enum OmniFlowVoiceMigration {
    static func preparePreferences() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "omniflow.freeflowPreferences.v1") else { return }
        let legacy = defaults.persistentDomain(forName: "local.freeflow.mac") ?? [:]
        let keys = ["followFocus", "outputStyle", "writingStyle", "translationTarget", "historyRetention",
                    "typingWPM", "liveText", "openHub", "recordingLimit", "locale", "polishMode", "cleanup",
                    "reduceBackgroundNoise", "vocabulary", "applicationProfiles", "phraseReplacements"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        if defaults.object(forKey: "omniflow.appearance") == nil {
            defaults.set(legacy["appearance"] as? String ?? "dark", forKey: "omniflow.appearance")
        }
        if defaults.object(forKey: "locale") == nil,
           let locale = defaults.string(forKey: "omniflow.dictation.locale"), !locale.isEmpty {
            defaults.set(locale, forKey: "locale")
        }
        defaults.set(true, forKey: "omniflow.freeflowPreferences.v1")
    }

    static func importHistory(into store: HistoryStore) async throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "omniflow.freeflowHistory.v1") else { return }
        let fm = FileManager.default
        let existing = try await store.load()
        var ids = Set(existing.entries.map(\.id))
        let original = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeFlow/Transcripts", isDirectory: true)
        if fm.fileExists(atPath: original.path) {
            for file in try fm.contentsOfDirectory(at: original, includingPropertiesForKeys: [.fileSizeKey]) where file.pathExtension == "json" {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) < 12_000_000,
                      let entry = try? JSONDecoder().decode(DictationEntry.self, from: Data(contentsOf: file)) else { continue }
                if ids.insert(entry.id).inserted { try await store.save(entry) }
            }
        }
        let prototype = NotchLeeStorage.root.appendingPathComponent("dictations.json")
        if fm.fileExists(atPath: prototype.path) {
            struct Legacy: Decodable {
                let id: UUID; let date: Date; let text: String; let recordingSeconds: Double; let isPartial: Bool?
            }
            let rows = try JSONDecoder().decode([Legacy].self, from: Data(contentsOf: prototype))
            for row in rows where ids.insert(row.id).inserted {
                try await store.save(.init(id: row.id, date: row.date, raw: row.text, text: row.text,
                    note: row.isPartial == true ? "Recovered partial dictation" : "Imported OmniFlow dictation",
                    destination: "", state: row.isPartial == true ? .cancelled : .needsCopy, durationSeconds: row.recordingSeconds))
            }
        }
        // Sources stay intact. A successful one-time import never changes the other app.
        defaults.set(true, forKey: "omniflow.freeflowHistory.v1")
    }
}

extension WorkspaceSection {
    var flowPage: String {
        switch self {
        case .dictation: "Home"
        case .history: "Recent"
        default: rawValue
        }
    }
}

/// Compact presentation of the same FreeFlow session when the island is used.
struct OmniFlowDictationView: View {
    var historyOnly = false
    @ObservedObject private var model = AppModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(historyOnly ? "Dictation history" : "Dictation", symbol: historyOnly ? "clock.arrow.circlepath" : OmniFlowSymbol.dictate)
                    .font(.title3.weight(.semibold))
                Text(model.status).foregroundStyle(.secondary)
                if !model.transcript.isEmpty { Text(model.transcript).textSelection(.enabled) }
                HStack {
                    if model.phase == .recording { Button("Finish", action: model.finish) }
                    else if !model.busy { Button("Start dictation") { model.begin(practice: true) }.disabled(!model.canRecord) }
                    if model.busy { Button("Cancel") { model.cancel() } }
                    Button("Open OmniFlow") { IslandWorkspace.shared.show(historyOnly ? .history : .dictation) }
                }
                Text("Hold Fn to talk · Fn + Space for hands-free").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// macOS exposes one Services provider per app. Preserve both selection workflows.
@MainActor
final class OmniFlowServices: NSObject {
    static let shared = OmniFlowServices()
    @objc func useSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        CursorActions.shared.useSelection(board, userData: userData ?? "", error: error)
    }
    @objc func cleanSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        AppModel.shared.selectionActions.cleanSelection(board, userData: userData, error: error)
    }
    @objc func translateSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        AppModel.shared.selectionActions.translateSelection(board, userData: userData, error: error)
    }
    @objc func styleSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        AppModel.shared.selectionActions.styleSelection(board, userData: userData, error: error)
    }
}
