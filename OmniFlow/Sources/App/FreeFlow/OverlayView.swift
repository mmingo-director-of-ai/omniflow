import SwiftUI

struct OverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @ObservedObject var model: AppModel
    var body: some View {
        GlassEffectContainer(spacing: 10) {
        VStack(spacing: 7) {
            Capsule().fill(.white.opacity(0.5)).frame(width: 30, height: 3)
                .frame(width: 80, height: 12).overlay(OmniFlowPillDragHandle())
                .help("Drag the voice pill to a highlighted edge")
            if !model.transcript.isEmpty && (model.phase == .processing || (model.phase == .recording && !model.streamingInField)) {
                LiveTranscript(text: model.transcript, font: .system(size: 13))
                    .lineLimit(3).truncationMode(.head).frame(width: 330, alignment: .leading)
                    .foregroundStyle(.white.opacity(0.92)).padding(13)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                    .environment(\.colorScheme, .dark)
            }
            if model.pendingRetry == nil && (model.phase == .recording || model.phase == .starting) {
                DictationOrb(phase: model.phase, level: model.level, locked: model.locked,
                             focusPaused: model.focusFollowsMouse ? model.pointerFocusPaused : nil,
                             spectrum: { (model.spectrum.bands, model.spectrum.peaks, Float(model.level)) },
                             actions: .init(finish: model.finish, cancel: { model.cancel() }, lock: model.lockRecording,
                                            togglePause: model.togglePointerFocusPause))
                Text(String(format: "%d:%02d", model.elapsed / 60, model.elapsed % 60))
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            } else if model.pendingRetry == nil, let kind = orbKind {
                DictationOrbStatus(kind: kind, message: orbMessage, leading: orbLeading, trailing: orbTrailing, open: openFromOrb)
            } else {
            HStack(spacing: 13) {
                if model.pendingRetry != nil {
                    Button(action: model.pastePendingRetry) {
                        Label(model.recovering ? "Pasting…" : "Paste saved text", systemImage: "arrow.uturn.right")
                            .font(.system(size: 11, weight: .medium))
                    }.disabled(model.recovering)
                    Button(action: model.dismissRetry) { Image(systemName: "xmark") }.disabled(model.recovering).help("Dismiss saved-text retry")
                } else if model.phase == .idle {
                    Button { model.onOpenHub?() } label: {
                        HStack(spacing: 10) {
                            RedPandaView(paused: true).frame(width: 24, height: 24)
                            Text("Hold fn to speak").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        }
                    }.buttonStyle(.press)
                } else if model.phase == .processing {
                    OmniFlowMascotActivity(phase: model.phase).frame(width: 32, height: 32)
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Making it flow…").font(.system(size: 12, weight: .medium))
                    Button { model.cancel() } label: { Image(systemName: "xmark").font(.system(size: 11)) }.help("Cancel processing")
                } else {
                    OmniFlowMascotActivity(phase: model.phase).frame(width: 28, height: 28)
                    Button {
                        if model.phase == .error { model.showVoiceSettings() }
                        else {
                            if model.phase == .result { model.selectedPage = "Recent" }
                            model.onOpenHub?()
                        }
                    } label: {
                        Text(model.status).font(.system(size: 11, weight: .medium)).lineLimit(2)
                            .frame(maxWidth: 260, alignment: .leading)
                    }.buttonStyle(.press)
                    if model.phase == .result {
                        OmniFlowCopyButton(help: "Copy transcript") { model.transcript }.font(.system(size: 12))
                    }
                    Button { model.cancel(message: "Ready") } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                }
                if model.focusFollowsMouse {
                    Button(action: model.togglePointerFocusPause) {
                        Image(systemName: model.pointerFocusPaused ? "cursorarrow" : "pause.fill").font(.system(size: 10))
                    }.help(model.pointerFocusPaused ? "Resume mouse-follow focus" : "Pause mouse-follow focus")
                }
            }.buttonStyle(.press).foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 17).frame(height: 46)
                .glassEffect(.regular, in: Capsule())
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            }
            if model.insertion.canRestoreClipboard {
                Button("Restore previous clipboard", action: model.insertion.restoreClipboard)
                    .font(.caption).buttonStyle(.bordered)
            }
            if model.phase == .error {
                Button("Check permissions & input", action: model.showVoiceSettings)
                    .font(.caption).buttonStyle(.bordered)
            }
            if model.phase == .recording, let issue = model.microphoneIssue {
                Text(issue).font(.system(size: 10)).lineLimit(2).frame(maxWidth: 330)
                    .padding(8).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
            }
            if model.pendingRetry != nil {
                Text(model.status).font(.system(size: 10)).lineLimit(2).frame(maxWidth: 330)
                    .padding(8).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
            }
            if model.phase == .recording || model.phase == .starting || model.phase == .processing {
                if !model.focusLabel.isEmpty {
                    Text(model.focusLabel).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.95)).padding(.horizontal, 10).padding(.vertical, 3)
                        .glassEffect(.regular, in: Capsule())
                }
            }
            if model.phase == .recording || model.phase == .starting {
                Text(model.locked ? "Hands-free · fn + space to finish · esc to cancel" : "Release to finish · fn + space to lock")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassEffect(.regular, in: Capsule())
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: model.phase)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.locked)
        }.environment(\.colorScheme, .dark)
    }
}

