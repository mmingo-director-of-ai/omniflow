import SwiftUI

/// Dictated notes on the Mac, Wispr Flow-style: "New dictated note" starts a
/// hands-free dictation that goes into a note instead of another app; the mic
/// adds more to the open note; the text is yours to edit. Notes are sealed
/// with the OmniFlow vault and sit behind App Lock with the rest of the Hub.
struct NotesPageView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var notes = NotesModel.shared
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 260)
            Divider()
            if let selection, notes.note(selection) != nil {
                NoteEditorPane(model: model, id: selection).id(selection)
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text",
                                       description: Text("Start a dictated note, or pick one on the left."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { newNote() } label: {
                Label { Text(model.dictatingIntoNote ? "Listening…" : "New dictated note") } icon: { WaveformGlyph(size: 16) { Float(model.dictatingIntoNote ? model.level : 0) } }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Color.flowAccent, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color.flowPaper)
            }
            .buttonStyle(.press)
            .disabled(model.busy)
            .help("Starts hands-free dictation into a new note. Click the orb or press fn + space to finish.")
            if let problem = notes.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            List(selection: $selection) {
                ForEach(notes.notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(note.updated.formatted(.relative(presentation: .named)) + " · \(note.wordCount) words")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(note.id)
                    .contextMenu {
                        Button("Copy") { copy(note.body) }
                        Button("Delete", role: .destructive) { delete(note.id) }
                    }
                }
                .onDelete { offsets in offsets.map { notes.notes[$0].id }.forEach(delete) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding(12)
    }

    private func newNote() {
        let id = notes.create()
        selection = id
        model.dictateIntoNote { text in NotesModel.shared.append(text, to: id) }
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        notes.delete([id])
    }

    private func copy(_ text: String) { _ = OmniFlowClipboard.copy(text) }
}

private struct NoteEditorPane: View {
    @ObservedObject var model: AppModel
    let id: UUID
    @ObservedObject private var notes = NotesModel.shared
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(notes.note(id)?.title ?? "Note").font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                Button {
                    if model.dictatingIntoNote { model.finish() }
                    else { model.dictateIntoNote { [id] text in NotesModel.shared.append(text, to: id) } }
                } label: {
                    Label(model.dictatingIntoNote ? "Finish" : "Dictate", symbol: model.dictatingIntoNote ? "stop.fill" : OmniFlowSymbol.dictate)
                }
                .disabled(model.busy && !model.dictatingIntoNote)
                .help(model.dictatingIntoNote ? "Finish and add to this note" : "Add to this note by voice")
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }.disabled(text.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            if model.dictatingIntoNote, !model.transcript.isEmpty {
                LiveTranscript(text: model.transcript, font: .system(size: 14, design: .serif))
                    .lineLimit(3).truncationMode(.head)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.flowBanner, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
            }
            TextEditor(text: $text)
                .font(.system(size: 15, design: .serif))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .onAppear { text = notes.note(id)?.body ?? "" }
        .onChange(of: text) { _, value in notes.setBody(value, of: id) }
        .onChange(of: notes.note(id)?.body) { _, body in if let body, body != text { text = body } }
        .onDisappear { if !model.dictatingIntoNote { notes.discardIfEmpty(id) } }
    }
}
