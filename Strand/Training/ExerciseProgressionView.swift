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
            guard !set.isWarmup, let weight = set.weightKg else { return nil }
            let volume = set.reps.map { weight * Double($0) } ?? weight
            return TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(set.completedAt)), value: volume)
        }
    }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(exerciseName), subtitle: "Volume over time", onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                ChartCard(title: "VOLUME", subtitle: "kg moved, across all trainings", tint: StrandPalette.effortColor) {
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
                        Text("Not enough data yet — log at least two working sets with a weight.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                if let suggestion = ProgressionCalculator.suggest(from: sets) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SUGGESTED NEXT").strandOverline()
                            Text("\(String(format: "%.1f", suggestion.suggestedWeightKg)) kg")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(suggestion.reasoning)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
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
            if set.isWarmup {
                Text("Warm-up")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            // Real full-history PR check — `sets` here IS the complete history for this exercise, so
            // (unlike ActiveTrainingView's session-only trophy) this one is authoritative.
            if PRDetector.isPR(set, among: sets.filter { $0.completedAt < set.completedAt }) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.statusPositive)
            }
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
            if let value = set.effortValue, let scale = set.effortScale {
                Text("· \(scale.uppercased()) \(String(format: "%.1f", value))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
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
