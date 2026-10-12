import Foundation

/// Owns one nested focus suspension. A completed old capture cannot release
/// the token acquired by a newer interaction on the same surface.
@MainActor
final class OmniFlowInteractionLease {
    private let reason: String
    private let suspend: @MainActor (String) -> UUID
    private let resume: @MainActor (UUID) -> Void
    private var token: UUID?

    init(reason: String,
         suspend: @escaping @MainActor (String) -> UUID = { OmniFlowFocusController.shared.suspend(reason: $0) },
         resume: @escaping @MainActor (UUID) -> Void = { OmniFlowFocusController.shared.resume($0) }) {
        self.reason = reason
        self.suspend = suspend
        self.resume = resume
    }

    var isHeld: Bool { token != nil }

    @discardableResult
    func begin() -> UUID {
        if let token { return token }
        let acquired = suspend(reason)
        token = acquired
        return acquired
    }

    func end(_ expected: UUID? = nil) {
        guard let active = token, expected == nil || expected == active else { return }
        token = nil
        resume(active)
    }
}
