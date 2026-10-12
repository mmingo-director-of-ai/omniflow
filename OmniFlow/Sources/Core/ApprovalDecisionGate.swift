import Foundation

/// Owned by the main actor in HookServer. Every action, including expiry,
/// consumes one exact request; a session or reused socket descriptor is not
/// an authorization identity.
struct ApprovalDecisionGate {
    private var pending: UUID?

    mutating func replace(with requestID: UUID) { pending = requestID }

    mutating func consume(_ requestID: UUID) -> Bool {
        guard pending == requestID else { return false }
        pending = nil
        return true
    }
}
