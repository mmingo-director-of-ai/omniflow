import SwiftUI

extension ReaderReadAlongStyle {
    /// The Mac read-along: OmniFlow's page palette with a large serif body.
    static var mac: ReaderReadAlongStyle {
        ReaderReadAlongStyle(ink: .flowInk, muted: .flowMuted, accent: .flowAccent, onAccent: .flowPaper,
                             chapterTitle: .system(size: 28, weight: .regular, design: .serif),
                             heading: .system(size: 22, weight: .semibold, design: .serif),
                             body: .system(size: 19, design: .serif), small: .system(size: 14, design: .serif))
    }
}

/// The cover header above the read-along text: the book, the transport and the
/// way back to the library. Scrolls with the text.
struct ReaderReadAlongHeader: View {
    @Binding var showLibrary: Bool
    @ObservedObject private var reader = ReaderController.shared
    @ObservedObject private var voice = VoiceAssistant.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 22) {
                ReaderCoverView(width: 132, height: 188, corner: 10)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 6) {
                    Text(reader.book?.title ?? "").font(.system(size: 26, weight: .regular, design: .serif))
                        .foregroundStyle(Color.flowInk).lineLimit(3)
                    if let author = reader.book?.author, !author.isEmpty {
                        Text(author).font(.title3).foregroundStyle(Color.flowMuted).lineLimit(1)
                    }
                    Text(reader.chapterTitle).font(.callout).foregroundStyle(Color.flowMuted).lineLimit(1)
                    ReaderTransport(compact: false).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: reader.chapterProgress).accessibilityLabel("Chapter progress")
            HStack(spacing: 10) {
                Button("Library", systemImage: "books.vertical") { showLibrary = true }
                if let document = reader.document {
                    Menu("Chapters") {
                        ForEach(Array(document.chapters.enumerated()), id: \.offset) { index, chapter in
                            if chapter.blocks.contains(where: \.spoken) {
                                Button {
                                    reader.startChapter(index)
                                } label: {
                                    if reader.currentRef?.chapter == index { Label(chapter.title, systemImage: "speaker.wave.2.fill") } else { Text(chapter.title) }
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Close book") { reader.close() }
            }
            .controlSize(.small)
            Group {
                switch reader.status {
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle")
                case .finished: Text("Finished the book.")
                default: Text("Click a sentence to read from there. \(reader.readingVoiceName ?? KokoroReadingVoice.selected.title), pace \(voice.speechRate, format: .number.precision(.fractionLength(2))); ⌃⌥R plays or pauses from anywhere.")
                }
            }
            .font(.footnote).foregroundStyle(Color.flowMuted).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 4)
        }
        .padding(.top, 12).padding(.bottom, 6)
    }
}
