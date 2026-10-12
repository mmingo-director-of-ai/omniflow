public struct ShortcutMachine {
    public enum State: Equatable { case idle, holding, locked, processing }
    public enum Event { case fnDown, fnUp, space, escape, otherKey }
    public enum Action: Equatable { case start, lock, finish, cancel }
    public private(set) var state: State = .idle
    private var fnHeld = false
    private var finishOnRelease = false
    public init() {}
    public mutating func lock() { if state == .idle || state == .holding { state = .locked } }
    public mutating func processing() { state = .processing; finishOnRelease = false }
    public mutating func reset() { state = .idle; fnHeld = false; finishOnRelease = false }
    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .fnDown:
            guard !fnHeld else { return [] }
            fnHeld = true
            if state == .idle { state = .holding; return [.start] }
            if state == .locked { state = .processing; finishOnRelease = true }
        case .fnUp:
            fnHeld = false
            if finishOnRelease { finishOnRelease = false; return [.finish] }
            if state == .holding { state = .processing; return [.finish] }
        case .space:
            if state == .holding && fnHeld { state = .locked; return [.lock] }
        case .escape:
            if state != .idle { state = .idle; finishOnRelease = false; return [.cancel] }
        case .otherKey:
            if state == .holding { state = .idle; return [.cancel] }
        }
        return []
    }
}
