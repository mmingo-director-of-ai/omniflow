import CryptoKit
import Foundation
import ImageIO
import UIKit

/// An EPUB the iOS Reader can open: in the folder the user chose (usually in
/// iCloud Drive) or imported into OmniFlow from Files or the Share sheet.
struct IOSReaderBook: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable { case folder, imported }
    /// Stable across launches: the source plus the path inside it. Positions are saved under it.
    let id: String
    let url: URL
    let source: Source
    var title: String
    var author: String
    /// Still in iCloud: never opened until downloaded (opening a dataless file blocks).
    var waitingForICloud: Bool
    var modified: Date?
}

/// The iOS Reader's library. All file work runs off the main thread: folder
/// access, iCloud downloads, reading titles and covers out of the archives,
/// and unpacking a book to open it. Book text never leaves the device.
@MainActor
final class IOSReaderLibrary: ObservableObject {
    static let shared = IOSReaderLibrary()

    @Published private(set) var books: [IOSReaderBook] = []
    @Published private(set) var folderName: String?
    @Published private(set) var scanning = false
    @Published private(set) var problem: String?
    @Published private(set) var covers: [String: UIImage] = [:]

    nonisolated private static let bookmarkKey = "omniflow.reader.folderBookmark"
    private var waitingPoll: Task<Void, Never>?

    /// Imported books live in the app's own container, protected until first unlock.
    nonisolated static var importedFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Books", isDirectory: true)
    }
    /// Unpacked books (a cache: rebuilt from the archive when missing or changed).
    nonisolated static var unpackedFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Reader", isDirectory: true)
    }

    private init() {
        folderName = Self.resolveFolder()?.lastPathComponent
    }

    /// The user picked a folder (Files › iCloud Drive › …). Remember it and scan.
    func chooseFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            folderName = url.lastPathComponent
            problem = nil
            rescan()
        } catch {
            problem = "OmniFlow couldn't keep access to that folder. Choose it again."
        }
    }

    func forgetFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderName = nil
        rescan()
    }

    /// Copies books shared or picked from Files into OmniFlow. Coordinated reads,
    /// so a book still in iCloud is downloaded first.
    func importFiles(_ urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            let folder = Self.importedFolder
            var failed = 0
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            } catch { failed = urls.count }
            for url in urls where failed == 0 {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var copied = false
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordinationError) { readable in
                    let target = folder.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: target)
                    copied = (try? FileManager.default.copyItem(at: readable, to: target)) != nil
                }
                if !copied { failed += 1 }
            }
            let failures = failed
            await MainActor.run {
                self.problem = failures > 0 ? "\(failures) book\(failures == 1 ? "" : "s") couldn't be imported." : nil
                self.rescan()
            }
        }
    }

    /// Lists both sources. Books still in iCloud are asked to download and
    /// shown as waiting; they are rescanned until they arrive.
    func rescan() {
        scanning = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                self.books = found.books
                if found.folderMissing { self.problem = "The Books folder is no longer available. Choose it again." }
                self.scanning = false
                self.loadCovers()
                self.pollWhileWaiting()
            }
        }
    }

    /// Unpacks a book for reading (re-using the cache when the archive hasn't
    /// changed) and returns the package folder for `ReaderEPUB.load`.
    nonisolated func prepare(_ book: IOSReaderBook) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let folder = book.source == .folder ? Self.resolveFolder() : nil
            let access = folder?.startAccessingSecurityScopedResource() ?? false
            defer { if access { folder?.stopAccessingSecurityScopedResource() } }
            let target = Self.unpackedFolder.appendingPathComponent(Self.cacheName(book.id), isDirectory: true)
            let stamp = target.appendingPathComponent(".omniflow-source")
            var result: Result<URL, Error> = .failure(ReaderZip.Failure.notAZip)
            var coordinationError: NSError?
            // Coordinated: waits for an iCloud download instead of reading a placeholder.
            NSFileCoordinator().coordinate(readingItemAt: book.url, options: .withoutChanges, error: &coordinationError) { readable in
                let values = try? readable.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let signature = "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                if (try? String(contentsOf: stamp, encoding: .utf8)) == signature { result = .success(target); return }
                result = Result {
                    try? FileManager.default.removeItem(at: target)
                    try ReaderZip.extract(readable, to: target)
                    try signature.write(to: stamp, atomically: true, encoding: .utf8)
                    return target
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    // MARK: - Scanning (off the main thread)

    private struct Scan: Sendable { var books: [IOSReaderBook]; var folderMissing: Bool }

    nonisolated private static func scan() -> Scan {
        var books: [IOSReaderBook] = []
        var folderMissing = false
        if UserDefaults.standard.data(forKey: bookmarkKey) != nil {
            if let folder = resolveFolder() {
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                books += list(folder, source: .folder)
            } else {
                folderMissing = true
            }
        }
        books += list(importedFolder, source: .imported)
        return Scan(books: books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, folderMissing: folderMissing)
    }

    nonisolated private static func list(_ folder: URL, source: IOSReaderBook.Source) -> [IOSReaderBook] {
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var books: [IOSReaderBook] = []
        let root = folder.standardizedFileURL.path
        while let url = walker.nextObject() as? URL {
            // Older iCloud placeholders are hidden files named ".Title.epub.icloud".
            var name = url.lastPathComponent
            var placeholder = false
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count)); placeholder = true
            }
            guard name.lowercased().hasSuffix(".epub") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let real = placeholder ? url.deletingLastPathComponent().appendingPathComponent(name) : url
            let status = values?.ubiquitousItemDownloadingStatus
            let waiting = placeholder || (values?.isUbiquitousItem == true && status != .current && status != .downloaded)
            if waiting { try? FileManager.default.startDownloadingUbiquitousItem(at: real) }
            let relative = String(real.standardizedFileURL.path.dropFirst(root.count + 1))
            var title = (name as NSString).deletingPathExtension, author = ""
            if !waiting, let metadata = try? ReaderZip.metadata(real) {
                title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? title
                author = metadata.creator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            books.append(IOSReaderBook(id: "\(source.rawValue):\(relative)", url: real, source: source, title: title,
                                       author: author, waitingForICloud: waiting, modified: values?.contentModificationDate))
        }
        return books
    }

    nonisolated private static func resolveFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return url
    }

    nonisolated private static func cacheName(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// While any book is still downloading from iCloud, look again every few seconds (for up to ten minutes).
    private func pollWhileWaiting() {
        waitingPoll?.cancel()
        guard books.contains(where: \.waitingForICloud) else { return }
        waitingPoll = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let found = await Task.detached(priority: .utility) { Self.scan() }.value
                self.books = found.books
                self.loadCovers()
                if !found.books.contains(where: \.waitingForICloud) { return }
            }
        }
    }

    /// Covers for downloaded books, decoded at list size off the main thread.
    private func loadCovers() {
        let missing = books.filter { !$0.waitingForICloud && covers[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let folder = Self.resolveFolder()
        Task.detached(priority: .utility) {
            let access = folder?.startAccessingSecurityScopedResource() ?? false
            defer { if access { folder?.stopAccessingSecurityScopedResource() } }
            var decoded: [String: UIImage] = [:]
            for book in missing {
                guard let bytes = try? ReaderZip.metadata(book.url).cover,
                      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
                decoded[book.id] = UIImage(cgImage: image)
            }
            let ready = decoded
            await MainActor.run { self.covers.merge(ready) { $1 } }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