extension OverlayView {
    /// Every non-recording state uses the orb; only the saved-text retry keeps its capsule.
    var orbKind: DictationOrbStatus.Kind? {
        switch model.phase {
        case .idle: .idle
        case .processing: .processing
        case .result: .result
        case .error: .error
        default: nil
        }
    }

    var orbMessage: String {
        switch model.phase {
        case .idle: "Hold fn to speak"
        case .processing: "Making it flow…"
        default: model.status
        }
    }

    var orbLeading: [DictationOrbStatus.Satellite] {
        switch model.phase {
        case .processing: [.init(id: "cancel", symbol: "xmark", help: "Cancel processing") { model.cancel() }]
        case .result, .error: [.init(id: "dismiss", symbol: "xmark", help: "Dismiss") { model.cancel(message: "Ready") }]
        default: []
        }
    }

    var orbTrailing: [DictationOrbStatus.Satellite] {
        var items: [DictationOrbStatus.Satellite] = []
        switch model.phase {
        case .result:
            items.append(.init(id: "copy", symbol: "doc.on.doc", help: "Copy transcript") { _ = OmniFlowClipboard.copy(model.transcript) })
            items.append(.init(id: "history", symbol: "clock.arrow.circlepath", help: "Open in History") {
                model.selectedPage = "Recent"; model.onOpenHub?()
            })
        case .error:
            items.append(.init(id: "settings", symbol: "gearshape", help: "Check permissions & input") { model.showVoiceSettings() })
        default: break
        }
        if model.focusFollowsMouse {
            items.append(.init(id: "pause", symbol: model.pointerFocusPaused ? "cursorarrow" : "pause.fill",
                               help: model.pointerFocusPaused ? "Resume mouse-follow focus" : "Pause mouse-follow focus") {
                model.togglePointerFocusPause()
            })
        }
        return items
    }

    func openFromOrb() {
        switch model.phase {
        case .error: model.showVoiceSettings()
        case .result: model.selectedPage = "Recent"; model.onOpenHub?()
        default: model.onOpenHub?()
        }
    }
}

/// Latest band snapshot from the microphone tap, main-actor owned.
@MainActor @Observable
final class DictationSpectrumLevels {
    private(set) var bands: [Float] = []
    private(set) var peaks: [Float] = []

    func update(bands: [Float], peaks: [Float]) { self.bands = bands; self.peaks = peaks }
    func clear() { bands = []; peaks = [] }
}
