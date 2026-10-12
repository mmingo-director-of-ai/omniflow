import SwiftUI
import AppKit

extension Color {
    static let flowInk = OmniFlowBrand.adaptive("flowInkLight", "flowInkDark", lightFallback: "#1F1F1F", darkFallback: "#E8E8E8")
    static let flowPaper = OmniFlowBrand.adaptive("flowPaperLight", "flowPaperDark", lightFallback: "#F5F5F5", darkFallback: "#16181B")
    static let flowSurface = OmniFlowBrand.adaptive("flowSurfaceLight", "flowSurfaceDark", lightFallback: "#FFFFFF", darkFallback: "#1D2024")
    static let flowBanner = OmniFlowBrand.adaptive("flowBannerLight", "flowBannerDark", lightFallback: "#EBF2ED", darkFallback: "#1B2E2E")
    static let flowAccent = OmniFlowBrand.adaptive("flowAccentLight", "flowAccentDark", lightFallback: "#1F7A70", darkFallback: "#70D9B8")
    static let flowMuted = OmniFlowBrand.adaptive("flowMutedLight", "flowMutedDark", lightFallback: "#787878", darkFallback: "#9C9C9C")
    static let flowPanel = Color(red: 0.075, green: 0.10, blue: 0.12)
}

struct FlowButton: ButtonStyle {
    var primary = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(primary ? Color.flowPaper : Color.flowInk)
            .background(primary ? Color.flowInk : Color.flowInk.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct HubView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @FocusState private var focusedSidebarPage: String?
    @ObservedObject var model: AppModel
    @State private var editingEntry: DictationEntry?
    private let companionPages: [WorkspaceSection] = [.assistant, .reader, .sessions, .system, .focus, .shortcuts, .ambient, .memory, .connections]
    private var matchingEntries: [DictationEntry] {
        guard !model.historySearch.isEmpty else { return model.entries }
        return model.entries.filter { $0.raw.localizedCaseInsensitiveContains(model.historySearch) || $0.text.localizedCaseInsensitiveContains(model.historySearch) || $0.destination.localizedCaseInsensitiveContains(model.historySearch) }
    }
    var body: some View {
        content.sheet(item: $editingEntry) { entry in
            TranscriptEditSheet(entry: entry) { model.editEntry(entry, text: $0) }
        }
    }
    private var content: some View {
        HStack(spacing: 10) {
            if model.sidebarVisible {
                sidebar
                    .modifier(OmniFlowNavigationGlass())
                    .padding(.leading, 10).padding(.vertical, 9)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            OmniFlowLockGate {
            VStack(alignment: .leading, spacing: 0) {
                if WorkspaceSection(rawValue: model.selectedPage) == nil || model.selectedPage == "Settings" {
                    pageHeader.id(model.selectedPage).transition(.opacity).padding(.horizontal, 28).padding(.vertical, 22)
                }
                if model.selectedPage == "Settings" {
                    FlowSettingsView(model: model).padding(.horizontal, 20).padding(.bottom, 12)
                } else if model.selectedPage == "Actions" {
                    SelectionActionsView(service: model.selectionActions)
                } else if model.selectedPage == "Notes" {
                    NotesPageView(model: model)
                } else if model.selectedPage == "Conversations" {
                    TranscriptListView()
                } else if let section = WorkspaceSection(rawValue: model.selectedPage) {
                    WorkspaceSectionContent(section: section)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if !model.historyError.isEmpty {
                                Label(model.historyError, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            switch model.selectedPage {
                            case "Recent": recent
                            case "Dictionary": dictionary
                            case "Insights": InsightsView(model: model)
                            default: home
                            }
                        }.padding(.horizontal, 32).padding(.bottom, 32)
                    }.id(model.selectedPage)
                }
            }
            }
            .scrollContentBackground(.hidden)
            .background {
                // One painting per page: pages whose header already carries artwork get no backdrop.
                if !Self.pagesWithHeaderArtwork.contains(model.selectedPage) {
                    OmniFlowPageBackdrop(page: model.selectedPage, settingsTab: model.settingsTab)
                }
            }
            .background(Color.flowSurface)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.flowInk.opacity(0.08)).allowsHitTesting(false))
            .padding(.top, 4).padding(.bottom, 9).padding(.trailing, 9)
            .padding(.leading, model.sidebarVisible ? 0 : 9)
        }
        .frame(minWidth: 1040, minHeight: 720)
        .foregroundStyle(Color.flowInk)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: model.sidebarVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.selectedPage)
        .onChange(of: model.selectedPage) { _, page in
            if focusedSidebarPage != page { focusedSidebarPage = nil }
        }
    }
    private static let pagesWithHeaderArtwork: Set<String> = ["Home", "Recent", WorkspaceSection.system.rawValue]
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                RedPandaView(paused: true).frame(width: 34, height: 34)
                Text("OmniFlow").font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-1)
            }.padding(.horizontal, 9).padding(.top, 22).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            ForEach([("Home", "Dictation", OmniFlowSymbol.dictate), ("Notes", "Notes", "note.text"), ("Recent", "History", "clock.arrow.circlepath"), ("Insights", "Insights", "chart.bar"), ("Dictionary", "Dictionary", "text.book.closed"), ("Actions", "Text actions", "text.badge.star")], id: \.0) { page, name, icon in
                navigation(page, name: name, icon: icon)
            }
                    Divider().opacity(0.4).padding(.vertical, 12)
                    Text("COMPANION").font(.system(size: 8, weight: .semibold)).tracking(1.1)
                        .foregroundStyle(Color.flowMuted).padding(.horizontal, 12).padding(.bottom, 8)
                    ForEach(companionPages) { page in navigation(page.rawValue, name: page.rawValue, icon: page.symbol) }
                    navigation("Conversations", name: "Conversations", icon: "bubble.left.and.bubble.right")
                }
            }.scrollIndicators(.hidden)
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("Room to keep going.", systemImage: "infinity").font(.system(size: 12, weight: .semibold))
                Text("No word limits. No subscription.\nJust you and your Mac.")
                    .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Color.flowMuted)
                HStack(spacing: 5) {
                    Circle().fill(Color.green.opacity(0.75)).frame(width: 5, height: 5)
                    Text("ON-DEVICE VOICE").font(.system(size: 8, weight: .semibold)).tracking(1.1)
                }.padding(.top, 3)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.flowSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.flowInk.opacity(0.07)).allowsHitTesting(false))
                .padding(.bottom, 18)
            quickActions.padding(.bottom, 12)
            Divider().opacity(0.4).padding(.bottom, 10)
            Button(action: model.revealHistory) {
                Label("Open history folder", systemImage: "folder").font(.system(size: 12)).foregroundStyle(Color.flowMuted)
                    .padding(.horizontal, 12).padding(.vertical, 11)
            }.buttonStyle(.press)
            Text("OMNIFLOW  /  " + OmniFlowBuildStamp.current.short.uppercased()).font(.system(size: 8, weight: .medium)).tracking(1.3)
                .foregroundStyle(Color.flowMuted.opacity(0.65)).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 20)
        }.padding(.horizontal, 12).frame(width: 216)
    }
    /// Settings, Home and appearance, one tap each, under the sidebar card.
    private var quickActions: some View {
        HStack(spacing: 8) {
            quickAction("gearshape", help: "Settings", selected: model.selectedPage == "Settings") { model.onOpenSettings?() }
            quickAction("house", help: "Home", selected: model.selectedPage == "Home") {
                model.selectedPage = "Home"; IslandWorkspace.shared.section = .dictation
            }
            quickAction(isDark ? "sun.max" : "moon", help: isDark ? "Switch to light mode" : "Switch to dark mode", selected: false) {
                model.appearance = isDark ? "light" : "dark"
            }
        }
        .frame(maxWidth: .infinity)
    }
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { model.appearance == "system" ? colorScheme == .dark : model.appearance == "dark" }
    private func quickAction(_ icon: String, help: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(symbol: icon).font(.system(size: 15, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(selected ? Color.flowAccent.opacity(0.16) : Color.flowInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? Color.flowAccent : Color.flowInk)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.press)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func navigation(_ page: String, name: String, icon: String) -> some View {
        Button {
            if page == "Settings" { model.onOpenSettings?() } else {
                model.selectedPage = page
                if let section = companionPages.first(where: { $0.rawValue == page }) { IslandWorkspace.shared.section = section }
                else if page == "Home" { IslandWorkspace.shared.section = .dictation }
            }
        } label: {
            HStack(spacing: 11) {
                Image(symbol: icon).font(.system(size: 16)).frame(width: 20)
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(model.selectedPage == page ? Color.flowInk.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    if focusedSidebarPage == page {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(Color.flowAccent.opacity(0.5), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
        }.buttonStyle(.press)
            .focused($focusedSidebarPage, equals: page)
            .focusEffectDisabled()
            .accessibilityAddTraits(model.selectedPage == page ? .isSelected : [])
            .padding(.bottom, 4)
    }
    private var home: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 25) {
                    welcomeBanner
                    if !model.canRecord || !model.hotkeyReady { setupCard }
                    if model.busy || !model.transcript.isEmpty { liveCard }
                    else if model.status != "Your voice. A little more free." && model.status != "Ready" {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.status).font(.system(size: 12)).foregroundStyle(Color.flowMuted)
                            if model.phase == .error || model.microphoneIssue != nil {
                                HStack {
                                    Button("Check permissions & input", action: model.showVoiceSettings)
                                    Button("Open Sound input", action: model.openSoundInput)
                                }.buttonStyle(FlowButton(primary: false))
                            }
                        }
                    }
                    historyFeed(limit: 12)
                }.frame(maxWidth: .infinity, alignment: .leading)
                statsRail.frame(width: 185)
            }
        }
    }
    private var welcomeBanner: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Let your thoughts flow.").font(.system(size: 26, design: .serif)).tracking(-0.8)
                    Text("A little less typing. A lot more you.").font(.system(size: 12)).foregroundStyle(Color.flowMuted)
                }
                Spacer(minLength: 8)
                Color.clear.frame(width: 85, height: 60).accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Text("fn").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.flowSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                Text("hold to speak").font(.system(size: 11))
                Text("·").foregroundStyle(Color.flowMuted)
                Text("fn + space").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.flowSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                Text("lock").font(.system(size: 11))
            }.padding(.top, 5)
            Button(model.canRecord ? "Try a dictation" : "Set up OmniFlow") {
                if model.canRecord { model.begin(practice: true) } else { model.selectedPage = "Settings" }
            }.buttonStyle(FlowButton(primary: false)).disabled(model.busy)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(OmniFlowWatercolor(artwork: .dictation))
            .background(Color.flowBanner, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private var statsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.date, format: .dateTime.hour().minute()).font(.system(size: 30, design: .serif)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 11)).foregroundStyle(Color.flowMuted)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.words.formatted()).font(.system(size: 25, design: .serif))
                    Text("total words").font(.system(size: 11))
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.metrics.speakingWPM.map(String.init) ?? "—").font(.system(size: 25, design: .serif))
                    Text("words / min").font(.system(size: 11))
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.sessions.formatted()).font(.system(size: 25, design: .serif))
                    Text("dictations").font(.system(size: 11))
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.entries.count.formatted()).font(.system(size: 25, design: .serif))
                    Text("saved locally").font(.system(size: 11))
                }
            }.padding(20)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 10) {
                Label("Unlimited words", systemImage: "infinity").font(.system(size: 12, weight: .semibold))
                Text("No weekly caps. Your Mac does the work.").font(.system(size: 11)).lineSpacing(4).foregroundStyle(Color.flowMuted)
                Text("Always free to flow.").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }.padding(20)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 10) {
                Label("Your words, kept.", systemImage: "internaldrive").font(.system(size: 12, weight: .semibold))
                Text(model.saveHistory ? "Original and polished transcripts are saved on this Mac, ready when you need them." : "History is off. Copy your current transcript before starting again or closing OmniFlow.")
                    .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Color.flowMuted)
                Button("View history") { model.selectedPage = "Recent" }.buttonStyle(FlowButton(primary: false))
            }.padding(20)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.flowPaper.opacity(0.75), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.flowInk.opacity(0.08)).allowsHitTesting(false))
    }
    private func historyFeed(limit: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("YOUR DICTATIONS").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(Color.flowMuted)
                Spacer()
                if limit != nil { Button("View all") { model.selectedPage = "Recent" }.buttonStyle(.press).font(.system(size: 10)).foregroundStyle(Color.flowMuted) }
            }
            if matchingEntries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "quote.bubble").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(Color.flowMuted)
                    Text(model.historySearch.isEmpty ? "Your next thought starts here." : "No matching dictations.").font(.system(size: 21, design: .serif))
                    Text(model.saveHistory ? "Click a text field, hold fn, and speak. Your transcript will be saved here automatically." : "History is off. Your current dictation stays available for review until you start again or close OmniFlow.")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Color.flowMuted)
                }.padding(25).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.flowInk.opacity(0.1)).allowsHitTesting(false))
            } else {
                ForEach(dictationDays(limit: limit), id: \.date) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(day.date, format: .dateTime.weekday(.wide).month(.wide).day().year())
                            .font(.headline).padding(.top, 8)
                        ForEach(day.entries) { entry in transcriptRow(entry) }
                    }
                }
            }
        }
    }
    private func dictationDays(limit: Int?) -> [DictationDay] {
        DictationDay.group(Array(matchingEntries.prefix(limit ?? matchingEntries.count)))
    }

    private func transcriptRow(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·"); Text(entry.destination)
                Spacer()
                if entry.unfinished && !model.busy { Label("Recovered", systemImage: "arrow.counterclockwise").foregroundStyle(Color.flowAccent) }
            }.font(.system(size: 10)).foregroundStyle(Color.flowMuted)
            MarkdownView(source: entry.displayText)
            HStack {
                Text(entry.unfinished && !model.busy ? "Recovered from an unfinished dictation. Check the destination before copying again." : entry.note)
                    .font(.system(size: 10)).foregroundStyle(Color.flowMuted)
                Spacer(minLength: 12)
                OmniFlowCopyButton(help: "Copy transcript") { entry.displayText }
                Menu {
                    Button("Prepare to paste again…") { model.prepareRetry(entry) }.disabled(model.busy || model.managingHistory)
                    Button("Edit transcript…") { editingEntry = entry }.disabled(model.busy || model.managingHistory)
                    Button("Copy original") { model.copy(entry.raw) }
                    Button("Move to Trash…", role: .destructive) { model.deleteEntry(entry) }.disabled(model.busy || model.managingHistory)
                    Button("Open history folder", action: model.revealHistory) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
            }
            if entry.raw != entry.text && !entry.text.isEmpty {
                DisclosureGroup("Original transcript") { Text(entry.raw).font(.system(size: 12)).textSelection(.enabled).padding(.top, 6) }.font(.system(size: 10)).foregroundStyle(Color.flowMuted)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.flowPaper.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.flowInk.opacity(0.08)).allowsHitTesting(false))
    }
    private func shortcutCard(key: String, title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(key).font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.flowInk.opacity(0.12)).allowsHitTesting(false))
                Spacer(); Image(symbol: icon).font(.system(size: 17)).foregroundStyle(Color.flowMuted)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.flowMuted)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.flowInk.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Image(symbol: icon).foregroundStyle(Color.flowMuted); Spacer() }
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded))
            Text(label).font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundStyle(Color.flowMuted)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.flowInk.opacity(0.10)).allowsHitTesting(false))
    }
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Make yourself at home.").font(.system(size: 18, weight: .medium, design: .serif))
                Spacer()
                Text("ONE-TIME SETUP").font(.system(size: 8, weight: .semibold)).tracking(1.3).foregroundStyle(Color.flowMuted)
            }
            setupRow("Microphone", detail: model.microphonePermission.guidance, ready: model.micReady,
                     button: model.microphonePermission.actionTitle, action: model.requestMicrophone)
            Divider().opacity(0.4)
            setupRow("Accessibility", detail: model.accessibilityReady && !model.hotkeyReady ? "Enable keyboard monitoring, then relaunch OmniFlow." : "For the fn shortcut and text insertion.", ready: model.hotkeyReady, button: "Enable", action: model.requestAccessibility)
            Divider().opacity(0.4)
            setupRow("Speech model", detail: model.speechStatus, ready: model.speechReady, button: model.preparing ? "Preparing…" : "Prepare") { model.checkSpeech(download: true) }
            Text("In Keyboard Settings, set “Press 🌐 key to” to “Do Nothing” and disable the built-in double-Fn Dictation shortcut. OmniFlow won’t change these settings for you.")
                .font(.system(size: 11)).foregroundStyle(Color.flowMuted).fixedSize(horizontal: false, vertical: true)
            Button("Open Keyboard Settings ↗", action: model.openKeyboard).buttonStyle(.press).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.flowAccent)
        }.padding(22).background(Color.flowSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }
    private func setupRow(_ title: String, detail: String, ready: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.flowMuted.opacity(0.5)).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.flowMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if ready { Text("Ready").font(.system(size: 11)).foregroundStyle(Color.flowMuted) }
            else { Button(button, action: action).buttonStyle(FlowButton(primary: false)).disabled(model.preparing && title == "Speech model") }
        }
    }
    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OmniFlowMascotActivity(phase: model.phase, level: model.level).frame(width: 42, height: 42)
                Text(model.status).font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.phase == .recording { Button("Finish", action: model.finish).buttonStyle(FlowButton()) }
                if model.busy { Button("Cancel") { model.cancel() }.buttonStyle(.press) }
            }
            Text(model.transcript.isEmpty ? "Your words will appear here…" : model.transcript)
                .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
            if model.insertion.canRestoreClipboard {
                Button("Restore previous clipboard", action: model.insertion.restoreClipboard).buttonStyle(FlowButton(primary: false))
            }
            if !model.busy && !model.transcript.isEmpty {
                OmniFlowCopyButton("Copy transcript", help: "Copy transcript", style: FlowButton(primary: false)) { model.transcript }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.flowSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
    private var recent: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.flowMuted)
                    TextField("Search your dictations", text: $model.historySearch).textFieldStyle(.plain)
                }.padding(12).background(Color.flowPaper, in: RoundedRectangle(cornerRadius: 9))
                Button("Open folder", action: model.revealHistory).buttonStyle(FlowButton(primary: false))
                Button("Export…", action: model.exportHistory).buttonStyle(FlowButton(primary: false)).disabled(model.entries.isEmpty)
                Button("Clear history…", action: model.clearHistory).buttonStyle(FlowButton(primary: false)).disabled(model.busy || model.entries.isEmpty)
            }
            historyFeed()
        }
    }
    private var dictionary: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Give local cleanup a little spelling guidance. Add one word or phrase per line. This does not retrain Apple’s speech model.")
                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(Color.flowMuted)
            TextEditor(text: $model.vocabulary).font(.system(size: 15)).scrollContentBackground(.hidden)
                .padding(16).frame(height: 270).background(Color.flowSurface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.flowInk.opacity(0.10)).allowsHitTesting(false))
            Toggle(isOn: $model.securityVocabulary) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(VocabularyPack.security.title).font(.system(size: 13, weight: .medium))
                    Text(VocabularyPack.security.terms.prefix(8).joined(separator: ", ") + "…").font(.system(size: 11)).foregroundStyle(Color.flowMuted)
                }
            }.toggleStyle(OmniFlowSwitchStyle())
            HStack { Image(systemName: "internaldrive"); Text("Saved only on this Mac. Used when cleanup is on.") }
                .font(.system(size: 11)).foregroundStyle(Color.flowMuted)
            LearnedRulesView(learning: model.learning).padding(.top, 8)
        }
    }
    @ViewBuilder private var pageHeader: some View {
        switch model.selectedPage {
        case "Actions": pageTitle("Give your words another pass.", subtitle: "Clean up, translate or restyle selected text on your Mac.")
        case "Recent":
            pageTitle("A history of your thoughts.", subtitle: model.saveHistory ? "Originals and polished words. Saved on your Mac, even when things go wrong." : "History is off. Existing saved dictations remain until you delete them.")
                .padding(.trailing, 120).frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                .background(OmniFlowWatercolor(artwork: .history))
        case "Notes": pageTitle("Think out loud.", subtitle: "Dictated notes, polished as you go. Encrypted on your Mac.")
        case "Dictionary": pageTitle("Your kind of language.", subtitle: "Names, projects, and the words you use every day.")
        case "Settings": pageTitle("Find your flow.", subtitle: "Your preferences, all in one place.")
        case "Insights": pageTitle("A little more time for you.", subtitle: "Your dictation habits, measured locally. No cloud analytics or team tracking.")
        default:
            Text("Welcome back, \(NSFullUserName().split(separator: " ").first.map(String.init) ?? "friend")")
                .font(.system(size: 23, weight: .semibold)).tracking(-0.5)
        }
    }
    private func pageTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 37, weight: .regular, design: .serif)).tracking(-1)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.flowMuted)
        }
    }
}
