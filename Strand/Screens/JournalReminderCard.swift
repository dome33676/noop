import SwiftUI
import StrandDesign

// MARK: - Journal widget (Today screen) — #627
//
// A persistent Today widget for the Journal: a WHOOP-style strip of the last `stripDays` days
// (filled = a journal entry that day, today ringed) plus an always-present tap-through to the journal.
// The Journal (behavioural logging that feeds Insights / "What Moves You") is otherwise only reachable
// inside the Insights screen, which isn't a primary destination — easy to forget, and the only proactive
// prompt is the once-a-morning sleep sheet — missed on any day you don't open Sleep. This surfaces it on
// Today where it can't be missed, and doubles as the "direct link to Insights" the report (#627) asked for.
//
// Opt-out via `PuffinExperiment.journalReminderKey` (default ON — the same key also gates the Android
// morning sleep sheet twin). Read-only: it never writes a journal entry. Twin of Android
// `JournalReminderCard` (android/.../ui/JournalReminder.kt). Design-Reset compliant — a flat accent-tinted
// NoopCard, NoopMetrics / StrandPalette / StrandFont tokens, matching the other Today cards.

struct JournalReminderCard: View {

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter

    /// Default ON so the reminder works out of the box; the Settings toggle / this key opt out.
    @AppStorage(PuffinExperiment.journalReminderKey) private var reminderEnabled = true

    /// Which of the last `stripDays` day-keys carry a native journal entry. nil = still loading / read
    /// error → render nothing (never a misleading all-empty strip).
    @State private var loggedDays: Set<String>?

    private static let stripDays = 7

    var body: some View {
        Group {
            if !reminderEnabled {
                disabledHint
            } else if let logged = loggedDays {
                card(logged)
            }
        }
        // Keyed ONLY on `reminderEnabled`, deliberately NOT on `repo.refreshSeq`: `.task(id:)` CANCELS
        // and restarts its work every time the id changes, and a cold launch bumps refreshSeq several
        // times in quick succession (multiple sequential sync/backfill passes) — keying on it here
        // meant this card's very first load kept getting cancelled mid-flight before `loggedDays` could
        // ever be assigned, so BOTH branches of the Group above missed (not `!reminderEnabled`, not a
        // non-nil `loggedDays` either) and the whole section silently vanished for the rest of the
        // session. A later refreshSeq bump (e.g. flipping the Settings toggle re-fires this task via
        // `reminderEnabled` changing) would eventually land once the launch burst settled, which is why
        // toggling off/on "fixed" it. Post-launch reloads now go through `.onChangeCompat` below, which
        // fires a plain `reload()` call without cancelling anything already in flight.
        .task(id: reminderEnabled) {
            await reload()
        }
        .onChangeCompat(of: repo.refreshSeq) { _ in
            Task { await reload() }
        }
    }

    /// When the section is placed in Today (this view was even instantiated) but the reminder toggle is
    /// off, a silent empty Group is indistinguishable from a bug — nothing explains why the card is
    /// missing. One calm line instead, no chrome beyond the card itself.
    private var disabledHint: some View {
        NoopCard {
            Text(String(localized: "Journal reminder is off — enable it in Settings → Features"))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func card(_ logged: Set<String>) -> some View {
        let keys = Self.dayKeys()
        let todayKey = keys.last ?? ""
        let todayLogged = logged.contains(todayKey)
        // A recent PAST day with no entry — surfaces the tap-a-bar-to-backfill interaction once today is
        // done (#656). Accent while anything is actionable; calm secondary once fully caught up.
        let hasMissed = keys.contains { $0 != todayKey && !logged.contains($0) }
        let subtitle: String = !todayLogged ? String(localized: "Log today's journal")
            : hasMissed ? String(localized: "Tap a day to catch up")
            : String(localized: "Logged today")
        // No outer Button: each bar is its own tap target that deep-links the journal to THAT day (#656),
        // and nested SwiftUI buttons don't work — so header + subtitle carry their own onTapGesture (→
        // today) and the bars carry theirs. The regions are non-overlapping in the VStack, so a tap lands
        // on exactly one. Tapping a bar does NOT set today, so a bar's day always wins.
        return NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(String(localized: "Journal"))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .onTapGesture { router.openJournal() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(String(localized: "Journal")))
                .accessibilityHint(Text(String(localized: "Open journal")))
                // The last-N-days strip: one equal-width bar per day, each its own tap target. Filled =
                // logged; today is ringed. Tapping a bar deep-links the journal to that day (#656).
                HStack(spacing: 6) {
                    ForEach(keys.indices, id: \.self) { i in
                        let key = keys[i]
                        let off = Self.stripDays - 1 - i          // keys[0] = 6 days ago … last = today
                        let isLogged = logged.contains(key)
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)                    // taller invisible tap target
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isLogged ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.22))
                                    .frame(height: 10)
                                    .overlay {
                                        if off == 0, !isLogged {
                                            RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(StrandPalette.accent, lineWidth: 1)
                                        }
                                    }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { router.openJournal(day: off) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(Self.barLabel(off))
                    }
                }
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle((!todayLogged || hasMissed) ? StrandPalette.accent : StrandPalette.textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture { router.openJournal() }
                    .accessibilityAddTraits(.isButton)   // it opens the journal — announce it as one
            }
        }
    }

    /// Screen-reader label for a strip bar (#656): the day it deep-links to. Twin of JournalLogCard's
    /// day-picker labels; "%lld days ago" is a String Catalog key so it stays localized.
    private static func barLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func reload() async {
        guard reminderEnabled else { loggedDays = nil; return }
        let keys = Self.dayKeys()
        loggedDays = await repo.nativeJournalDays(from: keys.first ?? "", to: keys.last ?? "")
    }

    /// The `stripDays` local-day keys (yyyy-MM-dd), oldest → today, matching Android's `journalDayKey`
    /// (civil-day arithmetic via Calendar so a DST edge can't mislabel a day).
    private static func dayKeys() -> [String] {
        let cal = Calendar.current
        let today = Date()
        return (0..<stripDays).reversed().map { n in
            Repository.localDayKey(cal.date(byAdding: .day, value: -n, to: today) ?? today)
        }
    }
}
