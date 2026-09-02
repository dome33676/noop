import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Weekly training schedule ("This Week")
//
// A repeating Monday..Sunday routine — assign a template to each weekday once, reused every
// week — stored independently of any specific calendar week. Only the on-screen date labels
// (and the "trained today?" check) advance to the CURRENT week; the assignment itself doesn't
// expire or need re-entry.

private let weekdayKeys = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
private let weekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

struct WeeklyScheduleSection: View {
    @EnvironmentObject var repo: Repository
    @AppStorage("trainingWeeklyScheduleJSON") private var scheduleJSON = "{}"
    @State private var templates: [StrengthTemplateRow] = []
    @State private var sessions: [StrengthSessionRow] = []
    @State private var expandedWeekday: String?
    @State private var assigningWeekday: String?

    /// This week's Monday..Sunday, as actual `Date`s — Monday is the most recent past-or-today Monday.
    private var weekDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // Sunday = 1 ... Saturday = 7
        let sinceMonday = (weekday - 2 + 7) % 7
        let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: today) ?? today
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: monday) ?? monday }
    }

    var body: some View {
        let dates = weekDates
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("This Week").strandOverline()
            NoopCard {
                VStack(spacing: 0) {
                    ForEach(Array(weekdayKeys.enumerated()), id: \.offset) { idx, key in
                        dayRow(key: key, label: weekdayLabels[idx], date: dates[idx])
                        if idx < weekdayKeys.count - 1 { Divider().opacity(0.3) }
                    }
                }
            }
        }
        .task {
            templates = await repo.strengthTemplates()
            sessions = await repo.strengthSessions()
        }
        .sheet(item: Binding(
            get: { assigningWeekday.map { AssignTarget(weekday: $0) } },
            set: { assigningWeekday = $0?.weekday }
        )) { target in
            AssignTemplateSheet(templates: templates) { templateId in
                setAssignment(templateId, for: target.weekday)
            }
        }
    }

    @ViewBuilder
    private func dayRow(key: String, label: String, date: Date) -> some View {
        let assignedTemplate = template(for: key)
        let matchedSession = session(on: date)
        let expanded = expandedWeekday == key
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expandedWeekday = expanded ? nil : key
                }
            } label: {
                HStack(spacing: 12) {
                    Text("\(label) \(Self.dayNumberFmt.string(from: date))")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 48, alignment: .leading)
                    Text(assignedTemplate?.name ?? "Rest day")
                        .font(StrandFont.subhead)
                        .foregroundStyle(assignedTemplate == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    Spacer()
                    if matchedSession != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(StrandPalette.statusPositive)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            if expanded {
                expandedContent(key: key, date: date, assignedTemplate: assignedTemplate, session: matchedSession)
            }
        }
    }

    @ViewBuilder
    private func expandedContent(key: String, date: Date, assignedTemplate: StrengthTemplateRow?, session: StrengthSessionRow?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.2)
            Text(assignedTemplate?.name ?? "No template assigned")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            if let session {
                Text("\(session.name) · \(Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusPositive)
            } else if date < Calendar.current.startOfDay(for: Date()) {
                Text("Not trained")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                NoopButton("Assign Template", kind: .secondary) {
                    assigningWeekday = key
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func template(for weekday: String) -> StrengthTemplateRow? {
        guard let id = decodeSchedule()[weekday] else { return nil }
        return templates.first { $0.id == id }
    }

    private func session(on date: Date) -> StrengthSessionRow? {
        let key = Repository.localDayKey(date)
        return sessions.first { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == key }
    }

    private func decodeSchedule() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(scheduleJSON.utf8))) ?? [:]
    }

    private func encodeSchedule(_ schedule: [String: String]) -> String {
        (try? String(data: JSONEncoder().encode(schedule), encoding: .utf8)) ?? "{}"
    }

    private func setAssignment(_ templateId: String?, for weekday: String) {
        var schedule = decodeSchedule()
        if let templateId {
            schedule[weekday] = templateId
        } else {
            schedule.removeValue(forKey: weekday)
        }
        scheduleJSON = encodeSchedule(schedule)
    }

    private static let dayNumberFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()
}

private struct AssignTarget: Identifiable {
    let weekday: String
    var id: String { weekday }
}

// MARK: - Assign/clear sheet

private struct AssignTemplateSheet: View {
    let templates: [StrengthTemplateRow]
    let onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            Text("Assign Template")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            NoopButton("Clear", kind: .secondary, fullWidth: true) {
                onPick(nil); dismiss()
            }
            if templates.isEmpty {
                Text("No templates yet.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(templates.enumerated()), id: \.element.id) { idx, template in
                            Button { onPick(template.id); dismiss() } label: {
                                Text(template.name)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}
