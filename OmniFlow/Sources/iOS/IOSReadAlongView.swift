import SwiftUI

/// The iPhone/iPad read-along: the shared view with OmniFlow's iOS palette.
struct IOSReadAlongView: View {
    var body: some View {
        ReaderReadAlongView(engine: IOSReaderModel.shared.engine, style: .iOS)
    }
}

extension ReaderReadAlongStyle {
    static var iOS: ReaderReadAlongStyle {
        ReaderReadAlongStyle(ink: Theme.ink, muted: Theme.muted, accent: Theme.accent, onAccent: Theme.onAccent,
                             chapterTitle: Theme.heading(24), heading: Theme.heading(21),
                             body: .system(.title3, design: .serif), small: .system(.footnote, design: .serif))
    }
}
