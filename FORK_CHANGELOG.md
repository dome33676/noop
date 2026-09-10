# Fork changelog (dome33676/noop)

Technical changelog for this fork's own work on top of upstream NOOP. Written for an AI coding
agent (or a future session of this one) picking up context cold — each entry names the files/types
touched and the *why*, not just the user-facing description. Newest first. Commit hashes are on
`main` in this repo; `git show <hash>` for the full diff.

Upstream's own `CHANGELOG.md` (release notes with issue numbers) is a separate, pre-existing file —
do not merge entries between the two.

---

## `f06c670e` — Add FORK_CHANGELOG.md and a post-commit hook that keeps it in sync (2026-09-10)

Technical, AI-readable changelog of this fork's own work on top of upstream
NOOP (upstream's own CHANGELOG.md is separate release notes, left untouched).
.githooks/post-commit appends every subsequent commit's hash/subject/body to
it and pushes automatically, so the changelog never drifts from what's
actually on main without a manual step.

---

## `befa309d` — Suggest last-used weight/reps when adding exercises to a template

**Files:** `Strand/Training/ProgressionSuggestion.swift`, `Strand/Training/TemplateEditorView.swift`

- Added `ProgressionCalculator.lastSessionSets(from sets: [StrengthSetRow]) -> [StrengthSetRow]`:
  groups by `sessionId`, returns the most recent session's sets sorted by `setIndex`. Unlike
  `ProgressionCalculator.suggest(from:)` (which drops warm-ups and only projects one working-set
  weight), this returns every set as actually logged, reps included.
- `TemplateEditorView` now has `@EnvironmentObject private var repo: Repository` (it had none
  before) and `@State private var lastSets: [String: [StrengthSetRow]]`, keyed by exercise name.
  Loaded on `.task` for every exercise already in `plan` (editing an existing template), and on
  `ExercisePickerSheet`'s completion closure for a freshly-added one.
- A freshly-added exercise's `TemplateSetPlan` array is now seeded from `lastSessionSets` (one
  `TemplateSetPlan` per historical set, `targetReps`/`targetWeightKg` copied over) instead of a
  single empty set — only on add, never overwriting an existing plan's already-typed values.
- Every exercise card shows a persistent `"Last time: 10 reps @ 60.0 kg, 8 reps @ 60.0 kg"` caption
  (`lastTimeHint(for:)`), so the reference stays visible even after the user edits the fields away
  from the prefilled values.
- Exercise identity is a plain name string end to end — same space `Repository.strengthSets(exerciseName:)`,
  `CustomExerciseStore`, and `ProgressionCalculator` already use — so this works identically whether
  the exercise was last logged under a *different* template or none at all. This was the actual bug
  being fixed: suggestions previously only existed in the live-workout screen (`ActiveTrainingController`),
  never in the template editor.

---

## `b4af7783` — Add Edit button to already-selected food in LogMealSheet

**Files:** `Strand/Food/LogMealSheet.swift`

