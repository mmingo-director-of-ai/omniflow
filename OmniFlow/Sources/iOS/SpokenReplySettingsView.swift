import AVFoundation
import SwiftUI

/// iOS settings: replies are always written; speaking them is optional and uses
/// installed system voices, or the user's Personal Voice once they allow it
/// (user decisions, 2026-10-04). Same preference keys as the Mac app.
struct SpokenReplySettingsView: View {
    @AppStorage("voiceSpokenReplies") private var spokenReplies = false
    @State private var sample = KokoroReplySpeaker()

    var body: some View {
        Form {
            Section {
                SettingsHero()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            DictationSettingsSection()
            LearningSettingsSection()
            AppLockSettingsSection()
                OmniFlowSyncSettings()
            Section {
                Toggle("Speak replies", isOn: $spokenReplies)
                KokoroReaderSettings(assistant: true) { sample.stop() }
                Button("Play sample", systemImage: "play.circle", action: playSample)
            } header: { Text("Spoken replies · Kokoro") }
            footer: { Text("Replies stay available in writing. Speech runs on this device after the first download.") }
            Section {
                KokoroReaderSettings { IOSReaderModel.shared.readingVoiceChanged() }
            } header: { Text("Reader · Kokoro") }
            footer: { Text("Choose a voice matching your book’s language. Speech runs on this device after the first download.") }
            Section { } footer: { buildStamp }
        }
        .scrollContentBackground(.hidden)
        .background { Theme.backdrop }
        .navigationTitle("Settings")
        .onDisappear { sample.stop() }
    }

    /// Version, build number and commit, so installs can be told apart.
    private var buildStamp: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let sha = info["OmniFlowGitSHA"] as? String ?? "dev"
        return Text("OmniFlow \(version) · build \(build) · \(sha)")
            .font(.caption2.monospaced()).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .textSelection(.enabled)
            .accessibilityLabel("Version \(version), build \(build), commit \(sha)")
    }

    private func playSample() {
        sample.beginReply()
        sample.enqueue("This is how OmniFlow will read its replies to you.", rate: 1, pitch: 1)
        sample.endReply()
    }

}

/// The Settings hero: what OmniFlow is doing for you right now.
private struct SettingsHero: View {
    @ObservedObject private var lock = OmniFlowAppLock.shared
    @AppStorage("polishMode") private var polishMode = PolishMode.polished.rawValue

    var body: some View {
        HStack(spacing: 14) {
            RedPandaView(state: .idle, cheerful: true).frame(width: 54, height: 54).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your OmniFlow").font(Theme.heading(20)).foregroundStyle(Theme.ink)
                Text("\((PolishMode(rawValue: polishMode) ?? .polished).title) · \(lock.enabled ? "Locked with \(lock.biometryName)" : "Lock off") · On-device")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .heroCard(padding: 16)
    }
}
