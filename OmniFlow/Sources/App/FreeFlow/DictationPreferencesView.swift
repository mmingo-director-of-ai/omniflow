import AppKit
import SwiftUI

@MainActor
final class DictationPreferencesStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var profiles: [ApplicationProfile] { didSet { save(profiles, key: "applicationProfiles") } }
    @Published var replacements: [PhraseReplacement] { didSet { save(replacements, key: "phraseReplacements") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = defaults.data(forKey: "applicationProfiles").flatMap { try? JSONDecoder().decode([ApplicationProfile].self, from: $0) } ?? []
        replacements = defaults.data(forKey: "phraseReplacements").flatMap { try? JSONDecoder().decode([PhraseReplacement].self, from: $0) } ?? []
    }
    func resolve(bundleID: String?, defaultWritingStyle: WritingStyle, defaultOutputStyle: String) -> ResolvedDictationPreferences {
        .resolve(bundleID: bundleID, profiles: profiles, defaultWritingStyle: defaultWritingStyle, defaultOutputStyle: defaultOutputStyle)
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

struct DictationPreferencesView: View {
    @ObservedObject var store: DictationPreferencesStore
    var body: some View {
        Form {
            Section("Application preferences") {
                Text("Choose writing and output styles for individual apps. Defaults inherit your Dictation settings. The destination app is chosen when dictation starts; moving focus does not change its style.").font(.callout).foregroundStyle(.secondary)
                ForEach($store.profiles) { $profile in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            TextField("Application name", text: $profile.name)
                            Button(role: .destructive) { store.profiles.removeAll { $0.id == profile.id } } label: { Image(systemName: "minus.circle") }.help("Remove application preference")
                        }
                        TextField("Bundle ID (for example com.apple.Notes)", text: $profile.bundleID).font(.system(.body, design: .monospaced))
                        Picker("Writing style", selection: $profile.writingStyle) {
                            Text("Use default").tag(String?.none)
                            ForEach(WritingStyle.allCases, id: \.self) { Text($0.title).tag(Optional($0.rawValue)) }
                        }
                        Picker("Output style", selection: $profile.outputStyle) {
                            Text("Use default").tag(String?.none)
                            Text("Natural prose").tag(Optional("natural"))
                            Text("Structured Markdown").tag(Optional("markdown"))
                            Text("Agent prompt").tag(Optional(AgentLayout.outputStyle))
                        }
                        if store.profiles.filter({ !$0.bundleID.isEmpty && $0.bundleID == profile.bundleID }).count > 1 {
                            Text("Duplicate bundle ID: the first matching preference is used.").font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(.vertical, 5)
                }
                HStack {
                    Button("Choose application…", action: chooseApplication)
                    Button("Add manually") { store.profiles.append(.init()) }
                    Button("Agent prompt in coding apps", action: useAgentLayoutInCodingApps)
                        .help("Adds the coding apps installed on this Mac (terminals, editors, Claude, Codex) with the Agent prompt output style")
                }
            }
            Section("Custom replacements") {
                Text("Replace a spoken phrase with its exact spelling after cleanup, even when polishing is off. Matching ignores case and respects whole phrases. Code blocks are preserved. Longest matches win; replacements never trigger another replacement.").font(.callout).foregroundStyle(.secondary)
                ForEach($store.replacements) { $rule in
                    HStack {
                        Toggle("Enabled", isOn: $rule.enabled).labelsHidden().help("Enable replacement")
                        TextField("Spoken phrase", text: $rule.phrase)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Exact replacement", text: $rule.replacement)
                        Button(role: .destructive) { store.replacements.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }.help("Remove replacement")
                    }
                }
                Button("Add replacement") { store.replacements.append(.init()) }
                Text("Saved only on this Mac. Original transcripts stay unchanged in history.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
    /// Terminals, editors and agent apps where dictation is usually a prompt for a coding agent.
    static let codingApps: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"), ("Warp", "dev.warp.Warp-Stable"), ("iTerm", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"), ("Visual Studio Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Windsurf", "com.exafunction.windsurf"), ("Zed", "dev.zed.Zed"), ("Xcode", "com.apple.dt.Xcode"),
        ("Claude", "com.anthropic.claudefordesktop"), ("Codex", "com.openai.codex"),
    ]

    private func useAgentLayoutInCodingApps() {
        for app in Self.codingApps where NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil {
            if let index = store.profiles.firstIndex(where: { $0.bundleID == app.bundleID }) {
                store.profiles[index].outputStyle = AgentLayout.outputStyle
            } else {
                store.profiles.append(.init(name: app.name, bundleID: app.bundleID, outputStyle: AgentLayout.outputStyle))
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        guard !store.profiles.contains(where: { $0.bundleID == id }) else { return }
        store.profiles.append(.init(name: url.deletingPathExtension().lastPathComponent, bundleID: id))
    }
}
