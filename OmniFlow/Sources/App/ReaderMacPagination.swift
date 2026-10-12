import AppKit
import SwiftUI
import CoreText

/// Immutable layout results cross back from a background Core Text layout.
struct ReaderMacPages: Sendable {
    struct Page: Sendable { var range: NSRange; var text: String }
    var text: String
    var pages: [Page]
    var blocks: [Int: Int]
    var chapter: Int
    func page(for ref: ReaderSentenceRef, in document: ReaderDocument) -> Int? {
        guard ref.chapter == chapter, let start = blocks[ref.block] else { return nil }
        let offset = start + document.block(ref).sentences[ref.sentence].lowerBound
        return pages.firstIndex { NSLocationInRange(offset, $0.range) }
    }
    func ref(on page: Int, in document: ReaderDocument) -> ReaderSentenceRef? {
        guard pages.indices.contains(page) else { return nil }
        let range = pages[page].range
        for (b, start) in blocks.sorted(by: { $0.value < $1.value }) {
            let block = document.chapters[chapter].blocks[b]
            for (s, sentence) in block.sentences.enumerated() where block.spoken {
                if NSIntersectionRange(NSRange(location: start + sentence.lowerBound, length: sentence.count), range).length > 0 {
                    return .init(chapter: chapter, block: b, sentence: s)
                }
            }
        }
        return nil
    }
    static func attributes(fontSize: Double) -> [NSAttributedString.Key: Any] {
        [.font: CTFontCreateWithName("Georgia" as CFString, fontSize, nil),
         .foregroundColor: NSColor.labelColor]
    }
    static func build(document: ReaderDocument, chapter: Int, size: CGSize, fontSize: Double) -> Self {
        var text = "", blocks: [Int: Int] = [:]
        for (b, block) in document.chapters[chapter].blocks.enumerated() where ![.figure, .table, .code, .math, .pageMarker, .matter].contains(block.kind) && !block.text.isEmpty {
            blocks[b] = text.utf16.count
            text += block.text + "\n\n"
        }
        let attributed = NSAttributedString(string: text, attributes: attributes(fontSize: fontSize))
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var pages: [Page] = [], offset = 0
        let ns = text as NSString
        while offset < ns.length, !Task.isCancelled {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            let range = NSRange(location: offset, length: visible.length)
            pages.append(.init(range: range, text: ns.substring(with: range)))
            offset += visible.length
        }
        return Self(text: text, pages: pages, blocks: blocks, chapter: chapter)
    }
}

/// Draw exactly the Core Text layout used for pagination, avoiding SwiftUI text reflow.
struct ReaderMacPageCanvas: NSViewRepresentable {
    var text: String
    var fontSize: Double
    var highlight: NSRange?
    func makeNSView(context: Context) -> Canvas { Canvas() }
    func updateNSView(_ view: Canvas, context: Context) {
        view.text = text; view.fontSize = fontSize; view.highlight = highlight; view.needsDisplay = true
        view.setAccessibilityElement(true); view.setAccessibilityRole(.staticText); view.setAccessibilityValue(text)
    }
    final class Canvas: NSView {
        var text = ""
        var fontSize = 19.0
        var highlight: NSRange?
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let content = NSMutableAttributedString(string: text, attributes: ReaderMacPages.attributes(fontSize: fontSize))
            if let highlight, highlight.location + highlight.length <= content.length {
                content.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: highlight)
                content.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: highlight)
            }
            let setter = CTFramesetterCreateWithAttributedString(content)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: bounds, transform: nil), nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
    }
}
