import SwiftUI

/// Colours and fonts for the read-along view, supplied by each platform.
struct ReaderReadAlongStyle {
    var ink: Color
    var muted: Color
    var accent: Color
    var onAccent: Color
    var chapterTitle: Font
    var heading: Font
    var body: Font
    var small: Font
}

/// The book's text, following the narration: the chapter being read, with the
/// sentence being spoken in full ink and the current word lit within it
/// (estimated from playback progress, see `ReaderWordTiming`). Scrolls along on
/// its own until the reader scrolls away, then offers "Follow" to catch up.
/// Tapping a paragraph starts reading there. Text stays on the device.
/// Shared by iOS and the Mac: each supplies its engine and style.
struct ReaderReadAlongView: View {
    @ObservedObject var engine: ReaderEngine
    var style: ReaderReadAlongStyle
    /// The catch-up button's title ("Back to reading" on the Mac).
    var followTitle = "Follow"
    /// Shown above the chapter title, inside the scroll view (the Mac's cover header).
    var header: AnyView? = nil
    /// A sentence was clicked or tapped; reads from there unless the host handles it.
    var onSelect: ((ReaderSentenceRef) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true

    private var current: ReaderSentenceRef? { engine.currentRef }

    var body: some View {
        if let document = engine.document, let current {
            let chapter = document.chapters[current.chapter]
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: 0).id(Self.top)
                        if let header { header }
                        // Most chapters open with their own heading; show the title only when they don't.
                        if chapter.blocks.first(where: Self.shows)?.text != chapter.title {
                            Text(chapter.title).font(style.chapterTitle).foregroundStyle(style.ink)
                                .padding(.bottom, 4)
                        }
                        ForEach(Array(chapter.blocks.enumerated()), id: \.offset) { index, block in
                            if Self.shows(block) {
                                ReadAlongBlock(block: block, index: index, active: index == current.block ? current.sentence : nil,
                                               engine: engine, style: style, animate: engine.isPlaying && !reduceMotion)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                }
                // Each sentence is a link (see ReadAlongBlock): selecting one reads from it.
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == ReadAlongBlock.scheme, let parts = Optional(url.pathComponents.dropFirst().compactMap { Int($0) }),
                          parts.count == 2 else { return .systemAction }
                    select(ReaderSentenceRef(chapter: current.chapter, block: parts[0], sentence: parts[1]))
                    return .handled
                })
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { following = false }
                }
                .onChange(of: current) { old, new in
                    // A new chapter starts at its top; within a chapter, keep the spoken paragraph in view.
                    guard following, old.block != new.block || old.chapter != new.chapter else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { scroll(proxy, to: new) }
                }
                .onAppear { scroll(proxy, to: current) }
                .overlay(alignment: .bottomTrailing) {
                    if !following {
                        Button {
                            following = true
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { scroll(proxy, to: current) }
                        } label: {
                            Label(followTitle, systemImage: "text.line.first.and.arrowtriangle.forward")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(style.accent, in: Capsule()).foregroundStyle(style.onAccent)
                        }
                        .padding(16)
                        .transition(.opacity)
                    }
                }
            }
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "book", description: Text("Open a book to read along."))
        }
    }

    /// Text worth showing: speech, headings, quotes, lists, captions and notes.
    /// Figures, tables, code, maths and page markers have no readable text here.
    static func shows(_ block: ReaderBlock) -> Bool {
        ![.figure, .table, .code, .math, .pageMarker, .matter].contains(block.kind) && !block.text.isEmpty
    }

    private static let top = "top"

    /// Keeps the spoken paragraph a third of the way down; at a chapter's first
    /// paragraph, shows the top so the header and title stay whole.
    private func scroll(_ proxy: ScrollViewProxy, to ref: ReaderSentenceRef) {
        let first = engine.document?.chapters[ref.chapter].blocks.firstIndex(where: Self.shows)
        if ref.block <= first ?? 0 {
            proxy.scrollTo(Self.top, anchor: .top)
        } else {
            proxy.scrollTo(ref.block, anchor: UnitPoint(x: 0.5, y: 0.3))
        }
    }

    private func select(_ ref: ReaderSentenceRef) {
        following = true
        if let onSelect { onSelect(ref); return }
        guard let index = engine.order.firstIndex(of: ref) else { return }
        engine.seek(to: index)
    }
}

/// One paragraph. The paragraph being read redraws a few times a second to
/// move the word highlight; the others are plain text.
private struct ReadAlongBlock: View {
    static let scheme = "omniflow-read"
    let block: ReaderBlock
    let index: Int
    /// The sentence being spoken, when it's in this block.
    let active: Int?
    let engine: ReaderEngine
    let style: ReaderReadAlongStyle
    let animate: Bool

    var body: some View {
        if let active, block.sentences.indices.contains(active) {
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animate)) { _ in
                Text(highlighted(sentence: active, progress: engine.playback.sentenceProgress()))
                    .font(font).lineSpacing(6)
                    .tint(style.ink.opacity(0.62))
            }
            .accessibilityLabel(block.text)
        } else if block.spoken {
            Text(linked(except: nil)).font(font).lineSpacing(6)
                .tint(style.ink.opacity(0.62))
        } else {
            Text(block.text).font(font).lineSpacing(6).foregroundStyle(style.muted.opacity(0.7))
        }
    }

    private var font: Font {
        switch block.kind {
        case .heading: style.heading
        case .caption, .footnote: style.small
        default: style.body
        }
    }

    /// The block with every sentence (but `except`) as a link to itself, so a
    /// tap or click lands on a sentence. Links take the view's tint colour.
    private func linked(except active: Int?) -> AttributedString {
        var text = AttributedString(block.text)
        text.foregroundColor = style.ink.opacity(0.62)
        for (sentence, range) in block.sentences.enumerated() where sentence != active {
            guard let span = Range(NSRange(location: range.lowerBound, length: range.count), in: text),
                  let url = URL(string: "\(Self.scheme)://s/\(index)/\(sentence)") else { continue }
            text[span].link = url
        }
        return text
    }

    private func highlighted(sentence: Int, progress: Double?) -> AttributedString {
        var text = linked(except: sentence)
        let range = block.sentences[sentence]
        if let span = Range(NSRange(location: range.lowerBound, length: range.count), in: text) {
            text[span].foregroundColor = style.ink
        }
        let words = ReaderWordTiming.words(in: block.substring(range))
        if let progress, let word = ReaderWordTiming.word(at: progress, in: words),
           let span = Range(NSRange(location: range.lowerBound + word.lowerBound, length: word.count), in: text) {
            text[span].foregroundColor = style.onAccent
            text[span].backgroundColor = style.accent
        }
        return text
    }
}
