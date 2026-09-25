# Task 30: Structure and Polish

**Wave:** 3A (in parallel with task 34) · **Depends on:** waves 1–2 merged · **Branch:** `perf/30-structure-and-polish` · **Size:** L

**Goal:**
- Split what remains of `PhotoLibraryViewModel` (about 1,580 lines after wave 2) into focused types. **Lay the files
  out so that wave 3B's four parallel tasks each own separate files.**
- Keep the grid alive underneath the detail view.
- Move file trashing off the main thread.
- Flush pending metadata writes on quit.
- Finish the leftovers the earlier tasks deferred.
- Update `CLAUDE.md` so the next person, or agent, starts from an accurate map.

**Why:** spec §H1, §H2, §G4, §G5, plus the follow-ups in `results/10.md`–`23.md` and `results/wave-2-coordinator.md`.
**Read every `results/*.md` first.**

## Files

You own everything **except task 34's files**, which task 34 changes at the same time:
- `Services/ImageLoader.swift`, `Services/ThumbnailDiskCache.swift`, `Services/MetadataWriter.swift`;
- `ImageLoaderTests`, `ThumbnailDiskCacheTests`, `MetadataWriterTests`, `DetailNavigationBenchmarks`.

Leave `ImageLoader.loadFullResolution(for:)` alone; task 34 removes it. Stay within the items below, and don't
reformat untouched code.

## Target structure (wave 3B depends on it)

The names are guidelines; keep them unless there's a good reason. Each type should be ≤ ~400 lines with one
responsibility. Where a type is larger, split it into **extension files by concern**. Wave 3B's parallel tasks each own
one of these files, so the split is what keeps their merges clean.

```
Library/
  LibraryStore.swift            @Observable @MainActor: model context, the in-memory library state (allPhotos/binPhotos
                                 + facts, counts, tag lists, grid state), index(of:), photosDidChange
  LibraryStore+Loading.swift    loadExistingData(), makeFacts, availability (refreshAvailability, missingPhotoIDs)
                                 → task 32 owns this file in wave 3B
  LibraryStore+Scan.swift       scanFolder/performScan/applyScanUpdates/insertScannedPhotos (task 20's code)
                                 → task 32 owns this file in wave 3B
  LibraryStore+Mutations.swift  rating, tags, bin/restore/delete, relocate/grid patching
  LibrarySort.swift             THE ONE place that defines photo order: the fetch SortDescriptor, the in-memory
                                 insertion key (today `creationDate`), and how toggleSortOrder works
                                 → task 33 owns this file in wave 3B (capture-date sort)
  PhotoQuery.swift, ScanPlan.swift, TagParsing.swift   (existing)
  SelectionModel.swift          @Observable @MainActor: selectedPhotos, lastSelectedId, toggle/range/selectAll/clear,
                                 grid keyboard navigation, primarySelectedPhoto
Services/
  FileTrasher.swift             actor on a DispatchSerialQueue (step 5)
Editing/                         (task 22; unchanged here)
ViewModels/
  PhotoLibraryViewModel.swift   thin coordinator: owns LibraryStore, SelectionModel, editSession; UI flags
                                 (showingDetail, showFolderPicker, sheets, gridColumns); cross-cutting actions
                                 (openDetail, navigateDetail, closeDetail, delete flows, editing entry points)
```

- **One place for the sort key.** Every use of `creationDate` for ordering must go through `LibrarySort`:
  - the two fetch `SortDescriptor`s in `loadExistingData`;
  - `insertionIndex(for:in:)`;
  - the merge in `relocateByMerging`;
  - `toggleSortOrder`.

  That lets task 33 switch to capture date in one file.
- **Views** access `viewModel.library.…` and `viewModel.selection.…` directly. Update the call sites instead of adding
  forwarding properties. A few forwarding properties are fine where a value is used in many places.
- **Keep these entry points on `PhotoLibraryViewModel`, with the same signatures.** The coordinator's harness
  (`Tools/coordinator/CoordinatorEditBenchmarks-Session.swift`) and many tests call them:
  - `setModelContext(_:)`;
  - `loadExistingData()`, as a forwarder;
  - `openDetail(for:)`, `navigateDetail(direction:)`, `closeDetail()`;
  - `startEditing(photo:isRAW:)`, `stopEditing(save:)`, `editSession`.
