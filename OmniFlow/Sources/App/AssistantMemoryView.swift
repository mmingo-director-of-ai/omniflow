import SwiftUI

struct AssistantMemoryView: View {
    @ObservedObject private var memory = AssistantMemory.shared
    @ObservedObject private var voice = VoiceAssistant.shared
    @State private var search = ""
    @State private var editing: SavedAssistantNote?
    @State private var clear = false

    private var scope: String { memory.project.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Use memory for new requests", isOn: $memory.enabled).disabled(!memory.busyTasks.isEmpty)
                Spacer()
                Button("Add note") { editing = SavedAssistantNote(scope: scope, text: "") }
                Button("Forget all…") { clear = true }.disabled(!memory.busyTasks.isEmpty)
            }
            TextField("Project context — leave empty for personal work", text: $memory.project)
                .textFieldStyle(.roundedBorder)
            Text("Personal notes and the selected project's memories can be recalled. Notes stay until you delete them. Task evidence stays on this Mac for up to 30 days, 20 tasks or 512 MB. Disabling memory stops recall and storage for new requests; it does not delete saved work.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = memory.error { Text(error).font(.caption).foregroundStyle(.red) }
            TextField("Search notes and saved work", text: $search).textFieldStyle(.roundedBorder)
            List {
                Section("Selected notes") {
                    ForEach(memory.document.notes.filter { ($0.scope.isEmpty || $0.scope == scope) && matches($0.text) }
                        .sorted { $0.updatedAt > $1.updatedAt }) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.scope.isEmpty ? "Personal" : note.scope).font(.caption).foregroundStyle(.secondary)
                            Text(note.text).textSelection(.enabled)
                            HStack {
                                Text(note.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                if note.sourceTask != nil { Text("Selected from a task · derived").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("Edit") { editing = note }
                                Button("Forget", role: .destructive) { Task { await memory.forgetNote(note.id) } }
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
                Section("Saved work") {
                    ForEach(memory.document.tasks.filter { $0.scope == scope && matches($0.question + $0.answer) }
                        .sorted { $0.updatedAt > $1.updatedAt }) { task in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                if !task.answer.isEmpty { Text(task.answer).textSelection(.enabled) }
                                if let progress = task.progress {
                                    Text("Source read: \(progress.processedBytes) of \(progress.totalBytes) bytes\(progress.complete ? " · analysis complete" : " · checkpoint saved")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(task.findings, id: \.id) { finding in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(finding.text).textSelection(.enabled)
                                        if let sources = finding.sources {
                                            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                                                if let quote = source.quote {
                                                    Text(quote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                                }
                                            }
                                        }
                                        Button("Keep as a note") {
                                            editing = SavedAssistantNote(scope: task.scope, text: String(finding.text.prefix(1400)), sourceTask: task.id, sourceNote: finding.id)
                                        }.buttonStyle(.borderless)
                                    }.padding(.vertical, 4)
                                }
                                HStack {
                                    Button(task.progress?.complete == true ? "Review saved source" : "Continue reading") {
                                        voice.resume(task)
                                        IslandWorkspace.shared.show(.assistant)
                                    }.disabled(!memory.enabled || task.progress == nil || voice.isBusy || !memory.busyTasks.isEmpty)
                                    Button("Keep answer as a note") {
                                        editing = SavedAssistantNote(scope: task.scope, text: String(task.answer.prefix(1400)), sourceTask: task.id)
                                    }.disabled(task.answer.isEmpty)
                                    Spacer()
                                    Button("Forget task", role: .destructive) { Task { await memory.forgetTask(task.id) } }
                                        .disabled(memory.busyTasks.contains(task.id))
                                }.buttonStyle(.borderless)
                                Text("Continuation uses saved source data. It does not replay MCP actions. Forgetting a task removes its evidence; notes you selected remain until deleted separately.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.question).lineLimit(2)
                                Text("\(task.status.rawValue.capitalized) · \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }.padding(18).task { await memory.load() }
            .sheet(item: $editing) { note in AssistantNoteEditor(note: note) }
            .confirmationDialog("Forget all saved notes, tasks and their source evidence on this Mac?", isPresented: $clear) {
                Button("Forget all memory", role: .destructive) { Task { await memory.clear() } }
            }
    }

    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
}

private struct AssistantNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var memory = AssistantMemory.shared
    let note: SavedAssistantNote
    @State private var text: String
    @State private var scope: String
    @State private var saving = false
    init(note: SavedAssistantNote) {
        self.note = note
        _text = State(initialValue: note.text); _scope = State(initialValue: note.scope)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remember a note").font(.headline)
            TextField("Project — leave empty for a personal note", text: $scope).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).frame(minHeight: 140).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
            Text("\(text.utf8.count) / 2,000 bytes. Write the preference or decision you want recalled. You can correct or delete it later.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = memory.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save note") {
                    saving = true
                    Task {
                        var updated = note
                        updated.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Edited wording is now the user's note, not an exact
                        // claim made by the original derived source.
                        if updated.text != note.text { updated.sourceTask = nil; updated.sourceNote = nil }
                        await memory.put(updated)
                        saving = false
                        if memory.error == nil { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 2000 || scope.utf8.count > 120)
            }
        }.padding(20).frame(width: 440)
    }
}
