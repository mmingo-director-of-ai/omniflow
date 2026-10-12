import SwiftUI

/// Past dictations by day, newest first. Kept sealed on this iPhone for the
/// chosen retention period, with optional private iCloud sync.
struct HistoryView: View {
    @EnvironmentObject private var flow: IOSFlowModel
    @State private var search = ""

    var body: some View {
        Group {
            if flow.entries.contains(where: { !$0.displayText.isEmpty }) {
                List {
                    if search.isEmpty {
                        todayHero
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    ForEach(days, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                NavigationLink(value: entry.id) { HistoryRow(entry: entry) }
                                    .listRowBackground(Theme.surface)
                                    .swipeActions(edge: .leading) {
                                        Button("Copy", systemImage: "doc.on.doc") { flow.copy(entry.displayText, entryID: entry.id) }.tint(Theme.accent)
                                    }
                            }
                            .onDelete { offsets in flow.delete(offsets.map { group.entries[$0].id }) }
                        } header: {
                            Text(group.title).font(Theme.heading(17)).foregroundStyle(Theme.ink).textCase(nil)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .searchable(text: $search, prompt: "Search dictations")
                .overlay {
                    if days.isEmpty { ContentUnavailableView.search(text: search) }
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No dictations yet").font(Theme.heading(22))
                    } icon: {
                        RedPandaView(state: .sleeping).frame(width: 96, height: 96)
                    }
                } description: {
                    Text("What you dictate is kept here, encrypted on this iPhone, for \(flow.retention.title.lowercased()).")
                }
            }
        }
        .background { Theme.backdrop }
        .navigationTitle("History")
        .navigationDestination(for: UUID.self) { id in
            if let entry = flow.entries.first(where: { $0.id == id }) { HistoryDetail(entry: entry) }
        }
        .refreshable { await flow.reloadHistory() }
    }

    /// Today at a glance: the section's hero.
    private var todayHero: some View {
        let today = flow.entries.filter { Calendar.current.isDateInToday($0.date) && !$0.displayText.isEmpty }
        let words = today.reduce(0) { $0 + UsageMetrics.countWords($1.raw) }
        return HStack(alignment: .center, spacing: 14) {
            Image("PandaHistoryWash").resizable().scaledToFit().frame(width: 72, height: 54).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Today").eyebrow()
                Text("\(today.count) \(today.count == 1 ? "dictation" : "dictations") · \(words.formatted()) words")
                    .font(Theme.heading(20)).foregroundStyle(Theme.ink)
                Text("Kept encrypted on this iPhone for \(flow.retention.title.lowercased()).").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .heroCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var days: [(day: Date, title: String, entries: [DictationEntry])] {
        let visible = flow.entries.filter { !$0.displayText.isEmpty }
            .filter { search.isEmpty || $0.displayText.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search) }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).month().day())
            return (day, title, grouped[day]!.sorted { $0.date > $1.date })
        }
    }
}

private struct HistoryRow: View {
    let entry: DictationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.displayText).font(.body).foregroundStyle(Theme.ink).lineLimit(3)
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.hour().minute())
                if !entry.destination.isEmpty { tag(entry.destination) }
                if entry.state == .cancelled { tag("Interrupted") }
                if entry.text != entry.raw, !entry.text.isEmpty { tag("Translated") }
            }
            .font(.caption).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
    }

    private func tag(_ text: String) -> some View {
        Text(text).padding(.horizontal, 7).padding(.vertical, 2).background(Theme.banner, in: Capsule())
    }
}

private struct HistoryDetail: View {
    @EnvironmentObject private var flow: IOSFlowModel
    let entry: DictationEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.date.formatted(date: .complete, time: .shortened)).eyebrow()
                OutputCard(title: entry.text != entry.raw && !entry.text.isEmpty ? "Result" : "Transcript",
                           text: entry.displayText, note: entry.note, prominent: true,
                           edit: { flow.edit(entry.id, to: $0) }) { flow.copy(entry.displayText, entryID: entry.id) }
                if entry.text != entry.raw, !entry.raw.isEmpty, !entry.text.isEmpty {
                    OutputCard(title: "Original", text: entry.raw, note: nil) { flow.copy(entry.raw, entryID: entry.id) }
                }
            }
            .padding(20)
        }
        .background { Theme.backdrop }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
        .pushedPage()
    }
}