- **`PhocasaTests/PerformanceBenchmarks.swift`** calls many view-model APIs (listed in `results/00.md` and extended by
  tasks 10 and 20).
  - Update it for the new API in this branch.
  - **Keep every `BENCH|` line label identical.** The coordinator compares lines by label between `main` and your
    branch.

## Steps

- [ ] **Step 1: Baseline.**
  1. Run the full suite. It should report "Executed 441 tests, with 20 tests skipped and 0 failures".
  2. Run `DataPathBenchmarks` and the gated benchmark classes (`ThumbnailSchedulerBenchmarks`,
     `DetailNavigationBenchmarks`, `ImageEditingServiceBenchmarks`, `ThumbnailDiskCacheBenchmarks`,
     `MetadataSidecarBenchmarks`).
  3. Collect the numbers from every `results/*.md` into one before/after table in `results/30.md`. Use the spec's
     numbers as "before" and `results/wave-2-coordinator.md` as "after wave 2".
  4. Read the "Needs from other tasks" and "Follow-ups" sections of every results file, and list the ones you're
     handling here.

- [ ] **Step 2: Extract `SelectionModel`.** Move the tests with the code, into a new `SelectionModelTests`, keeping
  every assertion. Commit.

- [ ] **Step 3: Extract `LibraryStore`** in the file layout above, including the scan path and `LibrarySort`.
  - Move the tests into `LibraryStoreTests`, or keep them in `ViewModelTests` if they exercise the coordinator. Keep
    every assertion.
  - Task 10's oracle tests (`testInMemoryStateMatchesFreshLoad`, `testRandomisedInteractionsMatchFreshLoad`) must pass
    unchanged in meaning.
  - Commit.

- [ ] **Step 4: Tidy the leftover duplication.**
  - One helper for trashing a photo's files, including its XMP sidecar. It replaces `trashRAWFile`, `trashJPGFile` and
    the inline code in `confirmPermanentDelete`.
  - `PhotoGridView`'s context menu uses `library.tagsByCategory`. `contextMenuTagState` and `toggleTag` use the
    index-based selection, with no O(N) scan per tag.
  - `DetailOverlayControls` and `PhotoDetailView.prefetchNeighbours` use `library.index(of:)`, not
    `photos.firstIndex(where:)`.

- [ ] **Step 5: File trashing off the main thread (spec §G5).**
  - `confirmPermanentDelete`, `emptyBin` and the file-type delete collect URLs on the main actor. They then trash them
    on `actor FileTrasher`, which runs on a `DispatchSerialQueue`.
  - Update the store on the main actor afterwards.
  - Show progress in the status bar for batches of more than 20.
  - Test with temp files: trashing 200 files leaves the main actor free. Assert that a main-actor task scheduled
    mid-way runs before trashing finishes.

- [ ] **Step 6: Keep the grid alive (spec §G4).**
  - `ContentView.mainContent` keeps the `NavigationSplitView` in the hierarchy at all times, and layers the detail view
    (plus `EditSidebarView`) above it in a `ZStack`.
  - While the detail view is shown, the hidden grid gets `.allowsHitTesting(false)`, `.accessibilityHidden(true)` and
    opacity 0.
  - Returning from the detail view scrolls to `selection.lastSelectedId` only if it isn't already visible, using
    `ScrollViewReader`.
  - Keyboard focus must still reach the detail view. Check the existing `.focused($isContentFocused)` flow.
  - **The hidden grid must not keep decoding thumbnails.** Its cells' `.task`s are still alive. Check with a debug
    counter or the scheduler that opening the detail view doesn't start grid thumbnail work.

- [ ] **Step 7: Split `ContentView`'s body.** Move the status bar and the toolbar content into their own
  `View`/`ToolbarContent` structs, so that selection changes don't re-evaluate the whole `ContentView`.

