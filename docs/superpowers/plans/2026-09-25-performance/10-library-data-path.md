# Task 10: In-Memory Library Data Path

**Wave:** 1 · **Depends on:** 00 · **Branch:** `perf/10-library-data-path` · **Size:** L

**Goal:** Filter clicks, sort toggles, search keystrokes, rating and tag changes, and moving to or from the bin should cost under 20 ms at 10k photos instead of 340–440 ms. Two changes get there:
- stop re-fetching from SwiftData on every interaction;
- run filtering, search and counts over plain-value snapshots instead of model objects.

**Why:** spec §A1–§A4 and §G3. At 10k photos `applyFilter` costs 386–445 ms, while the same filter in memory costs 7 ms over models and about 1 ms over plain values.

## Files

- Create: `Phocasa/Phocasa/Library/PhotoQuery.swift`, containing `FilterCategory`, `SidebarFilter` (moved out of the view model), `PhotoFacts`, `FacetCounts` and `PhotoQuery`
- Modify: `Phocasa/Phocasa/ViewModels/PhotoLibraryViewModel.swift`, **only these regions**:
  - the `SidebarFilter` enum (move it out);
  - the stored properties related to photos, tags and counts;
  - `// MARK: - Data Loading`, `recomputeSidebarCounts`, `updateSidebarAfterChange`;
  - `// MARK: - Rating`, `// MARK: - Selection`, `// MARK: - Deletion / Bin`, `// MARK: - Tags` (except `findOrCreateTag`, which task 20 owns), `// MARK: - Filtering`, `// MARK: - Sorting`, `// MARK: - Navigation`, `// MARK: - Grid Keyboard Navigation`, `// MARK: - Keyboard Rating Helper`, `// MARK: - Lightweight Tag Refresh`.
- Modify: `Phocasa/Phocasa/Views/ContentView.swift` (search debounce, `firstSelectedPhoto`)
- Modify: `Phocasa/Phocasa/Views/SidebarView.swift` (use precomputed tag groups)
- Modify: `Phocasa/PhocasaTests/ViewModelTests.swift`
- Create: `Phocasa/PhocasaTests/PhotoQueryTests.swift`
- Modify: `Phocasa/PhocasaTests/PerformanceBenchmarks.swift` (add benchmark lines only)

**Don't touch:**
- `scanFolder`, `rescanCurrentLibrary`, `handleFolderSelected`, `setModelContext`, `findOrCreateTag` (task 20);
- `checkFileAvailability`, `refreshAvailability`, `missingPhotoIDs`, `needsAvailabilityCheck` (keep calling them exactly as today; task 20 owns them). **One exception:** `refreshAvailability()` calls `applyActiveFilters()`, which you delete. Replace that single call with whatever keeps its behaviour (for example nothing, if `loadExistingData()` already ends in `refreshVisiblePhotos()`), and change nothing else there;
- `clearRAWSidecarEdits` and `revertEditsForPhoto`, which sit inside `// MARK: - Tags` but belong to editing (task 22);
- the editing calls inside `navigateDetail` (`saveCurrentEditParameters`) and `closeDetail` (`stopEditing`): keep them exactly as they are;
- everything under `// MARK: - Image Editing` and below, including crop, export and presets (tasks 13 and 22);
- `metadataWriteItem(for:)` and `writeMetadataInBackground(_:)`: call them, don't edit them (task 14);
- `PhotoGridView`, `PhotoGridItemView`, `PhotoDetailView` (tasks 11 and 12).

## Interfaces

