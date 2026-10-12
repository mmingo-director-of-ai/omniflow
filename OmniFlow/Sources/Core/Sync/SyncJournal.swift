import Foundation
import CryptoKit

/// One logical record per transcript, book position or preference. Deletions are
/// retained so a device reconnecting after months cannot resurrect an item.
struct SyncValue: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case transcript, position, preference }
    var kind: Kind
    var key: String
    var modified: Date
    var nonce: String = UUID().uuidString
    var payload: Data? // nil is a tombstone
    var recordName: String { Self.recordName(kind: kind, key: key) }
    static func recordName(kind: Kind, key: String) -> String {
        kind.rawValue + "-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func wins(over other: Self) -> Bool {
        // A deleted transcript cannot be recreated by an old editing session.
        if kind == .transcript, (payload == nil) != (other.payload == nil) { return payload == nil }
        return modified == other.modified ? nonce > other.nonce : modified > other.modified
    }
}

/// Disk-backed outbox and downloaded cache, sealed with the device's vault key.
/// All mutations are synchronous under a lock so exit/offline saves are durable.
final class SyncJournal: @unchecked Sendable {
    struct State: Codable {
        var values: [String: SyncValue] = [:]
        var dirty: Set<String> = []
        var account: String?
    }
    static let shared = SyncJournal(file: NotchLeeStorage.root.appendingPathComponent("Sync/journal.json"))
    let file: URL
    private let lock = NSLock()
    private var cached: State?
    init(file: URL) { self.file = file }
    private func read() throws -> State {
        if let cached { return cached }
        let state: State
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: OmniFlowVault.read(file).plaintext)
        } else { state = State() }
        cached = state
        return state
    }
    private func write(_ state: State) throws {
        try NotchLeeStorage.prepare(file.deletingLastPathComponent())
        try OmniFlowVault.write(JSONEncoder().encode(state), to: file)
        cached = state
    }
    func snapshot() throws -> State { try lock.withLock { try read() } }
    func bind(account: String) throws {
        try lock.withLock {
            var state = try read()
            if let previous = state.account, previous != account { throw SyncFailure.accountChanged }
            state.account = account
            try write(state)
        }
    }
    func put(_ value: SyncValue, remote: Bool = false) throws {
        try lock.withLock {
            var state = try read()
            if let previous = state.values[value.recordName] {
                if previous == value { return }
                guard value.wins(over: previous) else { return }
            }
            state.values[value.recordName] = value
            if remote { state.dirty.remove(value.recordName) } else { state.dirty.insert(value.recordName) }
            try write(state)
        }
    }
    func acknowledge(_ value: SyncValue) throws {
        try lock.withLock {
            var state = try read()
            // A local edit made while the request was in flight remains pending.
            if state.values[value.recordName] == value { state.dirty.remove(value.recordName) }
            try write(state)
        }
    }
    func seed(_ value: SyncValue) throws {
        try lock.withLock {
            var state = try read()
            guard state.values[value.recordName] == nil else { return }
            state.values[value.recordName] = value
            state.dirty.insert(value.recordName)
            try write(state)
        }
    }
}

enum SyncFailure: LocalizedError {
    case accountChanged, unavailable, malformed, oversized
    var errorDescription: String? {
        switch self {
        case .accountChanged: "The iCloud account changed. Sync is paused to keep the previous account's data private."
        case .unavailable: "Sign in to iCloud in system settings to sync OmniFlow."
        case .malformed: "An iCloud record could not be read. Your local data has been kept."
        case .oversized: "A transcript is too large for this sync version. It remains saved on this device."
        }
    }
}
