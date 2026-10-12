import SwiftUI

// Retained as the session-card API; all character art and motion are original to OmniFlow.

struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    @State private var cheerful = false

    var body: some View {
        GeometryReader { geometry in
            RedPandaView(state: state.effectiveState,
                         paused: state.mode == .hidden || (state.mode == .expanded && IslandConst.viewLayouts[state.view]?.botDiameter == 0),
                         cheerful: cheerful)
                .frame(width: geometry.size.width, height: geometry.size.height - particleOverhang)
                .offset(y: particleOverhang)
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { _ in cheerful = true }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in cheerful = true }
        .task(id: cheerful) {
            if cheerful {
                try? await Task.sleep(for: .seconds(1.8))
                if !Task.isCancelled { cheerful = false }
            }
        }
    }
}

struct MiniBotCanvasView: View {
    let task: AgentTask
    var paused = false
    var body: some View { RedPandaView(state: task.state, paused: paused, blinks: false) }
}

// MARK: - CGColor from hex string

func cgColorFromHex(_ hex: String) -> CGColor? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let val = UInt64(h, radix: 16) else { return nil }
    let r = CGFloat((val >> 16) & 0xFF) / 255
    let g = CGFloat((val >> 8)  & 0xFF) / 255
    let b = CGFloat( val        & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

extension CGColor {
    static func from(_ hex: String) -> CGColor {
        cgColorFromHex(hex) ?? CGColor(gray: 0.5, alpha: 1)
    }
}
