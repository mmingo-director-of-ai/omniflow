import AppIntents
import SwiftUI
import WidgetKit

// Control Center and menu bar controls. Actions run in the OmniFlow app;
// current values come from the snapshot the app publishes.

struct OmniFlowDictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OmniFlowDictateControl") {
            ControlWidgetButton(action: WidgetStartDictationIntent()) {
                Label("Dictate", image: OmniFlowSymbol.dictate)
            }
        }
        .displayName("Dictate")
        .description("Start hands-free dictation in OmniFlow.")
    }
}

struct OmniFlowAskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OmniFlowAskControl") {
            ControlWidgetButton(action: WidgetAskOmniFlowIntent()) {
                Label("Ask Omni", systemImage: "bubble.left.fill")
            }
        }
        .displayName("Ask Omni")
        .description("Open OmniFlow's on-device assistant.")
    }
}

struct OmniFlowFocusControl: ControlWidget {
    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool { OmniFlowWidgetStore.read().focusFollowsMouse }
    }

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OmniFlowFocusControl", provider: Provider()) { isOn in
            ControlWidgetToggle("Focus Follows Mouse", isOn: isOn, action: WidgetSetFocusIntent()) { on in
                Label(on ? "On" : "Off", systemImage: on ? "cursorarrow.motionlines" : "cursorarrow")
            }
        }
        .displayName("Focus Follows Mouse")
        .description("Let the window under your pointer take focus.")
    }
}

struct OmniFlowAgentsControl: ControlWidget {
    struct Provider: ControlValueProvider {
        var previewValue: String { "2 running" }
        func currentValue() async throws -> String {
            guard let agents = OmniFlowWidgetStore.read().agents else { return "Open OmniFlow" }
            let running = agents.sessions.filter { $0.state == "running" }.count
            return running == 0 ? "\(agents.sessions.count) idle" : "\(running) running"
        }
    }

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OmniFlowAgentsControl", provider: Provider()) { status in
            ControlWidgetButton(action: WidgetOpenMonitoringIntent()) {
                Label(status, systemImage: "terminal")
            }
        }
        .displayName("Agent Status")
        .description("See how many coding agents are working, and open monitoring.")
    }
}
