import Foundation
import NaturalLanguage

/// Reads an unpacked EPUB package (the form Apple Books keeps in its iCloud
/// folder) into a `ReaderDocument`. Read-only; never touches the package.
/// Zipped `.epub` files are not supported yet.
enum ReaderEPUB {
    enum Failure: LocalizedError, Equatable {
        case notAPackage, protected, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notAPackage: "This book isn't an unpacked EPUB package."
            case .protected: "This book is copy-protected and can't be read aloud."
            case .unreadable(let what): "Couldn't read \(what) in this book."
            }
        }
    }

    static func load(_ package: URL) throws -> ReaderDocument {
        let container = package.appendingPathComponent("META-INF/container.xml")
        guard let containerText = try? String(contentsOf: container, encoding: .utf8) else { throw Failure.notAPackage }
        if FileManager.default.fileExists(atPath: package.appendingPathComponent("META-INF/sinf.xml").path) { throw Failure.protected }
        if let encryption = try? String(contentsOf: package.appendingPathComponent("META-INF/encryption.xml"), encoding: .utf8),
           Self.encryptsContent(encryption) { throw Failure.protected }
        guard let opfPath = ReaderMarkup.elements(in: containerText).first(where: { $0.name == "rootfile" })?.attributes["full-path"]
        else { throw Failure.unreadable("the package description") }
        let opfURL = package.appendingPathComponent(opfPath)
        guard let opf = try? String(contentsOf: opfURL, encoding: .utf8) else { throw Failure.unreadable("the package description") }
        let base = opfURL.deletingLastPathComponent()
        let package = Package(opf)
        let toc = tableOfContents(package, base: base)

        var chapters: [ReaderChapter] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for (index, item) in package.spine.enumerated() {
            guard let entry = package.manifest[item.idref], entry.mediaType.contains("html") else { continue }
            let file = base.appendingPathComponent(entry.href.removingPercentEncoding ?? entry.href)
            guard let xhtml = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else { continue }
            let tocTitle = toc[Self.fileKey(entry.href)]
            let matter = !item.linear || entry.properties.contains("nav") || Self.isMatter(title: tocTitle, href: entry.href)
            var blocks = ReaderXHTML.blocks(xhtml)
            if matter { for i in blocks.indices { blocks[i].kind = .matter } }
            for i in blocks.indices where blocks[i].kind != .matter && !blocks[i].text.isEmpty {
                blocks[i].sentences = ReaderSegmenter.sentences(in: blocks[i].text, heading: blocks[i].kind == .heading, tokenizer: tokenizer)
            }
            let title = tocTitle ?? blocks.first { $0.kind == .heading && $0.spoken }?.text ?? "Section \(chapters.count + 1)"
            chapters.append(ReaderChapter(title: title, spineIndex: index, idref: item.idref, blocks: blocks))
        }
        return ReaderDocument(title: package.title ?? package.fallbackTitle(opfURL), author: package.creator ?? "",
                              language: package.language, chapters: chapters, cover: cover(package, base: base))
    }

    /// The cover image file: the EPUB 3 `cover-image` item, the EPUB 2 cover
    /// meta, or the first image in the cover page. Reads only the package
    /// description (and the cover page), never the book.
    static func coverURL(_ package: URL) -> URL? {
        guard let containerText = try? String(contentsOf: package.appendingPathComponent("META-INF/container.xml"), encoding: .utf8),
              let opfPath = ReaderMarkup.elements(in: containerText).first(where: { $0.name == "rootfile" })?.attributes["full-path"],
              let opf = try? String(contentsOf: package.appendingPathComponent(opfPath), encoding: .utf8) else { return nil }
        return cover(Package(opf), base: package.appendingPathComponent(opfPath).deletingLastPathComponent())
    }

    /// What a library row shows: the cover file and a short plain-text
    /// description. Reads only the package description and the cover page.
    struct Summary: Sendable { var cover: URL?; var description: String? }

    static func summary(_ package: URL) -> Summary {
        guard let containerText = try? String(contentsOf: package.appendingPathComponent("META-INF/container.xml"), encoding: .utf8),
              let opfPath = ReaderMarkup.elements(in: containerText).first(where: { $0.name == "rootfile" })?.attributes["full-path"],
              let opf = try? String(contentsOf: package.appendingPathComponent(opfPath), encoding: .utf8) else { return Summary() }
        let parsed = Package(opf)
        return Summary(cover: cover(parsed, base: package.appendingPathComponent(opfPath).deletingLastPathComponent()),
                       description: parsed.description.map { plainDescription($0) }.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// dc:description is often escaped HTML: strip tags, decode, collapse, and
    /// cut at a word boundary.
    static func plainDescription(_ raw: String, limit: Int = 220) -> String {
        let decoded = ReaderMarkup.decode(raw)
        let text = ReaderMarkup.collapse(ReaderMarkup.tokens("<x>" + decoded + "</x>").compactMap {
            if case .text(let value) = $0 { return value + " " }; return nil
        }.joined())
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    static func cover(_ package: Package, base: URL) -> URL? {
        func file(_ href: String) -> URL { base.appendingPathComponent(href.removingPercentEncoding ?? href).standardizedFileURL }
        if let item = package.manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) { return file(item.href) }
        if let id = package.coverID, let item = package.manifest[id], item.mediaType.hasPrefix("image/") { return file(item.href) }
        // The cover page: the first spine document named like a cover.
        let pages = package.spine.compactMap { package.manifest[$0.idref].map { ($0, $0.href.lowercased()) } }
        guard let page = pages.prefix(3).first(where: { $0.1.contains("cover") })?.0 ?? (package.manifest.values.first { $0.href.lowercased().contains("cover") && $0.mediaType.contains("html") }),
              let xhtml = try? String(contentsOf: file(page.href), encoding: .utf8) else { return nil }
        let pageBase = file(page.href).deletingLastPathComponent()
        for element in ReaderMarkup.elements(in: xhtml) where element.name == "img" || element.name == "image" {
            if let source = element.attributes["src"] ?? element.attributes["xlink:href"] ?? element.attributes["href"] {
                return pageBase.appendingPathComponent(source.removingPercentEncoding ?? source).standardizedFileURL
            }
        }
        return nil
    }

    /// Font obfuscation (IDPF/Adobe) is harmless; any other encrypted resource means DRM.
    static func encryptsContent(_ encryption: String) -> Bool {
        let algorithms = ReaderMarkup.elements(in: encryption).filter { $0.name == "EncryptionMethod" }.compactMap { $0.attributes["Algorithm"] }
        return algorithms.contains { !$0.contains("idpf.org/2008/embedding") && !$0.contains("ns.adobe.com/pdf/enc#RC") }
    }

    static func isMatter(title: String?, href: String) -> Bool {
        let pattern = #"(?i)\b(cover|copyright|table of contents|contents|toc|index|colophon|title ?page|half ?title|bibliography|also by|praise for)\b"#
        let file = (href as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        if let title { return title.range(of: pattern, options: .regularExpression) != nil && title.count < 40 }
        return file.range(of: pattern, options: .regularExpression) != nil
    }

    static func fileKey(_ href: String) -> String {
        let path = String(href.split(separator: "#", maxSplits: 1).first ?? "")
        return ((path.removingPercentEncoding ?? path) as NSString).lastPathComponent.lowercased()
    }

    struct Package {
        struct Item { var href: String; var mediaType: String; var properties: String }
        struct SpineItem { var idref: String; var linear: Bool }
        var title: String?, creator: String?, language: String?, description: String?
        var manifest: [String: Item] = [:]
        var spine: [SpineItem] = []
        var ncx: String?
        /// EPUB 2 `<meta name="cover" content="…">`: the manifest ID of the cover image.
        var coverID: String?

        init(_ opf: String) {
            let tokens = ReaderMarkup.tokens(opf)
            var capture: String?
            var text = ""
            for token in tokens {
                switch token {
                case .start(let name, let attributes, let selfClosing):
                    switch name {
                    case "item":
                        if let id = attributes["id"], let href = attributes["href"] {
                            manifest[id] = Item(href: href, mediaType: attributes["media-type"] ?? "", properties: attributes["properties"] ?? "")
                        }
                    case "itemref":
                        if let idref = attributes["idref"] { spine.append(SpineItem(idref: idref, linear: attributes["linear"] != "no")) }
                    case "spine": ncx = attributes["toc"]
                    case "meta": if attributes["name"] == "cover", let id = attributes["content"] { coverID = id }
                    case "title", "creator", "language", "description": if !selfClosing { capture = name; text = "" }
                    default: break
                    }
                case .text(let value): if capture != nil { text += value }
                case .end(let name):
                    guard name == capture else { break }
                    let value = ReaderMarkup.collapse(text)
                    if name == "title", title == nil, !value.isEmpty { title = value }
                    if name == "creator", creator == nil, !value.isEmpty { creator = value }
                    if name == "language", language == nil, !value.isEmpty { language = value }
                    if name == "description", description == nil, !value.isEmpty { description = value }
                    capture = nil
                }
            }
        }

        func fallbackTitle(_ opf: URL) -> String {
            opf.deletingLastPathComponent().deletingLastPathComponent().deletingPathExtension().lastPathComponent
        }
    }

    /// File name → first table-of-contents title, from the EPUB 3 nav document or the EPUB 2 NCX.
    static func tableOfContents(_ package: Package, base: URL) -> [String: String] {
        var result: [String: String] = [:]
        func add(_ href: String, _ title: String) {
            let key = fileKey(href), title = ReaderMarkup.collapse(title)
            if !key.isEmpty, !title.isEmpty, result[key] == nil { result[key] = title }
        }
        if let nav = package.manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let text = try? String(contentsOf: base.appendingPathComponent(nav.href), encoding: .utf8) {
            var inToc = false, depth = 0, href: String?, title = ""
            for token in ReaderMarkup.tokens(text) {
                switch token {
                case .start(let name, let attributes, _):
                    if name == "nav" {
                        let type = attributes["epub:type"] ?? ""
                        if type.contains("toc") { inToc = true; depth = 0 }
                        if inToc { depth += 1 }
                    }
                    if inToc, name == "a" { href = attributes["href"]; title = "" }
                case .text(let value): if href != nil { title += value }
                case .end(let name):
                    if inToc, name == "a", let target = href { add(target, title); href = nil }
                    if inToc, name == "nav" { depth -= 1; if depth == 0 { inToc = false } }
                }
            }
        }
        if result.isEmpty, let ncxID = package.ncx ?? package.manifest.first(where: { $0.value.mediaType.contains("dtbncx") })?.key,
           let ncx = package.manifest[ncxID], let text = try? String(contentsOf: base.appendingPathComponent(ncx.href), encoding: .utf8) {
            var label = "", inText = false, pending: String?
            for token in ReaderMarkup.tokens(text) {
                switch token {
                case .start(let name, let attributes, _):
                    if name == "navPoint" { label = ""; pending = nil }
                    if name == "text" { inText = true; label = "" }
                    if name == "content", let src = attributes["src"] { pending = src; add(src, label) }
                case .text(let value): if inText { label += value }
                case .end(let name): if name == "text" { inText = false }
                }
            }
            _ = pending
        }
        return result
    }
}

/// Turns one XHTML spine document into blocks, recording EPUB CFI paths as it
/// walks the element tree (even steps for elements, odd for text chunks).
enum ReaderXHTML {
    private static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "dt", "dd", "blockquote", "div",
        "pre", "table", "figure", "figcaption", "caption", "aside", "section", "article", "header", "footer", "nav", "ul", "ol",
        "dl", "tr", "td", "th", "hr", "main", "body", "math", "svg", "picture", "video", "audio", "canvas", "object", "iframe"]
    private static let voidTags: Set<String> = ["img", "br", "hr", "meta", "link", "input", "col", "area", "base", "wbr", "source", "embed", "param", "track"]

    private struct Element {
        var name: String
        var step: Int
        var children = 0
        var kind: ReaderBlockKind?
        var hidden = false
        /// Text inside `sup`/`a` waits until the element closes: a bare number is a note marker.
        var capture: [(path: [Int], text: String)]?
    }

    static func blocks(_ xhtml: String) -> [ReaderBlock] {
        var stack: [Element] = []
        var started = false
        var blocks: [ReaderBlock] = []
        var current: ReaderBlock?

        func path() -> [Int] { stack.dropFirst().map(\.step) }
        func flush() {
            if var block = current, !block.text.trimmingCharacters(in: .whitespaces).isEmpty {
                while block.text.hasSuffix(" ") { block.text.removeLast() }
                blocks.append(block)
            }
            current = nil
        }
        func contextKind() -> ReaderBlockKind {
            if let skip = stack.last(where: { $0.kind != nil && ![.heading, .listItem, .quote].contains($0.kind!) })?.kind { return skip }
            return stack.last(where: { $0.kind != nil })?.kind ?? .paragraph
        }
        func blockPath() -> [Int] {
            guard let last = stack.lastIndex(where: { blockTags.contains($0.name) }), last > 0 else { return [] }
            return stack[1...last].map(\.step)
        }
        func append(_ raw: String, at textPath: [Int]) {
            if current == nil {
                current = ReaderBlock(kind: contextKind(), text: "", path: stack.count > 1 ? blockPath() : [], anchors: [], sentences: [])
            }
            var piece = ReaderMarkup.collapse(raw, keepEdges: true)
            if current!.text.isEmpty || current!.text.hasSuffix(" ") { while piece.hasPrefix(" ") { piece.removeFirst() } }
            guard !piece.isEmpty else { return }
            current!.anchors.append(ReaderTextAnchor(path: textPath, blockOffset: current!.text.utf16.count, length: piece.utf16.count))
            current!.text += piece
        }

        for token in ReaderMarkup.tokens(xhtml) {
            switch token {
            case .start(let name, let attributes, let selfClosing):
                if !started {
                    guard name == "html" else { continue }
                    started = true
                    stack = [Element(name: "html", step: 0)]
                    continue
                }
                guard !stack.isEmpty else { continue }
                stack[stack.count - 1].children += 1
                var element = Element(name: name, step: 2 * stack[stack.count - 1].children)
                element.kind = classify(name, attributes)
                element.hidden = ["head", "script", "style", "title", "template"].contains(name) || attributes["aria-hidden"] == "true"
                if name == "sup" || (name == "a" && (attributes["href"]?.contains("#") ?? false)) { element.capture = [] }
                if blockTags.contains(name) { flush() }
                if name == "br" { if current != nil, !current!.text.hasSuffix(" ") { current!.text += " " }; continue }
                if selfClosing || voidTags.contains(name) { continue }
                stack.append(element)
            case .text(let raw):
                guard stack.count > 1, !stack.contains(where: \.hidden) else { continue }
                let parent = stack[stack.count - 1]
                let textPath = path() + [2 * parent.children + 1]
                if let i = stack.lastIndex(where: { $0.capture != nil }) {
                    stack[i].capture!.append((textPath, raw))
                    continue
                }
                if let kind = parent.kind, kind == .pageMarker || kind == .footnote, !blockTags.contains(parent.name) { continue }
                if stack.contains(where: { $0.kind == .pageMarker && !blockTags.contains($0.name) }) { continue }
                if stack.contains(where: { $0.kind == .footnote && !blockTags.contains($0.name) }) { continue }
                append(raw, at: textPath)
            case .end(let name):
                guard let i = stack.lastIndex(where: { $0.name == name }), i > 0 else { continue }
                // Implicitly close anything left open inside (tag soup).
                while stack.count > i {
                    let closing = stack.removeLast()
                    if let captured = closing.capture {
                        let text = captured.map(\.text).joined()
                        let isMarker = closing.kind == .footnote || Self.looksLikeNoteMarker(text)
                        if !isMarker {
                            if let outer = stack.lastIndex(where: { $0.capture != nil }) { stack[outer].capture!.append(contentsOf: captured) }
                            else if !stack.contains(where: \.hidden) { for part in captured { append(part.text, at: part.path) } }
                        }
                    }
                    if blockTags.contains(closing.name) { flush() }
                }
            }
        }
        flush()
        return blocks
    }

    static func looksLikeNoteMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "[]()")))
        guard !trimmed.isEmpty, trimmed.count <= 4 else { return false }
        return trimmed.allSatisfy { $0.isNumber || "*†‡§¶#abcdefghij".contains($0) }
    }

    static func classify(_ name: String, _ attributes: [String: String]) -> ReaderBlockKind? {
        let type = (attributes["epub:type"] ?? "").lowercased()
        let role = (attributes["role"] ?? "").lowercased()
        let classes = (attributes["class"] ?? "").lowercased()
        func typeHas(_ values: String...) -> Bool { values.contains { v in type.split(separator: " ").contains { $0 == v } } }
        if typeHas("pagebreak") || role == "doc-pagebreak" || classes.contains("pagebreak") || classes.contains("pagenum") || classes.contains("page-number") { return .pageMarker }
        if typeHas("noteref") || role == "doc-noteref" { return .footnote }
        if typeHas("footnote", "footnotes", "endnote", "endnotes", "rearnote", "rearnotes", "note") || role.hasPrefix("doc-footnote") || role.hasPrefix("doc-endnote") { return .footnote }
        if typeHas("index", "toc", "copyright-page", "colophon", "bibliography", "titlepage", "halftitlepage", "cover", "landmarks", "page-list", "loi", "lot") || name == "nav" { return .matter }
        switch name {
        case "figure", "img", "svg", "picture", "video", "audio", "canvas", "object", "iframe": return .figure
        case "figcaption", "caption": return .caption
        case "table": return .table
        case "pre": return .code
        case "math": return .math
        case "h1", "h2", "h3", "h4", "h5", "h6": return .heading
        case "li", "dt", "dd": return .listItem
        case "blockquote": return .quote
        default: break
        }
        if name == "div" || name == "p" || name == "span" {
            if ["programlisting", "screen", "code-block", "sourcecode", "highlight", "listing"].contains(where: { classes.contains($0) }) { return .code }
            if ["caption", "figcap", "figure-title", "fig-title"].contains(where: { classes.contains($0) }) && name != "span" { return .caption }
            if classes.split(separator: " ").contains("figure") || classes.contains("informalfigure") { return .figure }
            if classes.contains("table") && name == "div" && !classes.contains("tablecell") { return .table }
        }
        return nil
    }
}

