import SwiftUI
import UIKit

/// Translate typed or pasted text on this device with Apple Translation.
struct TranslateView: View {
    @EnvironmentObject private var flow: IOSFlowModel
    @State private var input = ""
    @State private var result: TranslationResult?
    @State private var working = false
    @FocusState private var editing: Bool

    private var canTranslate: Bool {
        !working && !flow.translationTargetID.isEmpty && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(sourceName).eyebrow()
                        Spacer()
                        if !input.isEmpty {
                            Button("Clear", systemImage: "xmark.circle.fill") { input = ""; result = nil }
                                .labelStyle(.iconOnly).foregroundStyle(Theme.muted)
                        }
                    }
                    TextField("Type or paste text", text: $input, axis: .vertical)
                        .font(Theme.heading(22, weight: .regular))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(3...12)
                        .focused($editing)
                    if input.isEmpty, UIPasteboard.general.hasStrings {
                        PasteButton(payloadType: String.self) { strings in input = strings.joined(separator: "\n") }
                            .buttonBorderShape(.capsule).tint(Theme.accent)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Translate to").eyebrow()
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36).background(Theme.banner, in: Circle())
                        TranslationTargetPicker(selection: $flow.translationTargetID, languages: flow.languages)
                        Spacer()
                        Button {
                            run()
                        } label: {
                            HStack(spacing: 6) {
                                if working { ProgressView().controlSize(.small).tint(.white) }
                                Text(working ? "Translating" : "Translate")
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(canTranslate || working ? Theme.accent : Theme.muted.opacity(0.4), in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(PressScale())
                        .disabled(!canTranslate)
                    }
                }
                .heroCard(padding: 14)

                if !flow.translationTargetID.isEmpty, result?.didTranslate != true {
                    TranslationSetupView(sourceIdentifier: sourceID, targetIdentifier: flow.translationTargetID)
                        .padding(.horizontal, 4)
                }

                if let result {
                    OutputCard(title: result.didTranslate ? targetName : "Not translated", text: result.text,
                               note: result.note, prominent: true) { flow.copy(result.text) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if flow.translationTargetID.isEmpty {
                    Text("Choose a language to translate into.").font(.footnote).foregroundStyle(Theme.muted).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: result?.text)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { Theme.backdrop }
        .navigationTitle("Translate")
        .onChange(of: flow.translationTargetID) { result = nil }
    }

    private var sourceID: String {
        PremiumSpeechVoices.language(of: input) ?? flow.locale.language.minimalIdentifier
    }

    private var sourceName: String {
        input.isEmpty ? "Text" : (Locale.current.localizedString(forIdentifier: sourceID) ?? "Text")
    }

    private var targetName: String {
        flow.languages.first { $0.id == flow.translationTargetID }?.name ?? "Translation"
    }

    private func run() {
        editing = false
        working = true
        let text = input, target = flow.translationTargetID
        Task {
            result = await flow.translate(text, to: target)
            working = false
        }
    }
}
