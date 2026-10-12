import AppKit
import SwiftUI

/// The Reader page in the OmniFlow window. While a book plays it shows the
/// read-along (the shared `ReaderReadAlongView`) under a large cover header;
/// otherwise the Books library, with the open book's card above it.
struct ReaderPageView: View {
    @ObservedObject private var reader = ReaderController.shared
    @ObservedObject private var voice = VoiceAssistant.shared
    @State private var search = ""
    @State private var previewID: String?
    @State private var showOrganization = false
    @State private var showLibrary = false
    @ObservedObject private var organization = ReaderController.shared.favorites
    @State private var libraryFilter = "all"
    @AppStorage("omniflow.reader.librarySort") private var librarySort = "recent"
    @State private var creatingCollection = false
    @State private var collectionName = ""


    var body: some View {
        Group {
            if reader.document != nil, reader.currentRef != nil, !showLibrary {
                ReaderWorkspaceView(showLibrary: $showLibrary).id(reader.book?.id)

            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        OmniFlowPageHeading("Reader", subtitle: "Your books. A little space to read, listen, and pick up where you left off.")
                        if reader.book != nil { nowReading }
                        library
                    }
                    .padding(28).frame(maxWidth: .infinity)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .alert("New collection", isPresented: $creatingCollection) {
            TextField("Collection name", text: $collectionName)
            Button("Create") { if organization.create(collectionName) { libraryFilter = "collection:" + collectionName.trimmingCharacters(in: .whitespacesAndNewlines) }; collectionName = "" }
            Button("Cancel", role: .cancel) { collectionName = "" }
        } message: { Text("Organizes books in OmniFlow without changing Apple Books.") }
        .onAppear { if reader.library.isEmpty { reader.loadLibrary() } }
        .onChange(of: reader.book?.id) { showLibrary = false }
    }

    @ViewBuilder private var nowReading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                ReaderCoverView(width: 84, height: 118, corner: 8)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue reading").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(reader.book?.title ?? "").font(.title3.weight(.semibold)).lineLimit(2)
                    Text([reader.book?.author ?? "", reader.chapterTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if reader.currentRef != nil {
                    Button("Read along", systemImage: "text.book.closed") { showLibrary = false }.controlSize(.small)
                }
                Button("Close book") { reader.close() }.controlSize(.small)
            }
            ReaderTransport(compact: false)
            ProgressView(value: reader.chapterProgress).accessibilityLabel("Chapter progress")
            Group {
                switch reader.status {
                case .loading: Text(reader.startNote ?? "Preparing the book…")
                case .failed(let message): Label(message, systemImage: "exclamationmark.triangle")
                case .finished: Text("Finished the book.")
                default: if let note = reader.startNote { Text(note) }
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Reading tools & voice") {
            if reader.booksStart != nil {
                Button("Start from Apple Books' page") { reader.startFromBooksPage() }.controlSize(.small)
            }
            Label("Starts from where Apple Books left off; Books itself is never changed.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Kokoro voice is selected in the Reader. Current: \(reader.readingVoiceName ?? KokoroReadingVoice.selected.title), pace \(voice.speechRate, format: .number.precision(.fractionLength(2))). ⌃⌥R plays or pauses from anywhere.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let document = reader.document {
                DisclosureGroup("Chapters") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(document.chapters.enumerated()), id: \.offset) { index, chapter in
                            if chapter.blocks.contains(where: \.spoken) {
                                Button {
                                    reader.startChapter(index)
                                } label: {
                                    HStack {
                                        Text(chapter.title).lineLimit(1)
                                        Spacer()
                                        if reader.currentRef?.chapter == index { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(.top, 6)
                }
            }
            }

        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your Apple Books").font(.headline)
                Spacer()
                TextField("Search title or author", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button("Refresh", systemImage: "arrow.clockwise") { reader.loadLibrary() }.labelStyle(.iconOnly)
            }
            DisclosureGroup("Organize your library", isExpanded: $showOrganization) {
            HStack {
                Picker("Show", selection: $libraryFilter) {
                    Text("All books").tag("all")
                    Text("Favorites").tag("favorites")
                    Text("In progress").tag("progress")
                    ForEach(organization.collections.keys.sorted(), id: \.self) { name in Text(name).tag("collection:" + name) }
                }.frame(maxWidth: 240)
                Picker("Sort", selection: $librarySort) {
                    Text("Recently opened").tag("recent")
                    Text("Title").tag("title")
                    Text("Author").tag("author")
                }.frame(maxWidth: 220)
                Spacer()
                Button("New collection", systemImage: "folder.badge.plus") { creatingCollection = true }
                if libraryFilter.hasPrefix("collection:") {
                    Button("Remove collection", systemImage: "folder.badge.minus") {
                        organization.removeCollection(String(libraryFilter.dropFirst(11))); libraryFilter = "all"
                    }.help("Removes the collection only; no books are deleted.")
                }
            }.controlSize(.small)
            }
            .padding(12)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            if reader.libraryLoading && reader.library.isEmpty {
                ProgressView().controlSize(.small)
            } else if let error = reader.libraryError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "lock").foregroundStyle(.secondary)
                    Button("Open Full Disk Access settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }
                }
            } else if reader.library.isEmpty {
                Text("No EPUB books you added yourself were found in Apple Books. Store purchases are protected and can't be read aloud.")
                    .foregroundStyle(.secondary)
            } else {
                let books = filteredBooks
                if books.isEmpty {
                    ContentUnavailableView("No matching books", systemImage: "magnifyingglass", description: Text("Try another search or collection. Add favorites with the star beside a book."))
                }
                if let selected = books.first(where: { $0.id == previewID }) ?? books.first {
                    ReaderBookPreview(book: selected) { autoplay in
                        reader.open(selected, autoplay: autoplay)
                        showLibrary = false
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(books) { book in
                        ReaderBookTile(book: book, selected: book.id == (previewID ?? books.first?.id), favorite: organization.ids.contains(book.id),
                                       select: { previewID = book.id }, favoriteAction: { organization.toggle(book.id) })
                        .contextMenu {
                            Button("Read") { reader.open(book, autoplay: false); showLibrary = false }
                            Button("Listen") { reader.open(book, autoplay: true); showLibrary = false }
                            ForEach(organization.collections.keys.sorted(), id: \.self) { name in
                                Button { organization.toggle(book.id, in: name) } label: {
                                    Label(name, systemImage: organization.collections[name]?.contains(book.id) == true ? "checkmark" : "folder")
                                }
                            }
                        }
                    }
                }
                Text("Only books you added yourself are listed; Store purchases are protected.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private var filteredBooks: [ReaderBook] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let books = reader.library.filter { book in
            let matches = query.isEmpty || book.title.localizedStandardContains(query) || book.author.localizedStandardContains(query)
            let included: Bool
            if libraryFilter == "favorites" { included = organization.ids.contains(book.id) }
            else if libraryFilter == "progress" { included = book.progress > 0 && book.progress < 1 }
            else if libraryFilter.hasPrefix("collection:") { included = organization.collections[String(libraryFilter.dropFirst(11))]?.contains(book.id) == true }
            else { included = true }
            return matches && included
        }
        return books.sorted {
            switch librarySort {
            case "title": return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case "author": return ($0.author + $0.title).localizedStandardCompare($1.author + $1.title) == .orderedAscending
            default: return ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast)
            }
        }
    }

}

/// Play/pause, sentence and paragraph skips, and the pace (shared setting).
struct ReaderTransport: View {
    let compact: Bool
    @ObservedObject private var reader = ReaderController.shared
    @ObservedObject private var voice = VoiceAssistant.shared

    var body: some View {
        HStack(spacing: compact ? 9 : 14) {
            button("backward.end.fill", "Previous paragraph") { reader.skipParagraph(-1) }
            button("gobackward", "Previous sentence") { reader.skipSentence(-1) }
            Button { reader.togglePlay() } label: {
                Image(systemName: reader.isPlaying ? "pause.fill" : "play.fill").font(.system(size: compact ? 20 : 24, weight: .semibold))
                    .frame(width: compact ? 48 : 58, height: compact ? 48 : 58)
                    .background(Color.flowAccent, in: Circle()).foregroundStyle(Color.black)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(reader.isPlaying ? "Pause reading" : "Read aloud")
            button("goforward", "Next sentence") { reader.skipSentence(1) }
            button("forward.end.fill", "Next paragraph") { reader.skipParagraph(1) }
            Menu {
                ForEach([0.8, 0.9, 1.0, 1.1, 1.2, 1.3], id: \.self) { rate in
                    Button(String(format: "%.1f×", rate)) { reader.setRate(rate) }
                }
            } label: {
                Text(String(format: "%.2g×", voice.speechRate)).font(.system(size: compact ? 10 : 12, weight: .semibold)).monospacedDigit()
            }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Reading pace")
        }
        .buttonStyle(.press)
        .font(.system(size: compact ? 12 : 15))
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 40, height: 40).background(.quaternary.opacity(0.4), in: Circle()) }.accessibilityLabel(label).help(label)
    }
}

/// The island's Reading page. It replaces the Music card while a book is
/// open, so there is one media card. Shows the book and chapter, never book text.
struct ReaderIslandPanel: View {
    @ObservedObject private var reader = ReaderController.shared

    var body: some View {
        ZStack {
            CardBackground(wash: .soft)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "book").font(.system(size: 10, weight: .semibold))
                    Text("Reading").font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                    Spacer(minLength: 4)
                }
                .foregroundColor(Color(hex: "#9EA4AE"))
                HStack(spacing: 10) {
                    ReaderCoverView(width: 40, height: 56, corner: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reader.book?.title ?? "No book open").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(subtitle).font(.system(size: 10.5)).foregroundColor(Color(hex: "#9398A1")).lineLimit(1)
                        ReaderProgressBar(value: reader.chapterProgress)
                    }
                }
                    ReaderIslandTransport().foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 118).padding(.trailing, 14).padding(.vertical, 8)
        }
    }

    private var subtitle: String {
        switch reader.status {
        case .loading: "Preparing…"
        case .failed(let message): message
        case .finished: "Finished"
        default: reader.chapterTitle
        }
    }
}

