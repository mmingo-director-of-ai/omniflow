import SwiftUI

/// Nova watercolor from Qatalyst supplies decorative page art.
/// The app icon and animated status indicators keep their existing identities.
enum OmniFlowPageArtwork: String {
    case dictation = "NovaDictationWash"
    case history = "NovaHistoryWash"
    case monitoring = "NovaMonitoringWash"

    var assetName: String { rawValue }

    static func forPage(_ page: String, settingsTab: String = "") -> Self {
        switch page {
        case "Home", "Dictation", "Assistant": .dictation
        case "Recent", "History", "Transcripts", "Conversations", "Dictionary", "Memory": .history
        case "Settings": settingsTab == "Dictation" ? .dictation : .history
        default: .monitoring
        }
    }
}

/// The character is the byte-for-byte canonical watercolor, never a generated
/// variant. Scene props are separate and cannot alter her proportions or armor.
struct OmniFlowNovaScene: View {
    let artwork: OmniFlowPageArtwork

    var body: some View {
        Color.clear.aspectRatio(1.5, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .trailing) {
                        Image(artwork.assetName).resizable().scaledToFit()
                        Image("NovaReference").resizable().scaledToFit()
                            .frame(width: geometry.size.width * 0.78, height: geometry.size.height)
                    }
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A static painted canvas shared by every main page. It fills spare space
/// without contributing layout height, intercepting input or running a timer.
struct OmniFlowPageBackdrop: View {
    let page: String
    var settingsTab = ""
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let gutter = trailingMargin(in: geometry.size.width)
            if let gutter, gutter < 180 {
                // A dense narrow page has no spare side column. Its header has
                // room for a small illustration above the controls instead.
                illustration.frame(width: 300, height: 112)
                    .padding(.top, 12).padding(.trailing, 16)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
            } else {
                let width = gutter.map { min(1100, $0 * 2) }
                    ?? min(1100, max(460, geometry.size.width * 0.78))
                illustration
                    .frame(width: width, height: min(width * 2 / 3, geometry.size.height * 0.72))
                    .padding(.trailing, 20).padding(.bottom, 20)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
                    .mask {
                        if let gutter {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: max(0, geometry.size.width - gutter))
                                LinearGradient(stops: [.init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.22), .init(color: .black, location: 1)],
                                    startPoint: .leading, endPoint: .trailing)
                            }
                        } else { Rectangle() }
                    }
            }
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }

    private var illustration: some View {
        OmniFlowNovaScene(artwork: .forPage(page, settingsTab: settingsTab))
            .opacity(reduceTransparency ? 0.14 : (scheme == .dark ? 0.38 : 0.48))
    }

    /// Match the existing content columns. Never paint behind form rows or
    /// their footnotes merely because a native row background is translucent.
    private func trailingMargin(in width: CGFloat) -> CGFloat? {
        switch page {
        case "Settings": max(0, (width - 800) / 2)
        case "Monitoring": max(0, (width - 1008) / 2)
        case "Shortcuts": max(0, (width - 1088) / 2)
        case "Focus & pointer": max(0, width - 1104)
        case "Connections": max(0, width - 920)
        case "Conversations", "Transcripts": max(0, width - 960)
        default: nil
        }
    }
}

struct OmniFlowWatercolor: View {
    let artwork: OmniFlowPageArtwork
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            OmniFlowNovaScene(artwork: artwork)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                .opacity(reduceTransparency ? 0.16 : (scheme == .dark ? 0.46 : 0.52))
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Existing native mascot drawing supplies breathing, listening, thinking and
/// the completion wave. Static logo instances stay paused to avoid idle timers.
struct OmniFlowMascotActivity: View {
    let phase: AppModel.Phase
    var level: Double = 0
    private var state: BotState {
        switch phase {
        case .idle: .idle
        case .starting, .processing: .thinking
        case .recording: .working
        case .result: .finished
        case .error: .question
        }
    }
    var body: some View {
        RedPandaView(state: state, look: CGPoint(x: 0, y: -min(1, max(0, level))), paused: phase == .idle || phase == .error)
            .accessibilityHidden(true)
    }
}
