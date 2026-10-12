import Compression
import Foundation

/// Unpacks a zipped `.epub` into a folder so `ReaderEPUB.load` can read it.
/// Apple Books keeps books unpacked on the Mac, but EPUB files in iCloud Drive
/// or Files are ZIP archives, and iOS has no unzip API.
///
/// Handles what EPUBs use: stored and deflated entries in a classic (non-ZIP64)
/// archive. Refuses entries that would land outside the destination, encrypted
/// entries, and archives that inflate past `maxTotalBytes` (a zip bomb).
enum ReaderZip {
    enum Failure: LocalizedError, Equatable {
        case notAZip, unsupported(String), unsafePath(String), tooLarge, corrupt(String)
        var errorDescription: String? {
            switch self {
            case .notAZip: "This file isn't an EPUB (ZIP) archive."
            case .unsupported(let what): "This EPUB uses an unsupported ZIP feature (\(what))."
            case .unsafePath(let name): "This EPUB has an unsafe file name (\(name))."
            case .tooLarge: "This EPUB is too large to open."
            case .corrupt(let what): "This EPUB is damaged (\(what))."
            }
        }
    }

    /// Generous for books (most are under 50 MB unpacked), small enough to stop a zip bomb.
    static let maxTotalBytes = 1 << 30

    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    static func extract(_ archive: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try self.entries(in: data)
        guard entries.reduce(0, { $0 + $1.size }) <= maxTotalBytes else { throw Failure.tooLarge }
        let root = destination.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            let target = try safeURL(for: entry.name, in: root)
            if entry.name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents(of: entry, in: data).write(to: target)
        }
    }

    /// The central directory's entries, in order.
    static func entries(in data: Data) throws -> [Entry] {
        guard let end = endOfCentralDirectory(in: data) else { throw Failure.notAZip }
        let count = Int(data.u16(end + 10)), size = Int(data.u32(end + 12)), offset = Int(data.u32(end + 16))
        guard count != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw Failure.unsupported("ZIP64") }
        guard offset + size <= end else { throw Failure.corrupt("central directory") }
        var entries: [Entry] = [], cursor = offset
        for _ in 0..<count {
            guard cursor + 46 <= end, data.u32(cursor) == 0x0201_4b50 else { throw Failure.corrupt("central directory") }
            let nameLength = Int(data.u16(cursor + 28)), extra = Int(data.u16(cursor + 30)), comment = Int(data.u16(cursor + 32))
            guard cursor + 46 + nameLength <= end else { throw Failure.corrupt("file name") }
            let name = String(decoding: data[(data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: data.u16(cursor + 10), flags: data.u16(cursor + 8),
                                 compressedSize: Int(data.u32(cursor + 20)), size: Int(data.u32(cursor + 24)),
                                 localHeaderOffset: Int(data.u32(cursor + 42))))
            cursor += 46 + nameLength + extra + comment
        }
        return entries
    }

    static func contents(of entry: Entry, in data: Data) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw Failure.unsupported("encryption") }
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.u32(header) == 0x0403_4b50 else { throw Failure.corrupt("entry header") }
        let start = header + 30 + Int(data.u16(header + 26)) + Int(data.u16(header + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.corrupt("entry data") }
        let compressed = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw Failure.corrupt("stored entry") }
            return Data(compressed)
        case 8:
            guard entry.size > 0 else { return Data() }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { out in
                compressed.withUnsafeBytes { input in
                    // COMPRESSION_ZLIB is raw DEFLATE, which is what ZIP stores.
                    compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              input.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.corrupt("compressed entry") }
            return output
        default:
            throw Failure.unsupported("compression method \(entry.method)")
        }
    }

    /// The destination for an entry name, refusing absolute paths and `..` escapes.
    static func safeURL(for name: String, in root: URL) throws -> URL {
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !name.hasPrefix("/"), !name.contains("\\"), !parts.isEmpty, !parts.contains(where: { $0 == ".." }) else {
            throw Failure.unsafePath(name)
        }
        let url = parts.reduce(root) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw Failure.unsafePath(name) }
        return url
    }

    /// The end-of-central-directory record: searched backwards past an optional comment.
    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var position = data.count - 22
        while position >= lowest {
            if data.u32(position) == 0x0605_4b50 { return position }
            position -= 1
        }
        return nil
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}

extension ReaderZip {
    /// What a library row needs, read straight from the archive without
    /// unpacking it: title, author and the cover image's bytes.
    struct Metadata: Sendable { var title: String?; var creator: String?; var cover: Data? }

    static func metadata(_ archive: URL) throws -> Metadata {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try self.entries(in: data)
        func text(_ name: String) throws -> String? {
            try entries.first(where: { $0.name == name }).map { String(decoding: try contents(of: $0, in: data), as: UTF8.self) }
        }
        guard let container = try text("META-INF/container.xml"),
              let opfPath = ReaderMarkup.elements(in: container).first(where: { $0.name == "rootfile" })?.attributes["full-path"],
              let opf = try text(opfPath) else { throw ReaderEPUB.Failure.notAPackage }
        let package = ReaderEPUB.Package(opf)
        // EPUB 3 marks the cover image in the manifest; EPUB 2 names it in <meta name="cover">.
        let coverItem = package.manifest.values.first { $0.properties.split(separator: " ").contains("cover-image") }
            ?? package.coverID.flatMap { package.manifest[$0] }.flatMap { $0.mediaType.hasPrefix("image/") ? $0 : nil }
        let base = (opfPath as NSString).deletingLastPathComponent
        let coverName = coverItem.map { item in
            let joined = base.isEmpty ? item.href : base + "/" + item.href
            return (joined.removingPercentEncoding ?? joined as String)
        }
        let cover = try coverName.flatMap { name in try entries.first(where: { $0.name == (name as NSString).standardizingPath }).map { try contents(of: $0, in: data) } }
        return Metadata(title: package.title, creator: package.creator, cover: cover)
    }
}