/// A thin chapter-progress bar (drawn, so it costs nothing while idle).
struct ReaderProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(NotchLeeTheme.accent).frame(width: max(3, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Chapter progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// The island card's controls: the waveform is the play/pause button, with
/// sentence and paragraph skips around it and the pace on the right.
struct ReaderIslandTransport: View {
    @ObservedObject private var reader = ReaderController.shared
    @ObservedObject private var voice = VoiceAssistant.shared

    var body: some View {
        HStack(spacing: 12) {
            Button { reader.skipParagraph(-1) } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Previous paragraph")
            Button { reader.skipSentence(-1) } label: { Image(systemName: "gobackward") }.accessibilityLabel("Previous sentence")
            ReaderWaveformButton(size: 24)
            Button { reader.skipSentence(1) } label: { Image(systemName: "goforward") }.accessibilityLabel("Next sentence")
            Button { reader.skipParagraph(1) } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("Next paragraph")
            Spacer(minLength: 4)
            Menu {
                ForEach([0.8, 0.9, 1.0, 1.1, 1.2, 1.3], id: \.self) { rate in
                    Button(String(format: "%.1f×", rate)) { reader.setRate(rate) }
                }
            } label: {
                Text(String(format: "%.2g×", voice.speechRate)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Reading pace")
        }
        .buttonStyle(.press)
        .font(.system(size: 12))
    }
}

/// A library row: cover, title, a short description (or the author), and its
/// controls. Cover and description load off the main thread when the row
/// first appears (the list is lazy, so only visible rows do work).
struct ReaderBookRow: View {
    let book: ReaderBook
    let isOpen: Bool
    let listen: () -> Void
    @State private var details: ReaderBookDetails.Details?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            BookCoverView(image: details?.cover, title: book.title, width: 40, height: 56, corner: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.body.weight(.medium)).lineLimit(1)
                Text(details?.description ?? book.author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if book.progress > 0 {
                Text(book.progress, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(isOpen ? "Continue" : "Listen", action: listen).controlSize(.small)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(isOpen ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .task(id: book.id) {
            details = ReaderBookDetails.cached(book.id)
            if details == nil { details = await ReaderBookDetails.load(book) }
        }
    }
}

/// A visual library entry; selection previews a book without starting audio.
private struct ReaderBookTile: View {
    let book: ReaderBook
    let selected: Bool
    let favorite: Bool
    let select: () -> Void
    let favoriteAction: () -> Void
    @State private var details: ReaderBookDetails.Details?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .bottom) {
                        BookCoverView(image: details?.cover, title: book.title, width: 76, height: 106, corner: 6)
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 5)
                        Spacer()
                    }
                    Text(book.title).font(.headline).lineLimit(2).frame(height: 38, alignment: .topLeading)
                    Text(book.author.isEmpty ? "Unknown author" : book.author)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(selected ? Color.flowAccent.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? Color.flowAccent.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: 1))
            }.buttonStyle(ReaderCardPressStyle()).accessibilityLabel("Preview \(book.title)")
            HStack {
                Text(book.progress > 0 ? "\(Int(min(1, max(0, book.progress)) * 100))% in Apple Books" : "Ready to explore")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: favoriteAction) {
                    Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.flowAccent : .secondary)
                }.buttonStyle(ReaderCardPressStyle()).accessibilityLabel(favorite ? "Remove favorite" : "Add favorite")
            }.padding(.horizontal, 12)
        }

        .task(id: book.id) { details = ReaderBookDetails.cached(book.id); details = await ReaderBookDetails.load(book) }
    }
}

