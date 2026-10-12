import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// iPhone and iPad widgets. The first version reads no shared data: every
// widget and control launches an App Intent, and the Live Activity is started
// and updated by the app itself. The data widgets below need an App Group,
// which only a paid Apple team can provision on iOS (OmniFlowMobileSnapshot.swift).

@main
struct OmniFlowiOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        OmniFlowDictateWidget()
        OmniFlowTranslateWidget()
        OmniFlowNewNoteWidget()
        OmniFlowQuickActionsWidget()
        OmniFlowRecordingLiveActivity()
        OmniFlowControls().body
        #if OMNIFLOW_IOS_APP_GROUP
        OmniFlowDataWidgets().body
        #endif
    }
}

extension OmniWidgetLayout {
    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        case .accessoryCircular: self = .circular
        case .accessoryRectangular: self = .rectangular
        case .accessoryInline: self = .inline
        default: self = .small
        }
    }
}

/// Action widgets show the same thing forever, so one entry and no refresh.
struct OmniStaticProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

/// Reads the environment and hands plain values to the shared views.
private struct ActionWidgetHost<Intent: AppIntent>: View {
    let action: OmniWidgetAction<Intent>
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    var body: some View {
        OmniActionWidgetView(action: action, layout: OmniWidgetLayout(family), fullColor: renderingMode == .fullColor)
            .containerBackground(for: .widget) { OmniWidgetBackground() }
    }
}

private let actionFamilies: [WidgetFamily] = [.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline]

struct OmniFlowDictateWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OmniFlowDictateWidget", provider: OmniStaticProvider()) { _ in
            ActionWidgetHost(action: dictateAction)
        }
        .configurationDisplayName("Dictate")
        .description("Open OmniFlow straight into recording.")
        .supportedFamilies(actionFamilies)
    }
}

struct OmniFlowTranslateWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OmniFlowTranslateWidget", provider: OmniStaticProvider()) { _ in
            ActionWidgetHost(action: translateAction)
        }
        .configurationDisplayName("Translate")
        .description("Speak and read it translated, on your device.")
        .supportedFamilies(actionFamilies)
    }
}

struct OmniFlowNewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OmniFlowNewNoteWidget", provider: OmniStaticProvider()) { _ in
            ActionWidgetHost(action: newNoteAction)
        }
        .configurationDisplayName("New Note")
        .description("Start a new note and dictate into it.")
        .supportedFamilies(actionFamilies)
    }
}

struct OmniFlowQuickActionsWidget: Widget {
    private struct Host: View {
        @Environment(\.widgetFamily) private var family
        @Environment(\.widgetRenderingMode) private var renderingMode
        var body: some View {
            OmniQuickActionsView(layout: OmniWidgetLayout(family), fullColor: renderingMode == .fullColor)
                .containerBackground(for: .widget) { OmniWidgetBackground() }
        }
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OmniFlowQuickActionsWidget", provider: OmniStaticProvider()) { _ in Host() }
            .configurationDisplayName("OmniFlow")
            .description("Dictate, translate or start a note.")
            .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Live Activity

struct OmniFlowRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OmniFlowRecordingAttributes.self) { context in
            OmniRecordingLockScreenView(mode: context.attributes.mode, state: context.state)
                .activityBackgroundTint(OmniWidgetPalette.island.paper)
                .activitySystemActionForegroundColor(OmniWidgetPalette.island.accent)
        } dynamicIsland: { context in
            let mode = context.attributes.mode
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { OmniIslandExpanded.Leading(mode: mode, phase: state.phase) }
                DynamicIslandExpandedRegion(.trailing) { OmniIslandExpanded.Trailing(state: state) }
                DynamicIslandExpandedRegion(.bottom) { OmniIslandExpanded.Bottom(mode: mode, state: state) }
            } compactLeading: {
                OmniIslandCompactLeading(mode: mode, phase: state.phase)
            } compactTrailing: {
                OmniIslandCompactTrailing(state: state)
            } minimal: {
                OmniIslandMinimal(mode: mode, phase: state.phase)
            }
            .keylineTint(OmniWidgetPalette.island.accent)
        }
    }
}

// MARK: - Controls (Control Center, Lock Screen, Action button)

struct OmniFlowControls: WidgetBundle {
    var body: some Widget {
        OmniFlowDictateControl()
        OmniFlowTranslateControl()
        OmniFlowNewNoteControl()
    }
}

struct OmniFlowDictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OmniFlowDictateControl") {
            ControlWidgetButton(action: OmniFlowDictateIntent()) { Label("Dictate", image: OmniFlowSymbol.dictate) }
        }
        .displayName("Dictate")
        .description("Open OmniFlow and start dictating.")
    }
}

struct OmniFlowTranslateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OmniFlowTranslateControl") {
            ControlWidgetButton(action: OmniFlowTranslateIntent()) { Label("Translate", systemImage: "character.bubble.fill") }
        }
        .displayName("Translate")
        .description("Open OmniFlow and translate what you say.")
    }
}

struct OmniFlowNewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OmniFlowNewNoteControl") {
            ControlWidgetButton(action: OmniFlowNewNoteIntent()) { Label("New Note", systemImage: "square.and.pencil") }
        }
        .displayName("New Note")
        .description("Start a new note and dictate into it.")
    }
}

// MARK: - Data widgets (paid team only)

#if OMNIFLOW_IOS_APP_GROUP
struct OmniDataEntry: TimelineEntry {
    let date: Date
    let snapshot: OmniFlowMobileSnapshot
}

struct OmniDataProvider: TimelineProvider {
    func placeholder(in context: Context) -> OmniDataEntry { .init(date: .now, snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (OmniDataEntry) -> Void) {
        completion(.init(date: .now, snapshot: context.isPreview ? .preview : OmniFlowMobileWidgetStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OmniDataEntry>) -> Void) {
        // The app reloads timelines after each dictation; midnight resets "today".
        let midnight = Calendar.current.startOfDay(for: .now).addingTimeInterval(24 * 60 * 60 + 60)
        completion(Timeline(entries: [.init(date: .now, snapshot: OmniFlowMobileWidgetStore.read())], policy: .after(midnight)))
    }
}

struct OmniFlowDataWidgets: WidgetBundle {
    var body: some Widget {
        OmniFlowTodayWidget()
        OmniFlowRecentDictationWidget()
    }
}

struct OmniFlowTodayWidget: Widget {
    private struct Host: View {
        let entry: OmniDataEntry
        @Environment(\.widgetFamily) private var family
        @Environment(\.widgetRenderingMode) private var renderingMode
        var body: some View {
            OmniTodayStatsView(snapshot: entry.snapshot, layout: OmniWidgetLayout(family), fullColor: renderingMode == .fullColor)
                .containerBackground(for: .widget) { OmniWidgetBackground() }
        }
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniFlowMobileWidgetStore.kinds.today, provider: OmniDataProvider()) { Host(entry: $0) }
            .configurationDisplayName("Words Today")
            .description("Words dictated today and your daily streak.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct OmniFlowRecentDictationWidget: Widget {
    private struct Host: View {
        let entry: OmniDataEntry
        @Environment(\.widgetFamily) private var family
        var body: some View {
            OmniRecentDictationView(snapshot: entry.snapshot, layout: OmniWidgetLayout(family))
                .containerBackground(for: .widget) { OmniWidgetBackground() }
        }
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OmniFlowMobileWidgetStore.kinds.recent, provider: OmniDataProvider()) { Host(entry: $0) }
            .configurationDisplayName("Recent Dictation")
            .description("Your latest dictation, hidden while your device is locked.")
            .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}
#endif
