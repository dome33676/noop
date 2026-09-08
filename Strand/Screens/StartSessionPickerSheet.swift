import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Start-session fork in the road (Live Session vs. Start Training)
//
// Today's "Start session" used to go straight into a live BLE session. This is the shared
// picker that now sits in front of it: two choices, each just forwarded via a callback — this
// sheet owns no live-session or training-creation logic itself. "Start Training" reuses
// `StartTrainingSheet` (TrainingView.swift) verbatim as a nested sheet, the same blank/template
// chooser the Training tab's own "Start Training" button presents.

struct StartSessionPickerSheet: View {
    /// Called (after this sheet dismisses) to start the existing live BLE/HR session.
    let onLiveSession: () -> Void
    /// Called (after this sheet dismisses) with the chosen template, or nil for blank —
    /// `StartTrainingSheet`'s own `onPick` contract.
    let onStartTraining: (StrengthTemplateRow?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showTrainingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            Text("Start Session")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            NoopButton("Live Session", systemImage: "shield.lefthalf.filled", kind: .primary, fullWidth: true) {
                dismiss(); onLiveSession()
            }
            NoopButton("Start Training", systemImage: "dumbbell.fill", kind: .secondary, fullWidth: true) {
                showTrainingPicker = true
            }
        }
        .padding(NoopMetrics.space6)
        .frame(maxWidth: .infinity)
        .background(NoopChromeSurface())
        .sheet(isPresented: $showTrainingPicker) {
            StartTrainingSheet { template in
                dismiss()              // dismiss the whole picker stack
                onStartTraining(template)
            }
        }
    }
}
