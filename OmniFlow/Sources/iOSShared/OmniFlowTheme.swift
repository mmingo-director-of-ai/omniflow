import SwiftUI
import UIKit

/// The OmniFlow (Freeflow) palette from Resources/Brand/tokens.json, resolved
/// for light and dark appearance, plus the editorial type the Mac app uses:
/// system text with serif headings.
enum Theme {
    // The OmniFlow/Quandry emerald brand (tokens.json: canvas, surface, accent,
    // text, secondary, border) on cards and highlights, over a near-black page.
    /// Near-black page (the Mac's dark flow paper); the greens live on the cards.
    static let paper = Color(hex: 0x0C0E0D)
    static let paperTop = Color(hex: 0x141816)
    /// Ordinary cards: the system's dark grouped surface, like the Settings form.
    static let surface = Color(hex: 0x1C1C1E)
    /// Hero cards (one per section) wear the emerald.
    static let heroTop = Color(hex: 0x10473C)
    static let heroBottom = Color(hex: 0x0A3A31)
    static let heroLine = Color(hex: 0x1F5A4B)
    static let raised = heroTop
    static let ink = Color(hex: 0xF0F0ED)
    static let muted = Color(hex: 0x9CCDB8)
    static let accent = Color(hex: 0x5BB591)
    static let onAccent = Color(hex: 0x011C18)
    /// Notices, tags and icon wells: neutral, so only hero cards are green.
    static let banner = Color(hex: 0x2A2C2E)
    static let line = Color(hex: 0x2C2C2E)
    static let emerald = Color(hex: 0x5BB591)
    static let mint = Color(hex: 0xA8E4CC)
    static let deep = Color(hex: 0x011C18)

    /// The screen backdrop: deep canvas with a lighter green glow from the top.
    static var backdrop: some View {
        ZStack {
            LinearGradient(colors: [paperTop, paper], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.07), .clear], center: .topTrailing, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    static func heading(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Navigation titles in the serif heading face, on every screen.
    @MainActor static func applyAppearance() {
        let large = UIFont.systemFont(ofSize: 34, weight: .bold).withDesign(.serif)
        let inline = UIFont.systemFont(ofSize: 17, weight: .semibold).withDesign(.serif)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: large, .foregroundColor: UIColor(Theme.ink)]
        appearance.titleTextAttributes = [.font: inline, .foregroundColor: UIColor(Theme.ink)]
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.largeTitleTextAttributes = appearance.largeTitleTextAttributes
        scrolled.titleTextAttributes = appearance.titleTextAttributes
        UINavigationBar.appearance().standardAppearance = scrolled
        UINavigationBar.appearance().compactAppearance = scrolled
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}

extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

/// The card every iOS screen uses: surface fill, hairline, continuous corners.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

/// The one emerald card a section leads with.
struct HeroCardStyle: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Theme.heroTop, Theme.heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.heroLine, lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardStyle(padding: padding)) }
    func heroCard(padding: CGFloat = 18) -> some View { modifier(HeroCardStyle(padding: padding)) }

    /// Section label in the Mac app's small uppercase style.
    func eyebrow() -> some View {
        font(.caption.weight(.semibold)).tracking(0.8).textCase(.uppercase).foregroundStyle(Theme.muted)
    }
}
