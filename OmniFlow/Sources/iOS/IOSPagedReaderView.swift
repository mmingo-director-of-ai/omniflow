import SwiftUI
import UIKit

/// The book as pages: swipe or tap the edges to turn, tap the middle for the
/// controls. While the narration plays, the spoken word is lit and pages turn to keep up, until the reader turns away; then
/// "Back to reading" catches up. Contents, a progress scrubber and the Aa
/// settings live in the controls. With the Scroll layout it shows the shared
/// read-along view instead.
///
/// Performance: the controls float over the page, so the page area never
/// changes size; each chapter is paginated once per size and appearance, off
/// the main thread (`IOSPaginationCache`); and highlights are drawn as a layer
/// over static text, so moving the word repaints one view without layout.
struct IOSPagedReaderView: View {
    @ObservedObject private var model = IOSReaderModel.shared
    @ObservedObject private var engine = IOSReaderModel.shared.engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @AppStorage("omniflow.reader.readAlong") private var readAlong = false
    @State private var appearance = IOSReaderAppearance.load()
    @State private var layout: IOSChapterPages?
    @State private var chapter = 0
    /// -1 and `pages.count` are the edges into the previous and next chapters.
    @State private var page = 0
    @State private var area: CGSize = .zero
    @State private var chrome = false
    @State private var following = true
    @State private var showContents = false
    @State private var showAppearance = false
    @State private var scrub: Double?
    /// The reader turned the page itself (following the narration), not a swipe.
    @State private var turningForNarration = false

