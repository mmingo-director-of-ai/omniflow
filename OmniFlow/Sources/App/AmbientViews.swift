import AppKit
import SwiftUI

struct AmbientSettingsView: View {
    @ObservedObject private var monitor = AmbientMonitor.shared
    @ObservedObject private var draft = AmbientDraft.shared
    @State private var capability: AmbientCapability?
    @State private var editing: AmbientRule?
    @State private var reference: CursorReference?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ambient").font(.title3.weight(.semibold))
                        Text(monitor.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Ambient monitoring", isOn: $monitor.enabled).labelsHidden().toggleStyle(OmniFlowSwitchStyle())
                        .accessibilityLabel("Ambient monitoring")
                }
                if let capability {
                    AmbientWatchEditor(capability: capability, existing: editing, reference: reference) {
                        self.capability = nil; editing = nil; reference = nil; draft.reference = nil
                    }.id(editing?.id.uuidString ?? capability.id)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(AmbientCapability.allCases) { item in
                            Button { capability = item; editing = nil } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: item.symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(NotchLeeTheme.accent)
                                    Text(item.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                                }.frame(maxWidth: .infinity).frame(height: 70)
                                    .background(NotchLeeTheme.card, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NotchLeeTheme.border))
                            }.buttonStyle(.press).help(item.detail).accessibilityLabel("Configure \(item.title)")
                        }
                    }
                    Text("Choose an ability, set the details, then return here to add another.").font(.caption).foregroundStyle(NotchLeeTheme.sage)
                    if !monitor.rules.isEmpty {
                        Text("Your watches").font(.headline)
                        ForEach($monitor.rules) { $rule in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 10) {
                                    Image(systemName: AmbientCapability.forSource(rule.source).symbol).frame(width: 18)
                                    Toggle(rule.name, isOn: $rule.enabled)
                                    Spacer()
                                    Button("Configure") { editing = rule; capability = AmbientCapability.forSource(rule.source) }
                                    Button { monitor.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).help("Remove watch")
                                }
                                if let status = monitor.ruleStatus[rule.id], rule.enabled { Text(status).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).background(NotchLeeTheme.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    Text("Recent events").font(.headline)
                    if monitor.events.isEmpty { Text("Matching events will appear here.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(monitor.events) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(event.title).font(.headline); Spacer(); Text(event.date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                            Text(event.detail).font(.system(size: 12)).textSelection(.enabled)
                            HStack {
                                Button { monitor.feedback(event, useful: true) } label: { Label("Useful", systemImage: event.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") }
                                Button { monitor.feedback(event, useful: false) } label: { Label("Not useful", systemImage: event.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") }
                                if event.conversation != nil { Button("Follow conversation") { monitor.follow(event) } }
                            }.controlSize(.small)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(NotchLeeTheme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(16)
        }
        .onReceive(draft.$reference) { value in
            if let value { reference = value; capability = .selection; editing = nil }
        }
    }
}

private struct ConversationChoice: Identifiable, Sendable {
    let id: Int64
    let title: String
    let subtitle: String
}

private struct AmbientWatchEditor: View {
    let capability: AmbientCapability
    let existing: AmbientRule?
    let reference: CursorReference?
    let onDone: () -> Void
    @State private var rule: AmbientRule
    @State private var query = ""
    @State private var results: [ConversationChoice] = []
    @State private var searchStatus = "Type at least two characters to search recent local conversations."
    @State private var selectedTitle = ""
    @State private var searchWork: Task<Void, Never>?

    init(capability: AmbientCapability, existing: AmbientRule?, reference: CursorReference?, onDone: @escaping () -> Void) {
        self.capability = capability; self.existing = existing; self.reference = reference; self.onDone = onDone
        var initial = existing ?? AmbientRule(name: capability.title, source: capability.source)
        if let reference { initial.referenceBundle = reference.bundleID; initial.referenceWindow = reference.window; initial.name = "Watch \(reference.app)" }
        _rule = State(initialValue: initial)
    }
    private var canSave: Bool {
        if rule.source == .messages { return rule.messageConversation != nil }
        if rule.source == .selection { return rule.referenceBundle?.isEmpty == false }
        return true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onDone) { Label("Abilities", systemImage: "chevron.left") }.buttonStyle(.press)
                Spacer(); Label(capability.title, systemImage: capability.symbol).font(.headline)
            }
            Text(capability.detail).font(.caption).foregroundStyle(.secondary)
            TextField("Watch name", text: $rule.name).textFieldStyle(.roundedBorder)
            if capability == .messages || capability == .email {
                TextField(capability == .messages ? "Find a person, group or message…" : "Find a sender, subject or email…", text: $query)
                    .textFieldStyle(.roundedBorder).onChange(of: query) { _, _ in search() }
                if !selectedTitle.isEmpty || rule.messageConversation != nil || rule.conversation != nil {
                    HStack {
                        Label(selectedTitle.isEmpty ? "Selected conversation" : selectedTitle, systemImage: "checkmark.circle.fill").font(.caption)
                        Spacer()
                        Button("Clear") { rule.conversation = nil; rule.messageConversation = nil; selectedTitle = "" }
                    }
                }
                Text(searchStatus).font(.caption).foregroundStyle(.secondary)
                ForEach(results) { result in
                    Button {
                        if capability == .messages { rule.messageConversation = result.id } else { rule.conversation = result.id }
                        selectedTitle = result.title; results = []; query = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(NotchLeeTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.press)
                }
                if capability == .email {
                    TextField("Sender or address (optional)", text: $rule.sender).textFieldStyle(.roundedBorder)
                    TextField("Topic or kind of email (optional)", text: $rule.filter).textFieldStyle(.roundedBorder)
                } else { TextField("Containing these words (optional)", text: $rule.filter).textFieldStyle(.roundedBorder) }
                Text("Search stays on this Mac. Full Disk Access is needed for Apple Mail and Messages. Rich-text-only messages may not be searchable by their body.").font(.caption2).foregroundStyle(.secondary)
            } else if capability == .selection {
                Text(rule.referenceBundle.map { "App: \($0)\nWindow: \(rule.referenceWindow?.isEmpty == false ? rule.referenceWindow! : "Any foreground window")" }
                     ?? "Use Command–right-click → Watch this in another app, or choose the current app below.").font(.caption)
                Button("Use current app") {
                    guard let app = MacContext.foregroundApp, !MacScreenContext.protectedApp(app.bundleIdentifier ?? "") else { return }
                    rule.referenceBundle = app.bundleIdentifier; rule.referenceWindow = nil
                    rule.name = "Watch \(app.localizedName ?? "app")"
                }
                TextField("Notify when changed content contains (optional)", text: $rule.filter).textFieldStyle(.roundedBorder)
            } else if capability == .agents {
                Picker("Event", selection: $rule.source) {
                    Text("Finishes").tag(AmbientSource.agentFinished)
                    Text("Needs attention").tag(AmbientSource.agentAttention)
                }
                TextField("Project name (optional)", text: $rule.filter).textFieldStyle(.roundedBorder)
            } else if [.cpu, .storage, .battery].contains(capability) {
                let fallback = capability == .cpu ? 85.0 : capability == .storage ? 10.0 : 20.0
                HStack {
                    Text(capability == .cpu ? "Above" : "Below")
                    Slider(value: Binding(get: { rule.threshold ?? fallback }, set: { rule.threshold = $0 }), in: 5...95, step: 5)
                    Text("\(Int(rule.threshold ?? fallback))%").monospacedDigit().frame(width: 38)
                }
            }
            if [.memory, .updates, .security].contains(capability) { AmbientMaintenanceView(capability: capability) }
            Toggle("Speak when this happens", isOn: $rule.spoken)
            HStack {
                Spacer(); Button("Cancel", action: onDone)
                Button(existing == nil ? "Add watch" : "Save changes") {
                    rule.name = String(rule.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                    if rule.name.isEmpty { rule.name = capability.title }
                    rule.filter = String(rule.filter.prefix(500)); rule.sender = String(rule.sender.prefix(200))
                    if let index = AmbientMonitor.shared.rules.firstIndex(where: { $0.id == rule.id }) { AmbientMonitor.shared.rules[index] = rule }
                    else { AmbientMonitor.shared.rules.append(rule) }
                    AmbientMonitor.shared.enabled = true
                    onDone()
                }.buttonStyle(.borderedProminent).foregroundStyle(NotchLeeTheme.onAccent).disabled(!canSave).keyboardShortcut(.defaultAction)
            }
        }.padding(14).background(NotchLeeTheme.card, in: RoundedRectangle(cornerRadius: 12))
            .onDisappear { searchWork?.cancel() }
    }
    private func search() {
        searchWork?.cancel()
        let term = query
        results = []
        guard term.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            searchStatus = "Type at least two characters to search recent local conversations."; return
        }
        searchStatus = "Searching this Mac…"
        let mail = capability == .email
        searchWork = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let found = try await Task.detached(priority: .utility) {
                    if mail { return try MailCacheReader.search(term).map { ConversationChoice(id: $0.conversation, title: $0.subject, subtitle: "\($0.senderName.isEmpty ? $0.sender : $0.senderName) · \($0.summary.prefix(180))") } }
                    return try MessagesCacheReader.search(term).map { ConversationChoice(id: $0.conversation, title: $0.name, subtitle: $0.text.isEmpty ? $0.sender : String($0.text.prefix(180))) }
                }.value
                try Task.checkCancellation()
                results = found; searchStatus = found.isEmpty ? "No matching recent local conversations." : "Choose a conversation to follow."
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; searchStatus = error.localizedDescription }
        }
    }
}

private struct AmbientMaintenanceView: View {
    let capability: AmbientCapability
    @State private var result = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if capability == .memory {
                Text("Memory alerts use macOS pressure events. Purge clears filesystem caches; it does not free memory owned by apps. It runs only when you click below and approve the macOS administrator prompt.").font(.caption).foregroundStyle(.secondary)
                Button("Run purge…") { perform { await LocalSystemChecks.purge() } }.disabled(busy)
            } else if capability == .updates {
                Button("Read cached update status") { perform { let value = LocalSystemChecks.updates(); return value.title + "\n" + value.detail } }.disabled(busy)
            } else {
                HStack {
                    Button("Check protections now") { perform { let value = await LocalSystemChecks.security(); return value.detail } }.disabled(busy)
                    Button("Scan a folder offline…") {
                        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
                        picker.prompt = "Scan locally"
                        if picker.runModal() == .OK, let url = picker.url { perform { await LocalSystemChecks.scanFolder(url) } }
                    }.disabled(busy || LocalSystemChecks.scannerPath == nil)
                }
                Text(LocalSystemChecks.scannerPath == nil ? "No local Trivy installation found. No scanner will be installed automatically." : "Uses your existing Trivy and cached vulnerability database, with network access blocked.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView().controlSize(.small) }
            if !result.isEmpty { Text(result).font(.caption).textSelection(.enabled) }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async -> String) {
        busy = true
        Task { result = await operation(); busy = false }
    }
}
