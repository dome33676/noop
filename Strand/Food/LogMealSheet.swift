import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Log meal sheet
//
// Search the food library for an item (or create a new one), enter a quantity and meal type, and
// save one `MealEntryRow` for `day`. Mirrors `ManualWorkoutSheet`'s field()/footer idiom; the food
// picker is a plain inline search list rather than the floating-overlay sport picker, to keep this
// sheet's scope to what a meal log actually needs.

struct LogMealSheet: View {
    /// The entry being edited, or nil for a new log. When editing, `initialFood` is the food it
    /// currently references (resolved by the caller, since the store only holds the id).
    let editing: MealEntryRow?
    let initialFood: FoodItemRow?
    let day: String
    let onSave: (MealEntryRow) -> Void

    /// When set, pre-selects this meal type instead of the time-of-day default — used by the
    /// per-meal-type "+" button on `FoodView` so quick-adding a snack doesn't default to breakfast.
    let presetMealType: FoodMealType?

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFood: FoodItemRow?
    @State private var searchQuery = ""
    @State private var searchResults: [FoodItemRow] = []
    @State private var quantityText: String
    @State private var mealType: FoodMealType
    @State private var showNewFoodSheet = false

    private enum NumberField: Hashable { case quantity }
    @FocusState private var focusedField: NumberField?

    init(editing: MealEntryRow? = nil, initialFood: FoodItemRow? = nil, presetMealType: FoodMealType? = nil,
         day: String, onSave: @escaping (MealEntryRow) -> Void) {
        self.editing = editing
        self.initialFood = initialFood
        self.presetMealType = presetMealType
        self.day = day
        self.onSave = onSave
        _selectedFood = State(initialValue: initialFood)
        _quantityText = State(initialValue: editing.map { Self.trimmed($0.quantityGrams) } ?? "100")
        _mealType = State(initialValue: presetMealType ?? editing.flatMap { FoodMealType(rawValue: $0.mealType) } ?? Self.defaultMealType())
    }

    private static func trimmed(_ v: Double) -> String {
        var s = String(format: "%.1f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A sensible default meal type from the current time of day, so a fresh log doesn't always
    /// default to breakfast.
    private static func defaultMealType() -> FoodMealType {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<11: .breakfast
        case 11..<16: .lunch
        case 16..<21: .dinner
        default: .snack
        }
    }

    var body: some View {
        #if os(macOS)
        formContent
            .padding(NoopMetrics.space6)
            .frame(width: 420)
            .background(NoopChromeSurface())
            .keyboardDoneToolbar($focusedField)
        #else
        ScrollView {
            formContent
                .padding(NoopMetrics.space6)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity)
        .noopSheetPresentation(largeFirst: true)
        .background(NoopChromeSurface())
        .keyboardDoneToolbar($focusedField)
        #endif
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            header
            if let selectedFood {
                selectedFoodRow(selectedFood)
                field("Quantity") {
                    HStack(spacing: 6) {
                        TextField("100", text: $quantityText)
                            .textFieldStyle(.plain)
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .numericKeyboard()
                            .focused($focusedField, equals: .quantity)
                        Text("g").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(StrandPalette.surfaceInset, in: inputShape)
                    .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                }
                field("Meal") {
                    SegmentedPillControl(FoodMealType.allCases, selection: $mealType,
                                         adaptsToAvailableWidth: true) { $0.label }
                }
            } else {
                foodPicker
            }
            if let validationNote { noteRow(validationNote) }
            footer
        }
        .sheet(isPresented: $showNewFoodSheet) {
            FoodItemEditorSheet { item in
                Task { await repo.saveFoodItem(item); selectedFood = item }
            }
        }
    }

    // MARK: - Food picker (search the library, or create a new item)

    private var foodPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Food") {
                TextField("Search your food library", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: inputShape)
                    .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .onChangeCompat(of: searchQuery) { newValue in Task { await search(newValue) } }
                    .task { await search("") }
            }
            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { idx, food in
                        Button { selectedFood = food } label: {
                            HStack(spacing: 8) {
                                Text(food.name)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer(minLength: 8)
                                if let kcal = food.kcalPer100g {
                                    Text("\(Int(kcal.rounded())) kcal/100g")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if idx < searchResults.count - 1 { Divider().opacity(0.4) }
                    }
                }
                .padding(.horizontal, 12)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
            NoopButton("New food", systemImage: "plus", kind: .secondary, fullWidth: true) {
                showNewFoodSheet = true
            }
        }
    }

    private func selectedFoodRow(_ food: FoodItemRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "fork.knife")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
            Text(food.name)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            Button("Change") { selectedFood = nil }
                .font(StrandFont.footnote)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(StrandPalette.surfaceInset, in: inputShape)
        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        searchResults = trimmed.isEmpty ? await repo.foodItems() : await repo.searchFoodItems(query: trimmed)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 30, height: 30)
                .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "Log Meal" : "Edit Meal")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(editing == nil ? "Pick a food and how much you had." : "Adjust this entry.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: NoopMetrics.space3) {
            NoopButton("Cancel", kind: .tertiary) { dismiss() }
            Spacer()
            NoopButton(editing == nil ? "Add" : "Save", systemImage: "checkmark", kind: .primary) {
                save()
            }
            .disabled(builtEntry == nil)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.statusWarning)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Validation / build

    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private var quantityGrams: Double? {
        let t = quantityText.trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v > 0 else { return nil }
        return v
    }

    private var builtEntry: MealEntryRow? {
        guard let food = selectedFood, let grams = quantityGrams else { return nil }
        return MealEntryRow(
            id: editing?.id ?? UUID().uuidString,
            deviceId: WhoopStore.foodLogSourceId,
            foodItemId: food.id,
            day: day,
            mealType: mealType.rawValue,
            quantityGrams: grams,
            loggedAt: editing?.loggedAt ?? Int(Date().timeIntervalSince1970)
        )
    }

    private var validationNote: String? {
        guard builtEntry == nil else { return nil }
        if selectedFood == nil { return nil }
        return "Enter a quantity greater than zero."
    }

    private func save() {
        guard let entry = builtEntry else { return }
        onSave(entry)
        dismiss()
    }
}
