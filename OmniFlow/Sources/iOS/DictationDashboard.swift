import SwiftUI

/// The iOS landing page, after the Mac Hub: a painted welcome card with the
/// dictate action, your numbers (the same UsageMetrics the Mac shows) and your
/// latest dictations, polished and as said. It reads the live history, so it
/// updates as soon as a dictation lands.
struct DictationDashboard: View {
    @EnvironmentObject private var flow: IOSFlowModel
    let dictate: () -> Void
    #if DEBUG
    /// Screenshots: `-OmniFlowReaderDemo YES` opens the Reader and its first book in read-along.
    @State private var demoReader = false
    #endif

    private var metrics: UsageMetrics { UsageMetrics(entries: flow.entries) }
    private var recent: [DictationEntry] { Array(flow.entries.filter { !$0.displayText.isEmpty }.prefix(5)) }

    var body: some View {
        content
        #if DEBUG
            .navigationDestination(isPresented: $demoReader) { IOSReaderHome().pushedPage() }
            .task {
                guard UserDefaults.standard.bool(forKey: "OmniFlowReaderDemo") else { return }
                try? await Task.sleep(for: .milliseconds(1500))
                demoReader = true
            }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            if let message = flow.message { notice(message) }
            listenLink
            translateLink
            stats
            weekChart
            recentList
            privacy
        }
    }

    // MARK: Welcome

    private var hero: some View {
        ZStack(alignment: .bottomTrailing) {
            Image("PandaDictationWash")
                .resizable().scaledToFit()
                .frame(height: 150)
                .opacity(0.9)
                .offset(x: 28, y: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(greeting).font(.subheadline.weight(.medium)).foregroundStyle(Theme.mint)
                Text("Let your thoughts flow.").font(Theme.heading(28)).foregroundStyle(Theme.ink)
                Text("A little less typing. A lot more you.").font(.subheadline).foregroundStyle(Theme.muted)
                Button(action: dictate) {
                    Label { Text("Start dictating") } icon: { WaveformGlyph(size: 18) }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(PressScale())
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background {
            LinearGradient(colors: [Theme.heroTop, Theme.heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.heroLine, lineWidth: 0.5))
    }

    private var listenLink: some View {
        NavigationLink { IOSReaderHome().pushedPage() } label: {
            HStack(spacing: 12) {
                Image(systemName: "book").font(.title3).foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40).background(Theme.banner, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listen to a book").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Your EPUBs read aloud, from iCloud Drive or Files").font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
    }

    private var translateLink: some View {
        NavigationLink { TranslateView().pushedPage() } label: {
            HStack(spacing: 12) {
                Image(systemName: "character.bubble").font(.title3).foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40).background(Theme.banner, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate text").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Type or paste, translated on this iPhone").font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            .card(padding: 12)
        }
        .buttonStyle(.plain)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: Numbers

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            stat(metrics.words.formatted(), "words dictated", "text.word.spacing")
            stat(metrics.speakingWPM.map { "\($0)" } ?? "—", "words a minute", "speedometer")
            stat("\(metrics.streak)", metrics.streak == 1 ? "day streak" : "day streak", "flame.fill")
            stat(saved, "saved vs typing", "clock.arrow.circlepath")
        }
    }

    private var saved: String {
        guard let seconds = metrics.estimatedSavedSeconds, seconds >= 60 else { return "—" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    private func stat(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
            Text(value).font(Theme.heading(26)).foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
        .animation(.snappy, value: value)
    }

    private var weekChart: some View {
        let days = metrics.days
        let peak = max(1, days.map(\.words).max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This week").eyebrow()
                Spacer()
                Text("\(days.reduce(0) { $0 + $1.words }.formatted()) words").font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 6) {
                        Capsule()
                            .fill(Calendar.current.isDateInToday(day.date) ? Theme.accent : Theme.accent.opacity(0.45))
                            .frame(height: max(4, 64 * CGFloat(day.words) / CGFloat(peak)))
                        Text(day.date.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))): \(day.words) words")
                }
            }
            .frame(height: 84, alignment: .bottom)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: days.map(\.words))
        }
        .card()
    }

    // MARK: Recent

    @ViewBuilder private var recentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your dictations").eyebrow()
            if recent.isEmpty {
                Text("Your dictations will show up here, polished and as you said them.")
                    .font(.subheadline).foregroundStyle(Theme.muted).card()
            } else {
                ForEach(recent) { entry in RecentDictationCard(entry: entry) }
            }
        }
    }

    private var privacy: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill").foregroundStyle(Theme.accent).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your words, kept.").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("Speech, cleanup and history stay on this iPhone, encrypted. No word limits, no subscription.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        }
        .card(padding: 16)
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.footnote).foregroundStyle(Theme.ink)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.banner, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { flow.clearMessage() }
    }
}

/// One dictation: where it went and when, the polished text, the original on demand.
private struct RecentDictationCard: View {
    @EnvironmentObject private var flow: IOSFlowModel
    let entry: DictationEntry
    @State private var showsOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.date, format: .relative(presentation: .named))
                if !entry.destination.isEmpty { Text("· " + entry.destination) }
                Spacer()
                Button { flow.copy(entry.displayText, entryID: entry.id) } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy")
                    .foregroundStyle(Theme.accent)
            }
            .font(.caption).foregroundStyle(Theme.muted)
            Text(entry.displayText).font(.body).foregroundStyle(Theme.ink).lineLimit(showsOriginal ? nil : 4)
            if entry.text != entry.raw, !entry.raw.isEmpty, !entry.text.isEmpty {
                DisclosureGroup("Original transcript", isExpanded: $showsOriginal) {
                    Text(entry.raw).font(.callout).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                .font(.caption.weight(.medium)).tint(Theme.mint)
            }
        }
        .card(padding: 14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
