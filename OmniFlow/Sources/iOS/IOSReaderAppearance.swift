import SwiftUI
import UIKit

/// How books look in the iOS reader: text size, typeface, spacing, margins and
/// page colours, plus whether pages turn with the narration and the spoken
/// word is lit. Remembered between launches.
struct IOSReaderAppearance: Codable, Hashable, Sendable {
    enum Typeface: String, Codable, CaseIterable, Identifiable {
        case newYork, charter, georgia, palatino, system
        var id: Self { self }
        var title: String {
            switch self {
            case .newYork: "New York"
            case .charter: "Charter"
            case .georgia: "Georgia"
            case .palatino: "Palatino"
            case .system: "San Francisco"
            }
        }
    }

    enum Theme: String, Codable, CaseIterable, Identifiable {
        case dark, black, sepia, light
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var paper: Color {
            switch self {
            case .dark: Color(red: 0.05, green: 0.06, blue: 0.055)
            case .black: .black
            case .sepia: Color(red: 0.97, green: 0.93, blue: 0.85)
            case .light: .white
            }
        }
        var ink: Color {
            switch self {
            case .dark, .black: Color(red: 0.94, green: 0.94, blue: 0.93)
            case .sepia: Color(red: 0.27, green: 0.2, blue: 0.13)
            case .light: Color(red: 0.1, green: 0.1, blue: 0.1)
            }
        }
        var isDark: Bool { self == .dark || self == .black }
        /// The highlight: OmniFlow's green, darkened on light pages so text on it stays readable.
        var accent: Color { isDark ? Color(red: 0.36, green: 0.71, blue: 0.57) : Color(red: 0.12, green: 0.45, blue: 0.34) }
        var onAccent: Color { isDark ? Color(red: 0.0, green: 0.11, blue: 0.09) : .white }
    }

    enum Margins: String, Codable, CaseIterable, Identifiable {
        case narrow, normal, wide
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var points: CGFloat { switch self { case .narrow: 16; case .normal: 28; case .wide: 48 } }
    }

    enum Layout: String, Codable, CaseIterable, Identifiable {
        case pages, scroll
        var id: Self { self }
        var title: String { self == .pages ? "Pages" : "Scroll" }
    }

    var size: Double = 19
    var typeface: Typeface = .newYork
    /// Line height as a multiple of the font's.
    var lineSpacing: Double = 1.35
    var margins: Margins = .normal
    var theme: Theme = .dark
    var layout: Layout = .pages
    /// Light the word being spoken (the sentence is always marked).
    var highlightWords = true
    /// Turn pages to keep up with the narration.
    var followNarration = true

    static let sizes: ClosedRange<Double> = 13...34

    func font(heading: Bool = false) -> UIFont {
        let size = CGFloat(heading ? self.size * 1.3 : self.size)
        let weight: UIFont.Weight = heading ? .semibold : .regular
        switch typeface {
        case .newYork:
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        case .system: return .systemFont(ofSize: size, weight: weight)
        case .charter: return named(heading ? "Charter-Bold" : "Charter-Roman", size: size, weight: weight)
        case .georgia: return named(heading ? "Georgia-Bold" : "Georgia", size: size, weight: weight)
        case .palatino: return named(heading ? "Palatino-Bold" : "Palatino-Roman", size: size, weight: weight)
        }
    }

    private func named(_ name: String, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    // Persistence: one JSON value in UserDefaults.
    private static let key = "omniflow.reader.appearance"
    static func load() -> IOSReaderAppearance {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(IOSReaderAppearance.self, from: data) else { return IOSReaderAppearance() }
        return saved
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// The Aa sheet: size, typeface, spacing, margins, theme, layout and the narration options.
struct IOSReaderAppearanceSheet: View {
    @Binding var appearance: IOSReaderAppearance

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    HStack(spacing: 16) {
                        Button { appearance.size = max(IOSReaderAppearance.sizes.lowerBound, appearance.size - 1) } label: {
                            Image(systemName: "textformat.size.smaller").frame(width: 44, height: 36)
                        }
                        .accessibilityLabel("Smaller text")
                        Slider(value: $appearance.size, in: IOSReaderAppearance.sizes, step: 1)
                            .accessibilityLabel("Text size")
                        Button { appearance.size = min(IOSReaderAppearance.sizes.upperBound, appearance.size + 1) } label: {
                            Image(systemName: "textformat.size.larger").frame(width: 44, height: 36)
                        }
                        .accessibilityLabel("Larger text")
                    }
                    .buttonStyle(.borderless)
                    Picker("Font", selection: $appearance.typeface) {
                        ForEach(IOSReaderAppearance.Typeface.allCases) { face in
                            Text(face.title).font(Font(IOSReaderAppearance(size: 17, typeface: face).font())).tag(face)
                        }
                    }
                    Picker("Line spacing", selection: $appearance.lineSpacing) {
                        Text("Tight").tag(1.15); Text("Normal").tag(1.35); Text("Loose").tag(1.6)
                    }
                    .pickerStyle(.segmented)
                    Picker("Margins", selection: $appearance.margins) {
                        ForEach(IOSReaderAppearance.Margins.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Page") {
                    HStack(spacing: 12) {
                        ForEach(IOSReaderAppearance.Theme.allCases) { theme in
                            Button { appearance.theme = theme } label: {
                                VStack(spacing: 6) {
                                    Text("Aa").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(theme.ink)
                                        .frame(width: 56, height: 44)
                                        .background(theme.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(appearance.theme == theme ? theme.accent : Color.secondary.opacity(0.3), lineWidth: appearance.theme == theme ? 3 : 1))
                                    Text(theme.title).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(appearance.theme == theme ? .isSelected : [])
                        }
                    }
                    Picker("Layout", selection: $appearance.layout) {
                        ForEach(IOSReaderAppearance.Layout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("Turn pages with the narration", isOn: $appearance.followNarration)
                    Toggle("Highlight the spoken word", isOn: $appearance.highlightWords)
                } header: { Text("While listening") } footer: {
                    Text("The sentence being read is always marked. The word is estimated from the narration's timing.")
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
