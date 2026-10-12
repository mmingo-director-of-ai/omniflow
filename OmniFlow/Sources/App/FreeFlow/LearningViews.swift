import SwiftUI

/// Edit a dictation's result in place. Saving keeps the original transcript and,
/// when learning is on, lets OmniFlow learn from what you changed.
struct TranscriptEditSheet: View {
    let entry: DictationEntry
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(entry: DictationEntry, onSave: @escaping (String) -> Void) {
        self.entry = entry; self.onSave = onSave
        _text = State(initialValue: entry.displayText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit transcript").font(.system(size: 17, weight: .semibold))
            Text("Fix what OmniFlow got wrong. The original transcript is kept. When learning is on, repeated fixes become suggestions in Dictionary.")
                .font(.system(size: 12)).foregroundStyle(Color.flowMuted)
            TextEditor(text: $text).font(.system(size: 14)).frame(minWidth: 460, minHeight: 220)
                .padding(8).background(Color.flowSurface.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22)
    }
}

/// Settings › Dictionary: what OmniFlow learned from your corrections. Every rule
/// that applies is listed here, with accept and reject.
struct LearnedRulesView: View {
    @ObservedObject var learning: CorrectionLearningModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LEARNED FROM YOUR CORRECTIONS").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Color.flowMuted)
                Spacer()
                Picker("Learning", selection: $learning.mode) {
                    ForEach(CorrectionLearningModel.Mode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 190)
            }
            Text(learning.mode == .off
                 ? "Learning is off. Edits of your dictations are not used."
                 : "Edit a dictation in Recent to correct it. A fix you make in at least two dictations becomes a suggestion here. Numbers and negations are never learned. \(learning.pairCount) corrected dictation(s) saved, encrypted on this Mac.")
                .font(.system(size: 11)).foregroundStyle(Color.flowMuted)
            if learning.listed.isEmpty {
                Text("Nothing learned yet.").font(.system(size: 12)).foregroundStyle(Color.flowMuted)
            } else {
                ForEach(learning.listed) { rule in row(rule) }
            }
            if learning.pairCount > 0 || !learning.listed.isEmpty {
                Button("Clear all learning", role: .destructive) { learning.clearAll() }.buttonStyle(.borderless).font(.system(size: 11))
            }
        }
    }

    private func row(_ rule: LearnedRule) -> some View {
        let status = learning.status(of: rule)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.title).font(.system(size: 13, weight: .medium))
                Text(statusText(status, count: rule.count)).font(.system(size: 10)).foregroundStyle(Color.flowMuted)
                if !rule.example.isEmpty { Text(rule.example).font(.system(size: 11)).foregroundStyle(Color.flowMuted).lineLimit(2) }
            }
            Spacer()
            if status != .accepted { Button("Accept") { learning.accept(rule) }.font(.system(size: 11)) }
            if status != .rejected { Button("Reject") { learning.reject(rule) }.font(.system(size: 11)) }
        }.padding(10).background(Color.flowPaper.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private func statusText(_ status: CorrectionLearningModel.Status, count: Int) -> String {
        let seen = count > 0 ? "Seen in \(count) dictations · " : ""
        switch status {
        case .pending: return seen + "Suggested, not applied"
        case .accepted: return seen + "Applied"
        case .rejected: return seen + "Rejected, never applied"
        case .automatic: return seen + "Applied automatically"
        }
    }
}
