import AppKit
import SwiftUI

/// Shared click feedback so every action visibly lands: buttons press in,
/// copies confirm in place, and a short toast says what happened.

/// A plain-looking button that presses in. Use it wherever `.plain` was used.
struct OmniFlowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.45))
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == OmniFlowPressStyle {
    /// Plain appearance with a visible press.
    static var press: OmniFlowPressStyle { OmniFlowPressStyle() }
}

/// One short confirmation at a time, shown at the bottom of the OmniFlow window.
@MainActor
final class OmniFlowToastCenter: ObservableObject {
    static let shared = OmniFlowToastCenter()
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
    }
    @Published private(set) var current: Toast?
    private var dismissal: Task<Void, Never>?

    func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        current = Toast(text: text, symbol: symbol)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
            self?.current = nil
        }
    }
}

enum OmniFlowClipboard {
    /// Writes plain text for this Mac only and confirms it.
    @MainActor @discardableResult
    static func copy(_ text: String, confirmation: String = "Copied to clipboard") -> Bool {
        NSPasteboard.general.prepareForNewContents(with: .currentHostOnly)
        let copied = NSPasteboard.general.setString(text, forType: .string)
        if copied { OmniFlowToastCenter.shared.show(confirmation) }
        else { OmniFlowToastCenter.shared.show("Couldn't copy", symbol: "exclamationmark.circle.fill") }
        return copied
    }
}

struct OmniFlowToastOverlay: View {
    @ObservedObject private var center = OmniFlowToastCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                Label(toast.text, systemImage: toast.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.75), value: center.current)
        .allowsHitTesting(false)
    }
}

/// A copy button that swaps to a checkmark and "Copied" for a moment.
struct OmniFlowCopyButton<Style: ButtonStyle>: View {
    let title: String?
    let help: String
    let style: Style
    let text: () -> String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    init(_ title: String? = nil, help: String = "Copy", style: Style, text: @escaping () -> String) {
        self.title = title; self.help = help; self.style = style; self.text = text
    }

    var body: some View {
        Button {
            guard OmniFlowClipboard.copy(text()) else { return }
            copied = true
            reset?.cancel()
            reset = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
                copied = false
            }
        } label: {
            Group {
                if let title {
                    Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                } else {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.accentColor : Color.primary)
                }
            }
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy, value: copied)
        }
        .buttonStyle(style)
        .help(copied ? "Copied" : help)
        .accessibilityLabel(copied ? "Copied" : help)
    }
}

extension OmniFlowCopyButton where Style == OmniFlowPressStyle {
    init(_ title: String? = nil, help: String = "Copy", text: @escaping () -> String) {
        self.init(title, help: help, style: .press, text: text)
    }
}
