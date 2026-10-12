// Native Atlas runtime: the single owner of task-workspace file IO.
// Swift port of the Atlas host adapter and Go SDK (MIT, Copyright (c) 2026 Quandry Labs;
// see Core/AtlasRuntime/AtlasRuntime-LICENSE.txt) at SDK revision 49104b74160ee24cc350eee461df6378e51cccd3.
//
//
// Every byte the payload store and task journal persist passes through this
// type: evidence payloads (`pN.gz`), the payload index, the append-only
// journal, and the workspace lock. Encryption at rest can wrap these methods
// without touching the store or journal logic. The on-disk layout and modes
// match the Go helper: 0600 files in a 0700 directory, descriptors
// close-on-exec, and an exclusive flock on `.lock`.
import Foundation

final class AtlasWorkspaceFiles {
    let directory: String
    private var lockDescriptor: Int32 = -1

    static let indexName = "payload-index.json"
    static let journalName = "task-memory.jsonl"

    /// A missing directory creates a private temporary one, like the Go helper.
    init(directory: String?) throws {
        var path = directory ?? ""
        if path.isEmpty { path = try AtlasFiles.makeTemporaryDirectory(prefix: "notchlee-atlas-payloads-") }
        guard let info = AtlasFiles.lstat(path), AtlasFiles.isDirectory(info), AtlasFiles.isPrivate(info) else {
            throw AtlasRuntimeError("private_payload_directory_required")
        }
        self.directory = path
    }

    func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

    // MARK: Payloads

    /// Writes a new payload exactly once (gzip, exclusive create).
    func writePayload(_ id: String, _ data: [UInt8]) throws {
        try AtlasFiles.createExclusive(path(id + ".gz"), data: try AtlasGzip.compress(data))
    }

    /// Reads a payload, returning at most `limit` + 1 decompressed bytes.
    /// Symlinks, oversized files and undecodable gzip are rejected.
    func readPayload(_ id: String, limit: Int) throws -> [UInt8] {
        let file = path(id + ".gz")
        guard let info = AtlasFiles.lstat(file), AtlasFiles.isRegular(info), Int(info.st_size) <= limit + 65536,
              let compressed = AtlasFiles.read(file, limit: limit + 65536) else {
            throw AtlasRuntimeError("invalid_payload_file")
        }
        guard let data = try? AtlasGzip.decompress(compressed, limit: limit) else { throw AtlasRuntimeError("payload_integrity_failed") }
        return data
    }

    // MARK: Index

    var indexExists: Bool { AtlasFiles.lstat(path(Self.indexName)) != nil || errno != ENOENT }

    /// Atomic replace: write a private temporary file, fsync, rename.
    func writeIndex(_ bytes: [UInt8]) throws {
        var template = Array(path(".index-XXXXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkostemp($0.baseAddress!, O_CLOEXEC) }
        guard fd >= 0 else { throw AtlasRuntimeError("checkpoint_write_failed") }
        let temporary = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { unlink(temporary) }
        let written = AtlasFiles.writeAll(fd, bytes) && fsync(fd) == 0
        let closed = close(fd) == 0
        guard written, closed, rename(temporary, path(Self.indexName)) == 0 else { throw AtlasRuntimeError("checkpoint_write_failed") }
    }

    func readIndex(limit: Int) throws -> [UInt8] { try readCheckpoint(Self.indexName, limit: limit) }

    // MARK: Journal

    /// Appends one complete line; `sync` makes it durable before returning.
    func appendJournal(_ line: [UInt8], sync: Bool) throws {
        let fd = open(path(Self.journalName), O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtlasRuntimeError("task_memory_write_failed") }
        var written = AtlasFiles.writeAll(fd, line + [0x0A])
        if written && sync { written = fsync(fd) == 0 }
        let closed = close(fd) == 0
        guard written, closed else { throw AtlasRuntimeError("task_memory_write_failed_broken") }
    }

    func readJournal(limit: Int) throws -> [UInt8] { try readCheckpoint(Self.journalName, limit: limit) }

    /// Discards a torn final append.
    func truncateJournal(to length: Int) throws {
        guard truncate(path(Self.journalName), off_t(length)) == 0 else { throw AtlasRuntimeError("checkpoint_write_failed") }
    }

    /// Checkpoints must be regular private files within the size limit.
    private func readCheckpoint(_ name: String, limit: Int) throws -> [UInt8] {
        let file = path(name)
        guard let info = AtlasFiles.lstat(file), AtlasFiles.isRegular(info), Int(info.st_size) <= limit, AtlasFiles.isPrivate(info) else {
            throw AtlasRuntimeError("invalid_checkpoint")
        }
        guard let data = AtlasFiles.read(file, limit: limit) else { throw AtlasRuntimeError("checkpoint_unavailable") }
        return data
    }

    // MARK: Lifetime

    /// Exclusive, non-blocking workspace lock (one live run per task). The
    /// lock is a plain flock, so it also excludes a Go helper on the same
    /// workspace during cutover or rollback.
    ///
    /// A just-released lock can look held for a moment: while any process in
    /// the app spawns a child, the child briefly shares every open file
    /// description, close-on-exec ones included, until its exec completes.
    /// Retry for up to `settle` seconds before reporting a live run.
    func lock(settle: Double = 0.25) throws {
        let fd = open(path(".lock"), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtlasRuntimeError("checkpoint_unavailable") }
        let deadline = Date().addingTimeInterval(settle)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR, Date() < deadline else {
                close(fd)
                throw AtlasRuntimeError(failure == EWOULDBLOCK ? "checkpoint_in_use" : "checkpoint_unavailable")
            }
            usleep(2000)
        }
        lockDescriptor = fd
    }

    func unlock() {
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
    }

    func removeAll() { AtlasFiles.removeTree(directory) }
}
