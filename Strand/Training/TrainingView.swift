import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Training tab root
//
// A list of past trainings (newest first) plus a "Start Training" button, matching the
// `WorkoutsView`/`ScreenScaffold` + `NoopCard` row convention used throughout the app.

struct TrainingView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel

    @State private var sessions: [StrengthSessionRow] = []
    @State private var loaded = false
    @State private var startedSession: StrengthSessionRow?

    var body: some View {
        ScreenScaffold(title: "Training", subtitle: "Your strength sessions, on this device only.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopButton("Start Training", systemImage: "dumbbell.fill", kind: .primary, fullWidth: true) {
                    startTraining()
                }
                if loaded && sessions.isEmpty {
                    NoopCard {
                        Text("No trainings logged yet.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    NoopCard {
                        VStack(spacing: 0) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    sessionRow(session)
                                }
                                .buttonStyle(.plain)
                                if idx < sessions.count - 1 { Divider().opacity(0.3) }
                            }
                        }
                    }
                }
            }
        }
        .task { await reload() }
        // A just-started session is presented full-screen (matching the Live-session convention:
        // an in-progress session owns the whole display) rather than pushed — `.navigationDestination
        // (item:)` needs macOS 14, and this file compiles into the macOS 13 target too.
        #if os(iOS)
        .fullScreenCover(item: $startedSession) { session in
            ActiveTrainingView(session: session, repo: repo, model: model)
        }
        #else
        .sheet(item: $startedSession) { session in
            ActiveTrainingView(session: session, repo: repo, model: model)
        }
        #endif
    }

    private func sessionRow(_ session: StrengthSessionRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            if session.endTs == nil {
                Text("Active")
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private func startTraining() {
        let session = StrengthSessionRow(
            id: UUID().uuidString, deviceId: WhoopStore.strengthLogSourceId,
            name: "Training — " + Self.dateFmt.string(from: Date()),
            startTs: Int(Date().timeIntervalSince1970), endTs: nil, notes: nil
        )
        Task {
            await repo.saveStrengthSession(session)
            startedSession = session
        }
    }

    private func reload() async {
        sessions = await repo.strengthSessions()
        loaded = true
    }
}

// MARK: - Past session detail (read-only)

private struct SessionDetailView: View {
    private struct ExerciseGroup: Identifiable {
        let name: String
        let sets: [StrengthSetRow]
        var id: String { name }
    }

    let session: StrengthSessionRow
    @EnvironmentObject private var repo: Repository
    @State private var sets: [StrengthSetRow] = []

    private var byExercise: [ExerciseGroup] {
        var order: [String] = []
        var grouped: [String: [StrengthSetRow]] = [:]
        for set in sets {
            if grouped[set.exerciseName] == nil { order.append(set.exerciseName) }
            grouped[set.exerciseName, default: []].append(set)
        }
        return order.map { ExerciseGroup(name: $0, sets: grouped[$0] ?? []) }
    }

    var body: some View {
        ScreenScaffold(title: session.name) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                ForEach(byExercise) { group in
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                            HStack {
                                Text(group.name).strandOverline()
                                Spacer()
                                NavigationLink {
                                    ExerciseProgressionView(exerciseName: group.name)
                                } label: {
                                    Image(systemName: "chart.line.uptrend.xyaxis")
                                        .foregroundStyle(StrandPalette.accent)
                                }
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(group.sets.enumerated()), id: \.element.id) { idx, set in
                                    HStack {
                                        Text("Set \(idx + 1)")
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                        Spacer()
                                        if let reps = set.reps, let weight = set.weightKg {
                                            Text("\(reps) × \(String(format: "%.1f", weight)) kg")
                                                .font(StrandFont.subhead)
                                                .foregroundStyle(StrandPalette.textPrimary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { sets = await repo.strengthSets(sessionId: session.id) }
    }
}
