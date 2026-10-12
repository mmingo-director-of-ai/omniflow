import AppKit
import SwiftUI
import EventKit

/// Music, Weather and News pages of the island carousel. Each does work only
/// while `active` (the visible page): the Now Playing bridge runs, feeds are
/// fetched and weather is requested only then.
struct NotchLeeMediaPanel: View {
    let panel: NotchLeePanel
    let active: Bool

    var body: some View {
        ZStack {
            CardBackground(wash: .soft)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: panel.symbol).font(.system(size: 10, weight: .semibold))
                    Text(panel.title).font(.system(size: 10, weight: .semibold)).tracking(0.8).textCase(.uppercase)
                    Spacer(minLength: 4)
                }
                .foregroundColor(Color(hex: "#9EA4AE"))
                Group {
                    switch panel {
                    case .music: NotchLeeMusicPanel(active: active)
                    case .weather: NotchLeeWeatherPanel(active: active)
                    default: NotchLeeNewsPanel(active: active)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(.leading, 118).padding(.trailing, 14).padding(.vertical, 8)
        }
    }
}

private struct NotchLeeMusicPanel: View {
    let active: Bool
    @ObservedObject private var player = NowPlayingService.shared
    @State private var holding = false

    var body: some View {
        Group {
            if player.unavailable {
                message("Now Playing is unavailable on this version of macOS.")
            } else if let track = player.track {
                HStack(spacing: 12) {
                    artwork
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundColor(Color(hex: "#9398A1")).lineLimit(1)
                        progress(track)
                    }
                    controls(track)
                }
            } else {
                // Controls stay available with nothing playing: Play resumes the last
                // player, or opens Music and starts it.
                HStack(spacing: 12) {
                    artwork
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing playing").font(.system(size: 13, weight: .semibold))
                        Text("Play resumes your last player or opens Music.")
                            .font(.system(size: 10.5)).foregroundColor(Color(hex: "#9398A1")).lineLimit(1)
                    }
                    idleControls
                }
            }
        }
        .onAppear { hold(active) }
        .onChange(of: active) { _, value in hold(value) }
        .onDisappear { hold(false) }
    }

    private func hold(_ value: Bool) {
        guard value != holding else { return }
        holding = value
        value ? player.acquire() : player.release()
    }

    @ViewBuilder private var artwork: some View {
        Group {
            if let image = player.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 22)).foregroundColor(Color(hex: "#9398A1"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.06))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    /// The system animates timer-interval progress; OmniFlow runs no timer for it.
    @ViewBuilder private func progress(_ track: NowPlayingService.Track) -> some View {
        if let duration = track.duration, duration > 0, let position = track.position() {
            if track.isPlaying {
                let start = Date.now.addingTimeInterval(-position / max(track.rate, 0.01))
                ProgressView(timerInterval: start...start.addingTimeInterval(duration / max(track.rate, 0.01)), countsDown: false) {
                    EmptyView()
                } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear).tint(NotchLeeTheme.accent).labelsHidden()
            } else {
                ProgressView(value: position, total: duration).progressViewStyle(.linear).tint(NotchLeeTheme.accent.opacity(0.6))
            }
        }
    }

    private func controls(_ track: NowPlayingService.Track) -> some View {
        HStack(spacing: 10) {
            Button { player.send(.previous) } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous track")
            Button { player.send(.toggle) } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(track.isPlaying ? "Pause" : "Play")
            Button { player.send(.next) } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next track")
        }
        .buttonStyle(.press)
        .font(.system(size: 13))
        .foregroundColor(.white)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1"))
    }

    private var idleControls: some View {
        HStack(spacing: 10) {
            Button { player.send(.previous) } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous track")
            Button { player.playOrOpenMusic() } label: { Image(systemName: "play.fill").font(.system(size: 16)) }
                .accessibilityLabel("Play")
            Button { player.send(.next) } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next track")
        }
        .buttonStyle(.press)
        .font(.system(size: 13))
        .foregroundColor(.white)
    }
}

private struct NotchLeeWeatherPanel: View {
    let active: Bool
    @ObservedObject private var weather = IslandWeatherService.shared

    var body: some View {
        Group {
            switch weather.status {
            case .ready(let now):
                HStack(spacing: 14) {
                    Image(systemName: now.symbol).symbolRenderingMode(.multicolor).font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(now.temperature.formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0)))))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text(now.summary).font(.system(size: 10.5)).foregroundColor(Color(hex: "#9398A1")).lineLimit(1)
                    }
                    if let high = now.high, let low = now.low {
                        Text("H \(high.formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0)))))  L \(low.formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0)))))")
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1"))
                    }
                    Spacer(minLength: 0)
                    if let attribution = weather.attribution {
                        Link(destination: attribution.legal) { Text(" Weather").font(.system(size: 9)) }
                            .foregroundColor(Color(hex: "#9398A1"))
                            .accessibilityLabel("Apple Weather data sources")
                    }
                }
            case .needsSetup(let text), .failed(let text):
                Text(text).font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1")).lineLimit(3)
            case .locating:
                Text("Finding your location… If macOS asks, allow Location for OmniFlow.")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1")).lineLimit(2)
            case .idle, .loading:
                Text("Getting the weather…").font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1"))
            }
        }
        .onAppear { if active { weather.refreshIfStale() } }
        .onChange(of: active) { _, value in if value { weather.refreshIfStale() } }
    }
}

