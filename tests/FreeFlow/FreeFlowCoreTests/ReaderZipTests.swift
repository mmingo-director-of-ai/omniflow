import Foundation
import Testing
@testable import OmniFlowApp

/// Zips `files` with Python's zipfile (mimetype stored, the rest deflated, as EPUBs are).
private func makeZip(_ files: [(String, String)]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-zip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let spec = folder.appendingPathComponent("spec.json"), archive = folder.appendingPathComponent("book.epub")
    try JSONSerialization.data(withJSONObject: files.map { [$0.0, $0.1] }).write(to: spec)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", """
    import json, sys, zipfile
    files = json.load(open(sys.argv[1]))
    with zipfile.ZipFile(sys.argv[2], "w") as z:
        for name, text in files:
            z.writestr(name, text, zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED)
    """, spec.path, archive.path]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return archive
}

private let chapter = String(repeating: "<p>The first paragraph sets the scene. It has a second sentence too.</p>\n", count: 40)
private let book: [(String, String)] = [
    ("mimetype", "application/epub+zip"),
    ("META-INF/container.xml", "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>"),
    ("OPS/book.opf", """
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Zipped Guide</dc:title></metadata><manifest><item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/></manifest>
    <spine><itemref idref="c1"/></spine></package>
    """),
    ("OPS/text/c1.xhtml", "<html><body><h1>One</h1>\(chapter)</body></html>"),
]

@Test func zippedEPUBUnpacksAndLoads() throws {
    let archive = try makeZip(book)
    let entries = try ReaderZip.entries(in: Data(contentsOf: archive))
    #expect(entries.map(\.method) == [0, 8, 8, 8])
    #expect(try ReaderZip.metadata(archive).title == "Zipped Guide")
    let out = archive.deletingLastPathComponent().appendingPathComponent("unpacked")
    try ReaderZip.extract(archive, to: out)
    #expect(try String(contentsOf: out.appendingPathComponent("OPS/text/c1.xhtml"), encoding: .utf8).contains("second sentence"))
    let document = try ReaderEPUB.load(out)
    #expect(!document.chapters.isEmpty)
}

@Test func zipEntriesCannotEscapeTheDestination() throws {
    let archive = try makeZip([("mimetype", "application/epub+zip"), ("../escaped.txt", "nope")])
    let out = archive.deletingLastPathComponent().appendingPathComponent("unpacked")
    #expect(throws: ReaderZip.Failure.unsafePath("../escaped.txt")) { try ReaderZip.extract(archive, to: out) }
    #expect(!FileManager.default.fileExists(atPath: archive.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    for name in ["/etc/passwd", "a/../../b", "a\\b"] {
        #expect(throws: ReaderZip.Failure.self) { try ReaderZip.safeURL(for: name, in: out) }
    }
}

@Test func encryptedAndDamagedZipEntriesAreRefused() throws {
    let archive = try makeZip(book)
    var data = try Data(contentsOf: archive)
    let entries = try ReaderZip.entries(in: data)
    let encrypted = ReaderZip.Entry(name: entries[3].name, method: 8, flags: 1, compressedSize: entries[3].compressedSize,
                                    size: entries[3].size, localHeaderOffset: entries[3].localHeaderOffset)
    #expect(throws: ReaderZip.Failure.unsupported("encryption")) { try ReaderZip.contents(of: encrypted, in: data) }
    // Damage the deflated chapter's bytes: inflation must fail, not return garbage of the right length silently.
    let header = entries[3].localHeaderOffset
    let start = header + 30 + Int(data[header + 26]) + Int(data[header + 28])
    for offset in 0..<min(16, entries[3].compressedSize) { data[start + offset] = 0xFF }
    #expect(throws: ReaderZip.Failure.self) { try ReaderZip.contents(of: entries[3], in: data) }
    #expect(throws: ReaderZip.Failure.notAZip) { try ReaderZip.entries(in: Data("not a zip at all, just text".utf8)) }
}
