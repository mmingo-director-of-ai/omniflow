import SwiftUI
import AppKit

/// Navigation stays visible while the book itself scrolls or turns pages.
struct ReaderWorkspaceView: View {
    @Binding var showLibrary: Bool
    @ObservedObject private var reader = ReaderController.shared
    @ObservedObject private var organization = ReaderController.shared.favorites
    @AppStorage("omniflow.reader.macLayout") private var layout = "spread"
    @AppStorage("omniflow.reader.macFontSize") private var fontSize = 19.0
    @State private var navigation = true
    @State private var navigationTab = "contents"
    @State private var query = ""
    @State private var results: [ReaderSearchHit] = []
    @State private var searching = false
    @State private var browseTarget: ReaderSentenceRef?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { showLibrary = true } label: { Label("Library", systemImage: "books.vertical") }
                Button { navigation.toggle() } label: { Image(systemName: "sidebar.left") }.accessibilityLabel("Toggle reader navigation")
                Text(reader.book?.title ?? "Reader").font(.headline).lineLimit(1)
                if let book = reader.book {
                    Button { organization.toggle(book.id) } label: { Image(systemName: organization.ids.contains(book.id) ? "star.fill" : "star") }
                        .accessibilityLabel(organization.ids.contains(book.id) ? "Remove favorite" : "Favorite book")
                }
                if let book = reader.book, let ref = reader.currentRef {
                    Button { organization.toggleBookmark(bookID: book.id, ref: ref, title: reader.chapterTitle, cfi: reader.document?.cfi(for: ref)?.string) } label: {
                        Image(systemName: organization.bookmarks.contains(where: { $0.bookID == book.id && $0.ref == ref }) ? "bookmark.fill" : "bookmark")
                    }.accessibilityLabel("Bookmark narration position")
                }
                Spacer(minLength: 4)
                Picker("Layout", selection: $layout) {
                    Text("Scroll").tag("scroll"); Text("Page").tag("pages"); Text("Two pages").tag("spread")
                }.frame(width: 160)
                Menu {
                    ForEach([16.0, 19.0, 22.0, 26.0], id: \.self) { size in Button("\(Int(size)) pt") { fontSize = size } }
                } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Page text size")
                Button { navigation = true; searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command).accessibilityLabel("Search in book")
            }.controlSize(.small).padding(16)
            Divider()
            HSplitView {
                if navigation { navigationPane.frame(minWidth: 180, idealWidth: 230, maxWidth: 300) }
                Group {
                    if layout == "scroll" {
                        ReaderReadAlongView(engine: reader.engine, style: .mac, followTitle: "Back to reading", onSelect: readFrom)
                    } else {
                        ReaderPagedMacView(reader: reader, browseTarget: $browseTarget, columns: layout == "spread" ? 2 : 1, fontSize: fontSize)
                            .padding(12)
                    }
                }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(spacing: 8) {
                ReaderTransport(compact: false).frame(maxWidth: .infinity)
                HStack {
                    Menu(reader.readingVoiceName ?? KokoroReadingVoice.selected.title) {
                        KokoroReaderSettings { reader.selectReadingVoice() }
                    }
                    Spacer()
                    Menu("Keyboard shortcuts", systemImage: "keyboard") {
                        Text("← / →   Turn pages")
                        Text("Space   Play / pause")
                        Text("⌥ ← / →   Previous / next sentence")
                        Text("⌥ ⇧ ← / →   Previous / next paragraph")
                        Text("⌘F   Search this book")
                    }.fixedSize()
                    Button("Close book") { reader.close() }
                }.font(.caption).foregroundStyle(.secondary).controlSize(.small)
            }.padding(14)
            if case .failed(let message) = reader.status { Label(message, systemImage: "exclamationmark.triangle").font(.callout).padding(8) }
        }
        .background(ReaderInputBridge { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if event.keyCode == 49 && modifiers.isEmpty { reader.togglePlay(); return true }
            if [123, 124].contains(event.keyCode), modifiers == .option || modifiers == [.option, .shift] {
                let direction = event.keyCode == 123 ? -1 : 1
                if modifiers.contains(.shift) { reader.skipParagraph(direction) } else { reader.skipSentence(direction) }
                return true
            }
            return false
        })
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = []; searching = !q.isEmpty
            guard !q.isEmpty, let document = reader.document else { searching = false; return }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let work = Task.detached(priority: .userInitiated) { ReaderSearch.find(q, in: document) }
            let hits = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            results = hits; searching = false
        }
        .id(reader.book?.id)
    }

    private var navigationPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search this book", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
            if !query.isEmpty {
                HStack {
                    Text(searching ? "Searching…" : "\(results.count) matching passages\(results.count == 200 ? " (first 200)" : "")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear book search")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(results) { hit in
                            Button { browse(hit.ref) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.chapterTitle).font(.caption.weight(.semibold)).foregroundStyle(Color.flowAccent)
                                    Text(hit.excerpt).font(.callout).lineLimit(5).foregroundStyle(Color.flowInk)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if !searching && results.isEmpty { Text("No matches in this book.").foregroundStyle(.secondary) }
                    }
                }
            } else {
                Picker("Navigation", selection: $navigationTab) {
                    Text("Contents").tag("contents"); Text("Bookmarks").tag("bookmarks")
                }.pickerStyle(.segmented)
                if navigationTab == "bookmarks" {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            let marks = organization.bookmarks.filter { $0.bookID == reader.book?.id }
                            if marks.isEmpty { Text("Use the bookmark button to save the narration position.").font(.callout).foregroundStyle(.secondary) }
                            ForEach(marks) { mark in
                                HStack {
                                    Button {
                                        if let target = bookmarkTarget(mark) { browse(target) }
                                    } label: { Label("\(mark.title) · ¶\(mark.ref.block + 1)", systemImage: "bookmark").lineLimit(2) }
                                    .buttonStyle(.plain).disabled(bookmarkTarget(mark) == nil)
                                    Spacer()
                                    Button { organization.toggleBookmark(bookID: mark.bookID, ref: mark.ref, title: mark.title) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).accessibilityLabel("Remove bookmark in \(mark.title)")
                                }.padding(.vertical, 6)
                            }
                        }
                    }
                } else { ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if let document = reader.document {
                            ForEach(Array(document.chapters.enumerated()), id: \.offset) { c, chapter in
                                if let b = chapter.blocks.firstIndex(where: \.spoken) {
                                    Button { browse(.init(chapter: c, block: b, sentence: 0)) } label: {
                                        HStack {
                                            Text(chapter.title).lineLimit(3)
                                            Spacer(minLength: 4)
                                            if reader.currentRef?.chapter == c { Image(systemName: "speaker.wave.2") }
                                        }.font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(reader.currentRef?.chapter == c ? Color.flowAccent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                }
                Text("Browse chapters or search without moving the narration. Choose “Read this page” to start there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14)
    }
    private func bookmarkTarget(_ mark: ReaderFavorites.Bookmark) -> ReaderSentenceRef? {
        if let cfi = mark.cfi.flatMap(ReaderCFI.init), let ref = reader.document?.sentence(for: cfi) { return ref }
        return reader.order.contains(mark.ref) ? mark.ref : nil
    }
    private func browse(_ ref: ReaderSentenceRef) {
        guard reader.order.contains(ref) else { return }
        if layout == "scroll" { layout = "pages" }
        browseTarget = ref
    }
    private func readFrom(_ ref: ReaderSentenceRef) {
        guard let index = reader.order.firstIndex(of: ref) else { return }
        reader.seek(to: index); reader.play()
    }
}
