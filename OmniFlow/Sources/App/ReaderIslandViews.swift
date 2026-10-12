import SwiftUI

/// The compact island's Reading badge, in the agent mini-grid's 28×28 slot
/// while a book is open: OmniFlow's waveform following the voice inside a
/// chapter-progress ring. Clicking it plays or pauses without opening the
/// island. Mounted only in compact mode, so it does no work otherwise.
struct ReaderCompactView: View {
    /// The cover as a dimmed circular backdrop under the waveform. Off: at
    /// 22 pt a busy cover (or generated initials) makes the waveform hard to
    /// read, so the compact badge stays plain and the cover shows when expanded.
    var showsCover = false
    @ObservedObject private var reader = ReaderController.shared

    var body: some View {
        Button { reader.togglePlay() } label: {
            ZStack {
                if showsCover {
                    ReaderCoverView(width: 24, height: 24, corner: 12)
                        .overlay(Circle().fill(Color.black.opacity(0.55)))
                        .clipShape(Circle())
                }
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.5)
                Circle().trim(from: 0, to: max(0.02, reader.chapterProgress))
                    .stroke(NotchLeeTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ReaderWaveform(size: showsCover ? 18 : 22).opacity(reader.isPlaying ? 1 : 0.6)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(IslandControlZone())
        .accessibilityLabel(reader.isPlaying ? "Pause reading" : "Resume reading")
        .accessibilityValue("\(Int(reader.chapterProgress * 100)) percent of the chapter")
    }
}

/// The open book's cover, or a generated one (initials on the accent colour)
/// when the book has none.
struct ReaderCoverView: View {
    let width: CGFloat, height: CGFloat, corner: CGFloat
    @ObservedObject private var reader = ReaderController.shared

    var body: some View {
        BookCoverView(image: reader.cover, title: reader.book?.title ?? "", width: width, height: height, corner: corner)
    }
}

/// A cover image, or initials on the accent colour.
struct BookCoverView: View {
    let image: NSImage?, title: String
    let width: CGFloat, height: CGFloat, corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [NotchLeeTheme.accent, NotchLeeTheme.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(ReaderCover.initials(title))
                        .font(.system(size: min(width, height) * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Covers and descriptions for library rows: read off the main thread only
/// when a row appears, then kept in memory.
@MainActor
enum ReaderBookDetails {
    struct Details { var cover: NSImage?; var description: String? }
    private static var cache: [String: Details] = [:]

    static func cached(_ id: String) -> Details? { cache[id] }

    static func load(_ book: ReaderBook) async -> Details {
        if let hit = cache[book.id] { return hit }
        let (cover, description) = await Task.detached(priority: .utility) { () -> (CGImage?, String?) in
            // A book that is only in iCloud keeps the generated cover: reading
            // its files here would download it just to draw a row.
            let container = URL(fileURLWithPath: book.path).appendingPathComponent("META-INF/container.xml")
            let status = try? container.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if let status, status != .current { return (nil, nil) }
            let summary = ReaderEPUB.summary(URL(fileURLWithPath: book.path))
            return (summary.cover.flatMap { ReaderCover.thumbnail($0, pixels: 200) }, summary.description)
        }.value
        let details = Details(cover: cover.map { NSImage(cgImage: $0, size: .zero) }, description: description)
        cache[book.id] = details
        return details
    }
}

/// The play/pause control as the dictation pill's voice ring: the same radial
/// spectrum, driven by the book's audio instead of the microphone, around a
/// small play/pause button. Still (an even ring) while paused or locked, and
/// under Reduce Motion. The ring overflows the row's layout size into the
/// card's spacing, so the card keeps its height.
struct ReaderWaveformButton: View {
    let size: CGFloat
    @ObservedObject private var reader = ReaderController.shared

    private var moving: Bool { reader.isPlaying && !reader.screenLocked }

    var body: some View {
        Button { reader.togglePlay() } label: {
            ZStack {
                VoiceRing(listening: moving, color: NotchLeeTheme.accent) { ReaderController.shared.outputSpectrum }
                    .frame(width: size * 1.8, height: size * 1.8)
                    .opacity(reader.isPlaying ? 1 : 0.55)
                    .allowsHitTesting(false)
                Image(systemName: reader.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(NotchLeeTheme.accent)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .frame(width: size + 6, height: size + 6)
            .contentShape(Circle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(reader.isPlaying ? "Pause reading" : "Resume reading")
    }
}

/// The waveform driven by the Reader's real output while a book plays. When
/// paused or the screen is locked it holds still at rest (no animation).
struct ReaderWaveform: View {
    let size: CGFloat
    @ObservedObject private var reader = ReaderController.shared

    var body: some View {
        if reader.isPlaying && !reader.screenLocked {
            WaveformGlyph(size: size) { ReaderController.shared.outputLevel }
        } else {
            // At rest and still: no timeline runs while paused or locked.
            Canvas { context, canvas in
                let side = min(canvas.width, canvas.height) * 0.86
                let rect = CGRect(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2, width: side, height: side)
                context.fill(OmniWaveform.path(in: rect, heights: OmniWaveform.restHeights), with: .foreground)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }
}

/// Marks a control inside the island so a click on it doesn't also open the
/// island (the island opens on any other click).
struct IslandControlZone: View {
    @State private var id = UUID()

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { IslandControlZones.set(id, geometry.frame(in: .global)) }
                .onChange(of: geometry.frame(in: .global)) { _, frame in IslandControlZones.set(id, frame) }
                .onDisappear { IslandControlZones.set(id, nil) }
        }
    }
}

/// Frames of island controls in the island window's top-left coordinates.
@MainActor
enum IslandControlZones {
    private static var zones: [UUID: CGRect] = [:]

    static func set(_ id: UUID, _ frame: CGRect?) { zones[id] = frame }

    /// Whether a click at `point` (window coordinates, origin bottom-left) lands on a control.
    static func contains(_ point: NSPoint, windowHeight: CGFloat) -> Bool {
        let flipped = CGPoint(x: point.x, y: windowHeight - point.y)
        return zones.values.contains { $0.insetBy(dx: -2, dy: -2).contains(flipped) }
    }
}

/// The compact island's trailing slot: the Reading badge while a book is
/// open, the agent mini-grid otherwise.
struct CompactTrailingSlot: View {
    @ObservedObject var state: AppState
    @ObservedObject private var reader = ReaderController.shared

    var body: some View {
        if reader.isActive { ReaderCompactView() } else { CompactMiniGrid(state: state) }
    }
}
