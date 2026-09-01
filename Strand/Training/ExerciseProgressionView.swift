import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Exercise progression
//
// Weight-over-time for one exercise across ALL past sessions, via the shared `TrendChart` +
// `ChartCard` (the same components `WorkoutDetailView`'s HR curve uses), plus a plain list of every
// past set beneath it.

struct ExerciseProgressionView: View {
    let exerciseName: String
    @EnvironmentObject private var repo: Repository

    @State private var sets: [StrengthSetRow] = []
    @State private var loaded = false

    private var points: [TrendPoint] {
        sets.compactMap { set in
            guard let weight = set.weightKg else { return nil }
            return TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(set.completedAt)), value: weight)
        }
    }

    var body: some View {
        ScreenScaffold(title: exerciseName, subtitle: "Weight over time", onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                ChartCard(title: "WEIGHT", subtitle: "kg, across all trainings", tint: StrandPalette.effortColor) {
                    if points.count >= 2 {
                        let values = points.map(\.value)
                        let lo = (values.min() ?? 0) - 2, hi = (values.max() ?? 1) + 2
                        TrendChart(
                            points: points,
                            gradient: StrandPalette.effortGradient,
                            valueRange: lo...hi,
                            showsArea: true,
                            valueFormat: { String(format: "%.1f kg", $0) }
                        )
                    } else {
                        Text("Not enough data yet — log at least two sets with a weight.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                if loaded && !sets.isEmpty {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            Text("All sets").strandOverline()
                            VStack(spacing: 0) {
                                ForEach(Array(sets.reversed().enumerated()), id: \.element.id) { idx, set in
                                    setRow(set)
                                    if idx < sets.count - 1 { Divider().opacity(0.3) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func setRow(_ set: StrengthSetRow) -> some View {
        HStack {
            Text(Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(set.completedAt))))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            if let reps = set.reps, let weight = set.weightKg {
                Text("\(reps) × \(String(format: "%.1f", weight)) kg")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            } else if let weight = set.weightKg {
                Text("\(String(format: "%.1f", weight)) kg")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(.vertical, 4)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    private func reload() async {
        sets = await repo.strengthSets(exerciseName: exerciseName)
        loaded = true
    }
}
