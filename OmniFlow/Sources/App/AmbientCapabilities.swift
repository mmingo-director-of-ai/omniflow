import AppKit
import Combine
import Foundation

/// The catalog describes real local capabilities; it never creates active watches.
enum AmbientCapability: String, CaseIterable, Identifiable {
    case messages, email, selection, agents, memory, cpu, storage, battery, updates, security
    var id: String { rawValue }
    var title: String {
        switch self {
        case .messages: "Messages"
        case .email: "Mail"
        case .selection: "Watch this"
        case .agents: "Agents"
        case .memory: "Memory"
        case .cpu: "CPU"
        case .storage: "Storage"
        case .battery: "Battery"
        case .updates: "Updates"
        case .security: "Security"
        }
    }
    var symbol: String {
        switch self {
        case .messages: "message"
        case .email: "envelope"
        case .selection: "viewfinder"
        case .agents: "terminal"
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .storage: "internaldrive"
        case .battery: "battery.25percent"
        case .updates: "arrow.down.circle"
        case .security: "shield.checkered"
        }
    }
    var source: AmbientSource {
        switch self {
        case .messages: .messages
        case .email: .email
        case .selection: .selection
        case .agents: .agentFinished
        case .memory: .systemPressure
        case .cpu: .cpu
        case .storage: .storage
        case .battery: .battery
        case .updates: .updates
        case .security: .security
        }
    }
    var detail: String {
        switch self {
        case .messages: "Follow an Apple Messages conversation stored on this Mac."
        case .email: "Watch a sender, topic or conversation in Apple Mail's local cache."
        case .selection: "Watch visible changes in a chosen app window while it is in front."
        case .agents: "Know when a connected agent finishes or needs your attention."
        case .memory: "Respond to macOS memory and thermal pressure. Used RAM alone is not a problem."
        case .cpu: "Get a heads-up when CPU usage stays above your threshold."
        case .storage: "Know when the home volume is running low on free space."
        case .battery: "Get a reminder before the battery runs low while unplugged."
        case .updates: "Watch update results already cached by macOS. OmniFlow does not contact update servers."
        case .security: "Watch local security protections and run an existing offline vulnerability scanner."
        }
    }
    static func forSource(_ source: AmbientSource) -> Self {
        allCases.first { $0.source == source } ?? .agents
    }
}

@MainActor
final class AmbientDraft: ObservableObject {
    static let shared = AmbientDraft()
    @Published var reference: CursorReference?
}