- `FoodItemEditorSheet` was only ever opened with `editing: nil` (brand-new items via "Enter by
  hand"/barcode-not-found fallback) — there was no UI path to reopen it for an item already in the
  food library, so a previously-logged food could never get a serving size or custom portion added
  after the fact.
- Added `@State private var showEditFoodSheet = false` + a `.sheet` presenting
  `FoodItemEditorSheet(editing: selectedFood) { item in Task { await repo.saveFoodItem(item); selectedFood = item } }`,
  and an "Edit" button next to the existing "Change" button in `selectedFoodRow(_:)`.

---

## `1710fcd2` — Restyle Stress Monitor as a sparkline tile; add custom food portions

**Files:** `Strand/Screens/TodayView.swift`, `Strand/Liquid/LiquidTodayView.swift`,
`Strand/Food/FoodPortion.swift` (new), `Strand/Food/FoodItemEditorSheet.swift`,
`Packages/WhoopStore/Sources/WhoopStore/{Database,FoodStore,WhoopStore}.swift`,
`Packages/WhoopStore/Tests/WhoopStoreTests/{ScaffoldTests,MigrationTests}.swift`,
both `schema_oracle.json` copies.

**Stress Monitor restyle:**
- `TodayView.stressMonitorSection` now uses `StatTile` (StrandDesign/Components.swift) instead of a
  `LiquidVessel` gauge — label + one-decimal value + `Sparkline` trend + `"of 3 · <band>"` caption,
  matching every other Key Metric tile's visual language.
- `LiquidTodayView.stressMonitorSection` mirrors this with `Sparkline` (StrandDesign/Sparkline.swift)
  inside its own `card{}` chrome.
- Both add a `"stress"` entry to their respective sparkline-loading dicts (`sparks`/`kSparks`) —
  `TodayView` via `sparkValuesExplore("stress", source: "my-whoop", window: 14)` (so a BLE-only strap's
  computed score still backs the trend line), `LiquidTodayView` by reusing its already-fetched
  `storedStress`.
- Deliberately does NOT touch `dashboardValue(.stress)` / `stressText` — both round to an integer and
  are still used elsewhere (a smaller pinned "Your Cards" row) where that's intentional. The new
  sections use an inline `String(format: "%.1f", ...)` instead.

**Custom food portions (WhoopStore migration v48, schemaVersion 24→25):**
- New `Strand/Food/FoodPortion.swift`: `struct FoodPortion: Codable, Equatable, Identifiable { var label: String; var grams: Double }`
  (app-layer shape, mirrors the `strengthTemplate.planJSON` convention — WhoopStore stores it as an
  opaque `String`, the app layer owns the actual shape). `FoodItemRow.customPortions` decodes it
  (empty array on malformed/absent JSON, never throws); `FoodItemRow.encodePortions(_:)` encodes it.
- `FoodItemRow.customPortionsJSON: String?` added (WhoopStore's `FoodStore.swift`), migration
  `"v48-food-custom-portions"` (`Database.swift`) adds the column, `upsertFoodItem`'s SQL updated
  (11 placeholders now). `WhoopStoreInfo.schemaVersion = 25`. Both hardcoded test assertions
  (`ScaffoldTests`, `MigrationTests`) and both `schema_oracle.json` copies updated in lockstep — this
  project's standard migration checklist.
- `FoodItemEditorSheet` gained a `myPortionsSection`: list of existing `customPortions` with
  remove buttons, plus an inline add-new-portion form (label + grams + "+"). Validated via
  `newPortionIsValid` (non-empty label, valid positive grams, no case-insensitive duplicate label).
  Additive to the pre-existing OFF-scanned `servingSizeG` — never overwrites it.

---

## `56df80e9` — Fix Journal card vanishing after cold launch and morning prompt never firing

**Files:** `Strand/Screens/JournalReminderCard.swift`, `StrandiOS/App/RootTabView.swift`

- **Root cause 1:** `JournalReminderCard` used `.task(id: JournalReminderLoadKey(seq: repo.refreshSeq, enabled: reminderEnabled))`.
  SwiftUI's `.task(id:)` **cancels and restarts** on every id change, and `repo.refreshSeq` bumps
  several times in quick succession during a cold launch (multiple sequential sync/backfill passes).
  Each bump cancelled the in-flight read before `loggedDays` could ever be assigned, so the card
  silently never rendered. Fixed by keying `.task(id: reminderEnabled)` only (stable across a
  session) plus a separate `.onChangeCompat(of: repo.refreshSeq)` that reloads without cancelling
  work already in flight. Removed the now-unused `JournalReminderLoadKey` struct. **General gotcha
  worth remembering:** `.task(id:)` is for "restart when this changes," never for "also refresh when
  this changes" — those need two different mechanisms.
- **Root cause 2:** `RootTabView.checkJournalWakePrompt()` read `repo.sleepSessions(from:to:)`, which
  only covers the IMPORTED source. A Bluetooth-only strap with no WHOOP/Apple-Health import banks
  sleep under the COMPUTED source instead, so the read was always empty and the guard failed on
  every check. Switched to `repo.allSleepSessions(days:)`, which unions both sources. **General
  gotcha:** `sleepSessions(from:to:)` vs `allSleepSessions(days:)` — the former is import-only, the
  latter is what "did the user actually sleep" should almost always mean.

---

## `ae31233a` — Backfill existing exercise names into the global custom exercise list

**Files:** `Strand/Training/CustomExerciseStore.swift`, `Strand/Training/TrainingView.swift`

- `CustomExerciseStore.backfillIfNeeded(repo:)`: one-time scan (UserDefaults flag gate) of every
  exercise name already present in logged sets + saved template plans, inserted into the store so
  names typed *before* `CustomExerciseStore` existed are remembered too. Wired into
  `TrainingView`'s `.task` alongside `reload()`/`reloadTemplates()`.

---

## `96b9d04e` — Global exercise library, food portions + macro detail, Workouts-tab start flow on Today

The commit that answered this fork's "global exercise DB / food portions / food macro detail /
Start Workout redesign" request. Everything above this entry is follow-up work.

**Global exercise names:** `CustomExerciseStore` (UserDefaults-backed) introduced; merged into
`ExercisePickerSheet`'s suggestions everywhere an exercise gets picked (live-add during a workout,
building a template, the backfill above). Stats were already aggregated globally by exact
`exerciseName` string (`Repository.strengthSets(exerciseName:)` reads across ALL sessions/templates,
no template-scoping ever existed at the data layer) — the actual problem this fixed was names
fragmenting because retyping a name slightly differently each time meant the (already-global) stats
query never matched prior entries. Consistent naming is what this feature actually buys.

**Food serving size (WhoopStore migration v47, schemaVersion → 24):** `FoodItemRow.servingSizeG: Double?`,
auto-filled from Open Food Facts' `serving_quantity` on scan/search (`OpenFoodFactsClient.swift`),
editable by hand otherwise. `LogMealSheet` gained a Grams/Portions `SegmentedPillControl` toggle
(only shown when `servingSizeG` is set), converting to grams for storage either way — this is the
2-way toggle that `1710fcd2`'s and later `befa309d`'s work generalized/built on top of.

**Food macro detail:** tapping a logged meal (or the live log-sheet) now shows Kcal/Protein/Carbs/Fat
for the *entered quantity*, not just grams + timestamp — previously those macros only ever appeared
as a whole-day total at the top of the Food tab.

**Today's "Start Workout" → Workouts-tab flow:** Today's Start Workout button now opens
`WorkoutSelectionScreen` (the same sport-catalogue + "My Templates" browser the Workouts tab's own
button presents) instead of a separate, narrower `StartSessionPickerSheet` (deleted, now dead code
at the time). A sport choice behaves identically to starting one from Workouts; a template choice
lands in the same `ActiveTrainingView` flow the Training tab uses (`TrainingLauncher.swift`'s
`startTraining(from:repo:into:)` / `.activeTrainingCover(item:repo:model:)`).

**⚠️ Known regression, not yet addressed:** this removed the plain "Live Session" (silent HR-only
guardian, no exercise logging) entry point from Today — its only other reachable spot in the app was
this exact button. If a user needs that mode reachable from Today again, it should be added back as
a third choice alongside "browse sports" / "pick a template."

---

## Conventions this fork follows (for whoever/whatever picks this up next)

- **This file updates itself.** `.githooks/post-commit` appends an entry here (hash, subject, full
  body) after every commit and pushes automatically — no manual "update the changelog" step needed.
  One-time setup per clone: `git config core.hooksPath .githooks` (git doesn't pick up a repo's
  hooksPath on its own; this has already been run in the current working copy).
- **No local Xcode.** All verification is via GitHub Actions
  (`.github/workflows/fork-testing-build.yml`) — `gh workflow run` → `gh run watch`/`gh run view` →
  download the built `.ipa` from `https://raw.githubusercontent.com/dome33676/noop/altstore-source/NOOP-latest.ipa?nocache=<build>`
  and inspect `Info.plist` (`CFBundleVersion`) to confirm the live build actually matches what was
  pushed.
- **GRDB migration checklist** (WhoopStore): add the migration in `Database.swift`
  (`migrator.registerMigration("vNN-slug") { db in try db.alter(table:) { ... } }`), bump
  `WhoopStore.schemaVersion`, update the exactly-2 hardcoded test assertions (`ScaffoldTests.swift`,
  `MigrationTests.swift`), and update **both** `schema_oracle.json` copies
  (`Packages/WhoopStore/Tests/WhoopStoreTests/Resources/` and `android/app/src/test/resources/`) —
  verify byte-identical with `diff` after editing.
- **German-locale decimals**: every free-text numeric field normalizes comma → period before
  `Double(...)` parsing (`text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")`).
  Mandatory convention across the whole app now, not just wherever it was first added.
- Untracked `hive/`, `roster-backups/`, `roster.json` at the repo root are unrelated to this app and
  must never be `git add`ed.