/// Sentence ranges (UTF-16) for one block.
enum ReaderSegmenter {
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "Fig.", "fig.", "Dr.", "Mr.", "Mrs.", "Ms.", "No.",
        "Vol.", "vol.", "Ch.", "ch.", "pp.", "p.", "St.", "approx.", "Inc.", "Ltd.", "Jr.", "Sr.", "cf.", "al.", "Eq.", "Sec.", "Ex."]

    /// Pass one tokenizer for a whole book: creating one per paragraph dominates parsing.
    static func sentences(in text: String, heading: Bool = false, tokenizer: NLTokenizer? = nil) -> [Range<Int>] {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        if heading { return [0..<length] }
        let tokenizer = tokenizer ?? NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var starts: [Int] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.append(NSRange(range, in: text).location); return true
        }
        if starts.isEmpty || starts[0] != 0 { starts.insert(0, at: 0) }
        let ranges = zip(starts, starts.dropFirst() + [length]).map { $0..<$1 }.filter { !$0.isEmpty }
        func piece(_ range: Range<Int>) -> String {
            ns.substring(with: NSRange(location: range.lowerBound, length: range.count)).trimmingCharacters(in: .whitespaces)
        }
        func endsInAbbreviation(_ piece: String) -> Bool {
            guard let word = piece.split(separator: " ").last else { return false }
            let isInitial = word.count == 2 && word.first!.isUppercase && word.hasSuffix(".")
            return isInitial || abbreviations.contains(String(word))
        }
        // Rejoin a split after "Dr." or "J.", and fold very short fragments back in.
        var merged: [Range<Int>] = []
        var previous = ""
        for range in ranges {
            let fragment = piece(range)
            if let last = merged.last, endsInAbbreviation(previous) || previous.count < 12 || (fragment.count < 12 && !endsInAbbreviation(fragment)) {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
                previous = piece(merged[merged.count - 1])
                continue
            }
            merged.append(range)
            previous = fragment
        }
        // Split very long sentences at clause punctuation to keep look-ahead tight.
        return merged.flatMap { split($0, in: ns) }
    }

    private static func split(_ range: Range<Int>, in text: NSString) -> [Range<Int>] {
        guard range.count > 400 else { return [range] }
        let middle = range.lowerBound + range.count / 2
        for separator in ["; ", ": ", " — ", ", "] {
            var best: Int?
            var search = NSRange(location: range.lowerBound + 80, length: max(0, range.count - 160))
            while search.length > 0 {
                let found = text.range(of: separator, range: search)
                guard found.location != NSNotFound else { break }
                if best == nil || abs(found.location - middle) < abs(best! - middle) { best = found.location }
                let next = found.location + found.length
                search = NSRange(location: next, length: range.lowerBound + range.count - 80 - next)
            }
            if let best {
                let cut = best + (separator as NSString).length
                return split(range.lowerBound..<cut, in: text) + split(cut..<range.upperBound, in: text)
            }
        }
        return [range]
    }

    static func substring(_ text: String, _ range: Range<Int>) -> String {
        (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }
}

