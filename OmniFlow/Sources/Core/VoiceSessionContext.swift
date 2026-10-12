import Foundation

/// A bounded snapshot of what the monitor actually knows, not the agent's full conversation.
struct VoiceSession: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let agent: String
    let status: String
    let latestStep: String

    var needsAttention: Bool { ["approval", "question", "error", "ratelimit"].contains(status) }

    var spokenStatus: String {
        switch status {
        case "approval": return "waiting for approval"
        case "question": return "waiting for your answer"
        case "error": return "reporting an error"
        case "ratelimit": return "waiting on a rate limit"
        case "finished": return "finished"
        case "idle", "sleeping": return "idle"
        default: return status
        }
    }

    var summary: String {
        let step = latestStep.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name) (\(agent)) is \(spokenStatus)." + (step.isEmpty ? "" : " Latest update: \(step)")
    }
}

struct VoiceSessionContext: Sendable {
    let sessions: [VoiceSession]
    let focusedID: String?

    var summary: String {
        guard !sessions.isEmpty else { return "No agent sessions are connected right now." }
        let visible = sessions.prefix(6).map(\.summary).joined(separator: " ")
        return visible + (sessions.count > 6 ? " There are \(sessions.count - 6) more sessions." : "")
    }

    var attentionSummary: String {
        let waiting = sessions.filter(\.needsAttention)
        guard !waiting.isEmpty else { return "No connected agent is waiting for your attention." }
        return waiting.prefix(6).map(\.summary).joined(separator: " ")
    }

    var modelContext: String {
        modelContext(maximumSessions: 12)
    }

    func modelContext(maximumSessions: Int) -> String {
        // Prioritize the focused session, then sessions needing attention. Bound model input.
        let ordered = sessions.sorted {
            func priority(_ s: VoiceSession) -> Int { s.id == focusedID ? 2 : (s.needsAttention ? 1 : 0) }
            return priority($0) > priority($1)
        }
        let bounded = ordered.prefix(maximumSessions).map {
            VoiceSession(id: String($0.id.prefix(80)), name: String($0.name.prefix(80)),
                         agent: $0.agent, status: $0.status, latestStep: String($0.latestStep.prefix(240)))
        }
        let data = (try? JSONEncoder().encode(bounded)) ?? Data("[]".utf8)
        return "Coding-agent sessions tracked by the session monitor: \(sessions.count)\n" + String(decoding: data, as: UTF8.self)
    }

    func matching(_ name: String) -> [VoiceSession] {
        let target = VoiceCommand.normalized(name)
        let exact = sessions.filter { VoiceCommand.normalized($0.name) == target }
        if !exact.isEmpty { return exact }
        return sessions.filter {
            VoiceCommand.normalized($0.name).contains(target)
                || VoiceCommand.normalized($0.agent).contains(target)
        }
    }
}

/// Only explicit, whole-utterance commands can change UI state. Model output never executes actions.
enum VoiceCommand: Equatable {
    case show(String), home, mute, unmute, status, attention, question
    case time, date, system, applications, activeWindow, storage, battery, processes, memory

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static func parse(_ text: String) -> VoiceCommand {
        var text = normalized(text)
        if text.hasPrefix("please ") { text = String(text.dropFirst(7)) }
        if text.hasSuffix(" please") { text = String(text.dropLast(7)) }
        switch text {
        case "what time is it", "what's the time", "what is the time", "tell me the time", "current time": return .time
        case "what's today's date", "what is today's date", "what day is it", "what's the date", "what is the date", "today's date": return .date
        case "what macos version am i running", "what version of macos am i running", "system information", "system info": return .system
        case "what apps are running", "which apps are running", "list running apps", "show running apps": return .applications
        case "what processes are using the most resources", "what processes are taking the most resources on my system", "top processes", "cpu usage", "what is using my cpu": return .processes
        case "memory usage", "how much memory am i using", "how much ram am i using": return .memory
        case "what app am i in", "what's the active app", "what is the active app", "what window am i in": return .activeWindow
        case "how much disk space is free", "how much free disk space do i have", "how much storage is left", "free disk space": return .storage
        case "what's my battery level", "what is my battery level", "how much battery is left", "battery level": return .battery
        case "home", "show home", "go home", "show sessions": return .home
        case "mute", "mute sound", "mute sounds", "mute omni", "turn sound off": return .mute
        case "unmute", "unmute sound", "unmute omni", "turn sound on": return .unmute
        case "status", "what's happening", "what is happening", "what's everyone doing",
             "what are my agents doing", "summarize my sessions": return .status
        case "who's waiting on me", "who is waiting on me", "who needs me",
             "what needs my attention", "who's waiting", "who is waiting": return .attention
        default:
            for prefix in ["show ", "focus ", "switch to "] where text.hasPrefix(prefix) {
                let target = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !target.isEmpty { return .show(target) }
            }
            return .question
        }
    }
}

/// Replaces speculative speech segments instead of appending each revision as duplicate text.
struct VoiceTranscript {
    private struct Segment { let text: String; let end: Double; let isFinal: Bool }
    private var segments: [Double: Segment] = [:]

    mutating func update(text: String, start: Double, end: Double? = nil, isFinal: Bool) {
        guard start.isFinite, segments[start]?.isFinal != true || isFinal else { return }
        let end = end ?? start
        guard end.isFinite, end >= start else { return }
        // Dictation can trim leading silence when finalizing (e.g. start 0 → 0.3).
        // Replace the overlapping provisional range instead of repeating the phrase.
        let overlapping = segments.filter { $0.key != start && $0.key < end && $0.value.end > start }
        if !isFinal && overlapping.contains(where: { $0.value.isFinal }) { return }
        for (key, segment) in overlapping where !segment.isFinal { segments.removeValue(forKey: key) }
        segments[start] = Segment(text: text, end: end, isFinal: isFinal)
    }

    var text: String {
        segments.keys.sorted().compactMap { segments[$0]?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum WakePhrase {
    static let vocabulary = ["Omni", "Hey Omni", "OmniFlow"]

    static func command(in text: String) -> String? {
        // Word boundaries prevent ordinary words containing the name from waking the app.
        // Apple dictation may insert punctuation after the greeting or name.
        guard let range = text.range(of: #"\b(?:hey[\s,.!?\-–—]+)?omni\b[\s,.:;!?\-–—]*"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