- **Produces (later tasks rely on these exact names):**
  ```swift
  enum FilterCategory: Hashable, Sendable { case special, rating, fileType, tag }

  enum SidebarFilter: Hashable, Sendable {          // same cases as today
      case all, unrated, rated(Int), tag(UUID), tagCategory(String), bin, jpgOnly, rawOnly
      var category: FilterCategory { get }            // replaces the String `filterCategory`
      func matches(_ facts: PhotoFacts) -> Bool
  }

  /// Plain-value snapshot of what filtering, search and counting read.
  struct PhotoFacts: Equatable, Sendable {
      let id: UUID
      var rating: Int
      var hasJPG: Bool
      var hasRAW: Bool
      var tagIDs: Set<UUID>
      var tagCategories: Set<String>      // non-empty categories of the photo's tags
      var searchKey: String               // lowercased fileName, tag names, tag categories, "\n"-joined
      @MainActor init(_ photo: PhotoAsset)
      init(id: UUID, rating: Int, hasJPG: Bool, hasRAW: Bool,
           tagIDs: Set<UUID>, tagCategories: Set<String>, searchKey: String)
  }

  struct FacetCounts: Equatable, Sendable {
      var ratings: [Int: Int] = [:]
      var tags: [UUID: Int] = [:]
      var categories: [String: Int] = [:]
      var jpg = 0
      var raw = 0
  }

  struct PhotoQuery: Equatable, Sendable {
      var filters: Set<SidebarFilter> = []
      var searchText: String = ""
      func matches(_ facts: PhotoFacts) -> Bool                    // filters AND search
      func matchesFilters(_ facts: PhotoFacts, ignoring: FilterCategory? = nil) -> Bool
      func matchesSearch(_ facts: PhotoFacts) -> Bool
      func facetCounts(over facts: [PhotoFacts]) -> FacetCounts
  }
  ```
- **New view-model API:**
  ```swift
  private(set) var tagsByCategory: [String: [Tag]]    // tags sorted by name within each category
  func index(of id: UUID) -> Int?                      // position in `photos`, O(1)
  var primarySelectedPhoto: PhotoAsset? { get }        // the photo Space/Return should open
  ```
  `id` is `PhotoAsset.id`, the `UUID` attribute. Don't use `PhotoAsset.ID`: SwiftData's `PersistentModel` also provides an `id` of type `PersistentIdentifier`.
- **Must stay source-compatible** (views and other tasks read them):
  - `photos`, `allPhotos`, `selectedPhotos`, `lastSelectedId`, `activeFilters`, `viewingBin`, `binCount`;
  - `ratingCounts`, `categoryCounts`, `tagCounts`, `jpgCount`, `rawCount`;
  - `allTags`, `tagCategories`, `uncategorizedTags`, `searchText`, `searchSuggestions`, `selectedPhotosList`, `hasFileTypeFilter`;
  - `loadExistingData()`, `applyFilter(_:isShiftHeld:)`, `applyCurrentFilter()`, `applySearch()`;
  - every mutation method (`setRating`, `setRatingForSelection`, `addTag`, `addTagToSelection`, `removeTag`, `toggleTag`, `moveToBin` via `deleteSelected`/`deletePhoto`, `restoreFromBin`, `restoreSelected`, `confirmPermanentDelete`, `emptyBin`);
  - `navigateDetail`, `navigateGrid`, `rangeSelect`, `toggleSelection`, `selectAll`, `clearSelection`, `toggleSortOrder`, `refreshAvailability()`.

## Semantics to preserve

These are today's behaviour; the tests encode most of them.

