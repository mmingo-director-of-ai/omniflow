import SwiftUI
import UniformTypeIdentifiers

/// The Reader's library on iPhone and iPad: books in the folder the user chose
/// (usually in iCloud Drive) and books imported from Files or the Share sheet.
/// Apple Books' own library is private to Books, so it can't appear here.
struct IOSReaderLibraryView: View {
    @ObservedObject private var library = IOSReaderLibrary.shared
    /// Opens a book for listening; `readAlong` shows its text rather than the player.
    var open: (_ book: IOSReaderBook, _ readAlong: Bool) -> Void
    @State private var picking: Source?
    @AppStorage("omniflow.reader.libraryGrid") private var showGrid = false
    @State private var search = ""
    @AppStorage("omniflow.reader.sort") private var sort = IOSReaderSort.recentlyListened
    /// When each book was last listened to (from the vault-sealed positions), for sorting.
    @State private var listened: [String: Date] = [:]

    private enum Source: Identifiable { case folder, files; var id: Self { self } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sourceCard
                if let problem = library.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.ink)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.banner, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if library.books.isEmpty && !library.scanning {
                    Text("Books you add appear here. OmniFlow reads EPUB files that aren't copy-protected; books bought in Apple Books are protected and stay in Books.")
                        .font(.subheadline).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                }
                Picker("Library display", selection: $showGrid) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Grid", systemImage: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.segmented)
                if visibleBooks.isEmpty && !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if showGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 14)], spacing: 14) {
                        ForEach(visibleBooks) { book in
                            BookGridCard(book: book, cover: library.covers[book.id],
                                         listen: { open(book, false) }, read: { open(book, true) })
                                .disabled(book.waitingForICloud)
                        }
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(visibleBooks) { book in
                            BookRow(book: book, cover: library.covers[book.id],
                                    listen: { open(book, false) }, read: { open(book, true) })
                                .disabled(book.waitingForICloud)
                                .contextMenu {
                                    Button("Listen", systemImage: "play.fill") { open(book, false) }
                                    Button("Read along", systemImage: "text.alignleft") { open(book, true) }
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background { Theme.backdrop }
        .navigationTitle("Listen")
        .searchable(text: $search, prompt: "Search title or author")
        .refreshable { library.rescan() }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Picker("Sort by", systemImage: "arrow.up.arrow.down", selection: $sort) {
                    ForEach(IOSReaderSort.allCases) { Text($0.title).tag($0) }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Choose a folder…", systemImage: "folder") { picking = .folder }
                    Button("Add books from Files…", systemImage: "doc.badge.plus") { picking = .files }
                    if library.folderName != nil {
                        Button("Stop using the folder", systemImage: "folder.badge.minus", role: .destructive) { library.forgetFolder() }
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add books")
            }
        }
        .fileImporter(isPresented: Binding(get: { picking == .folder }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.chooseFolder(url) }
        }
        .fileImporter(isPresented: Binding(get: { picking == .files }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: [.epub], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .onAppear {
            library.rescan()
            // Off the main thread: positions are decrypted from the vault.
            Task {
                let books = await Task.detached(priority: .utility) { ReaderPositionStore.standard.load().books }.value
                listened = books.mapValues(\.position.updatedAt)
            }
        }
    }

    private var visibleBooks: [IOSReaderBook] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let books = query.isEmpty ? library.books : library.books.filter {
            $0.title.localizedStandardContains(query) || $0.author.localizedStandardContains(query)
        }
        return sort.ordered(books, listened: listened)
    }

    /// Where books come from: the chosen folder, or a prompt to choose one.
    private var sourceCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud").font(.title3).foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40).background(Theme.banner, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(library.folderName ?? "Choose your books folder").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(library.folderName == nil ? "A folder of EPUBs in iCloud Drive or on this device"
                     : library.scanning ? "Looking for books…" : "\(library.books.count) book\(library.books.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            if library.scanning { ProgressView().tint(Theme.accent) }
            else if library.folderName == nil {
                Button("Choose") { picking = .folder }.buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
            }
        }
        .card(padding: 12)
    }
}

