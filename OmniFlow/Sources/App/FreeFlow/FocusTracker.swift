import Foundation

/// Samples only during a dictation. A missing destination clears the previous one;
/// it never silently falls back to an app the user has left.
@MainActor
final class FocusTracker<Target> {
    private(set) var current: Target?
    private(set) var isTracking = false
    private var task: Task<Void, Never>?
    private let read: () -> Target?
    var onChange: ((Target?) -> Void)?
    init(read: @escaping () -> Target?) { self.read = read }
    func start() {
        stop(); isTracking = true; sample()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.isTracking else { return }
                self.sample()
            }
        }
    }
    func sample() {
        guard isTracking else { return }
        current = read(); onChange?(current)
    }
    func freeze() -> Target? {
        sample()
        isTracking = false; task?.cancel(); task = nil
        return current
    }
    func stop() {
        isTracking = false; task?.cancel(); task = nil; current = nil
    }
}