- **Filters:** OR within a category, AND across categories. `.all` and `.bin` are "special" and never exclude photos. Clicking a filter without Shift replaces filters of the same category; with Shift it toggles.
- **Search:** case-insensitive `contains` over the file name, tag names and tag categories. Search also applies in the bin view. (Today, *clicking* Bin doesn't apply existing search text until the next keystroke; applying it consistently is fine, but note it as a deviation.)
- **Counts** are always computed over the non-binned, available photos (`allPhotos`) and **ignore search**.
  - No filters: plain counts.
  - With filters: faceted. Rating counts use photos matching every filter *except* rating ones; tag and category counts exclude tag filters; JPG/RAW counts exclude file-type filters.
  - A category counts at most once per photo.
- **Sort:** by `creationDate`, newest first by default. Toggling reverses. Reversing the arrays in memory is acceptable, even though ties may reorder.
- `tagCategories` is sorted by `categoryCounts` (descending), then by name. `allTags` is sorted by `(category, name)`.
- `binCount` is the number of photos in the bin.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite and the 10k benchmarks (README). Record lines `1`, `3a`–`3d`, `4`, `5a`, `5b`.

- [ ] **Step 2: Write `PhotoQueryTests` first** (pure, no SwiftData). Build facts with the memberwise initializer. Cover at least:
  - `testEmptyQueryMatchesEverything`
  - `testRatingFiltersAreORWithinCategory`: `[.rated(3), .rated(5)]` matches 3 and 5 but not 4
  - `testDifferentCategoriesAreANDed`: `[.rated(3), .jpgOnly]`
  - `testSpecialFiltersNeverExclude`: `[.all]` and `[.bin]` match everything
  - `testTagAndTagCategoryFilters`
  - `testSearchMatchesFileNameTagNameAndCategoryCaseInsensitively`
  - `testSearchDoesNotMatchAcrossFieldBoundaries`: the file name `"ab"` plus tag `"cd"` must not match `"bc"`
  - `testFacetCountsWithoutFiltersArePlainCounts`
  - `testFacetCountsExcludeOwnCategory`: with `[.rated(3)]`, rating counts cover all photos, while tag counts only cover 3-star photos
  - `testCategoryCountedOncePerPhoto`
  - `testFacetCountsIgnoreSearch`

  Run them and watch them fail to compile, since the types don't exist yet.

- [ ] **Step 3: Implement `Library/PhotoQuery.swift`** so the tests pass.
  - Move `SidebarFilter` there and delete it from the view model file.
  - Replace the string `filterCategory` with `category: FilterCategory` and update the view model's uses.
  - `facetCounts` must be a single pass per facet group over `[PhotoFacts]`, with no model access.
  - Commit: `feat: add pure PhotoQuery/PhotoFacts filtering`.

- [ ] **Step 4: Update the existing test contract.** Many `ViewModelTests` insert rows into the context and then call `applyFilter`, `selectAll`, `navigateGrid` and so on, relying on those calls to re-fetch. The new contract:
  > The store is read by `loadExistingData()`, and by scans, which task 20 owns. UI interactions work on the in-memory state. In the app every store change goes through the view model, so nothing is lost.

  - In each affected test, add `viewModel.loadExistingData()` after seeding and before the first interaction.
  - **Don't change any assertion.**
  - Add a test documenting the contract: `testFilterChangesDoNotRefetch` inserts a photo straight into the context *after* `loadExistingData()`, calls `applyFilter(.all)`, and asserts that the photo is **not** in `photos`; then calls `loadExistingData()` and asserts that it is.
  - Run the suite: everything that passed before must still pass.

- [ ] **Step 5: Hold in-memory state in the view model.**
  - `loadExistingData()` stays the **only** method that fetches photos: non-binned photos (minus `missingPhotoIDs`), bin photos, tags and the library. After fetching it:
    - builds `PhotoFacts` for every photo;
    - builds `tagsByCategory`, `uncategorizedTags` and `tagCategories`;
    - calls a new `private func refreshVisiblePhotos()`.
  - Keep facts in arrays that line up with `allPhotos` and `binPhotos`. Hot paths must **never** read model properties. `$0.id` on a model costs as much as any other property read (≈0.8 µs); that's the whole point (spec §A1).
  - `refreshVisiblePhotos()` builds the query from `activeFilters` + `searchText`, picks the source (`binPhotos` when `viewingBin`, otherwise `allPhotos`), filters it through the aligned facts into `photos`, and rebuilds the `[UUID: Int]` index of `photos`. Counts come from `query.facetCounts(over: allFacts)`, assigned to `ratingCounts`, `tagCounts`, `categoryCounts`, `jpgCount` and `rawCount`.
  - `applyFilter`, `applyCurrentFilter`, `applySearch` and `toggleSortOrder` call `refreshVisiblePhotos()` and **never** `loadExistingData()`. `toggleSortOrder` reverses the arrays in memory. Delete `applyActiveFilters`, `applyFilterGroup`, `recomputeCrossFilterCounts` and `recomputeSidebarCounts`; the query replaces them.
  - Commit: `perf: filter, search and sort in memory without refetching`.

- [ ] **Step 6: Update mutations in memory.** For each mutation below, write or adjust a test first.
  - **Ratings and tags:** `setRating`, `setRatingForSelection`, `addTag`, `addTagToSelection`, `removeTag`, `toggleTag` mutate the model, save, update the facts of the changed photos, then call `refreshVisiblePhotos()`. If a tag was created, also update the tag lists. Keep calling `writeMetadataInBackground(...)` exactly as today.
  - **Bin moves:** `moveToBin` and `restoreFromBin` move photos between `allPhotos` and `binPhotos` (and their facts) in memory, keeping creation-date order (binary insert), then call `refreshVisiblePhotos()`.
    - Test `testMoveToBinAndRestoreKeepOrder`.
    - A restored photo shows up even if it was binned before the last availability check (see the existing `testRestoringPhotoBinnedBeforeAvailabilityCheckShowsIt`).
  - **Rare operations:** `confirmPermanentDelete`, `emptyBin` and `deleteFileTypeOnly` may still call `loadExistingData()`. `emptyBin()` currently runs its own `FetchDescriptor` for bin photos; use the in-memory `binPhotos` instead.
  - Commit: `perf: apply rating, tag and bin mutations in memory`.

- [ ] **Step 7: O(1) lookups.**
  - Implement `index(of:)` from the index built in `refreshVisiblePhotos()`.
  - Use it in `navigateDetail`, `rangeSelect` and `navigateGrid`.
  - `selectedPhotosList` becomes `selectedPhotos.compactMap(index(of:)).sorted().map { photos[$0] }`: O(k log k), and still in grid order.
  - Add `primarySelectedPhoto`: `lastSelectedId` if it is selected, otherwise the selected photo with the lowest index.
  - Tests: `testIndexOfTracksFiltering`, `testSelectedPhotosListInGridOrder`, `testPrimarySelectedPhotoPrefersLastSelected`.

- [ ] **Step 8: Views.**
  - **`ContentView`:**
    - Replace `.onChange(of: viewModel.searchText) { viewModel.applyCurrentFilter() }` with a SwiftUI-native debounce:
      ```swift
      .task(id: viewModel.searchText) {
          try? await Task.sleep(for: .milliseconds(150))
          guard !Task.isCancelled else { return }
          viewModel.applyCurrentFilter()
      }
      ```
    - `firstSelectedPhoto` returns `viewModel.primarySelectedPhoto` (fixes spec §G3).
  - **`SidebarView`:** replace `viewModel.allTags.filter { $0.category == category && $0.parent == nil }` with `viewModel.tagsByCategory[category] ?? []`. Leave the `tag.children` rows in place; task 31 removes the hierarchy.
  - **`searchSuggestions`:** cache the lowercased tag names and categories when the tag lists change, instead of lowercasing them on every call.

- [ ] **Step 9: Benchmarks.**
  - Add lines to the `runSuite` benchmark: `8a moveToBin single photo`, `8b restoreFromBin single photo`, `8c setRatingForSelection 50 photos`.
  - Run the 10k benchmarks and fill in the table below in your results file.

- [ ] **Step 10: Full suite, warnings check, results file, commit.**

## Acceptance criteria

At N=10k, in a Debug build, median of 5 runs:

| Benchmark line | Before | Target |
|---|---|---|
| `3a applyFilter(.rated(3))` | 386–421 ms | **≤ 20 ms** |
| `3b applyFilter(.tag)` | 428–445 ms | **≤ 20 ms** |
| `3c applyFilter(.all)` | 340–347 ms | **≤ 20 ms** |
| `3d toggleSortOrder()` | 339–345 ms | **≤ 20 ms** |
| `4` search keystroke | 380–398 ms | **≤ 20 ms** |
| `5a`/`5b` setRating | 53–102 ms | **≤ 10 ms** |
| `8a`/`8b` bin move/restore | n/a | **≤ 10 ms** |
| `1 loadExistingData()` | 341–346 ms | no worse than +10% (it still does a full fetch) |

- All existing assertions are unchanged and pass. The new tests pass. No new warnings.
- `grep -n "loadExistingData()" PhotoLibraryViewModel.swift` shows calls only in `setModelContext`, `refreshAvailability`, `scanFolder`, `confirmPermanentDelete`, `emptyBin`/`deleteFileTypeOnly` and `loadExistingData` itself.

## Out of scope and follow-ups

- Availability and scan behaviour (task 20).
- Splitting the view model into separate types (task 30). Keep your new state grouped under clear `// MARK:` sections so that split is mechanical.
- `PhotoGridView`'s context menu still filters `allTags` per category. Task 30 switches it to `tagsByCategory`.