private struct BookGridCard: View {
    let book: IOSReaderBook
    let cover: UIImage?
    var listen: () -> Void
    var read: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: listen) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        Theme.heroTop
                        if let cover {
                            Image(uiImage: cover).resizable().scaledToFit()
                        } else {
                            Text(ReaderCover.initials(book.title))
                                .font(Theme.heading(32)).foregroundStyle(Theme.mint)
                        }
                    }
                    .frame(height: 190).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(book.title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink).lineLimit(2, reservesSpace: true)
                    Text(book.author.isEmpty ? "Unknown author" : book.author)
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Listen to \(book.title)")
            if book.waitingForICloud {
                Label("Waiting for iCloud…", systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                HStack {
                    Button("Read along", systemImage: "text.alignleft", action: read)
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button(action: listen) { Image(systemName: "play.circle.fill").font(.title2) }
                        .accessibilityLabel("Listen to \(book.title)")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .card(padding: 10)
        .opacity(book.waitingForICloud ? 0.7 : 1)
        .contextMenu {
            Button("Listen", systemImage: "play.fill", action: listen)
            Button("Read along", systemImage: "text.alignleft", action: read)
        }
    }
}

private struct BookRow: View {
    let book: IOSReaderBook
    let cover: UIImage?
    var listen: () -> Void
    var read: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                else {
                    ZStack {
                        Theme.heroTop
                        Text(initials).font(Theme.heading(15)).foregroundStyle(Theme.mint)
                    }
                }
            }
            .frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                if book.waitingForICloud {
                    Label("Waiting for iCloud…", systemImage: "icloud.and.arrow.down").font(.caption).foregroundStyle(Theme.muted)
                } else if !book.author.isEmpty {
                    Text(book.author).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: read) {
                Image(systemName: "text.alignleft").font(.title3).foregroundStyle(book.waitingForICloud ? Theme.muted : Theme.ink)
                    .frame(width: 40, height: 40).background(Theme.banner, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Read along with \(book.title)")
            Button(action: listen) {
                Image(systemName: "play.circle.fill").font(.title).foregroundStyle(book.waitingForICloud ? Theme.muted : Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Listen to \(book.title)")
        }
        .card(padding: 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: listen)
        .opacity(book.waitingForICloud ? 0.7 : 1)
        .accessibilityHint(book.waitingForICloud ? "Downloading from iCloud" : "")
    }

    private var initials: String { ReaderCover.initials(book.title) }
}

/// The Reader's page: what's playing now, then the library. Opening a book
/// starts it and shows the player.
struct IOSReaderHome: View {
    @ObservedObject private var model = IOSReaderModel.shared
    @ObservedObject private var engine = IOSReaderModel.shared.engine
    @State private var showingPlayer = false
    @AppStorage("omniflow.reader.readAlong") private var readAlong = false

    var body: some View {
        IOSReaderLibraryView { book, readAlong in
            self.readAlong = readAlong
            model.open(book, autoplay: !readAlong)
            showingPlayer = true
        }
        .safeAreaInset(edge: .bottom) {
            if model.isActive, let book = model.book {
                Button { showingPlayer = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: engine.isPlaying ? "waveform" : "pause.circle")
                            .symbolEffect(.variableColor.iterative, isActive: engine.isPlaying)
                            .foregroundStyle(Theme.accent).font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(model.chapterTitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Button { model.togglePlay() } label: {
                            Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").font(.title3).foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(engine.isPlaying ? "Pause reading" : "Resume reading")
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 16).padding(.bottom, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(isPresented: $showingPlayer) { IOSReaderPlayerView() }
        #if DEBUG
        .task {
            guard UserDefaults.standard.bool(forKey: "OmniFlowReaderDemo") else { return }
            for _ in 0..<20 where IOSReaderLibrary.shared.books.first(where: { !$0.waitingForICloud }) == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let book = IOSReaderLibrary.shared.books.first(where: { !$0.waitingForICloud }) else { return }
            readAlong = true
            model.open(book, autoplay: false)
            showingPlayer = true
        }
        #endif
    }
}

/// How the library is ordered; remembered between launches.
enum IOSReaderSort: String, CaseIterable, Identifiable {
    case recentlyListened, title, author, recentlyAdded
    var id: Self { self }

    var title: String {
        switch self {
        case .recentlyListened: "Recently listened"
        case .title: "Title"
        case .author: "Author"
        case .recentlyAdded: "Recently added"
        }
    }

    /// Books never listened to (or without an author or date) follow the rest, by title.
    func ordered(_ books: [IOSReaderBook], listened: [String: Date]) -> [IOSReaderBook] {
        let byTitle: (IOSReaderBook, IOSReaderBook) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        func newestFirst(_ date: @escaping (IOSReaderBook) -> Date?) -> (IOSReaderBook, IOSReaderBook) -> Bool {
            { a, b in
                switch (date(a), date(b)) {
                case let (x?, y?) where x != y: x > y
                case (_?, nil): true
                case (nil, _?): false
                default: byTitle(a, b)
                }
            }
        }
        switch self {
        case .title: return books.sorted(by: byTitle)
        case .author:
            return books.sorted { a, b in
                switch (a.author.isEmpty, b.author.isEmpty) {
                case (false, true): return true
                case (true, false): return false
                default:
                    let order = a.author.localizedStandardCompare(b.author)
                    return order == .orderedSame ? byTitle(a, b) : order == .orderedAscending
                }
            }
        case .recentlyListened: return books.sorted(by: newestFirst { listened[$0.id] })
        case .recentlyAdded: return books.sorted(by: newestFirst { $0.modified })
        }
    }
}