/// A small, lenient XML/HTML tokenizer: publishers' XHTML is often not well
/// formed, and the reader needs exact element counts for CFI paths.
enum ReaderMarkup {
    enum Token: Equatable {
        case start(String, [String: String], selfClosing: Bool)
        case text(String)
        case end(String)
    }

    struct ElementInfo { var name: String; var attributes: [String: String] }

    static func elements(in text: String) -> [ElementInfo] {
        tokens(text).compactMap { if case .start(let name, let attributes, _) = $0 { return ElementInfo(name: name, attributes: attributes) }; return nil }
    }

    static func tokens(_ source: String) -> [Token] {
        var tokens: [Token] = []
        let s = Array(source.utf8)
        let n = s.count
        var i = 0, textStart = 0
        func string(_ range: Range<Int>) -> String { String(decoding: s[range], as: UTF8.self) }
        func emitText(_ end: Int) { if end > textStart { tokens.append(.text(decode(string(textStart..<end)))) } }
        func match(_ literal: StaticString, at index: Int) -> Bool {
            let count = literal.utf8CodeUnitCount
            guard index + count <= n else { return false }
            let bytes = UnsafeBufferPointer(start: literal.utf8Start, count: count)
            for k in 0..<count where s[index + k] != bytes[k] { return false }
            return true
        }
        func find(_ literal: StaticString, from index: Int) -> Int? {
            var j = index
            while j < n { if match(literal, at: j) { return j }; j += 1 }
            return nil
        }
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), dq = UInt8(ascii: "\""), sq = UInt8(ascii: "'")
        while i < n {
            guard s[i] == lt else { i += 1; continue }
            emitText(i)
            if match("<!--", at: i) { i = min(n, (find("-->", from: i + 4) ?? n) + 3); textStart = i; continue }
            if match("<![CDATA[", at: i) {
                let end = find("]]>", from: i + 9) ?? n
                tokens.append(.text(string((i + 9)..<end)))
                i = min(n, end + 3); textStart = i; continue
            }
            if match("<?", at: i) || match("<!", at: i) { i = min(n, (find(">", from: i) ?? n) + 1); textStart = i; continue }
            // A tag: find its end, respecting quoted attribute values.
            var j = i + 1, quote: UInt8 = 0
            while j < n {
                if quote != 0 { if s[j] == quote { quote = 0 } }
                else if s[j] == dq || s[j] == sq { quote = s[j] }
                else if s[j] == gt { break }
                j += 1
            }
            tokens.append(tag(string((i + 1)..<min(j, n))))
            i = min(n, j + 1); textStart = i
        }
        emitText(n)
        return tokens
    }

    private static let attributePattern = try! NSRegularExpression(pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)

    private static func tag(_ inner: String) -> Token {
        var body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("/") {
            return .end(localName(String(body.dropFirst()).trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""))
        }
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body.removeLast() }
        let name = body.prefix { !$0.isWhitespace && $0 != "/" }
        var attributes: [String: String] = [:]
        let rest = body.dropFirst(name.count)
        let string = String(rest)
        if string.contains(where: { !$0.isWhitespace }) {
            let regex = attributePattern
            for m in regex.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
                guard let keyRange = Range(m.range(at: 1), in: string) else { continue }
                let value = (2...4).lazy.compactMap { Range(m.range(at: $0), in: string) }.first.map { String(string[$0]) } ?? ""
                attributes[String(string[keyRange])] = decode(value)
            }
        }
        return .start(localName(String(name)), attributes, selfClosing: selfClosing)
    }

    /// `opf:item` → `item`; HTML names are case-insensitive.
    private static func localName(_ name: String) -> String {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return local == local.uppercased() ? local.lowercased() : local
    }

    static func collapse(_ text: String, keepEdges: Bool = false) -> String {
        var out = ""
        var space = false
        for c in text {
            if c.isWhitespace || c == "\u{00AD}" {
                if c == "\u{00AD}" { continue }
                space = true
            } else {
                if space && (keepEdges || !out.isEmpty) { out.append(" ") }
                space = false
                out.append(c)
            }
        }
        if space && keepEdges { out.append(" ") }
        return out
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "times": "×", "divide": "÷", "middot": "·", "bull": "•", "laquo": "«", "raquo": "»", "shy": "\u{00AD}",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "ouml": "ö", "uuml": "ü", "auml": "ä", "ccedil": "ç",
        "ntilde": "ñ", "szlig": "ß", "euro": "€", "pound": "£", "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡",
        "minus": "−", "le": "≤", "ge": "≥", "ne": "≠", "rarr": "→", "larr": "←", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}"]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = "", i = text.startIndex
        while i < text.endIndex {
            if text[i] == "&", let semi = text[i...].prefix(12).firstIndex(of: ";") {
                let name = text[text.index(after: i)..<semi]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } }
                else if name.hasPrefix("#") { replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } }
                else { replacement = entities[String(name)] }
                if let replacement { out += replacement; i = text.index(after: semi); continue }
            }
            out.append(text[i]); i = text.index(after: i)
        }
        return out
    }
}
