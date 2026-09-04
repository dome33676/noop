import SwiftUI
import StrandDesign
import WhoopStore
import PhotosUI

// MARK: - Log meal sheet
//
// Search the food library for an item (or create a new one), enter a quantity and meal type, and
// save one `MealEntryRow` for `day`. Mirrors `ManualWorkoutSheet`'s field()/footer idiom; the food
// picker is a plain inline search list rather than the floating-overlay sport picker, to keep this
// sheet's scope to what a meal log actually needs. Two scan paths sit beside the search field: a
// barcode lookup against Open Food Facts, and an AI photo scan (`FoodPhotoScanClient`, bring-your-
// own Anthropic key) that estimates a food from a camera shot — both resolve straight into a saved,
// selected library item, the same outcome tapping a search result already produces.

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
    @AppStorage("foodOpenFoodFactsEnabled") private var openFoodFactsEnabled = false

    @State private var selectedFood: FoodItemRow?
    @State private var searchQuery = ""
    @State private var searchResults: [FoodItemRow] = []
    @State private var quantityText: String
    @State private var mealType: FoodMealType
    @State private var showNewFoodSheet = false
    @State private var showScanner = false
    @State private var scanNotFound = false

    /// AI photo scan (Claude Haiku, bring-your-own-key — `FoodPhotoScanClient`): a camera shot or a
    /// picked photo goes through the same "resolve → save to library → select" path `selectOnline`
    /// already uses for an OFF result, just fed by an estimate instead of a lookup.
    @State private var showPhotoScanSourcePicker = false
    @State private var showPhotoScanCamera = false
    @State private var showPhotoLibraryPicker = false
    @State private var photoScanPickerItem: PhotosPickerItem?
    @State private var photoScanning = false
    @State private var photoScanError: FoodPhotoScanError?

    /// Online (Open Food Facts) results for the SAME query, shown inline below the library matches —
    /// no separate "add food" round trip needed to log something OFF already knows about.
    @State private var offResults: [OpenFoodFactsClient.Product] = []
    @State private var offSearching = false
    @State private var offPage = 1
    @State private var offHasMore = false
    @State private var offSearchTask: Task<Void, Never>?
    /// The online result currently being saved into the library + selected, so its row can show a
    /// spinner instead of being tappable twice.
    @State private var savingProduct: OpenFoodFactsClient.Product?

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
        .sheet(isPresented: $showScanner) {
            #if os(iOS)
            BarcodeScannerScreen { code in
                Task { await lookupBarcode(code) }
            }
            #endif
        }
        // A scan that Open Food Facts can't resolve would otherwise be a dead end now that the "New
        // food" button is gone, so the manual editor stays reachable as the fallback for exactly that
        // case — offered only when it's actually needed, rather than sitting in the way permanently.
        .alert("No match found", isPresented: $scanNotFound) {
            Button("Enter by hand") { showNewFoodSheet = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Open Food Facts has no product for that barcode.")
        }
        .sheet(isPresented: $showPhotoScanCamera) {
            #if os(iOS)
            CameraCaptureScreen { data in
                Task { await scanPhoto(data) }
            }
            #endif
        }
        .onChangeCompat(of: photoScanPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                await MainActor.run { photoScanPickerItem = nil }
                if let data { await scanPhoto(data) }
            }
        }
        .alert("Couldn't scan photo", isPresented: Binding(
            get: { photoScanError != nil }, set: { if !$0 { photoScanError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoScanError?.errorDescription ?? "")
        }
    }

    /// Downscales the captured/picked photo (full-res phone photos are several MB — 1024px is plenty
    /// for the model to identify a plate of food, and keeps the per-scan token cost small), sends it
    /// to Claude, and on a hit saves the estimate into the library and selects it — the same outcome
    /// `selectOnline`/`lookupBarcode` already produce, just fed by an AI estimate instead of a lookup.
    private func scanPhoto(_ rawData: Data) async {
        photoScanning = true
        defer { photoScanning = false }
        guard let jpeg = AvatarImage.downscaledJPEG(from: rawData, maxDimension: 1024, quality: 0.85) else {
            photoScanError = .decode
            return
        }
        do {
            let scanned = try await FoodPhotoScanClient.scan(imageData: jpeg)
            let item = FoodItemRow(
                id: UUID().uuidString,
                deviceId: WhoopStore.foodLogSourceId,
                name: scanned.name,
                kcalPer100g: scanned.kcalPer100g,
                proteinPer100g: scanned.proteinPer100g,
                carbsPer100g: scanned.carbsPer100g,
                fatPer100g: scanned.fatPer100g,
                barcode: nil,
                createdAt: Int(Date().timeIntervalSince1970)
            )
            await repo.saveFoodItem(item)
            selectedFood = item
            quantityText = Self.trimmed(scanned.estimatedGrams)
        } catch let e as FoodPhotoScanError {
            photoScanError = e
        } catch {
            photoScanError = .network(error.localizedDescription)
        }
    }

    /// Resolves a scanned barcode against Open Food Facts and, on a hit, saves it into the library and
    /// selects it — the same one-tap outcome as picking an online search result.
    private func lookupBarcode(_ code: String) async {
        guard let product = await OpenFoodFactsClient.lookup(barcode: code) else {
            scanNotFound = true
            return
        }
        selectOnline(product)
    }

    // MARK: - Food picker (search the library and, inline, Open Food Facts)

    private var foodPicker: some View {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 8) {
            field("Food") {
                HStack(spacing: 8) {
                    TextField(openFoodFactsEnabled ? "Search your foods or online" : "Search your food library",
                              text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: inputShape)
                        .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onChangeCompat(of: searchQuery) { newValue in
                            Task { await search(newValue) }
                            scheduleOffSearch(newValue)
                        }
                        .task { await search("") }
                    // Scanning resolves against Open Food Facts, so it's only offered when that's on —
                    // same condition the online results below use. VisionKit's live scanner is iOS-only
                    // (`BarcodeScannerScreen` is behind the same guard), so macOS never shows the button.
                    #if os(iOS)
                    if openFoodFactsEnabled { scanButton }
                    if photoScanning {
                        ProgressView().frame(width: 42, height: 40)
                    } else {
                        photoScanButton
                    }
                    #endif
                }
            }
            if !searchResults.isEmpty {
                resultsList(title: openFoodFactsEnabled && !offResults.isEmpty ? "Your foods" : nil) {
                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { idx, food in
                        Button { selectedFood = food } label: {
                            resultRow(name: food.name, kcalPer100g: food.kcalPer100g)
                        }
                        .buttonStyle(.plain)
                        if idx < searchResults.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
            if openFoodFactsEnabled && !trimmedQuery.isEmpty {
                onlineResultsSection
            }
        }
    }

    /// Barcode scan, sitting directly beside the search field: the fastest path to a packaged food is
    /// its barcode, not typing its name. A hit is saved into the library and selected in one step, the
    /// same as tapping an online search result.
    private var scanButton: some View {
        Button {
            showScanner = true
        } label: {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 42, height: 40)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan a barcode")
    }

    /// AI photo scan, sitting beside the barcode button: point the camera at a plate (or pick an
    /// existing photo) and Claude estimates what's on it. Offered regardless of the Open Food Facts
    /// toggle — it's a separate, bring-your-own-key feature, not an OFF lookup.
    private var photoScanButton: some View {
        Button {
            showPhotoScanSourcePicker = true
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 42, height: 40)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan a food photo with AI")
        .confirmationDialog("Scan food photo", isPresented: $showPhotoScanSourcePicker, titleVisibility: .visible) {
            Button("Take Photo") { showPhotoScanCamera = true }
            Button("Choose from Library") { showPhotoLibraryPicker = true }
        }
        .photosPicker(isPresented: $showPhotoLibraryPicker, selection: $photoScanPickerItem, matching: .images)
    }

    @ViewBuilder
    private var onlineResultsSection: some View {
        if !offResults.isEmpty {
            resultsList(title: "Online") {
                ForEach(Array(offResults.enumerated()), id: \.offset) { idx, product in
                    Button { selectOnline(product) } label: {
                        resultRow(name: product.name, kcalPer100g: product.kcalPer100g,
                                  isSaving: savingProduct == product)
                    }
                    .buttonStyle(.plain)
                    .disabled(savingProduct != nil)
                    .onAppear {
                        if idx == offResults.count - 1 { loadMoreOffResults() }
                    }
                    if idx < offResults.count - 1 { Divider().opacity(0.4) }
                }
                if offSearching && !offResults.isEmpty {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 8)
                }
            }
        } else if offSearching {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 12)
        }
    }

    private func resultsList<Content: View>(title: String?, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).strandOverline()
            }
            VStack(spacing: 0) { rows() }
                .padding(.horizontal, 12)
                .background(StrandPalette.surfaceInset, in: inputShape)
                .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
    }

    private func resultRow(name: String, kcalPer100g: Double?, isSaving: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            if isSaving {
                ProgressView().controlSize(.small)
            } else if let kcalPer100g {
                Text("\(Int(kcalPer100g.rounded())) kcal/100g")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
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

    /// Debounced Open Food Facts search for the same query box, so results appear inline instead of
    /// requiring the separate "New food" sheet. Resets pagination on every new query.
    private func scheduleOffSearch(_ query: String) {
        offSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard openFoodFactsEnabled, trimmed.count >= 2 else {
            offResults = []; offHasMore = false; offSearching = false
            return
        }
        offSearchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            offSearching = true
            offPage = 1
            let page = await OpenFoodFactsClient.search(query: trimmed, page: 1)
            guard !Task.isCancelled else { return }
            offResults = page.products
            offHasMore = page.hasMore
            offSearching = false
        }
    }

    /// Fetches the next page and appends — triggered by the last online row's `onAppear`, so scrolling
    /// to the bottom of what's loaded keeps loading more rather than dead-ending at the first page.
    private func loadMoreOffResults() {
        guard offHasMore, !offSearching else { return }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        offSearching = true
        Task {
            let nextPage = offPage + 1
            let page = await OpenFoodFactsClient.search(query: trimmed, page: nextPage)
            offPage = nextPage
            offResults += page.products
            offHasMore = page.hasMore
            offSearching = false
        }
    }

    /// Saves an online result straight into the food library and selects it — the one-tap path the
    /// separate "New food" → OFF-search → "Add" round trip used to require.
    private func selectOnline(_ product: OpenFoodFactsClient.Product) {
        guard savingProduct == nil else { return }
        savingProduct = product
        Task {
            let item = FoodItemRow(
                id: UUID().uuidString,
                deviceId: WhoopStore.foodLogSourceId,
                name: product.name,
                kcalPer100g: product.kcalPer100g,
                proteinPer100g: product.proteinPer100g,
                carbsPer100g: product.carbsPer100g,
                fatPer100g: product.fatPer100g,
                barcode: product.barcode,
                createdAt: Int(Date().timeIntervalSince1970)
            )
            await repo.saveFoodItem(item)
            selectedFood = item
            savingProduct = nil
        }
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
