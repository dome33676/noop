import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Food item editor
//
// Create or edit one food-library item: name + macros per 100g, with an optional Open Food Facts
// search to pre-fill the fields instead of typing them by hand. Mirrors `ManualWorkoutSheet`'s
// field()/inputShape/footer idiom. The OFF search only runs while the user has it enabled in
// Settings (§1.1e) — with it off, this is a plain hand-entry form and never touches the network.

struct FoodItemEditorSheet: View {
    /// The item being edited, or nil for a new one.
    let editing: FoodItemRow?
    let onSave: (FoodItemRow) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("foodOpenFoodFactsEnabled") private var openFoodFactsEnabled = false

    @State private var name: String
    @State private var kcalText: String
    @State private var proteinText: String
    @State private var carbsText: String
    @State private var fatText: String
    @State private var servingSizeText: String
    @State private var barcode: String?
    /// User-defined portion presets — ADDITIVE to `servingSizeText` above (the OFF-scanned default),
    /// so "I always eat 250g of this, not whatever OFF says" gets its own preset instead of
    /// overwriting the scanned one.
    @State private var customPortions: [FoodPortion]
    @State private var newPortionLabel = ""
    @State private var newPortionGramsText = ""

    @State private var offQuery = ""
    @State private var offResults: [OpenFoodFactsClient.Product] = []
    @State private var offSearching = false
    @State private var offSearchTask: Task<Void, Never>?
    #if os(iOS)
    @State private var showScanner = false
    @State private var scanNotFound = false
    #endif

    private enum NumberField: Hashable { case kcal, protein, carbs, fat, servingSize, newPortionGrams }
    @FocusState private var focusedField: NumberField?

