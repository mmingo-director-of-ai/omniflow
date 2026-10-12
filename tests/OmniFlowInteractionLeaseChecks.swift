import Foundation

@MainActor
enum OmniFlowInteractionLeaseChecks {
    static func run() {
        var active = Set<UUID>()
        var resumes = 0
        func lease(_ reason: String) -> OmniFlowInteractionLease {
            OmniFlowInteractionLease(reason: reason, suspend: { _ in
                let token = UUID()
                active.insert(token)
                return token
            }, resume: { token in
                precondition(active.remove(token) != nil, "A lease resumed an unknown or already released suspension")
                resumes += 1
            })
        }
        let voice = lease("voice"), gesture = lease("gesture")
        let capture = lease("capture"), panel = lease("panel")
        let voiceToken = voice.begin()
        precondition(voice.begin() == voiceToken && active.count == 1,
                     "Moving from preparation to listening acquired duplicate voice suspensions")
        gesture.begin()
        let captureToken = capture.begin()
        gesture.end()
        precondition(active.count == 2 && voice.isHeld && capture.isHeld,
                     "Ending a region gesture resumed focus during capture or voice")
        panel.begin()
        capture.end(captureToken)
        precondition(active.count == 2 && voice.isHeld && panel.isHeld,
                     "Completing capture resumed focus while its context panel remained open")
        voice.end()
        precondition(active.count == 1 && panel.isHeld,
                     "Completing/cancelling voice resumed focus while the cursor panel owned focus")
        panel.end()
        precondition(active.isEmpty)
        let ended = resumes
        voice.end(); gesture.end(); capture.end(); panel.end()
        precondition(resumes == ended, "Repeated close/stop released another interaction's suspension")

        let stale = capture.begin()
        capture.end()
        let replacement = capture.begin()
        capture.end(stale)
        precondition(capture.isHeld && active == [replacement],
                     "A cancelled capture's late completion resumed focus during its replacement")
        capture.end(replacement)
        precondition(active.isEmpty && !capture.isHeld)
        print("Focus interaction leases: nested voice/gesture/capture/panel handoff, idempotent cleanup and stale completion protection passed")
    }
}
