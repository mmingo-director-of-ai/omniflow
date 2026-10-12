import SwiftUI

/// Listening to a book: the cover, the chapter, and the dictation pill's voice
/// ring driven by the book's audio, with play/pause in its centre. The ring is
/// still while paused and under Reduce Motion. "Read along" swaps the ring for
/// the book's text, following the narration, with compact controls below.
struct IOSReaderPlayerView: View {
    @ObservedObject private var model = IOSReaderModel.shared
    @ObservedObject private var engine = IOSReaderModel.shared.engine
    @AppStorage("omniflow.reader.readAlong") private var readAlong = false

    var body: some View {
        Group {
            if readAlong {
                IOSPagedReaderView()
            } else {
                player
            }
        }
        .navigationTitle(readAlong ? (model.book?.title ?? "Listening") : "Listening")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { readAlong.toggle() } label: {
                    Image(systemName: readAlong ? "circle.circle" : "text.alignleft")
                }
                .accessibilityLabel(readAlong ? "Show the player" : "Read along")
            }
        }
    }

    private var player: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                ring
                transport
                Button { readAlong = true } label: {
                    Label("Read along", systemImage: "text.alignleft")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Theme.banner, in: Capsule()).foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(engine.document == nil)
                pace
                if let note = model.startNote, engine.status != .loading {
                    Text(note).font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background { Theme.backdrop }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let cover = model.cover { Image(uiImage: cover).resizable().scaledToFill() }
                else { ZStack { Theme.heroTop; Text(ReaderCover.initials(model.book?.title ?? "")).font(Theme.heading(20)).foregroundStyle(Theme.mint) } }
            }
            .frame(width: 70, height: 100).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(model.book?.title ?? "").font(Theme.heading(20)).foregroundStyle(Theme.ink).lineLimit(3)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(2)
                ProgressView(value: engine.chapterProgress).tint(Theme.accent)
                    .accessibilityLabel("Chapter progress")
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [Theme.heroTop, Theme.heroBottom], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var subtitle: String {
        switch engine.status {
        case .loading: "Preparing the book…"
        case .failed(let message): message
        case .finished: "Finished"
        default: model.chapterTitle
        }
    }

    /// The pill's ring around play/pause.
    private var ring: some View {
        Button { model.togglePlay() } label: {
            ZStack {
                VoiceRing(listening: engine.isPlaying, color: Theme.accent) { ReaderEngine.outputSpectrum(engine) }
                    .frame(width: 230, height: 230)
                    .opacity(engine.isPlaying ? 1 : 0.55)
                Circle().fill(Theme.accent).frame(width: 96, height: 96)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 16, y: 6)
                if engine.status == .loading {
                    ProgressView().tint(Theme.onAccent).controlSize(.large)
                } else {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36, weight: .semibold)).foregroundStyle(Theme.onAccent)
                }
            }
            .frame(width: 230, height: 230)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(engine.status == .loading)
        .accessibilityLabel(engine.isPlaying ? "Pause reading" : "Resume reading")
        .sensoryFeedback(.selection, trigger: engine.isPlaying)
    }

    private var transport: some View {
        HStack(spacing: 30) {
            control("backward.end.fill", "Previous chapter") { engine.skipChapter(-1) }
            control("gobackward.15", "Back 15 seconds") { engine.skipSeconds(-15) }
            control("arrow.uturn.backward", "Previous sentence") { engine.skipSentence(-1) }
            control("goforward.15", "Forward 15 seconds") { engine.skipSeconds(15) }
            control("forward.end.fill", "Next chapter") { engine.skipChapter(1) }
        }
        .font(.title3).foregroundStyle(Theme.ink)
        .disabled(engine.document == nil)
    }

    private func control(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 36, height: 36) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var pace: some View {
        HStack {
            Text("Pace").font(.subheadline).foregroundStyle(Theme.muted)
            Spacer()
            Picker("Pace", selection: $model.rate) {
                ForEach([0.8, 0.9, 1.0, 1.1, 1.2, 1.3], id: \.self) { Text(String(format: "%.1f×", $0)).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 280)
        }
        .card(padding: 12)
    }
}

extension ReaderEngine {
    /// The voice ring's input, as the pill's comes from the microphone: the
    /// spectrum precomputed per sentence and looked up by playback position.
    static func outputSpectrum(_ engine: ReaderEngine) -> VoiceRing.Spectrum {
        let frame = engine.playback.spectrum()
        return (frame.bands, frame.peaks, engine.playback.level())
    }
}
