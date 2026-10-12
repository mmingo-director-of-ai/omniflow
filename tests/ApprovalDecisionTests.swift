import Foundation

@main
enum ApprovalDecisionTests {
    static func main() {
        var gate = ApprovalDecisionGate()
        let requestA = UUID(), requestB = UUID()
        gate.replace(with: requestA)
        // Two requests can belong to the same agent session. Session identity
        // must never make A's notification, button or timeout apply to B.
        gate.replace(with: requestB)
        precondition(!gate.consume(requestA), "stale notification approved replacement")
        precondition(!gate.consume(requestA), "stale timeout consumed replacement")
        precondition(gate.consume(requestB), "current request must remain actionable")
        precondition(!gate.consume(requestB), "duplicate click replayed decision")
        precondition(!gate.consume(UUID()), "no pending request must fail closed")
        gate.replace(with: requestA)
        precondition(gate.consume(requestA))
        print("Approval request binding: passed (replacement, stale actions, replay, empty state)")
    }
}
