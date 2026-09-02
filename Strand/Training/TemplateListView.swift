import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Template management (list, create, edit, delete)

struct TemplateListView: View {
    @EnvironmentObject private var repo: Repository
    @State private var templates: [StrengthTemplateRow] = []
    @State private var showNewTemplate = false
    @State private var editingTemplate: StrengthTemplateRow?

    var body: some View {
        ScreenScaffold(title: "Templates", subtitle: "Reusable plans for Start Training",
                       onRefresh: { await reload() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopButton("New Template", systemImage: "plus", kind: .primary, fullWidth: true) {
                    showNewTemplate = true
                }
                if templates.isEmpty {
                    NoopCard {
                        Text("No templates yet. Create one to reuse a plan across trainings.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    NoopCard {
                        VStack(spacing: 0) {
                            ForEach(Array(templates.enumerated()), id: \.element.id) { idx, template in
                                Button { editingTemplate = template } label: {
                                    templateRow(template)
                                }
                                .buttonStyle(.plain)
                                if idx < templates.count - 1 { Divider().opacity(0.3) }
                            }
                        }
                    }
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showNewTemplate) {
            TemplateEditorView { template in
                Task { await repo.saveTemplate(template); await reload() }
            }
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditorView(editing: template) { updated in
                Task { await repo.saveTemplate(updated); await reload() }
            }
        }
    }

    private func templateRow(_ template: StrengthTemplateRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(template.plan.count) exercise\(template.plan.count == 1 ? "" : "s")")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await repo.deleteTemplate(id: template.id); await reload() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }

    private func reload() async {
        templates = await repo.strengthTemplates()
    }
}
