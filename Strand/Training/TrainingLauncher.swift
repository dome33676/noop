import SwiftUI
import WhoopStore

// MARK: - Shared training-launch plumbing
//
// `startTraining(from:repo:into:)` + `StartedTraining` + `.activeTrainingCover(item:repo:model:)`
// used to live as private members of `TrainingView` — the Training tab's only entry point into
// `ActiveTrainingView`. Today and Liquid Today's "Start Training" choice (via `StartSessionPickerSheet`)
// need the exact same session-creation + presentation logic, so this is hoisted out here rather than
// copy-pasted three times. Behavior is unchanged from the original `TrainingView`-private version.

/// Bundles a just-started session with the template it was started from — set as ONE `@State`
/// value rather than two separate ones, so the session and its template can never be observed out
/// of sync with each other (a two-`@State` version could intermittently open a session whose
/// exercises hadn't come from its template).
struct StartedTraining: Identifiable {
    let session: StrengthSessionRow
    let template: StrengthTemplateRow?
    var id: String { session.id }
}

private let trainingStartDateFmt: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
}()

/// Creates a strength session (blank, or seeded from `template`), saves it, then sets `started` —
/// mirrors the flow every "Start Training" entry point (Training tab, Today, Liquid Today) uses so
/// they all land in the identical `ActiveTrainingView` session.
func startTraining(from template: StrengthTemplateRow?, repo: Repository, into started: Binding<StartedTraining?>) {
    let session = StrengthSessionRow(
        id: UUID().uuidString, deviceId: WhoopStore.strengthLogSourceId,
        name: template?.name ?? "Training — " + trainingStartDateFmt.string(from: Date()),
        startTs: Int(Date().timeIntervalSince1970), endTs: nil, notes: nil
    )
    Task {
        await repo.saveStrengthSession(session)
        started.wrappedValue = StartedTraining(session: session, template: template)
    }
}

extension View {
    // A just-started session is presented full-screen (matching the Live-session convention: an
    // in-progress session owns the whole display) rather than pushed — `.navigationDestination
    // (item:)` needs macOS 14, and callers of this modifier compile into the macOS 13 target too.
    /// Present a just-started training session in the SAME `ActiveTrainingView` flow the Training
    /// tab's own "Start Training" uses: `fullScreenCover` on iOS, a plain `sheet` on macOS.
    @ViewBuilder func activeTrainingCover(item: Binding<StartedTraining?>, repo: Repository, model: AppModel) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item) { started in
            ActiveTrainingView(session: started.session, repo: repo, model: model, template: started.template)
        }
        #else
        self.sheet(item: item) { started in
            ActiveTrainingView(session: started.session, repo: repo, model: model, template: started.template)
        }
        #endif
    }
}
