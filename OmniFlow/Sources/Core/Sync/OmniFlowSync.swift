import CloudKit
import Combine
import SwiftUI

/// Private CloudKit database shared by the Mac and iOS bundle identifiers.
/// No local vault key is exported; CloudKit encrypts the payload field itself.
@MainActor
final class OmniFlowSync: ObservableObject {
    static let shared = OmniFlowSync()
    static let enabledKey = "omniflow.icloud.enabled"
    static let changed = Notification.Name("OmniFlowSyncChanged")
    static let preferenceKeys = ["omniflow.reader.sort", "omniflow.reader.libraryGrid", "omniflow.reader.kokoroVoice", "omniflow.assistant.kokoroVoice"]
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); if enabled { Task { await sync() } } }
    }
    @Published private(set) var running = false
    @Published private(set) var status = "Sync is off."
    @Published private(set) var lastSuccess: Date?
    private var loop: Task<Void, Never>?
    private var preferenceCache: [String: Data] = [:]
    private var preferencesSeeded = false
    private let transport = CloudSyncTransport()

    private init() { enabled = UserDefaults.standard.bool(forKey: Self.enabledKey) }
    func start() {
        guard loop == nil, OmniFlowVault.isAppProcess else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    func sync() async {
        guard enabled, !running else { return }
        running = true
        status = "Syncing…"
        defer { running = false }
        do {
            try capturePreferences()
            try await transport.exchange()
            guard enabled else { return }
            try applyPreferences()
            lastSuccess = .now
            status = "Up to date"
            NotificationCenter.default.post(name: Self.changed, object: nil)
        } catch {
            status = error.localizedDescription
        }
    }
    private func capturePreferences() throws {
        for key in Self.preferenceKeys {
            guard let value = UserDefaults.standard.object(forKey: key),
                  JSONSerialization.isValidJSONObject([value]) else { continue }
            let data = try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
            if !preferencesSeeded {
                try SyncJournal.shared.seed(.init(kind: .preference, key: key, modified: .distantPast, payload: data))
            } else if preferenceCache[key] != data {
                try SyncJournal.shared.put(.init(kind: .preference, key: key, modified: .now, payload: data))
            }
            preferenceCache[key] = data
        }
        preferencesSeeded = true
    }
    private func applyPreferences() throws {
        for value in try SyncJournal.shared.snapshot().values.values where value.kind == .preference {
            guard Self.preferenceKeys.contains(value.key), let data = value.payload,
                  let array = try JSONSerialization.jsonObject(with: data) as? [Any], let object = array.first else { continue }
            // Do not overwrite a preference edited while the network request ran.
            if let current = UserDefaults.standard.object(forKey: value.key),
               let bytes = try? JSONSerialization.data(withJSONObject: [current], options: [.sortedKeys]),
               let before = preferenceCache[value.key], bytes != before { continue }
            UserDefaults.standard.set(object, forKey: value.key)
            preferenceCache[value.key] = data
        }
    }
}

actor CloudSyncTransport {
    private let zone = CKRecordZone.ID(zoneName: "OmniFlowSyncV1", ownerName: CKCurrentUserDefaultName)
    private var token: CKServerChangeToken?
    private var account: String?
    private var prepared = false
    private var seeded = false

    func exchange() async throws {
        // Construct only after opting in, and only in a signed app with entitlements.
        let container = CKContainer(identifier: "iCloud.com.mengohlabs.OmniFlow")
        guard try await container.accountStatus() == .available else { throw SyncFailure.unavailable }
        let user = try await container.userRecordID().recordName
        try SyncJournal.shared.bind(account: user)
        if account != user { token = nil; prepared = false; account = user }
        let db = container.privateCloudDatabase
        if !prepared {
            _ = try await db.save(CKRecordZone(zoneID: zone))
            prepared = true
        }
        if !seeded { try await seedLocalData(); seeded = true }
        do { try await pull(db) }
        catch let error as CKError where error.code == .changeTokenExpired {
            token = nil
            try await pull(db)
        }
        let state = try SyncJournal.shared.snapshot()
        for name in state.dirty.sorted() {
            guard UserDefaults.standard.bool(forKey: "omniflow.icloud.enabled") else { return }
            guard let value = state.values[name] else { continue }
            try await push(value, db: db)
        }
    }
    private func seedLocalData() async throws {
        let history = HistoryStore(directory: NotchLeeStorage.root.appendingPathComponent("Dictations"))
        for entry in try await history.load().entries where entry.state != .recording && entry.state != .processing {
            try SyncJournal.shared.seed(.init(kind: .transcript, key: entry.id.uuidString,
                                             modified: entry.date, payload: JSONEncoder().encode(entry)))
        }
        for (key, entry) in ReaderPositionStore.standard.load().books where key.hasPrefix("book-v1-") {
            try SyncJournal.shared.seed(.init(kind: .position, key: key, modified: entry.position.updatedAt,
                                             payload: JSONEncoder().encode(entry)))
        }
    }
    private func pull(_ db: CKDatabase) async throws {
        var more = true
        while more {
            let changes = try await db.recordZoneChanges(inZoneWith: zone, since: token)
            for (_, result) in changes.modificationResultsByID {
                let record = try result.get().record
                let value = try decode(record)
                try SyncJournal.shared.put(value, remote: true)
            }
            // App deletions are tombstones, never hard deletes. A reset on the
            // server must not silently delete the user's offline files.
            token = changes.changeToken
            more = changes.moreComing
        }
    }
    private func decode(_ record: CKRecord) throws -> SyncValue {
        guard let data = record.encryptedValues["payload"] as? Data else { throw SyncFailure.malformed }
        let value = try JSONDecoder().decode(SyncValue.self, from: data)
        guard value.recordName == record.recordID.recordName else { throw SyncFailure.malformed }
        return value
    }
    private func push(_ value: SyncValue, db: CKDatabase) async throws {
        let id = CKRecord.ID(recordName: value.recordName, zoneID: zone)
        for _ in 0..<3 {
            var record: CKRecord
            do { record = try await db.record(for: id) }
            catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "OmniFlowValueV1", recordID: id)
            }
            if record.recordChangeTag != nil {
                let remote = try decode(record)
                if remote == value || remote.wins(over: value) {
                    try SyncJournal.shared.put(remote, remote: true)
                    try SyncJournal.shared.acknowledge(value)
                    return
                }
            }
            let data = try JSONEncoder().encode(value)
            guard data.count < 900_000 else { throw SyncFailure.oversized }
            record.encryptedValues["payload"] = data as NSData
            do {
                let result = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
                guard let saved = result.saveResults[id] else { throw SyncFailure.malformed }
                _ = try saved.get()
                try SyncJournal.shared.acknowledge(value)
                return
            } catch let error as CKError where error.code == .serverRecordChanged { continue }
        }
        throw CKError(.serverRecordChanged)
    }
}

struct OmniFlowSyncSettings: View {
    @ObservedObject private var sync = OmniFlowSync.shared
    var body: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $sync.enabled)
            if sync.enabled {
                Text(sync.status).font(.caption).foregroundStyle(.secondary)
                if let date = sync.lastSuccess { Text("Last synced \(date.formatted())").font(.caption2) }
                Button("Sync now") { Task { await sync.sync() } }.disabled(sync.running)
            }
        } header: { Text("iCloud sync") }
        footer: { Text("Sync completed transcripts, reading positions, library display preferences and voice choices with your other devices using the same Apple Account. Book files stay in your chosen folder. Turning sync off keeps existing copies.") }
    }
}
