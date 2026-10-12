import SwiftUI

/// Edit a dictation result. The original stays in history; when learning is
/// on, fixes repeated across dictations become suggestions in Settings.
struct EditDictationSheet: View {
    let original: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(text: String, onSave: @escaping (String) -> Void) {
        original = text; self.onSave = onSave
        _text = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fix what OmniFlow got wrong. Repeated fixes teach it your words and style.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                TextEditor(text: $text)
                    .font(.system(size: 18, design: .serif)).foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .focused($focused)
            }
            .padding(20)
            .background { Theme.backdrop }
            .navigationTitle("Edit").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == original)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }
}

/// Settings: what OmniFlow learned from your corrections, with accept and reject.
struct LearningSettingsSection: View {
    @EnvironmentObject private var flow: IOSFlowModel

    var body: some View {
        LearnedRulesList(learning: flow.learning)
    }
}

private struct LearnedRulesList: View {
    @ObservedObject var learning: CorrectionLearningModel

    var body: some View {
        Section {
            Picker("Learn from my edits", selection: $learning.mode) {
                ForEach(CorrectionLearningModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            if learning.mode != .off {
                if learning.listed.isEmpty {
                    Text("Nothing learned yet. Edit a dictation (Review or History › Edit); a fix you make in two dictations shows up here.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                ForEach(learning.listed) { rule in row(rule) }
                if learning.pairCount > 0 || !learning.listed.isEmpty {
                    Button("Clear all learning", role: .destructive) { learning.clearAll() }
                }
            }
        } header: {
            Text("Learning")
        } footer: {
            Text(learning.mode == .off ? "Your edits aren't used." :
                 "\(learning.pairCount) corrected \(learning.pairCount == 1 ? "dictation" : "dictations") saved, encrypted on this iPhone. Numbers and negations are never learned.")
        }
    }

    private func row(_ rule: LearnedRule) -> some View {
        let status = learning.status(of: rule)
        return VStack(alignment: .leading, spacing: 6) {
            Text(rule.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(statusText(status, count: rule.count)).font(.caption).foregroundStyle(Theme.muted)
            if !rule.example.isEmpty { Text(rule.example).font(.caption).foregroundStyle(Theme.muted).lineLimit(2) }
            HStack {
                if status != .accepted && status != .automatic { Button("Accept") { learning.accept(rule) }.buttonStyle(.bordered).tint(Theme.accent) }
                if status != .rejected { Button("Reject") { learning.reject(rule) }.buttonStyle(.bordered) }
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ status: CorrectionLearningModel.Status, count: Int) -> String {
        let seen = count > 0 ? "Seen in \(count) dictations · " : ""
        switch status {
        case .pending: return seen + "Suggested, not applied"
        case .accepted: return seen + "Applied"
        case .rejected: return seen + "Rejected"
        case .automatic: return seen + "Applied automatically"
        }
    }
}
