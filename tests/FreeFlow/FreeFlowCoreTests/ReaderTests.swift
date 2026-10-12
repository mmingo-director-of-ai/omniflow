import Foundation
import Testing
@testable import OmniFlowApp

/// A small synthetic EPUB written for these tests (no real book text).
private func makeFixture(extra: [String: String] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-fixture-\(UUID().uuidString).epub", isDirectory: true)
    let files: [String: String] = [
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """,
        "OEBPS/content.opf": """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fixture Field Guide</dc:title>
        <dc:creator>Test Author</dc:creator><dc:language>en</dc:language></metadata>
        <manifest>
          <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="ch01" href="ch01.xhtml" media-type="application/xhtml+xml"/>
          <item id="ch02" href="text/ch02.xhtml" media-type="application/xhtml+xml"/>
          <item id="idx" href="index.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="cover"/><itemref idref="nav" linear="no"/><itemref idref="ch01"/><itemref idref="ch02"/><itemref idref="idx"/></spine>
        </package>
        """,
        "OEBPS/nav.xhtml": """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head><body>
        <nav epub:type="toc"><ol><li><a href="cover.xhtml">Cover</a></li><li><a href="ch01.xhtml">Chapter 1. Getting Started</a></li>
        <li><a href="text/ch02.xhtml#top">Chapter 2. Next Steps</a></li><li><a href="index.xhtml">Index</a></li></ol></nav></body></html>
        """,
        "OEBPS/cover.xhtml": "<html><head><title>Cover</title></head><body><p>Cover words should never be spoken.</p></body></html>",
        "OEBPS/ch01.xhtml": """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Ch 1</title><style>p { color: red; }</style></head>
        <body>
        <section id="s1">
        <h1>Getting Started</h1>
        <p id="p1">The first paragraph sets the scene.<sup><a href="#fn1" epub:type="noteref">1</a></sup> It has a second sentence&nbsp;too.</p>
        <p>A page marker sits here<span epub:type="pagebreak" id="page12" title="12">12</span> without being read aloud.</p>
        <figure><img src="f.png" alt="A diagram"/><figcaption>Figure 1-1. A diagram nobody hears.</figcaption></figure>
        <table><tr><td>cell one</td><td>cell two</td></tr></table>
        <pre class="programlisting">print("code is skipped")</pre>
        <p>Call <code>load_config()</code> before e.g. starting the API server on 10.0.0.1 at https://example.com/docs/start.</p>
        <aside epub:type="footnote" id="fn1"><p>1. The footnote body is skipped.</p></aside>
        </section>
        </body>
        </html>
        """,
        "OEBPS/text/ch02.xhtml": """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ch 2</title></head>
        <body><h1 id="top">Next Steps</h1><div class="note"><p>NOTE: Keep the IOC list and EDR alerts in the SIEM.</p></div>
        <ul><li>First item of the list.</li><li>Second item, with Dr. Smith involved.</li></ul></body></html>
        """,
        "OEBPS/index.xhtml": "<html><head><title>Index</title></head><body><p>Index entries are skipped, page 12.</p></body></html>"
    ].merging(extra) { $1 }
    for (path, content) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

@Test func readerParsesSpineChaptersAndSkipsNonProse() throws {
    let url = try makeFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let book = try ReaderEPUB.load(url)
    #expect(book.title == "Fixture Field Guide" && book.author == "Test Author" && book.language == "en")
    #expect(book.chapters.filter { $0.blocks.contains(where: \.spoken) }.map(\.title) == ["Chapter 1. Getting Started", "Chapter 2. Next Steps"])
    let spoken = book.sentences.map { book.text($0) }
    let all = spoken.joined(separator: " | ")
    #expect(spoken.first == "Getting Started")
    #expect(all.contains("The first paragraph sets the scene."))
    #expect(all.contains("It has a second sentence too."))
    #expect(all.contains("A page marker sits here without being read aloud."))
    for hidden in ["Cover words", "diagram", "cell one", "code is skipped", "footnote body", "Index entries", "color", "Ch 1", "scene.1"] {
        #expect(!all.contains(hidden), "\(hidden) should be skipped")
    }
    #expect(all.contains("Call load_config() before e.g. starting the API server"))
    #expect(all.contains("Second item, with Dr. Smith involved."))
    let kinds = Set(book.chapters[2].blocks.map(\.kind))
    #expect(kinds.isSuperset(of: [.heading, .paragraph, .caption, .table, .code, .footnote]), "\(kinds)")
}

@Test func readerMapsBooksLocationsToSentencesAndBack() throws {
    let url = try makeFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let book = try ReaderEPUB.load(url)
    // body=/4, section=/2, h1=/2, first p=/4; its first text chunk is /1.
    let p1 = book.chapters[2].blocks.first { $0.text.hasPrefix("The first paragraph") }!
    #expect(p1.path == [4, 2, 4])
    // Books' page-start location inside the second sentence of that paragraph.
    let inSecond = ReaderCFI("epubcfi(/6/6[ch01]!/4/2/4/3,:5,:6)")!
    #expect(inSecond.spineIndex == 2 && inSecond.idref == "ch01" && inSecond.path == [4, 2, 4, 3] && inSecond.offset == 5)
    let ref = try #require(book.sentence(for: inSecond))
    #expect(book.text(ref).hasPrefix("It has a second sentence"))
    // Round trip: the sentence's own CFI maps back to the same sentence.
    let cfi = try #require(book.cfi(for: ref))
    #expect(book.sentence(for: ReaderCFI(cfi.string)!) == ref)
    // A location in a skipped spine item (the cover) starts the first read chapter.
    let cover = try #require(book.sentence(for: ReaderCFI("epubcfi(/6/2[cover]!/4/2/1:0)")!))
    #expect(book.text(cover) == "Getting Started")
    // A location inside the figure resumes at the next spoken sentence.
    let figure = book.chapters[2].blocks.first { $0.kind == .caption }!
    let afterFigure = try #require(book.sentence(for: ReaderCFI(spineIndex: 2, path: figure.path + [1], offset: 0)))
    #expect(book.text(afterFigure).hasPrefix("Call load_config()"))
    // A spine index past the book: no crash, last spoken sentence.
    #expect(book.sentence(for: ReaderCFI(spineIndex: 40, path: [4], offset: 0)) != nil)
}

@Test func readerRefusesProtectedBooksButAllowsFontObfuscation() throws {
    let fonts = try makeFixture(extra: ["META-INF/encryption.xml": """
        <encryption><EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></EncryptedData></encryption>
        """])
    defer { try? FileManager.default.removeItem(at: fonts) }
    #expect((try? ReaderEPUB.load(fonts)) != nil)
    let drm = try makeFixture(extra: ["META-INF/sinf.xml": "<fairplay/>"])
    defer { try? FileManager.default.removeItem(at: drm) }
    #expect(throws: ReaderEPUB.Failure.protected) { try ReaderEPUB.load(drm) }
    let encrypted = try makeFixture(extra: ["META-INF/encryption.xml": """
        <encryption><EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData></encryption>
        """])
    defer { try? FileManager.default.removeItem(at: encrypted) }
    #expect(throws: ReaderEPUB.Failure.protected) { try ReaderEPUB.load(encrypted) }
}

@Test func readerSegmentsSentencesWithoutBreakingAbbreviations() {
    let text = "See Fig. 3 for details. Dr. Lee agreed, e.g. in the lab. J. R. R. Tolkien wrote it. Short."
    let pieces = ReaderSegmenter.sentences(in: text).map { ReaderSegmenter.substring(text, $0).trimmingCharacters(in: .whitespaces) }
    #expect(pieces == ["See Fig. 3 for details.", "Dr. Lee agreed, e.g. in the lab.", "J. R. R. Tolkien wrote it. Short."], "\(pieces)")
    let long = String(repeating: "word ", count: 60) + "; " + String(repeating: "more ", count: 60) + "end."
    #expect(ReaderSegmenter.sentences(in: long).count == 2)
}

@Test func readerReadsAcronymsNaturally() {
    let p = ReaderPronunciation()
    #expect(p.reading("NASA") == "Nasa")
    #expect(p.reading("SCUBA") == "scuba")
    #expect(p.reading("IOC") == "I.O.C")
    #expect(p.reading("EDR") == "E.D.R")
    #expect(p.reading("API") == "A.P.I")
    #expect(p.reading("DHCP") == "D.H.C.P")
    #expect(p.reading("MD5") == "M.D 5")
    #expect(p.reading("NOTE") == "note")
    #expect(p.reading("ZORP") == "Zorp")       // unknown but pronounceable
    #expect(p.reading("QXZT") == "Q.X.Z.T")    // unknown, unpronounceable
    #expect(p.spoken("Two APIs and one IOC.") == "Two A.P.I's and one I.O.C.")
    #expect(p.spoken("WARNING: THE CPU IS HOT") .contains("warning"))
    // The user's dictation replacement for an acronym is how they say it.
    let vocabulary = DictationVocabulary(userTerms: [], replacements: [.init(from: "sequel", to: "SQL"), .init(from: "teh", to: "the")])
    let mine = ReaderPronunciation(vocabulary: vocabulary)
    #expect(mine.overrides == ["SQL": "sequel"])
    #expect(mine.spoken("Query it with SQL.") == "Query it with sequel.")
}

@Test func readerReadsNumbersLinksAndIdentifiersNaturally() {
    let p = ReaderPronunciation()
    #expect(p.spoken("Visit https://www.example.com/a/b?x=1 today.") == "Visit a link to example dot com today.")
    #expect(p.spoken("Mail ops@corp.example.org now.") == "Mail an email address at corp dot example dot org now.")
    #expect(p.spoken("Ping 192.168.1.10/24 first.") == "Ping 192 dot 168 dot 1 dot 10 slash 24 first.")
    #expect(p.spoken("Upgrade to 3.2.1 or v2.") == "Upgrade to 3 point 2 point 1 or version 2.")
    #expect(p.spoken("It ran 1990–1995, see pp. 12–15.") == "It ran 1990 to 1995, see pages 12 to 15.")
    #expect(p.spoken("Latency was 5 ms on 3.2 GHz.") == "Latency was 5 milliseconds on 3.2 gigahertz.")
    #expect(p.spoken("Read Chapter IV and Part II.") == "Read Chapter 4 and Part 2.")
    #expect(p.spoken("Henry VIII met World War II veterans.") == "Henry the Eighth met World War Two veterans.")
    #expect(p.spoken("I think so.") == "I think so.")
    #expect(p.spoken("Edit /etc/passwd or /usr/local/share/doc/readme.txt.") == "Edit slash etc slash passwd or a file path ending in readme.txt.")
    #expect(p.spoken("Pass --verbose to load_config() and getUserName().") == "Pass dash dash verbose to load config and get User Name.")
    #expect(p.spoken("Value 0x1F and 0xDEADBEEFCAFE.") == "Value hex 1 F and a hex value.")
    #expect(p.spoken("Hash 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 found.") == "Hash a long hash found.")
    #expect(p.spoken("Use it, e.g. now, i.e. today.") == "Use it, for example now, that is today.")
}

@Test func readerParsesBooksCFIForms() {
    let page = ReaderCFI("epubcfi(/6/22[ch01]!/4/92[ch01lev3sec1sec2]/1,:0,:1)")!
    #expect(page.spineIndex == 10 && page.idref == "ch01" && page.path == [4, 92, 1] && page.offset == 0)
    let plain = ReaderCFI("epubcfi(/6/22[ch01]!/4/98/7,:17,:18)")!
    #expect(plain.path == [4, 98, 7] && plain.offset == 17)
    #expect(ReaderCFI("not a cfi") == nil)
    #expect(ReaderCFI("epubcfi(/6/22[ch01]!/4/96/8/1:19)")?.offset == 19)
}

@Test func readerFindsCoverImages() throws {
    func package(_ manifest: String, meta: String = "", spine: String = "<itemref idref=\"t\"/>", files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-cover-\(UUID().uuidString).epub")
        let all = files.merging([
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>",
            "OPS/book.opf": "<package><metadata>\(meta)</metadata><manifest>\(manifest)<item id=\"t\" href=\"t.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine>\(spine)</spine></package>",
            "OPS/t.xhtml": "<html><body><p>Text.</p></body></html>"
        ]) { $1 }
        for (path, text) in all {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    let epub3 = try package("<item id=\"c\" href=\"images/front.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
    #expect(ReaderEPUB.coverURL(epub3)?.path.hasSuffix("OPS/images/front.jpg") == true)
    let epub2 = try package("<item id=\"cimg\" href=\"img/c.png\" media-type=\"image/png\"/>", meta: "<meta name=\"cover\" content=\"cimg\"/>")
    #expect(ReaderEPUB.coverURL(epub2)?.path.hasSuffix("OPS/img/c.png") == true)
    let page = try package("<item id=\"cp\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>",
                           spine: "<itemref idref=\"cp\"/><itemref idref=\"t\"/>",
                           files: ["OPS/text/cover.xhtml": "<html><body><svg><image xlink:href=\"../images/art.jpg\"/></svg></body></html>"])
    #expect(ReaderEPUB.coverURL(page)?.path.hasSuffix("OPS/images/art.jpg") == true)
    let none = try package("")
    #expect(ReaderEPUB.coverURL(none) == nil)
    for url in [epub3, epub2, page, none] { try? FileManager.default.removeItem(at: url) }
    #expect(ReaderCover.initials("The Art of Machine Learning") == "AM")
    #expect(ReaderCover.initials("OmniFlow Reader Test Book") == "OR")
    #expect(ReaderCover.initials("Go") == "G")
}

@Test func readerCleansBookDescriptions() {
    let raw = "&lt;p&gt;A &lt;b&gt;hands-on&lt;/b&gt; guide&amp;nbsp;to R.&lt;/p&gt;&lt;p&gt;Second   para.&lt;/p&gt;"
    #expect(ReaderEPUB.plainDescription(raw) == "A hands-on guide to R. Second para.")
    let long = String(repeating: "word ", count: 80)
    let cut = ReaderEPUB.plainDescription(long, limit: 50)
    #expect(cut.hasSuffix("…") && cut.count <= 51 && !cut.contains("wor…"))
}

@Test func readerCarouselSelectionFollowsThePanelNotTheIndex() {
    let reading: [NotchLeePanel] = [.reader, .sessions, .weather, .cpu]
    let normal: [NotchLeePanel] = [.sessions, .music, .weather, .cpu]
    // Selected by identity: the same panel stays selected when pages shift.
    #expect(NotchLeePanel.index(of: .cpu, page: 9, in: reading) == 3)
    #expect(NotchLeePanel.index(of: .weather, page: 0, in: normal) == 2)
    // A panel that left (Reading after a book closes) falls back to the clamped page.
    #expect(NotchLeePanel.index(of: .reader, page: 0, in: normal) == 0)
    #expect(NotchLeePanel.index(of: nil, page: 99, in: normal) == 3)
}