    var body: some View {
        Group {
            if engine.document == nil {
                ContentUnavailableView("Nothing open", systemImage: "book", description: Text("Open a book to read along."))
            } else if appearance.layout == .scroll {
                ReaderReadAlongView(engine: engine, style: scrollStyle, followTitle: "Back to reading")
                    .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            } else {
                GeometryReader { geometry in
                    pages
                        .onAppear { resize(geometry.size) }
                        .onChange(of: geometry.size) { _, new in resize(new) }
                }
                // The controls float over the page; the page area never changes size.
                .overlay(alignment: .top) { if chrome { topBar.transition(.move(edge: .top).combined(with: .opacity)) } }
                .overlay(alignment: .bottom) { if chrome { controls.transition(.move(edge: .bottom).combined(with: .opacity)) } }
            }
        }
        .background(appearance.theme.paper.ignoresSafeArea())
        .toolbar(appearance.layout == .pages ? .hidden : .visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if appearance.layout == .scroll {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Contents")
                    Button { showAppearance = true } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Appearance")
                }
            }
        }
        .background {
            if !showContents && !showAppearance {
                HStack {
                    Button("Previous page") { turn(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("Next page") { turn(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("Play or pause") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                    Button("Previous sentence") { engine.skipSentence(-1); backToReading() }.keyboardShortcut(.leftArrow, modifiers: .option)
                    Button("Next sentence") { engine.skipSentence(1); backToReading() }.keyboardShortcut(.rightArrow, modifiers: .option)
                }.frame(width: 0, height: 0).clipped().accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showContents) { contents }
        .sheet(isPresented: $showAppearance) { IOSReaderAppearanceSheet(appearance: $appearance) }
        .onChange(of: appearance) { _, new in new.save(); relayout() }
        .onChange(of: engine.currentRef) { _, ref in followNarration(to: ref) }
        .onAppear {
            chapter = engine.currentRef?.chapter ?? 0
            following = appearance.followNarration
        }
        .preferredColorScheme(appearance.theme.isDark ? .dark : .light)
        .statusBarHidden(!chrome && appearance.layout == .pages)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chrome)
    }

    // MARK: - Pages

    @ViewBuilder private var pages: some View {
        if let layout, layout.chapter == chapter {
            TabView(selection: $page) {
                if chapter > 0 { edge("Previous chapter").tag(-1) }
                ForEach(0..<layout.pages.count, id: \.self) { index in
                    pageView(index, of: layout).tag(index)
                }
                if let document = engine.document, chapter + 1 < document.chapters.count { edge("Next chapter").tag(layout.pages.count) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page) { _, new in turned(to: new) }
        } else {
            ProgressView().tint(appearance.theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pageView(_ index: Int, of layout: IOSChapterPages) -> some View {
        VStack(spacing: 0) {
            Text(engine.document?.chapters[chapter].title ?? "")
                .font(.caption).foregroundStyle(appearance.theme.ink.opacity(0.45)).lineLimit(1)
                .frame(height: Self.header)
            // Only the page being narrated redraws, and only its highlight layer.
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animates(index, in: layout))) { _ in
                PageCanvas(text: layout.text.attributedSubstring(from: layout.pages[index]), highlight: highlight(index, in: layout),
                           wordColor: UIColor(appearance.theme.accent.opacity(appearance.theme.isDark ? 0.6 : 0.35)))
                    .frame(width: textSize.width, height: textSize.height)
            }
            Spacer(minLength: 0)
            Text("\(index + 1) of \(layout.pages.count)")
                .font(.caption2.monospacedDigit()).foregroundStyle(appearance.theme.ink.opacity(0.45))
                .frame(height: Self.footer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearance.theme.paper)
        .contentShape(Rectangle())
        // Edges turn the page; the middle shows or hides the controls.
        .onTapGesture(coordinateSpace: .local) { location in
            if location.x < area.width * 0.25 { turn(by: -1) }
            else if location.x > area.width * 0.75 { turn(by: 1) }
            else { chrome.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Next page") { turn(by: 1) }
        .accessibilityAction(named: "Previous page") { turn(by: -1) }
    }

    private static let header: CGFloat = 30, footer: CGFloat = 26

    private func edge(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(appearance.theme.ink.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(appearance.theme.paper)
    }

    /// The text area: the page minus margins, the chapter title and the page number.
    private var textSize: CGSize {
        CGSize(width: max(0, area.width - appearance.margins.points * 2), height: max(0, area.height - Self.header - Self.footer - 8))
    }

    private func animates(_ index: Int, in layout: IOSChapterPages) -> Bool {
        guard engine.isPlaying, appearance.highlightWords, !reduceMotion, let document = engine.document,
              let ref = engine.currentRef else { return false }
        return layout.page(of: ref, in: document) == index
    }

    /// The spoken word on this page, as a range local to the page.
    private func highlight(_ index: Int, in layout: IOSChapterPages) -> PageCanvas.Highlight {
        guard let document = engine.document, let ref = engine.currentRef, ref.chapter == layout.chapter,
              let start = layout.blockStarts[ref.block] else { return .none }
        let page = layout.pages[index]
        func local(_ range: NSRange) -> NSRange? {
            let overlap = NSIntersectionRange(range, page)
            return overlap.length > 0 ? NSRange(location: overlap.location - page.location, length: overlap.length) : nil
        }
        let sentence = document.block(ref).sentences[ref.sentence]
        var result = PageCanvas.Highlight.none
        if appearance.highlightWords, engine.isPlaying || engine.status == .paused, let progress = engine.playback.sentenceProgress(),
           let word = ReaderWordTiming.word(at: progress, in: ReaderWordTiming.words(in: document.text(ref))) {
            result.word = local(NSRange(location: start + sentence.lowerBound + word.lowerBound, length: word.count))
        }
        return result
    }

    // MARK: - Layout and turning

    private func key(_ chapter: Int) -> IOSPaginationCache.Key? {
        guard let book = model.book?.id, textSize.width > 40, textSize.height > 40 else { return nil }
        return IOSPaginationCache.Key(book: book, chapter: chapter, width: Int(textSize.width), height: Int(textSize.height), appearance: appearance)
    }

    private func resize(_ new: CGSize) {
        guard new != area else { return }
        area = new
        relayout()
    }

    /// Shows a chapter: from the cache at once, or laid out off the main thread.
    /// Keeps the place (the narrated page when following, else the same text).
    private func relayout(to target: Int? = nil, page wanted: Int? = nil) {
        guard let document = engine.document, let key = key(target ?? chapter) else { return }
        let keep = layout.flatMap { old in old.chapter == key.chapter && old.pages.indices.contains(page) ? old.pages[page].location : nil }
        let place = { (fresh: IOSChapterPages) in
            chapter = fresh.chapter
            layout = fresh
            #if DEBUG
            // Screenshots: `-OmniFlowReaderPage 40` opens that page (checks pages far ahead of the narration).
            let debugPage = UserDefaults.standard.integer(forKey: "OmniFlowReaderPage")
            if debugPage > 0, wanted == nil { following = false; setPage(min(debugPage, fresh.pages.count - 1)); prefetchNeighbours(of: fresh.chapter, document: document); return }
            #endif
            if let wanted { setPage(wanted == .max ? max(0, fresh.pages.count - 1) : wanted) }
            else if following, let ref = engine.currentRef, ref.chapter == fresh.chapter, let narrated = fresh.page(of: ref, in: document) { setPage(narrated) }
            else if let keep { setPage(fresh.pages.firstIndex { NSLocationInRange(keep, $0) } ?? 0) }
            else { setPage(0) }
            prefetchNeighbours(of: fresh.chapter, document: document)
        }
        if let cached = IOSPaginationCache.shared.cached(key) { place(cached); return }
        Task {
            let fresh = await IOSPaginationCache.shared.pages(key, document: document)
            guard self.key(key.chapter) == key else { return }   // settings or size changed meanwhile
            place(fresh)
        }
    }

    /// Lay out the chapters either side in the background, so crossing into them is instant.
    private func prefetchNeighbours(of chapter: Int, document: ReaderDocument) {
        for neighbour in [chapter + 1, chapter - 1] where document.chapters.indices.contains(neighbour) {
            if let key = key(neighbour), IOSPaginationCache.shared.cached(key) == nil {
                Task { _ = await IOSPaginationCache.shared.pages(key, document: document) }
            }
        }
    }

    private func setPage(_ index: Int) {
        turningForNarration = true
        page = index
        Task { @MainActor in turningForNarration = false }
    }

    private func turn(by delta: Int) {
        guard let layout, let document = engine.document,
              !(delta < 0 && page == 0 && chapter == 0),
              !(delta > 0 && page >= layout.pages.count - 1 && chapter == document.chapters.count - 1) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page += delta }
    }

    /// Past an edge opens the next or previous chapter; turning away from the
    /// narration while it plays stops following it.
    private func turned(to new: Int) {
        guard let document = engine.document, let layout else { return }
        if new < 0, chapter > 0 { relayout(to: chapter - 1, page: .max); return }
        if new >= layout.pages.count, chapter + 1 < document.chapters.count { relayout(to: chapter + 1, page: 0); return }
        if !turningForNarration, engine.isPlaying, let ref = engine.currentRef, layout.page(of: ref, in: document) != new {
            following = false
        }
    }

    private func followNarration(to ref: ReaderSentenceRef?) {
        guard let ref, let document = engine.document, following, appearance.followNarration else { return }
        if ref.chapter != chapter { relayout(to: ref.chapter); return }
        guard let layout, let target = layout.page(of: ref, in: document), target != page else { return }
        turningForNarration = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { page = target }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); turningForNarration = false }
    }

    private func backToReading() {
        following = true
        guard let ref = engine.currentRef, let document = engine.document else { return }
        if ref.chapter != chapter { relayout(to: ref.chapter); return }
        if let target = layout?.page(of: ref, in: document) { setPage(target) }
    }

    // MARK: - Controls

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back")
            Text(model.book?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
            Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Contents")
            Button { showAppearance = true } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Appearance")
            Button { readAlong = false } label: { Image(systemName: "circle.circle") }.accessibilityLabel("Show the player")
        }
        .font(.title3).foregroundStyle(appearance.theme.ink)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let document = engine.document, !engine.order.isEmpty {
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { scrub ?? Double(engine.index) }, set: { scrub = $0 }),
                           in: 0...Double(max(1, engine.order.count - 1))) { editing in
                        if !editing, let target = scrub { engine.seek(to: Int(target)); following = true; scrub = nil; backToReading() }
                    }
                    .tint(appearance.theme.accent)
                    .accessibilityLabel("Position in the book")
                    HStack {
                        Text(scrubChapter(document)).lineLimit(1)
                        Spacer()
                        Text("\(Int((Double(scrub.map { Int($0) } ?? engine.index) / Double(max(1, engine.order.count)) * 100).rounded()))%")
                            .monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(appearance.theme.ink.opacity(0.6))
                }
            }
            HStack(spacing: 14) {
                button("backward.end.fill", "Previous chapter") { engine.skipChapter(-1); backToReading() }
                button("arrow.uturn.backward", "Previous sentence") { engine.skipSentence(-1); backToReading() }
                Button { model.togglePlay() } label: {
                    ZStack {
                        VoiceRing(listening: engine.isPlaying, color: appearance.theme.accent) { ReaderEngine.outputSpectrum(engine) }
                            .frame(width: 64, height: 64).opacity(engine.isPlaying ? 1 : 0.55)
                        Circle().fill(appearance.theme.accent).frame(width: 52, height: 52)
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(appearance.theme.onAccent)
                    }
                    .frame(width: 64, height: 64).contentShape(Circle())
                }
                .buttonStyle(IOSReaderPressStyle())
                .accessibilityLabel(engine.isPlaying ? "Pause reading" : "Resume reading")
                button("goforward.15", "Forward 15 seconds") { engine.skipSeconds(15) }
                button("forward.end.fill", "Next chapter") { engine.skipChapter(1); backToReading() }
            }
            .font(.title3).foregroundStyle(appearance.theme.ink)
            if appearance.layout == .pages, let document = engine.document, let layout {
                if !following, engine.currentRef != nil {
                    pill("Back to reading", "text.line.first.and.arrowtriangle.forward") { backToReading() }
                } else if let first = layout.firstSentence(onPage: page, in: document), first != engine.currentRef, !engine.isPlaying {
                    pill("Read from this page", "play") {
                        if let index = engine.order.firstIndex(of: first) { engine.seek(to: index) }
                        following = true
                        model.play()
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func scrubChapter(_ document: ReaderDocument) -> String {
        let index = scrub.map { Int($0) } ?? engine.index
        guard engine.order.indices.contains(index) else { return "" }
        return document.chapters[engine.order[index].chapter].title
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func pill(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(appearance.theme.accent, in: Capsule()).foregroundStyle(appearance.theme.onAccent)
        }
        .buttonStyle(.plain)
    }

    private var contents: some View {
        NavigationStack {
            List {
                if let document = engine.document {
                    ForEach(Array(document.chapters.enumerated()), id: \.offset) { index, item in
                        Button {
                            engine.startChapter(index)
                            following = true
                            relayout(to: index, page: 0)
                            showContents = false
                        } label: {
                            HStack {
                                Text(item.title.isEmpty ? "Chapter \(index + 1)" : item.title).foregroundStyle(.primary)
                                Spacer()
                                if engine.currentRef?.chapter == index { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                            }
                        }
                        .disabled(!engine.order.contains { $0.chapter == index })
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var scrollStyle: ReaderReadAlongStyle {
        ReaderReadAlongStyle(ink: appearance.theme.ink, muted: appearance.theme.ink.opacity(0.6),
                             accent: appearance.theme.accent, onAccent: appearance.theme.onAccent,
                             chapterTitle: Font(appearance.font(heading: true)), heading: Font(appearance.font(heading: true)),
                             body: Font(appearance.font()), small: Font(appearance.font().withSize(appearance.size * 0.8)))
    }
}

/// One page: its text laid out once with the same TextKit settings as the
/// pagination, and the highlights drawn behind it. Changing a highlight only
/// repaints; the text is never laid out again.
private struct PageCanvas: UIViewRepresentable {
    struct Highlight: Equatable {
        var word: NSRange?
        static let none = Highlight()
    }
    let text: NSAttributedString
    let highlight: Highlight
    let wordColor: UIColor

    func makeUIView(context: Context) -> PageCanvasView { PageCanvasView() }

    func updateUIView(_ view: PageCanvasView, context: Context) {
        view.wordColor = wordColor
        view.text = text
        view.highlight = highlight
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PageCanvasView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

private final class PageCanvasView: UIView {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    var wordColor = UIColor.clear

    var text = NSAttributedString() {
        didSet { if !text.isEqual(to: oldValue) { storage.setAttributedString(text); setNeedsDisplay() } }
    }
    var highlight = PageCanvas.Highlight.none {
        didSet { if highlight != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if container.size != bounds.size { container.size = bounds.size; setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        let state = IOSPaginationCache.signposts.beginInterval("drawPage")
        defer { IOSPaginationCache.signposts.endInterval("drawPage", state) }
        fill(highlight.word, wordColor, radius: 5)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
    }

    private func fill(_ range: NSRange?, _ color: UIColor, radius: CGFloat) {
        guard let range, NSMaxRange(range) <= storage.length else { return }
        color.setFill()
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: container) { box, _ in
            UIBezierPath(roundedRect: box.insetBy(dx: -2, dy: 1), cornerRadius: radius).fill()
        }
    }
}

private struct IOSReaderPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