    init(editing: FoodItemRow? = nil, onSave: @escaping (FoodItemRow) -> Void) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _kcalText = State(initialValue: editing?.kcalPer100g.map { Self.trimmed($0) } ?? "")
        _proteinText = State(initialValue: editing?.proteinPer100g.map { Self.trimmed($0) } ?? "")
        _carbsText = State(initialValue: editing?.carbsPer100g.map { Self.trimmed($0) } ?? "")
        _fatText = State(initialValue: editing?.fatPer100g.map { Self.trimmed($0) } ?? "")
        _servingSizeText = State(initialValue: editing?.servingSizeG.map { Self.trimmed($0) } ?? "")
        _barcode = State(initialValue: editing?.barcode)
        _customPortions = State(initialValue: editing?.customPortions ?? [])
    }

    private static func trimmed(_ v: Double) -> String {
        var s = String(format: "%.1f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
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
        .sheet(isPresented: $showScanner) {
            BarcodeScannerScreen { code in
                Task { await lookupBarcode(code) }
            }
        }
        .alert("No match found", isPresented: $scanNotFound) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open Food Facts has no product for that barcode. You can still enter it by hand.")
        }
        #endif
    }

    #if os(iOS)
    private func lookupBarcode(_ code: String) async {
        guard let product = await OpenFoodFactsClient.lookup(barcode: code) else {
            scanNotFound = true
            return
        }
        apply(product)
    }
    #endif

    private var formContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            header
            if openFoodFactsEnabled { offSearchSection }
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                field("Name") {
                    TextField("e.g. Rolled oats", text: $name)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: inputShape)
                        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .accessibilityLabel("Food name")
                }
                Text("Macros per 100 g").strandOverline()
                HStack(spacing: 14) {
                    field("Calories") { numberInput("optional", text: $kcalText, unit: "kcal", field: .kcal) }
                    field("Protein") { numberInput("optional", text: $proteinText, unit: "g", field: .protein) }
                }
                HStack(spacing: 14) {
                    field("Carbs") { numberInput("optional", text: $carbsText, unit: "g", field: .carbs) }
                    field("Fat") { numberInput("optional", text: $fatText, unit: "g", field: .fat) }
                }
                // Grams per portion — usually carried straight over from Open Food Facts' own
                // `serving_quantity` on a scan/search pick (see `apply(_:)`), so logging a meal can use
                // "1 portion" instead of always needing a weighed gram amount.
                field("Serving size (optional)") {
                    numberInput("e.g. 30", text: $servingSizeText, unit: "g", field: .servingSize)
                }
                myPortionsSection
            }
            if let validationNote { noteRow(validationNote) }
            footer
        }
    }

    // MARK: - Open Food Facts search

    private var offSearchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Look up online").strandOverline()
            HStack(spacing: 6) {
                TextField("Search Open Food Facts", text: $offQuery)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: inputShape)
                    .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .onChangeCompat(of: offQuery) { newValue in scheduleSearch(newValue) }
                if offSearching { ProgressView().controlSize(.small) }
                #if os(iOS)
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 38, height: 38)
                        .background(StrandPalette.surfaceInset, in: inputShape)
                        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                }
                .accessibilityLabel("Scan a barcode")
                #endif
            }
            if !offResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(offResults.enumerated()), id: \.offset) { idx, product in
                        Button { apply(product) } label: {
                            HStack(spacing: 8) {
                                Text(product.name)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer(minLength: 8)
                                if let kcal = product.kcalPer100g {
                                    Text("\(Int(kcal.rounded())) kcal/100g")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if idx < offResults.count - 1 { Divider().opacity(0.4) }
                    }
                }
                .padding(.horizontal, 12)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
        }
    }

    /// Debounce free-text search so every keystroke doesn't fire its own request.
    private func scheduleSearch(_ query: String) {
        offSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { offResults = []; return }
        offSearchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            offSearching = true
            let page = await OpenFoodFactsClient.search(query: trimmed)
            guard !Task.isCancelled else { return }
            offResults = page.products
            offSearching = false
        }
    }

    private func apply(_ product: OpenFoodFactsClient.Product) {
        name = product.name
        if let v = product.kcalPer100g { kcalText = Self.trimmed(v) }
        if let v = product.proteinPer100g { proteinText = Self.trimmed(v) }
        if let v = product.carbsPer100g { carbsText = Self.trimmed(v) }
        if let v = product.fatPer100g { fatText = Self.trimmed(v) }
        if let v = product.servingSizeG { servingSizeText = Self.trimmed(v) }
        barcode = product.barcode
        offResults = []
        offQuery = ""
    }

    // MARK: - My portions (custom presets, additive to the scanned serving size above)

    private var myPortionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("My portions").strandOverline()
            Text("Your own presets, e.g. \"250g\" — in addition to the serving size above, not instead of it.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !customPortions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(customPortions.enumerated()), id: \.element.id) { idx, portion in
                        HStack {
                            Text(portion.label)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: 8)
                            Text("\(Self.trimmed(portion.grams)) g")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Button {
                                customPortions.removeAll { $0.id == portion.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(portion.label)")
                        }
                        .padding(.vertical, 6)
                        if idx < customPortions.count - 1 { Divider().opacity(0.3) }
                    }
                }
                .padding(.horizontal, 12)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
            HStack(spacing: 6) {
                TextField("e.g. Meine Portion", text: $newPortionLabel)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: inputShape)
                    .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                numberInput("g", text: $newPortionGramsText, unit: "g", field: .newPortionGrams)
                    .frame(maxWidth: 100)
                Button(action: addPortion) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(newPortionIsValid ? StrandPalette.accent : StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!newPortionIsValid)
                .accessibilityLabel("Add portion")
            }
        }
    }

    private var newPortionIsValid: Bool {
        let label = newPortionLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, case .some(let grams) = parsed(newPortionGramsText), let grams, grams > 0 else { return false }
        return !customPortions.contains { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    private func addPortion() {
        guard newPortionIsValid,
              case .some(let grams) = parsed(newPortionGramsText), let grams else { return }
        customPortions.append(FoodPortion(label: newPortionLabel.trimmingCharacters(in: .whitespaces), grams: grams))
        newPortionLabel = ""
        newPortionGramsText = ""
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
                Text(editing == nil ? "Add Food" : "Edit Food")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Macros per 100 g, so any logged quantity scales.")
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
            .disabled(builtItem == nil)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String, field: NumberField) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .numericKeyboard()
                .focused($focusedField, equals: field)
            Text(unit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(StrandPalette.surfaceInset, in: inputShape)
        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.statusWarning)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Validation / build

    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private func parsed(_ text: String) -> Double?? {
        // German-locale comma decimal, mirrors JournalLogCard's NumericLogField.
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return .some(nil) }
        guard let v = Double(t), v >= 0 else { return nil }
        return .some(v)
    }

    private var builtItem: FoodItemRow? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }
        guard case .some(let kcal) = parsed(kcalText),
              case .some(let protein) = parsed(proteinText),
              case .some(let carbs) = parsed(carbsText),
              case .some(let fat) = parsed(fatText),
              case .some(let servingSize) = parsed(servingSizeText) else { return nil }
        return FoodItemRow(
            id: editing?.id ?? UUID().uuidString,
            deviceId: WhoopStore.foodLogSourceId,
            name: trimmedName,
            kcalPer100g: kcal, proteinPer100g: protein, carbsPer100g: carbs, fatPer100g: fat,
            barcode: barcode,
            createdAt: editing?.createdAt ?? Int(Date().timeIntervalSince1970),
            servingSizeG: servingSize,
            customPortionsJSON: FoodItemRow.encodePortions(customPortions)
        )
    }

    private var validationNote: String? {
        guard builtItem == nil else { return nil }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        return "Macros must be zero or a positive number."
    }

    private func save() {
        guard let item = builtItem else { return }
        onSave(item)
        dismiss()
    }
}
