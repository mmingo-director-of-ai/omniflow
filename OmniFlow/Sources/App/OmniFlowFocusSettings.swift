import AppKit
import Combine

struct OmniFlowFocusValues: Codable, Equatable, Sendable {
    var isEnabled = true
    var focusDelayMs = 200
    var focusInputOnHover = false
    var raiseWindow = true
    var raiseDelayMs = 0
    var excludedBundleIDs: [String] = []
    var showInDock = false
    var isShortcutGuideEnabled = true

    init() {}

    /// Missing keys take defaults; keys from older records are ignored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        focusDelayMs = try container.decodeIfPresent(Int.self, forKey: .focusDelayMs) ?? defaults.focusDelayMs
        focusInputOnHover = try container.decodeIfPresent(Bool.self, forKey: .focusInputOnHover) ?? defaults.focusInputOnHover
        raiseWindow = try container.decodeIfPresent(Bool.self, forKey: .raiseWindow) ?? defaults.raiseWindow
        raiseDelayMs = try container.decodeIfPresent(Int.self, forKey: .raiseDelayMs) ?? defaults.raiseDelayMs
        excludedBundleIDs = try container.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? defaults.excludedBundleIDs
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? defaults.showInDock
        isShortcutGuideEnabled = try container.decodeIfPresent(Bool.self, forKey: .isShortcutGuideEnabled) ?? defaults.isShortcutGuideEnabled
    }

    func normalized() -> Self {
        var result = self
        result.focusDelayMs = min(1000, max(0, focusDelayMs))
        result.raiseDelayMs = min(500, max(0, raiseDelayMs))
        return result
    }
}

@MainActor
final class OmniFlowFocusSettings: ObservableObject {
    static let shared = OmniFlowFocusSettings()
    static let storageKey = "omniFlowFocusSettings.v1"
    /// The master switch; `values.isEnabled` is the temporary pause.
    @Published var enabled: Bool { didSet { persist(); didChange?() } }
    @Published var values: OmniFlowFocusValues {
        didSet {
            let normalized = values.normalized()
            if normalized != values { values = normalized }
            persist()
            didChange?()
        }
    }
    @Published private(set) var storageError: String?
    var didChange: (@MainActor () -> Void)?
    private let defaults: UserDefaults
    private struct Record: Codable {
        var version = 1
        var enabled: Bool
        var values: OmniFlowFocusValues
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = false
        values = .init()
        if let data = defaults.data(forKey: Self.storageKey) {
            if data.count <= 256_000, let saved = try? JSONDecoder().decode(Record.self, from: data), saved.version == 1 {
                enabled = saved.enabled
                values = saved.values.normalized()
            } else { storageError = "Saved focus settings could not be read. The original record has been left in place." }
        }
    }

    private func persist() {
        do {
            let encoded = try JSONEncoder().encode(Record(enabled: enabled, values: values))
            guard encoded.count <= 256_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            defaults.set(encoded, forKey: Self.storageKey)
            storageError = nil
        } catch { storageError = "Focus settings could not be saved. Existing saved settings were retained." }
    }
}
