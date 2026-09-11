import SwiftUI
import Charts
import StrandDesign

// MARK: - Weekly eaten-vs-burned chart
//
// Two independently-tinted lines over a week. No existing StrandDesign chart fits: `TrendChart`
// plots one metric's value (its `segment` field only splits a line for continuity, e.g. across an
// incompatible VO2max estimator change — not two differently-tinted series with a legend), and
// `Sparkline` takes a single `[Double]`. So this is a small, purpose-built Swift Charts view
// rather than a new shared primitive — scoped to Food per the ground rules (other tasks are
// editing StrandDesign concurrently).

/// One day's eaten vs. burned kcal — the input to `EnergyBalanceWeekChart`.
struct EnergyBalanceDayPoint: Identifiable {
    let day: String   // yyyy-MM-dd
    let date: Date
    let eatenKcal: Double
    let burnedKcal: Double
    var id: String { day }
}

struct EnergyBalanceWeekChart: View {
    let points: [EnergyBalanceDayPoint]

    private static let eatenLabel = String(localized: "Eaten")
    private static let burnedLabel = String(localized: "Burned")

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Day", p.date, unit: .day), y: .value("kcal", p.eatenKcal))
                .foregroundStyle(by: .value("Series", Self.eatenLabel))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Day", p.date, unit: .day), y: .value("kcal", p.burnedKcal))
                .foregroundStyle(by: .value("Series", Self.burnedLabel))
                .interpolationMethod(.catmullRom)
        }
        .chartForegroundStyleScale(
            domain: [Self.eatenLabel, Self.burnedLabel],
            range: [StrandPalette.metricAmber, StrandPalette.metricCyan]
        )
        .chartLegend(.hidden) // legend rendered separately (EnergyBalanceDetailView's legendDot rows)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let kcal = value.as(Double.self) { Text("\(Int(kcal))") }
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityLabel("Weekly eaten versus burned calories")
    }
}