private struct NotchLeeNewsPanel: View {
    let active: Bool
    @ObservedObject private var news = NewsFeedService.shared

    var body: some View {
        Group {
            if news.feeds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add the news feeds you want in Settings.").font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1"))
                    Button("Open Settings") { IslandWorkspace.shared.show(.settings) }.buttonStyle(.press).font(.system(size: 11, weight: .semibold))
                }
            } else if news.headlines.isEmpty {
                Text(news.failure ?? "Loading headlines…").font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1"))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let digest = news.digest {
                        Text(digest).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    ForEach(news.headlines.prefix(news.digest == nil ? 3 : 2)) { headline in
                        Button {
                            if let link = headline.link { NSWorkspace.shared.open(link) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(headline.title).font(.system(size: 11)).lineLimit(1)
                                Text(headline.source).font(.system(size: 9.5)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                            }
                        }
                        .buttonStyle(.press)
                        .disabled(headline.link == nil)
                        .help(headline.title)
                    }
                }
            }
        }
        .onAppear { if active { news.refreshIfStale() } }
        .onChange(of: active) { _, value in if value { news.refreshIfStale() } }
    }
}

/// A compact, user-selected home card. Calendar access is requested only by its button.
struct NotchLeeHomePanel: View {
    let active: Bool
    @AppStorage("omniflow.home.clock") private var clock = true
    @AppStorage("omniflow.home.widget") private var widget = "calendar"
    @AppStorage("omniflow.home.24hour") private var militaryTime = false
    @StateObject private var agenda = IslandAgenda()
    @ObservedObject private var privacy = OmniFlowAppLock.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Your day", systemImage: "house").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Toggle("Show clock", isOn: $clock)
                    Toggle("24-hour clock", isOn: $militaryTime)
                    Picker("Home widget", selection: $widget) {
                        Text("Calendar").tag("calendar")
                        Text("Weather").tag("weather")
                        Text("Quick actions").tag("actions")
                    }
                } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize().help("Customize home")
            }
            HStack(alignment: .center, spacing: 18) {
                if clock {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(time(timeline.date)).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                            Text(timeline.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                Group {
                    if widget == "weather" { NotchLeeWeatherPanel(active: active) }
                    else if widget == "actions" {
                        HStack {
                            Button("Chat", systemImage: "bubble.left.and.bubble.right") { IslandWorkspace.shared.show(.assistant) }
                            Button("Dictate", systemImage: "mic") { IslandWorkspace.shared.show(.dictation) }
                        }.controlSize(.small)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            if privacy.isLocked {
                                Label("Unlock to see your agenda", systemImage: "lock").font(.caption)
                            } else {
                                Text(agenda.summary).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                if !agenda.authorized {
                                    Button("Connect calendar") { agenda.connect() }.controlSize(.small)
                                } else { Text(agenda.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }.padding(.leading, 118).padding(.trailing, 16).padding(.vertical, 10)
        .background(CardBackground(wash: .soft))
        .task(id: active && widget == "calendar" && !privacy.isLocked) {
            guard active, widget == "calendar", !privacy.isLocked else { return }
            repeat {
                agenda.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        if militaryTime { formatter.dateFormat = "HH:mm" }
        else { formatter.timeStyle = .short }
        return formatter.string(from: date)
    }
}

@MainActor
private final class IslandAgenda: ObservableObject {
    @Published private(set) var summary = "Your upcoming events"
    @Published private(set) var detail = ""
    @Published private(set) var authorized = false
    private let store = EKEventStore()
    private var requesting = false

    func connect() {
        guard !requesting else { return }
        requesting = true
        Task {
            defer { requesting = false }
            do {
                if try await store.requestFullAccessToEvents() { refresh() }
                else { summary = "Calendar access is off. Allow it in System Settings." }
            } catch { summary = "Calendar unavailable: " + error.localizedDescription }
        }
    }

    func refresh() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard authorized else { summary = "Your upcoming events"; detail = ""; return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
        guard let event = events.first else { summary = "No events in the next 24 hours"; detail = "Your time is yours."; return }
        summary = event.title ?? "Untitled event"
        detail = event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened)
    }
}
