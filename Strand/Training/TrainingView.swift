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
    @State private var startedTemplate: StrengthTemplateRow?
    @State private var showStartPicker = false
    @AppStorage(ActiveTrainingController.robustDoubleTapKey) private var robustDoubleTap = false
    @AppStorage(ActiveTrainingController.restTargetSecondsKey) private var restTargetSeconds = ActiveTrainingController.defaultRestTargetSeconds

    var body: some View {
        ScreenScaffold(title: "Training", subtitle: "Your strength sessions, on this device only.",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopButton("Start Training", systemImage: "dumbbell.fill", kind: .primary, fullWidth: true) {
                    showStartPicker = true
                }
                NavigationLink {
                    TemplateListView()
                } label: {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                        Text("Manage Templates")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 4)
                }
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        Toggle(isOn: $robustDoubleTap) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Less sensitive double-tap")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("Waits longer between taps and ignores an end-tap that arrives implausibly fast, so a hard rep is less likely to start/end a set by itself.")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .tint(StrandPalette.accent)
                        Divider().opacity(0.4)
                        Picker("Rest timer", selection: $restTargetSeconds) {
                            ForEach([30, 45, 60, 90, 120, 150, 180, 240], id: \.self) { seconds in
                                Text(ActiveWorkoutClock.clock(seconds)).tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("A short buzz on your strap when a rest this long has passed since your last set — your cue to start the next one.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
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
        .sheet(isPresented: $showStartPicker) {
            StartTrainingSheet { template in
                startTraining(from: template)
            }
        }
        // A just-started session is presented full-screen (matching the Live-session convention:
        // an in-progress session owns the whole display) rather than pushed — `.navigationDestination
        // (item:)` needs macOS 14, and this file compiles into the macOS 13 target too.
        #if os(iOS)
        .fullScreenCover(item: $startedSession) { session in
            ActiveTrainingView(session: session, repo: repo, model: model, template: startedTemplate)
        }
        #else
        .sheet(item: $startedSession) { session in
            ActiveTrainingView(session: session, repo: repo, model: model, template: startedTemplate)
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

    private func startTraining(from template: StrengthTemplateRow?) {
        let session = StrengthSessionRow(
            id: UUID().uuidString, deviceId: WhoopStore.strengthLogSourceId,
            name: template?.name ?? "Training — " + Self.dateFmt.string(from: Date()),
            startTs: Int(Date().timeIntervalSince1970), endTs: nil, notes: nil
        )
        Task {
            await repo.saveStrengthSession(session)
            startedTemplate = template
            startedSession = session
        }
    }

    private func reload() async {
        sessions = await repo.strengthSessions()
        loaded = true
    }
}

// MARK: - Start-training chooser (blank vs. a saved template)

private struct StartTrainingSheet: View {
    /// nil = start blank.
    let onPick: (StrengthTemplateRow?) -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [StrengthTemplateRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            Text("Start Training")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            NoopButton("Start Blank", systemImage: "plus", kind: .secondary, fullWidth: true) {
                onPick(nil); dismiss()
            }
            if !templates.isEmpty {
                Text("Or from a template").strandOverline()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(templates.enumerated()), id: \.element.id) { idx, template in
                            Button { onPick(template); dismiss() } label: {
                                HStack {
                                    Text(template.name)
                                        .font(StrandFont.body)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Text("\(template.plan.count) exercise\(template.plan.count == 1 ? "" : "s")")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            if idx < templates.count - 1 { Divider().opacity(0.3) }
                        }
                    }
                }
            }
        }
        .padding(NoopMetrics.space6)
        .frame(maxWidth: .infinity)
        .background(NoopChromeSurface())
        .task { templates = await repo.strengthTemplates() }
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
        ScreenScaffold(title: LocalizedStringKey(session.name)) {
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
