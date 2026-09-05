import SwiftUI
import StrandDesign

// MARK: - Morning journal wake prompt (iOS port of Android's ModalBottomSheet, SleepScreen.kt PR #260)
//
// Once per calendar day, when the freshest sleep session ended within the last 12 hours and today's
// journal isn't logged yet, RootTabView presents this on ANY app open (cold launch or foreground resume)
// — not gated to a specific tab, unlike Android's Sleep-screen-scoped twin, per the iOS ask: "the first
// time I then open the app" means any tab. Gated on the same `journalReminderKey` toggle that silences
// the Today JournalReminderCard strip (one switch silences both, matching Android).

struct JournalWakePrompt: View {
    /// Called when the user taps "Open Journal" — RootTabView dismisses this sheet AND opens the
    /// journal quick-action sheet in the SAME call, matching how JournalReminderCard's
    /// `router.openJournal()` tap routes today.
    let onOpenJournal: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "book.closed")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Good morning"))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(String(localized: "Your night's data is in — log how you felt."))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Maybe later", kind: .tertiary) { dismiss() }
                Spacer()
                NoopButton("Open Journal", systemImage: "square.and.pencil", kind: .primary) {
                    onOpenJournal()
                }
            }
        }
        .padding(NoopMetrics.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .background(NoopChromeSurface())
    }
}
