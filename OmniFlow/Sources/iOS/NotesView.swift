import SwiftUI

/// Dictated notes on iOS: start one by talking, keep adding to it by talking,
/// edit it by hand. Kept encrypted on this iPhone (NoteStore, vault-sealed).

struct NotesView: View {
    @EnvironmentObject private var flow: IOSFlowModel
    @ObservedObject private var notes = NotesModel.shared
    /// A just-created note to open (the tab already sits in a NavigationStack).
    @State private var opened: UUID?

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    newNoteCard
                    if let problem = notes.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.ink)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.banner, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if notes.notes.isEmpty {
                        Text("Your notes will appear here. Each one stays on this iPhone, encrypted.")
                            .font(.subheadline).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                    }
                    ForEach(notes.notes) { note in
                        NavigationLink(value: note.id) { NoteRow(note: note) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { flow.copy(note.body) }
                                ShareLink(item: note.body)
                                Button("Delete", systemImage: "trash", role: .destructive) { notes.delete([note.id]) }
                            }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            .background { Theme.backdrop }
            .navigationTitle("Notes")
            .navigationDestination(for: UUID.self) { id in NoteEditor(id: id) }
            .navigationDestination(item: $opened) { id in NoteEditor(id: id) }
            .onChange(of: notes.requestedOpen, initial: true) { _, id in
                guard let id else { return }
                opened = id
                notes.requestedOpen = nil
            }
            #if DEBUG
            // Screenshots: `-OmniFlowDemoNote YES` starts a dictated note with the demo engine.
            .task {
                guard UserDefaults.standard.bool(forKey: "OmniFlowDemoNote") else { return }
                try? await Task.sleep(for: .seconds(1))
                let id = notes.create()
                opened = id
                flow.dictateIntoNote { text in NotesModel.shared.append(text, to: id) }
                // Unstructured: opening the note ends this view's task.
                Task { [flow] in try? await Task.sleep(for: .seconds(7)); flow.stopRecording() }
            }
            #endif
    }

    private var newNoteCard: some View {
        Button {
            let id = notes.create()
            opened = id
            flow.dictateIntoNote { text in NotesModel.shared.append(text, to: id) }
        } label: {
            HStack(spacing: 14) {
                WaveformGlyph(size: 26).foregroundStyle(Theme.onAccent)
                    .frame(width: 48, height: 48).background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("New dictated note").font(Theme.heading(20)).foregroundStyle(Theme.ink)
                    Text("Start talking. Stop when you're done; it's polished and saved.").font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .heroCard(padding: 16)
        }
        .buttonStyle(PressScale())
        .disabled(flow.isDictating)
    }
}

private struct NoteRow: View {
    let note: DictationNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title).font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
            if !note.preview.isEmpty {
                Text(note.preview).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Text("\(note.updated.formatted(.relative(presentation: .named))) · \(note.wordCount) words")
                .font(.caption).foregroundStyle(Theme.muted)
        }
        .card(padding: 14)
    }
}

/// One note: edit by hand, or tap the mic to add more by voice.
private struct NoteEditor: View {
    let id: UUID
    @EnvironmentObject private var flow: IOSFlowModel
    @ObservedObject private var notes = NotesModel.shared
    @State private var text = ""
    @FocusState private var editing: Bool

    private var listening: Bool { flow.dictatingIntoNote && (flow.phase == .recording || flow.phase == .preparing || flow.phase == .finishing) }

    var body: some View {
        ZStack(alignment: .bottom) {
            TextEditor(text: $text)
                .font(.system(size: 18, design: .serif))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .focused($editing)
                .padding(.horizontal, 16)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !listening {
                        Text("Tap the mic and talk, or type.").font(.system(size: 18, design: .serif))
                            .foregroundStyle(Theme.muted).padding(.horizontal, 21).padding(.top, 8).allowsHitTesting(false)
                    }
                }
            dictationBar
        }
        .background { Theme.backdrop }
        .navigationTitle(notes.note(id)?.title ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }.disabled(text.isEmpty)
            }
            if editing {
                ToolbarItem(placement: .keyboard) { HStack { Spacer(); Button("Done") { editing = false } } }
            }
        }
        .onAppear { text = notes.note(id)?.body ?? "" }
        .onChange(of: text) { _, value in notes.setBody(value, of: id) }
        // A dictation landing in this note shows up in the editor.
        .onChange(of: notes.note(id)?.body) { _, body in if let body, body != text { text = body } }
        .onDisappear {
            if flow.dictatingIntoNote { flow.cancelRecording() }
            notes.discardIfEmpty(id)
        }
        .pushedPage()
    }

    private var dictationBar: some View {
        VStack(spacing: 10) {
            if listening {
                Group {
                    if let preview = flow.polishing, !preview.isEmpty {
                        LiveTranscript(text: preview, font: .system(size: 17, design: .serif))
                    } else if !flow.transcript.isEmpty {
                        LiveTranscript(text: flow.transcript, font: .system(size: 17, design: .serif))
                    } else {
                        Text(flow.phase == .preparing ? "Getting ready…" : "Listening…").font(.system(size: 17, design: .serif))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .foregroundStyle(Theme.ink)
                .lineLimit(3).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ZStack {
                VoiceRing(listening: flow.phase == .recording && flow.dictatingIntoNote, color: Theme.accent) { IOSMicrophone.shared.snapshot() }
                    .frame(width: 120, height: 120)
                    .opacity(listening ? 1 : 0)
                Button {
                    if flow.phase == .recording && flow.dictatingIntoNote { flow.stopRecording() }
                    else { editing = false; flow.dictateIntoNote { [id] text in NotesModel.shared.append(text, to: id) } }
                } label: {
                    Group {
                        if flow.phase == .recording && flow.dictatingIntoNote { Image(systemName: "stop.fill") }
                        else { WaveformGlyph(size: 26) }
                    }
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(flow.phase == .recording && flow.dictatingIntoNote ? .white : Theme.onAccent)
                        .frame(width: 60, height: 60)
                        .background(flow.phase == .recording && flow.dictatingIntoNote ? Color.red : Theme.accent, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressScale())
                .disabled(flow.phase == .preparing || flow.phase == .finishing || (flow.isDictating && !flow.dictatingIntoNote))
                .accessibilityLabel(flow.phase == .recording ? "Stop dictating" : "Dictate into this note")
            }
            .frame(height: 120)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: listening)
    }
}
