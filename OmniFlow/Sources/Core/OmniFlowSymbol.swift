import SwiftUI

/// Symbol names: SF Symbols, plus OmniFlow's own custom symbols in
/// Symbols.xcassets (prefixed `omniflow.`). Compiled into the apps and both
/// widget extensions, so a `symbol` string can name either kind.
enum OmniFlowSymbol {
    /// The dictation mark (OmniWaveform's bars), for places that can't animate.
    static let dictate = "omniflow.waveform"

    static func isCustom(_ name: String) -> Bool { name.hasPrefix("omniflow.") }
}

extension Image {
    /// An SF Symbol, or one of OmniFlow's custom symbols, by name.
    init(symbol name: String) {
        if OmniFlowSymbol.isCustom(name) { self.init(name) } else { self.init(systemName: name) }
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, symbol name: String) {
        self.init { Text(title) } icon: { Image(symbol: name) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, symbol name: String) {
        self.init { Text(title) } icon: { Image(symbol: name) }
    }
}
