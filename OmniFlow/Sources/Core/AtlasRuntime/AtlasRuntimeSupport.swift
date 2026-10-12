// Native Atlas runtime: shared errors, identity, text and file helpers.
// Ported from OmniFlow/Helpers/Atlas (Go) at Atlas SDK revision
// 49104b74160ee24cc350eee461df6378e51cccd3; see docs/omniflow/atlas-swift-port.md.
import Foundation

/// A fixed, host-defined failure code. Codes never embed server text, URLs,
/// arguments, paths or credentials, matching the Go helper's error surface.
public struct AtlasRuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var description: String { code }
}

/// The Atlas SDK release this runtime ports. It must equal atlas-sdk.lock.json.
public enum AtlasRuntimeIdentity {
    public static let version = "3.5.7"
    public static let revision = "49104b74160ee24cc350eee461df6378e51cccd3"
    public static let protocolVersion = 4
}

enum AtlasText {
    /// Go `strings.ToLower`: per-scalar simple lowercase mapping.
    static func goLower(_ text: String) -> String {
        String(decoding: goLowerBytes(Array(text.utf8)[...]), as: UTF8.self)
    }

    /// `goLower` over valid UTF-8 bytes, with an ASCII fast path.
    static func goLowerBytes(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cache: [UInt32: [UInt8]] = [:]
        let array = Array(bytes)
        var index = 0
        while index < array.count {
            let byte = array[index]
            if byte < 0x80 {
                output.append(byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte)
                index += 1
                continue
            }
            let (scalar, size) = AtlasUTF8.decodeRune(array, at: index)
            if let scalar {
                if let lowered = cache[scalar.value] {
                    output.append(contentsOf: lowered)
                } else {
                    let mapped = scalar.properties.lowercaseMapping.unicodeScalars.first ?? scalar
                    let lowered = Array(String(mapped).utf8)
                    cache[scalar.value] = lowered
                    output.append(contentsOf: lowered)
                }
            } else {
                output.append(contentsOf: array[index..<(index + size)])
            }
            index += size
        }
        return output
    }

    /// Go `unicode.IsLetter(r) || unicode.IsNumber(r)`.
    static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// Go `strings.FieldsFunc(text, !(IsLetter || IsNumber))`.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isLetterOrNumber(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current)); current = .init()
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// Go `strings.Fields`: split on Unicode white space.
    static func fields(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }).map { String(String.UnicodeScalarView($0)) }
    }

    static let stopWords: Set<String> = Set(fields("the and for from with this that what which where when how please tell find read search use using show give me my our your can could would about does not into then its of on as"))
}

enum AtlasBytes {
    /// Go `bytes.Index` from an offset; returns an absolute position.
    static func index(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty else { return start <= haystack.count ? start : nil }
        guard start >= 0, haystack.count - start >= needle.count else { return nil }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pattern in
                guard let found = memmem(hay.baseAddress! + start, hay.count - start, pattern.baseAddress!, pattern.count) else { return nil }
                return hay.baseAddress!.distance(to: UnsafeRawPointer(found))
            }
        }
    }

    static func lastIndex(of byte: UInt8, in bytes: ArraySlice<UInt8>) -> Int? { bytes.lastIndex(of: byte) }
}

/// POSIX file operations with the exact permission semantics the Go helper
/// relies on: private files are created 0600 and checkpoints with any group or
/// other permission bits are rejected.
enum AtlasFiles {
    static func lstat(_ path: String) -> stat? {
        var info = stat()
        return Darwin.lstat(path, &info) == 0 ? info : nil
    }

    static func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }
    static func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }
    static func isPrivate(_ info: stat) -> Bool { info.st_mode & 0o077 == 0 }

    /// Creates a new file exclusively with mode 0600 and writes `data`.
    static func createExclusive(_ path: String, data: [UInt8]) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtlasRuntimeError("payload_write_failed") }
        let written = writeAll(fd, data)
        let closed = close(fd) == 0
        guard written, closed else { unlink(path); throw AtlasRuntimeError("payload_write_failed") }
    }

    static func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    static func read(_ path: String, limit: Int) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return output }
            output.append(contentsOf: buffer[..<count])
            if output.count > limit { return output }
        }
    }

    /// Creates a private temporary directory like Go's `os.MkdirTemp`.
    static func makeTemporaryDirectory(prefix: String) throws -> String {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent(prefix + "XXXXXXXX").utf8CString)
        guard let result = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw AtlasRuntimeError("payload_directory_unavailable")
        }
        return String(cString: result)
    }

    static func removeTree(_ path: String) { try? FileManager.default.removeItem(atPath: path) }
}
