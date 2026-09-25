# Task 31: Schema Cleanup

**Wave:** 3B (in parallel with 32, 33, 35) · **Depends on:** 30 merged · **Branch:** `perf/31-schema-cleanup` · **Size:** S

**Goal:**
- Rename `PhotoAsset.isDeleted` to `isInBin`, since it hides `PersistentModel.isDeleted`.
- Remove the dead `thumbnailData` field and the unused `Tag` parent/children hierarchy.
- Prove with a test that existing stores migrate without data loss.

**Why:** spec §H4 and §H5, and `results/10.md` deviation 12: reading `isDeleted` after a `save()` can be stale,
because the key collides with Core Data's own `isDeleted`.

> **Data safety:** this task changes the persisted schema of the user's library.
> - Never open the real store (`~/Library/Application Support/default.store*`).
> - All migration testing uses temp stores created by the test.
> - The user decided the coordinator **merges without pausing** and reminds them, in its final report, to back up
>   `~/Library/Application Support/default.store*` before they run the new build normally. Put that reminder in your
>   results file too.

## Coordination with the other wave-3B tasks

- **Task 33 adds `PhotoAsset.captureDate`** (and maybe a second optional attribute) at the same time. Both of you edit
  `Models/PhotoAsset.swift`.
  - Change only your lines: the rename, and the `thumbnailData` removal.
  - Your migration test's "current schema" is the live model classes. After both merge, it covers V1 → final
    (rename + removals + new optional attributes).
  - Don't add a `captureDate` yourself.
- **Your rename touches files other tasks change:**
  - task 32's `LibraryStore+Loading.swift`, `LibraryStore+Scan.swift`, `ScanPlan.swift` and `PerformanceBenchmarks.swift`;
  - `ViewModelTests`, `LibraryStoreTests` and others.

  The coordinator merges you **first** in wave 3B, then re-applies the rename to the others' conflicting hunks. Keep
  the rename mechanical, with no other edits in those files, so that's easy. List every file you touched in your
  results.

## Files

- Modify: `Phocasa/Phocasa/Models/PhotoAsset.swift` (rename and removal only), `Phocasa/Phocasa/Models/Tag.swift`.
- Modify: every `isDeleted` call site that means the bin flag
  (`grep -rn "isDeleted" Phocasa/Phocasa Phocasa/PhocasaTests`), including the `#Predicate`s, `StoredPhoto.fetchAllNow`,
  `applyScanUpdates` and the benchmark harness.
- Modify: `Phocasa/Phocasa/Views/SidebarView.swift` (remove the child-tag rows).
- Create: `Phocasa/PhocasaTests/MigrationTests.swift`.
- Possibly create: `Phocasa/Phocasa/Models/Schema.swift` and edit the container in `PhocasaApp.swift`, only if
  automatic migration fails (step 4). Keep the in-memory test-host branch.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite.

- [ ] **Step 2: Failing migration test first** (`MigrationTests`).
  1. In the test file, declare a frozen copy of the **current** models, as they are before your change, as a versioned
     schema. Keep the class names identical so the entity names match.
     ```swift
     enum PhocasaSchemaV1: VersionedSchema {
         static let versionIdentifier = Schema.Version(1, 0, 0)
         static var models: [any PersistentModel.Type] { [PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self] }
         @Model final class PhotoAsset { /* verbatim copy of today's stored properties */ }
         @Model final class Tag { /* verbatim copy, including parent/children/photos */ }
         @Model final class PhotoLibrary { /* verbatim copy */ }
         @Model final class EditPreset { /* verbatim copy */ }
     }
     ```
  2. `testV1StoreMigratesWithoutDataLoss`:
     1. Create a temp store URL.
     2. Open it with `ModelContainer(for: Schema(versionedSchema: PhocasaSchemaV1.self), configurations: ModelConfiguration(url: url))`.
     3. Insert:
        - 3 photos: one in the bin, one rated 4 with 2 tags, one with `jpgEditParametersData` and `thumbnailData` set;
        - a tag with a child tag;
        - a library;
        - a preset.
     4. Save, then release the container and its context.
     5. Reopen the **same URL** with the app's current schema:
        `Schema([Phocasa.PhotoAsset.self, Phocasa.Tag.self, Phocasa.PhotoLibrary.self, Phocasa.EditPreset.self])`.
     6. Assert:
        - the counts are equal;
        - the binned photo has `isInBin == true` and the others `false`;
        - the rating and tag relationships are intact;
        - the edit parameters decode;
        - the library and preset survive.
  3. Also test that the bin flag reads correctly **straight after a `save()`**, with no refetch. Task 10's deviation 12
     is the stale-read bug.

  The test won't compile until `isInBin` exists; that's the expected failure.

- [ ] **Step 3: Make the model changes.**
  - `PhotoAsset`: `@Attribute(originalName: "isDeleted") var isInBin: Bool`. Delete `thumbnailData`.
  - `Tag`: delete `parent` and `children`, and drop the `parent` parameter from `init`. Keep the `photos` inverse.
  - Update every call site and predicate, e.g. `#Predicate { !$0.isInBin }`, and every test. Tests that worked around
    the stale read (`storedBinIDs()` through a separate context) may now assert on the property directly; keep their
    assertions.
  - `SidebarView`: remove the `ForEach(tag.children…)` rows.

- [ ] **Step 4: Run the migration test.**
  - If SwiftData's automatic lightweight migration passes it, you're done.
  - If it fails:
    1. Add `Models/Schema.swift` with `PhocasaSchemaV1`, holding the frozen old models (move the test's copy there and
       reuse it from the test), and `PhocasaSchemaV2` for the current models.
    2. Add `enum PhocasaMigrationPlan: SchemaMigrationPlan` with
       `.lightweight(fromVersion: PhocasaSchemaV1.self, toVersion: PhocasaSchemaV2.self)`.
    3. Create `PhocasaApp`'s container with `migrationPlan: PhocasaMigrationPlan.self`, and keep the in-memory
       test-host branch.
    4. Re-run the test.
  - If you need a migration plan, say so prominently in your results. Task 33's new optional attributes then land in
    V2 after both merge, and the coordinator re-runs `MigrationTests` on merged `main`.

- [ ] **Step 5: Full suite, warnings, results file, commit.**

## Acceptance criteria

- `MigrationTests` pass: a V1 store opens with the new schema with every value preserved, and `isInBin` is carried
  over from `isDeleted`.
- `grep -rn "\.isDeleted" Phocasa/Phocasa` finds nothing that refers to the bin flag.
- `thumbnailData`, `Tag.parent` and `Tag.children` are gone.
- Zero new warnings. The full suite passes. No benchmark regresses by more than 5% (the bin lines `8a`/`8b` especially).
- The results file contains the reminder: **back up the user's store before running this build against real data.**
