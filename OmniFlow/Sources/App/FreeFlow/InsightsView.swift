import SwiftUI
import Charts

struct InsightsView: View {
    @ObservedObject var model: AppModel
    private func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(Int(seconds)) sec" }
        return String(format: "%.1f min", seconds / 60)
    }
    var body: some View {
        let metrics = model.metrics
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                metric("Words spoken", value: metrics.words.formatted(), icon: "text.alignleft")
                metric("Speaking speed", value: metrics.speakingWPM.map { "\($0) wpm" } ?? "—", icon: "speedometer")
                metric("Typing time saved", value: duration(metrics.estimatedSavedSeconds), icon: "hourglass")
            }
            HStack(spacing: 14) {
                metric("Completed dictations", value: metrics.dictations.formatted(), icon: OmniFlowSymbol.dictate)
                metric("Time dictating", value: duration(metrics.seconds), icon: "clock")
                metric("Day streak", value: String(metrics.streak), icon: "flame")
            }
            VStack(alignment: .leading, spacing: 20) {
                Text("Your last seven days").font(.system(size: 17, weight: .semibold))
                Chart(metrics.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.words))
                        .foregroundStyle(Color.flowAccent.gradient).cornerRadius(5)
                }.chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                    .frame(height: 220)
            }.padding(24).background(Color.flowPaper, in: RoundedRectangle(cornerRadius: 15))
            Text("Time saved is an estimate: speaking time compared with typing the same words at \(Int(model.typingWPM)) words per minute. Change the baseline in Settings. Imported transcripts without timing data count toward words, but not speed or time saved. Cancelled and failed dictations are excluded.")
                .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Color.flowMuted)
        }
    }
    private func metric(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(symbol: icon).foregroundStyle(Color.flowAccent)
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded))
            Text(label).font(.system(size: 11)).foregroundStyle(Color.flowMuted)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.flowPaper, in: RoundedRectangle(cornerRadius: 12))
    }
}
