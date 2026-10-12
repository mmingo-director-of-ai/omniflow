import AppKit
import Foundation
import SwiftUI

/// Replaceable visual identity. Signing, bundle IDs and data paths never come from theme data.
enum OmniFlowBrand {
    private struct Tokens: Decodable, Sendable {
        var colors: [String: String]
        var typography: [String: String]
    }
    private static let tokens: Tokens? = {
        guard let url = Bundle.main.url(forResource: "tokens", withExtension: "json", subdirectory: "Brand"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }()
    private static func color(_ role: String, fallback: String) -> Color {
        let raw = tokens?.colors[role] ?? fallback
        let valid = raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
        return Color(hex: valid ? raw : fallback)
    }
    static let accent = color("accent", fallback: "#5BB591")
    static let canvas = color("canvas", fallback: "#011C18")
    static let surface = color("surface", fallback: "#00332B")
    static let text = color("text", fallback: "#F0F0ED")
    static let secondary = color("secondary", fallback: "#A8E4CC")
    static let border = color("border", fallback: "#3D8A6A")
    static let onAccent = color("onAccent", fallback: "#011C18")
    /// Companion surfaces follow system appearance; the compact island keeps its dark palette.
    static func adaptive(_ light: String, _ dark: String, lightFallback: String, darkFallback: String) -> Color {
        func native(_ role: String, _ fallback: String) -> NSColor {
            let raw = tokens?.colors[role] ?? fallback
            let valid = raw.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
            let value = UInt32((valid ? raw : fallback).dropFirst(), radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let day = native(light, lightFallback), night = native(dark, darkFallback)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? night : day
        })
    }
    static let pageBackground = Color.flowPaper
    static let contentBackground = Color.flowSurface
    static let cardBackground = Color.flowPaper.opacity(0.65)
    static let hairline = Color.flowInk.opacity(0.10)
    static let interactiveAccent = Color.flowAccent
    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: size >= 26 ? .regular : .semibold, design: size >= 26 ? .serif : .default)
    }
    static func body(_ size: CGFloat = 14) -> Font { .system(size: size) }

}

/// Compatibility facade while existing feature views migrate to semantic names.
enum NotchLeeTheme {
    static let green = OmniFlowBrand.accent
    static let accent = OmniFlowBrand.accent
    static let copper = OmniFlowBrand.secondary
    static let sage = OmniFlowBrand.interactiveAccent
    static let paper = Color.primary
    static let blueprint = OmniFlowBrand.surface
    static let canvas = OmniFlowBrand.pageBackground
    static let card = OmniFlowBrand.cardBackground
    static let inset = OmniFlowBrand.accent.opacity(0.15)
    static let border = OmniFlowBrand.hairline
    static let onAccent = OmniFlowBrand.onAccent
}

/// Explicit state colors remain visible with macOS's graphite accent setting.
/// The native accessibility representation retains toggle semantics and state.
struct OmniFlowSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    private var height: CGFloat {
        switch controlSize {
        case .mini: 14
        case .small: 18
        case .large: 26
        default: 22
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? Color(red: 0.15, green: 0.68, blue: 0.35) : Color.secondary.opacity(0.3))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).padding(2)
                            .frame(width: height, height: height)
                    }
                    .frame(width: height * 1.7, height: height)
                    .opacity(isEnabled ? 1 : 0.45)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}