- [ ] **Step 8: Flush pending metadata writes on quit.**
  - Check SwiftUI first: `scenePhase` doesn't cover app termination on macOS.
  - If needed, use `@NSApplicationDelegateAdaptor` with `applicationShouldTerminate` → `.terminateLater`. Await
    `MetadataWriter.shared.flush()` with a 5 s timeout, then call `reply(toApplicationShouldTerminate: true)`.
  - Add this to the CLAUDE.md list of known AppKit exceptions, with the reason.
  - `PhocasaApp` keeps its in-memory test-host store.

- [ ] **Step 9: Already done in wave 2; verify, don't redo.**
  - Task 22 already calls `ImageLoader.shared.invalidate(path:)` after exports, and reloads the detail view's decodes
    through `editedFilesVersion`.
  - Confirm with a test that an export invalidates the thumbnail.

- [ ] **Step 10: Update `CLAUDE.md`** for the whole codebase as it is after waves 1–2 and this task.
  - **Project Structure:** `Library/`, `Editing/`, `Views/Detail/`, `Services/` (with one line per key type),
    `Tools/imagebench/` and `Tools/coordinator/`.
  - **Concurrency conventions.** Replace "services with mutable caches use `@unchecked Sendable` with serial dispatch
    queues" with the real rules:
    - `ImageEditingService` and `MetadataWriter` are actors on `DispatchSerialQueue` executors;
    - `ThumbnailScheduler` is bounded, newest first and cancellable;
    - `FullImageLoader` and `ThumbnailDiskCache` synchronise with locks;
    - metadata writes go only through `MetadataWriter`, which is serial and coalescing, with a synchronous
      `enqueue` / `enqueueEditParameters` and an async `flush()`, and writes a pair's rating to both files;
    - RAW edit parameters are written only through `RAWEditStore` → `MetadataWriter`.
  - **SwiftData rule (task 20).** A background `ModelContext` may read, and may insert rows that have no relationships.
    It must never change, or link to, a row the main context may hold.
  - **Data-flow contract.** The store is read by `loadExistingData()` and scans. UI interactions work on in-memory
    `PhotoFacts` and must never re-fetch.
  - **Metadata.**
    - Sidecars are updated in place and never rewritten wholesale; unparseable ones are skipped.
    - JPEG writes splice in only the XMP/IPTC segments, falling back to the ImageIO rewrite.
  - **AppKit exceptions:** add `NSApp.currentEvent?.clickCount` (`RatingView`) and the quit-time delegate adaptor.
  - **Testing:**
    - the test host uses an in-memory store and has no disk cache unless `PHOCASA_THUMBNAIL_CACHE_DIR` is set;
    - the gated benchmarks run with `PHOCASA_BENCH=1` (add the command);
    - imagebench usage;
    - never touch `~/Library/Application Support`.
  - **Build settings:** objectVersion 77 synchronized folders, so new files need no `pbxproj` edits.
  - **Wave 3B changes** (schema, capture-date sort, launch) are documented by the coordinator after they merge. Don't
    anticipate them.

- [ ] **Step 11: Final measurements.** Run everything again and finish the before/after table in `results/30.md`. The
  full suite passes with zero warnings.

## Acceptance criteria

- `PhotoLibraryViewModel.swift` ≤ 400 lines. No new type or extension file exceeds ~400 lines.
- The file layout above exists, including `LibrarySort` as the only definition of photo order, so wave 3B's owners
  have separate files.
- Every test assertion that existed before this task still exists, whether moved or unchanged, and passes.
- The grid keeps its scroll position across opening and closing the detail view (a test where feasible, otherwise
  reasoning in the results file). The hidden grid starts no thumbnail work.
- No `FileManager.trashItem` calls on the main actor.
- Quit waits for pending metadata writes (at most 5 s).
- `CLAUDE.md` accurately describes the structure and conventions.
- **No benchmark regresses by more than 5%**, as re-measured by the coordinator. This is a structure task: behaviour
  and speed stay the same.
- Final benchmark table in `results/30.md`. The full suite passes with zero warnings.

## Out of scope

These belong to other wave-3 tasks:
- schema changes (31);
- launch off the main actor and the bin fix (32);
- capture-date sort (33);
- disk-cache follow-ups and `loadFullResolution` removal (34);
- edit render sizes (35).

Replacing `LazyVGrid`, a Metal preview view and colour management stay recommendations: list them with the evidence
from the results files.
