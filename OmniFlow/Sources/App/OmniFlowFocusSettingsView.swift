import AppKit
import SwiftUI

struct OmniFlowFocusSettingsView: View {
    @ObservedObject private var controller: OmniFlowFocusController
    @ObservedObject private var settings: OmniFlowFocusSettings
    private let onOpenMonitoring: (() -> Void)?
    private let onOpenShortcuts: (() -> Void)?
    private let onOpenPointerSettings: (() -> Void)?
    @State private var excludedBundle = ""
    @State private var runningApps: [RunningApp] = []
    @State private var selectedApp = ""

    private struct RunningApp: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    init(controller: OmniFlowFocusController = .shared,
         onOpenMonitoring: (() -> Void)? = nil,
         onOpenShortcuts: (() -> Void)? = nil,
         onOpenPointerSettings: (() -> Void)? = nil) {
        self.controller = controller
        settings = controller.settings
        self.onOpenMonitoring = onOpenMonitoring
        self.onOpenShortcuts = onOpenShortcuts
        self.onOpenPointerSettings = onOpenPointerSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Focus follows mouse").font(OmniFlowBrand.heading(32))
                        .accessibilityAddTraits(.isHeader)
                    Text("Let the window under your pointer receive focus. Choose the pace, and keep certain apps out of the way.")
                        .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ownershipCard
                behaviorCard
                exclusionsCard
                relatedCard
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            controller.refreshAvailability()
            refreshRunningApps()
        }
        .onChange(of: settings.values.excludedBundleIDs) { _, _ in
            if !availableApps.contains(where: { $0.id == selectedApp }) { selectedApp = "" }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunningApps()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningApps()
        }
    }

    private var ownershipCard: some View {
        card {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: controller.isActive ? "cursorarrow.motionlines" : "cursorarrow")
                        .font(.title2).foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(statusTitle).font(.headline)
                        Text(controller.status).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if controller.isActive && !controller.lastFocusResult.isEmpty {
                            Text(controller.lastFocusResult).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Toggle(isOn: $settings.enabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use OmniFlow for pointer focus").fontWeight(.medium)
                        Text("Pauses during dictation and context capture.").font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(OmniFlowSwitchStyle())
                if settings.enabled && !controller.hasAccessibility {
                    HStack(alignment: .center, spacing: 16) {
                        Text("Accessibility lets OmniFlow focus the window you choose.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Allow Accessibility") { controller.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text("Focus changes pause automatically while you record or select context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var behaviorCard: some View {
        card {
            VStack(alignment: .leading, spacing: 20) {
                heading("Make it feel right", detail: "A short delay helps avoid switching windows as you move past them.")
                Toggle("Pause focus following", isOn: Binding(
                    get: { !settings.values.isEnabled }, set: { settings.values.isEnabled = !$0 }
                )).toggleStyle(OmniFlowSwitchStyle())
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Stepper(value: $settings.values.focusDelayMs, in: 0...1000, step: 10) {
                        HStack {
                            Text("Wait before focusing")
                            Spacer()
                            Text("\(settings.values.focusDelayMs) ms").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text("A minimum of 16 ms is applied, even when set to zero.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Toggle("Focus input fields on hover", isOn: $settings.values.focusInputOnHover)
                    .toggleStyle(OmniFlowSwitchStyle())
                Text("Hover over an editable field to focus it without clicking. Uses at least 150 ms of delay. Password fields are excluded; pauses during dictation and context capture.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Bring the focused window to the front", isOn: $settings.values.raiseWindow)
                    .toggleStyle(OmniFlowSwitchStyle())
                if settings.values.raiseWindow {
                    Stepper(value: $settings.values.raiseDelayMs, in: 0...500, step: 10) {
                        HStack {
                            Text("Wait before bringing it forward")
                            Spacer()
                            Text("\(settings.values.raiseDelayMs) ms").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var exclusionsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 20) {
                heading("Leave these apps alone", detail: "OmniFlow won't bring an excluded app into focus when your pointer passes over it.")
                if settings.values.excludedBundleIDs.isEmpty {
                    Label("No apps excluded", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 14) {
                        ForEach(Array(Set(settings.values.excludedBundleIDs)).sorted(), id: \.self) { bundle in
                            HStack(spacing: 12) {
                                applicationIcon(runningApps.first { $0.id == bundle }?.icon)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(runningApps.first { $0.id == bundle }?.name ?? bundle).fontWeight(.medium)
                                    if runningApps.contains(where: { $0.id == bundle }) {
                                        Text(bundle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button {
                                    settings.values.excludedBundleIDs.removeAll { $0 == bundle }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Remove this exclusion")
                                    .accessibilityLabel("Remove exclusion for \(bundle)")
                            }
                        }
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Picker("Running application", selection: $selectedApp) {
                        Text("Choose a running app…").tag("")
                        ForEach(availableApps) { app in
                            Label {
                                Text(app.name)
                            } icon: {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                else { Image(systemName: "app") }
                            }.tag(app.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Running application to exclude")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Add app") { addBundle(selectedApp); selectedApp = "" }
                        .disabled(selectedApp.isEmpty || !availableApps.contains { $0.id == selectedApp })
                }
                if availableApps.isEmpty {
                    Text("Open an app to add it here, or enter its bundle ID below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Add an app by bundle ID") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            TextField("com.example.app", text: $excludedBundle)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Application bundle ID")
                                .onSubmit(addTypedBundle)
                            Button("Add") { addTypedBundle() }.disabled(!validBundle)
                        }
                        Text("Useful for apps that aren't running. You can find their bundle ID in the app's Info.plist.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }
            }
        }
    }

    private var relatedCard: some View {
        card {
            VStack(alignment: .leading, spacing: 20) {
                heading("A few finishing touches", detail: "These preferences are shared with the rest of OmniFlow.")
                Toggle("Show OmniFlow in the Dock", isOn: $settings.values.showInDock).toggleStyle(OmniFlowSwitchStyle())
                Toggle("Show the shortcut guide", isOn: $settings.values.isShortcutGuideEnabled).toggleStyle(OmniFlowSwitchStyle())
                if let error = settings.storageError {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                }
                Text("The Command-hold gesture is enabled separately in Shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
                if onOpenShortcuts != nil || onOpenMonitoring != nil || onOpenPointerSettings != nil {
                    Divider()
                    HStack(spacing: 20) {
                        if let onOpenShortcuts { Button("Shortcuts", systemImage: "command", action: onOpenShortcuts) }
                        if let onOpenMonitoring { Button("Monitoring", systemImage: "chart.xyaxis.line", action: onOpenMonitoring) }
                        if let onOpenPointerSettings { Button("Cursor appearance", systemImage: "cursorarrow", action: onOpenPointerSettings) }
                    }.buttonStyle(.link)
                }
            }
        }
    }

    private var statusTitle: String {
        if !settings.enabled { return "Ready when you are" }
        if !settings.values.isEnabled { return "Focus following is paused" }
        if controller.suspensionCount > 0 { return "Paused for your current interaction" }
        if !controller.hasAccessibility { return "One permission to get started" }
        return controller.isActive ? "Focus follows your pointer" : "Focus following is unavailable"
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func applicationIcon(_ icon: NSImage?) -> some View {
        if let icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true) }
        else { Image(systemName: "app").font(.title2).foregroundStyle(.secondary).frame(width: 28, height: 28).accessibilityHidden(true) }
    }

    private var availableApps: [RunningApp] {
        runningApps.filter { !settings.values.excludedBundleIDs.contains($0.id) }
    }

    private func refreshRunningApps() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = app.bundleIdentifier, seen.insert(bundle).inserted else { return nil }
            return RunningApp(id: bundle, name: app.localizedName ?? bundle, icon: app.icon)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !availableApps.contains(where: { $0.id == selectedApp }) { selectedApp = "" }
    }

    private var validBundle: Bool {
        let value = excludedBundle.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= 255 && value.contains(".") && value.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }

    private func addTypedBundle() {
        guard validBundle else { return }
        addBundle(excludedBundle.trimmingCharacters(in: .whitespacesAndNewlines))
        excludedBundle = ""
    }

    private func addBundle(_ bundle: String) {
        guard !bundle.isEmpty, !settings.values.excludedBundleIDs.contains(bundle) else { return }
        settings.values.excludedBundleIDs.append(bundle)
    }
}
