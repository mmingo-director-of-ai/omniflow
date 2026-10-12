import ActivityKit
import Foundation

/// The Lock Screen and Dynamic Island while OmniFlow records. The app starts
/// and updates it locally; no push token, App Group or server is involved.
struct OmniFlowRecordingAttributes: ActivityAttributes {
    typealias ContentState = OmniFlowRecordingContent

    var mode: OmniFlowRecordingMode
}

#if !OMNIFLOW_IOS_WIDGET
/// Call from the dictation model's phase changes: `start` when recording
/// begins, `update` as it cleans up or translates, `end` when it settles.
@MainActor
final class OmniFlowLiveActivity {
    static let shared = OmniFlowLiveActivity()
    /// Only the id is kept: Activity is not Sendable, so each change looks it
    /// up again off the main actor.
    private var activityID: String?
    private var state: OmniFlowRecordingContent?

    func start(_ mode: OmniFlowRecordingMode) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let previous = activityID { Task.detached { await Self.end(previous, nil, .immediate) } }
        let state = OmniFlowRecordingContent(phase: .listening, startedAt: .now)
        self.state = state
        // A refused request (Live Activities off, too many running) leaves recording unaffected.
        activityID = (try? Activity.request(attributes: OmniFlowRecordingAttributes(mode: mode),
                                            content: .init(state: state, staleDate: nil)))?.id
    }

    func update(_ phase: OmniFlowRecordingPhase) {
        guard let id = activityID, var state else { return }
        if phase == .listening, state.phase != .listening {
            // A new dictation in a long-lived (keyboard) activity: the clock restarts.
            state.startedAt = .now; state.stoppedAt = nil; state.words = nil
        } else if phase != .listening, state.stoppedAt == nil {
            state.stoppedAt = .now
        }
        state.phase = phase
        self.state = state
        let content = ActivityContent(state: state, staleDate: nil)
        Task.detached { await Self.activity(id)?.update(content) }
    }

    func end(words: Int? = nil) {
        guard let id = activityID, var state else { return }
        state.phase = .done
        state.stoppedAt = state.stoppedAt ?? .now
        state.words = words
        activityID = nil
        self.state = nil
        let content = ActivityContent(state: state, staleDate: nil)
        Task.detached { await Self.end(id, content, .after(.now.addingTimeInterval(8))) }
    }

    nonisolated private static func activity(_ id: String) -> Activity<OmniFlowRecordingAttributes>? {
        Activity<OmniFlowRecordingAttributes>.activities.first { $0.id == id }
    }

    nonisolated private static func end(_ id: String, _ content: ActivityContent<OmniFlowRecordingContent>?,
                                        _ policy: ActivityUIDismissalPolicy) async {
        await activity(id)?.end(content, dismissalPolicy: policy)
    }
}
#endif
