import SwiftUI

/// The iOS sections, in tab order. (The Assistant returns as a tab when the
/// native Atlas runtime is wired into iOS.)
enum OmniFlowSection: String, CaseIterable, Identifiable {
    case dictate, notes, assistant, history, settings, translate

    /// The tab bar (five fit on iPhone); Translate opens from the dashboard.
    static let tabs: [OmniFlowSection] = [.dictate, .notes, .assistant, .history, .settings]

    var id: Self { self }

    var title: String {
        switch self {
        case .dictate: "Home"
        case .translate: "Translate"
        case .notes: "Notes"
        case .assistant: "Assistant"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dictate: OmniFlowSymbol.dictate
        case .translate: "character.bubble"
        case .notes: "note.text"
        case .assistant: "sparkles"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// Adapts to the available width rather than the device: a tab bar when the
/// horizontal size class is compact (iPhone, narrow iPad windows, folded
/// devices) and a sidebar split view when it is regular. The selection lives
/// above the switch so resizing or rotating never resets the open section.
struct OmniFlowRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage("OmniFlow.selectedSection") private var selection: OmniFlowSection = .dictate
    #if DEBUG
    /// Screenshots: `-OmniFlowTab history` opens that section.
    private let debugTab = UserDefaults.standard.string(forKey: "OmniFlowTab").flatMap(OmniFlowSection.init(rawValue:))
    #endif

    @ObservedObject private var navigation = AppNavigation.shared

    var body: some View {
        content
            // On iPhone a Translate request (widget, shortcut) opens as a sheet over Dictation.
            .sheet(isPresented: $navigation.translatePushed) {
                NavigationStack {
                    TranslateView().toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { navigation.translatePushed = false } }
                    }
                }
            }
            .onChange(of: navigation.requested, initial: true) { _, section in
                guard let section else { return }
                if section == .translate && horizontalSizeClass == .compact {
                    selection = .dictate
                    navigation.translatePushed = true
                } else {
                    selection = section
                }
                navigation.requested = nil
            }
        #if DEBUG
            // After the split view settles, or its detail can miss the change.
            .task { if let debugTab { try? await Task.sleep(for: .milliseconds(1500)); selection = debugTab } }
        #endif
    }

    @ViewBuilder private var content: some View {
        if horizontalSizeClass == .compact {
            TabView(selection: $selection) {
                ForEach(OmniFlowSection.tabs) { section in
                    Tab(value: section) {
                        NavigationStack { OmniFlowSectionView(section: section) }
                    } label: {
                        Label(section.title, symbol: section.symbol)
                    }
                }
            }
            .edgeSwipe(selection: $selection)
            .sensoryFeedback(.selection, trigger: selection)
        } else {
            NavigationSplitView {
                List(OmniFlowSection.allCases, selection: sidebarSelection) { section in
                    Label(section.title, symbol: section.symbol).tag(section)
                }
                .navigationTitle("OmniFlow")
            } detail: {
                // A stack of its own, as each iPhone tab has: without it, pushes from the
                // detail (Listen → player → read-along, pushed pages) are silently ignored.
                NavigationStack { OmniFlowSectionView(section: selection) }.id(selection)
            }
        }
    }

    /// `List` selection is optional; a deselect keeps the current section.
    private var sidebarSelection: Binding<OmniFlowSection?> {
        Binding(get: { selection }, set: { if let section = $0 { selection = section } })
    }
}

struct OmniFlowSectionView: View {
    let section: OmniFlowSection

    var body: some View {
        switch section {
        case .dictate: DictateView()
        case .translate: TranslateView()
        case .history: HistoryView()
        case .settings: SpokenReplySettingsView()
        case .notes: NotesView()
        case .assistant: AssistantView()
        }
    }
}

/// Pages that are pushed inside a tab set this, so the left edge stays the system's back swipe.
@MainActor final class EdgeNavigation: ObservableObject {
    static let shared = EdgeNavigation()
    @Published var pushed = 0
}

extension View {
    /// Swipe in from the left or right screen edge to move to the previous or next tab.
    func edgeSwipe(selection: Binding<OmniFlowSection>) -> some View { modifier(EdgeSwipe(selection: selection)) }

    /// Marks a pushed page: edge swipes leave the left edge to the back gesture while it's shown.
    func pushedPage() -> some View {
        onAppear { EdgeNavigation.shared.pushed += 1 }.onDisappear { EdgeNavigation.shared.pushed -= 1 }
    }
}

private struct EdgeSwipe: ViewModifier {
    @Binding var selection: OmniFlowSection
    @ObservedObject private var navigation = EdgeNavigation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let edgeWidth: CGFloat = 18, distance: CGFloat = 60

    func body(content: Content) -> some View {
        content.overlay {
            HStack(spacing: 0) {
                if navigation.pushed == 0 { strip(step: -1) }
                Spacer(minLength: 0).allowsHitTesting(false)
                strip(step: 1)
            }
            .ignoresSafeArea()
        }
    }

    private func strip(step: Int) -> some View {
        Color.clear
            .frame(width: Self.edgeWidth)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                // Moving inward from the edge: rightwards on the left edge, leftwards on the right.
                guard CGFloat(-step) * drag.translation.width > Self.distance,
                      abs(drag.translation.width) > abs(drag.translation.height) else { return }
                move(step)
            })
            .accessibilityHidden(true)
    }

    private func move(_ step: Int) {
        let all = OmniFlowSection.tabs
        guard let index = all.firstIndex(of: selection) else { return }
        let next = all.index(index, offsetBy: step, limitedBy: step > 0 ? all.index(before: all.endIndex) : all.startIndex)
        guard let next, next != index else { return }
        withAnimation(reduceMotion ? nil : .snappy) { selection = all[next] }
    }
}
