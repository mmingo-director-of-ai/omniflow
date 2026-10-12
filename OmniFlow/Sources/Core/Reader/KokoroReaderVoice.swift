import Combine
import Foundation
import FluidAudio
import SwiftUI

struct KokoroReadingVoice: Identifiable, Sendable {
    let name: String
    let variant: KokoroAneVariant
    var id: String { variant.rawValue + ":" + name }
    var title: String { name.components(separatedBy: "_").dropFirst().joined(separator: " ").capitalized + " (" + name.prefix(2).uppercased() + ")" }
    static let selectionKey = "omniflow.reader.kokoroVoice"
    static let all: [Self] = KokoroAneVariant.allCases.flatMap { variant in
        variant.knownVoices.filter { variant != .english || $0.hasPrefix("af_") || $0.hasPrefix("am_") || $0.hasPrefix("bf_") || $0.hasPrefix("bm_") }.map { Self(name: $0, variant: variant) }
    }
    static func resolve(_ id: String?) -> Self {
        all.first { $0.id == id } ?? Self(name: "af_heart", variant: .english)
    }
    static var selected: Self { resolve(UserDefaults.standard.string(forKey: selectionKey)) }
}

/// Shared Core ML Reader. Models are loaded on demand; one language model is
/// retained at a time. CPU policy matches the device trial, not an ANE claim.
@MainActor final class KokoroReader: ObservableObject {
    static let shared = KokoroReader()
    @Published private(set) var status = "Kokoro · voices download on first use"
    @Published private(set) var preparing = false
    private let worker = KokoroReaderWorker()
    func prepare(_ voice: KokoroReadingVoice) async {
        guard !preparing else { return }
        preparing = true
        status = "Preparing \(voice.title). Keep the app open for the download."
        defer { preparing = false }
        do {
            _ = try await worker.run(text: nil, voice: voice, rate: 1)
            status = "Ready · \(voice.title)"
        } catch { status = "Preparation failed: \(error.localizedDescription)" }
    }
    func sentence(_ text: String, voice: KokoroReadingVoice, rate: Double) async throws -> [Float] {
        try await worker.run(text: text, voice: voice, rate: rate)
    }
}

private actor KokoroReaderWorker {
    private var manager: KokoroAneManager?
    private var variant: KokoroAneVariant?
    private var loadedVoices = Set<String>()
    private let converter = AudioConverter(sampleRate: 48_000)
    private var tail: Task<[Float], Error>?
    private var generation: UInt64 = 0
    func run(text: String?, voice: KokoroReadingVoice, rate: Double) async throws -> [Float] {
        generation &+= 1
        let token = generation, previous = tail
        defer { if generation == token { tail = nil } }
        let task = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await self.perform(text: text, voice: voice, rate: rate)
        }
        tail = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func perform(text: String?, voice: KokoroReadingVoice, rate: Double) async throws -> [Float] {
        if variant != voice.variant {
            await manager?.cleanup()
            manager = KokoroAneManager(variant: voice.variant, defaultVoice: voice.name, computeUnits: .cpuOnly)
            variant = voice.variant
            loadedVoices.removeAll()
        }
        guard let manager else { throw CocoaError(.coderInvalidValue) }
        if !loadedVoices.contains(voice.name) {
            try await manager.initialize(preloadVoices: [voice.name])
            loadedVoices.insert(voice.name)
        }
        try Task.checkCancellation()
        guard let text else { return [] }
        let result = try await manager.synthesizeDetailed(text: text, voice: voice.name, speed: Float(min(2, max(0.5, rate))))
        try Task.checkCancellation()
        guard !result.samples.isEmpty else { throw CocoaError(.coderInvalidValue) }
        return try converter.resample(result.samples, from: Double(result.sampleRate))
    }
}

@MainActor final class KokoroReaderVoice: ReaderVoiceSource {
    var onSentence: ((UInt32, [Float]?) -> Void)?
    var onExit: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var isRunning = false
    private(set) var voiceID: String?
    private var selected = KokoroReadingVoice.resolve(nil)
    private let selection: () -> KokoroReadingVoice
    init(selection: @escaping () -> KokoroReadingVoice = { KokoroReadingVoice.selected }) { self.selection = selection }
    private var nextID: UInt32 = 0
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var cancelled = Set<UInt32>()
    private var queue: [(UInt32, String, Double)] = []
    func start() throws {
        if isRunning { return }
        selected = selection()
        voiceID = selected.id
        isRunning = true
    }
    func stop() {
        generation &+= 1
        task?.cancel(); task = nil
        queue.removeAll(); cancelled.removeAll()
        isRunning = false; voiceID = nil
    }
    func resetSession() { stop() }
    func request(_ text: String, rate: Double, pitch: Double) -> UInt32? {
        guard isRunning else { return nil }
        nextID &+= 1
        queue.append((nextID, text, rate))
        pump()
        return nextID
    }
    func cancel(_ ids: [UInt32]) { cancelled.formUnion(ids) }
    private func pump() {
        guard task == nil, !queue.isEmpty, isRunning else { return }
        let (id, text, rate) = queue.removeFirst()
        if cancelled.remove(id) != nil { pump(); return }
        let token = generation, voice = selected
        task = Task { [weak self] in
            do {
                let samples = try await KokoroReader.shared.sentence(text, voice: voice, rate: rate)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.task = nil
                if self.cancelled.remove(id) == nil { self.onSentence?(id, samples) }
                self.pump()
            } catch {
                guard let self, self.generation == token else { return }
                self.task = nil
                self.onFailure?("Kokoro stopped: \(error.localizedDescription)")
            }
        }
    }
}

struct KokoroReaderSettings: View {
    @AppStorage private var selection: String
    private let assistant: Bool
    init(assistant: Bool = false, onChange: @escaping () -> Void) {
        _selection = AppStorage(wrappedValue: "english:af_heart", assistant ? KokoroReplySpeaker.selectionKey : KokoroReadingVoice.selectionKey)
        self.onChange = onChange
        self.assistant = assistant
    }
    @ObservedObject private var kokoro = KokoroReader.shared
    var onChange: () -> Void
    var body: some View {
        Picker(assistant ? "Response voice" : "Reading voice", selection: $selection) {
            ForEach(KokoroAneVariant.allCases, id: \.rawValue) { variant in
                Section(variant.rawValue.capitalized) {
                    ForEach(KokoroReadingVoice.all.filter { $0.variant == variant }) { voice in
                        Text(voice.title).tag(voice.id)
                    }
                }
            }
        }
        Text(kokoro.status).font(.caption).foregroundStyle(.secondary)
        Button("Prepare selected voice") {
            Task { await kokoro.prepare(KokoroReadingVoice.resolve(selection)) }
        }.disabled(kokoro.preparing)
        .onChange(of: selection) { _, _ in onChange() }
    }
}
