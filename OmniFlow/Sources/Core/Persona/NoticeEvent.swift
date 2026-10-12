import Foundation

enum NoticeSeverity: String, Codable, Sendable, Comparable {
    case info, warning, critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.info, .warning, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// Stable identity of a notice type; keys template pools and the no-repeat history.
enum NoticeKind: String, Codable, Sendable, CaseIterable {
    case memoryPressure, cpuHigh, thermalPressure, batteryLow, diskLow
    case agentNeedsApproval, agentQuestion, agentFinished, agentError, agentRateLimited
    case greeting, assistantReady, noSpeechHeard, micSilent, micStalled, micPermissionNeeded
    case speechModelMissing, translationAssetMissing, translationTimedOut
    case assistantUnavailable, answerTimedOut, voiceUnavailable, historySaveFailed
}

/// A system-generated notice with its facts as typed values. Persona text never
/// supplies facts: every number and name comes from here and is re-checked after rendering.
enum NoticeEvent: Sendable, Hashable {
    /// `percent` is nil when the source only signals pressure (DispatchSource memory pressure).
    case memoryPressure(percent: Int?)
    case cpuHigh(percent: Int)
    case thermalPressure
    case batteryLow(percent: Int)
    case diskLow(freePercent: Int)
    case agentNeedsApproval(agent: String, tool: String)
    case agentQuestion(agent: String)
    case agentFinished(agent: String)
    case agentError(agent: String)
    case agentRateLimited(agent: String)
    case greeting
    case assistantReady
    case noSpeechHeard
    case micSilent(microphone: String)
    case micStalled
    case micPermissionNeeded
    case speechModelMissing
    case translationAssetMissing(language: String)
    case translationTimedOut
    case assistantUnavailable
    case answerTimedOut
    case voiceUnavailable
    case historySaveFailed

    var kind: NoticeKind {
        switch self {
        case .memoryPressure: .memoryPressure
        case .cpuHigh: .cpuHigh
        case .thermalPressure: .thermalPressure
        case .batteryLow: .batteryLow
        case .diskLow: .diskLow
        case .agentNeedsApproval: .agentNeedsApproval
        case .agentQuestion: .agentQuestion
        case .agentFinished: .agentFinished
        case .agentError: .agentError
        case .agentRateLimited: .agentRateLimited
        case .greeting: .greeting
        case .assistantReady: .assistantReady
        case .noSpeechHeard: .noSpeechHeard
        case .micSilent: .micSilent
        case .micStalled: .micStalled
        case .micPermissionNeeded: .micPermissionNeeded
        case .speechModelMissing: .speechModelMissing
        case .translationAssetMissing: .translationAssetMissing
        case .translationTimedOut: .translationTimedOut
        case .assistantUnavailable: .assistantUnavailable
        case .answerTimedOut: .answerTimedOut
        case .voiceUnavailable: .voiceUnavailable
        case .historySaveFailed: .historySaveFailed
        }
    }

    /// Slot values for template filling. Keys match `{slot}` placeholders.
    var facts: [String: String] {
        switch self {
        case .memoryPressure(let percent): percent.map { ["percent": String($0)] } ?? [:]
        case .cpuHigh(let percent), .batteryLow(let percent): ["percent": String(percent)]
        case .diskLow(let free): ["percent": String(free)]
        case .agentNeedsApproval(let agent, let tool): ["agent": agent, "tool": tool]
        case .agentQuestion(let agent), .agentFinished(let agent), .agentError(let agent), .agentRateLimited(let agent):
            ["agent": agent]
        case .micSilent(let microphone): ["mic": microphone]
        case .translationAssetMissing(let language): ["language": language]
        default: [:]
        }
    }

    /// Numbers that must survive any rewrite unchanged.
    var numbers: [Int] {
        switch self {
        case .memoryPressure(let percent): percent.map { [$0] } ?? []
        case .cpuHigh(let p), .batteryLow(let p), .diskLow(let p): [p]
        default: []
        }
    }

    /// Names that must appear verbatim in any rendering.
    var names: [String] {
        switch self {
        case .agentNeedsApproval(let agent, let tool): [agent, tool]
        case .agentQuestion(let a), .agentFinished(let a), .agentError(let a), .agentRateLimited(let a): [a]
        case .micSilent(let mic): [mic]
        case .translationAssetMissing(let language): [language]
        default: []
        }
    }

    var severity: NoticeSeverity {
        switch self {
        case .agentNeedsApproval, .historySaveFailed: .critical
        case .greeting, .assistantReady, .agentFinished, .agentRateLimited, .speechModelMissing, .voiceUnavailable: .info
        default: .warning
        }
    }

    /// For critical notices, the neutral sentence that is always shown verbatim after any
    /// persona flavor. It never comes from a persona pool and Tier 2 never rewrites it.
    var coreSentence: String? {
        switch self {
        case .agentNeedsApproval(let agent, let tool): "\(agent) needs permission to run \(tool). Choose Allow or Deny."
        case .historySaveFailed: "History could not be saved. Copy your transcript now or it may be lost."
        default: nil
        }
    }

    /// Facts and core identity, for caching Tier 2 output against an identical recurrence.
    var fingerprint: String {
        kind.rawValue + "|" + facts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
}

/// A phrased notice ready for display or speech.
struct Notice: Sendable, Equatable {
    enum Tier: String, Sendable { case template, model }
    /// The full line to show or speak (flavor + core sentence for critical notices).
    let text: String
    /// The unrewritten factual sentence for critical notices, so UI can emphasise it.
    let coreSentence: String?
    let personaID: String
    let tier: Tier
}