private struct ReaderBookPreview: View {
    let book: ReaderBook
    let open: (Bool) -> Void
    @State private var details: ReaderBookDetails.Details?
    @ObservedObject private var organization = ReaderController.shared.favorites

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                overview.frame(minWidth: 420, maxWidth: .infinity)
                readingGuide.frame(width: 260)
            }
            VStack(alignment: .leading, spacing: 18) { overview; readingGuide }
        }
        .task(id: book.id) { details = ReaderBookDetails.cached(book.id); details = await ReaderBookDetails.load(book) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("BOOK PREVIEW", systemImage: "book.closed").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Color.flowAccent)
            HStack(alignment: .top, spacing: 20) {
                BookCoverView(image: details?.cover, title: book.title, width: 100, height: 140, corner: 8)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(book.author.isEmpty ? "Unknown author" : book.author).foregroundStyle(.secondary)
                    Text("EPUB · Apple Books").font(.caption).foregroundStyle(.secondary)
                    if let date = book.lastOpened {
                        Text("Last opened \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                    }
                    if book.progress > 0 {
                        ProgressView(value: min(1, max(0, book.progress)))
                        Text("\(Int(min(1, max(0, book.progress)) * 100))% read in Apple Books").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(details?.description ?? "No synopsis is available locally. Open the book to explore its contents.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Read", systemImage: "book.pages") { open(false) }.buttonStyle(.borderedProminent)
                Button("Listen", systemImage: "headphones") { open(true) }.buttonStyle(.bordered)
                Spacer()
                Menu {
                    Button(organization.ids.contains(book.id) ? "Remove favorite" : "Add favorite") { organization.toggle(book.id) }
                    ForEach(organization.collections.keys.sorted(), id: \.self) { name in
                        Button { organization.toggle(book.id, in: name) } label: {
                            Label(name, systemImage: organization.collections[name]?.contains(book.id) == true ? "checkmark" : "folder")
                        }
                    }
                } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).fixedSize().accessibilityLabel("Organize this book")
            }.controlSize(.large)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.flowAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
    }

    private var readingGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "book.pages").font(.system(size: 32)).foregroundStyle(Color.flowAccent)
            Text("Make yourself at home").font(.title3.weight(.semibold))
            Text("Open a book to find your way through it.").foregroundStyle(.secondary)
            Label("Jump between chapters", systemImage: "list.bullet.indent")
            Label("Find a passage with ⌘F", systemImage: "magnifyingglass")
            Label("Save a place for later", systemImage: "bookmark")
            Label("Read one page or two", systemImage: "rectangle.split.2x1")
            Text("Browse at your own pace. Listening starts when you choose it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout).padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Native-feeling depth with a still alternative when Reduce Motion is enabled.
struct ReaderCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.07 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 2 : 0)
            .shadow(color: .black.opacity(configuration.isPressed ? 0.02 : 0.12), radius: configuration.isPressed ? 1 : 5, y: configuration.isPressed ? 0 : 3)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
