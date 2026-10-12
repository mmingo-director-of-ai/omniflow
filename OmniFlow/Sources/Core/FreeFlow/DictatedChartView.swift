import Charts
import SwiftUI

struct DictatedChartView: View {
    let spec: DictatedChart
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title, !title.isEmpty { Text(title).font(.headline) }
            Chart(Array(spec.data.enumerated()), id: \.offset) { _, point in
                switch spec.type {
                case .bar:
                    BarMark(x: .value("Category", point.label), y: .value("Value", point.value))
                        .foregroundStyle(Color.accentColor)
                case .line:
                    LineMark(x: .value("Category", point.label), y: .value("Value", point.value))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Category", point.label), y: .value("Value", point.value))
                        .foregroundStyle(Color.accentColor)
                case .pie:
                    SectorMark(angle: .value("Value", point.value), innerRadius: .ratio(0.45), angularInset: 2)
                        .foregroundStyle(by: .value("Category", point.label))
                }
            }.frame(height: 220)
                .accessibilityLabel(spec.title ?? "Dictated \(spec.type.rawValue) chart")
            DisclosureGroup("Chart data") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
                    ForEach(Array(spec.data.enumerated()), id: \.offset) { _, point in
                        GridRow { Text(point.label); Text(point.value, format: .number).monospacedDigit() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.caption)
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
