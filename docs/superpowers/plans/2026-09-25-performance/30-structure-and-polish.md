# Task 30: Structure and Polish

**Wave:** 3 (runs alone) · **Depends on:** every task in waves 1–2 merged · **Branch:** `perf/30-structure-and-polish` · **Size:** L

**Goal:**
- Split what remains of `PhotoLibraryViewModel` into focused types.
- Keep the grid alive underneath the detail view.
- Move file trashing off the main thread.
- Finish the leftovers the earlier tasks deferred.
- Update `CLAUDE.md` so the next person, or agent, starts from an accurate map.

**Why:** spec §H1, §H2, §G4, §G5, plus the follow-ups from the tasks 10–22 results files. **Read every `results/*.md` first.**

## Files

You own everything in this wave. Stay within the items below; don't reformat untouched code.

## Target structure

These are guidelines; keep the names unless there's a good reason. Every type should be ≤ ~400 lines with one responsibility.

```
Library/
  LibraryStore.swift      @Observable @MainActor: model context, fetch/load, allPhotos/binPhotos + facts,
                           counts, tag lists, rating/tag/bin/delete mutations, scan (from task 20)
  PhotoQuery.swift        (task 10)
  SelectionModel.swift    @Observable @MainActor: selectedPhotos, lastSelectedId, toggle/range/selectAll/clear,
                           grid keyboard navigation, primarySelectedPhoto
  TagParsing.swift        (task 20)
Editing/
  EditSession.swift       (task 22)
ViewModels/
  PhotoLibraryViewModel.swift   thin coordinator: owns LibraryStore, SelectionModel, editSession;
                                 UI flags (showingDetail, showFolderPicker, sheets, gridColumns, sort);
                                 cross-cutting actions (openDetail, navigateDetail, closeDetail, delete flows)
```

Views access `viewModel.library.…` and `viewModel.selection.…` directly. Update the call sites instead of adding forwarding properties. A few forwarding properties are fine where a view uses a value in many places.

## Steps

- [ ] **Step 1: Baseline.**
  1. Run the full suite and **all** benchmarks: data path, the gated scheduler/editing/disk-cache benchmarks, and imagebench `conc`/`detail`/`ci`.
  2. Collect the numbers from every `results/*.md` into one before/after table in `results/30.md`, using the spec's numbers as "before".
  3. Read the "Needs from other tasks" and "Follow-ups" sections of every results file, and list the ones you're handling here.

- [ ] **Step 2: Extract `SelectionModel`.** Move the tests with the code, into a new `SelectionModelTests`, keeping every assertion. Commit.

- [ ] **Step 3: Extract `LibraryStore`,** including the scan path. Move the tests into `LibraryStoreTests`, or keep them in `ViewModelTests` if they exercise the coordinator; keep every assertion. Commit.

- [ ] **Step 4: Tidy the leftover duplication.**
  - One helper for trashing a photo's files, including its XMP sidecar. It replaces `trashRAWFile`, `trashJPGFile` and the inline code in `confirmPermanentDelete`.
  - `PhotoGridView`'s context menu uses `library.tagsByCategory`. `contextMenuTagState` and `toggleTag` use the index-based selection (no O(N) scan per tag).
  - `DetailOverlayControls` uses `library.index(of:)` instead of `photos.firstIndex(where:)`.
  - Delete `ImageLoader.loadFullResolution(for:)` if nothing calls it any more.

- [ ] **Step 5: File trashing off the main thread (spec §G5).**
  - `confirmPermanentDelete`, `emptyBin` and the file-type delete collect URLs on the main actor, then trash them on a background serial executor. A small `actor FileTrasher` on a `DispatchSerialQueue` is fine.
  - Update the store on the main actor afterwards.
  - Show progress in the status bar for batches of more than 20.
  - Test with temp files: trashing 200 files leaves the main actor free. Assert that a main-actor task scheduled mid-way runs before trashing finishes.

- [ ] **Step 6: Keep the grid alive (spec §G4).**
  - `ContentView.mainContent` keeps the `NavigationSplitView` in the hierarchy at all times and layers the detail view (plus `EditSidebarView`) above it in a `ZStack`.
  - The hidden grid gets `.allowsHitTesting(false)`, `.accessibilityHidden(true)` and opacity 0 while detail is shown.
  - Returning from detail scrolls to `selection.lastSelectedId` only if it isn't already visible, using `ScrollViewReader`.
  - Keyboard focus must still reach the detail view. Check the existing `.focused($isContentFocused)` flow.

- [ ] **Step 7: Split `ContentView`'s body.** Move the status bar and the toolbar content into their own `View`/`ToolbarContent` structs, so that selection changes don't re-evaluate the whole `ContentView`.

- [ ] **Step 8: Invalidate caches after exports.** In the success paths of `EditSession.exportRAWToJPG` and `exportJPGPermanent`:
  - call `ImageLoader.shared.invalidate(path:)` for the written path;
  - add and call `FullImageLoader.shared.invalidate(path:)`.

  Test: after an export, the next thumbnail load decodes again (debug counter).

- [ ] **Step 9: Flush pending metadata writes on quit.**
  - Check SwiftUI first: `scenePhase` doesn't cover app termination on macOS.
  - If needed, use `@NSApplicationDelegateAdaptor` with `applicationShouldTerminate` → `.terminateLater`. Await `MetadataWriter.shared.flush()` with a 5 s timeout, then `reply(toApplicationShouldTerminate: true)`.
  - Add this to the CLAUDE.md list of known AppKit exceptions, with the reason.

- [ ] **Step 10: Update `CLAUDE.md`.**
  - **Project Structure:** the new folders (`Library/`, `Editing/`, `Views/Detail/`, `Tools/imagebench/`) and one line per key type.
  - **Concurrency conventions:** replace "services with mutable caches use `@unchecked Sendable` with internal synchronization via serial dispatch queues" with the new rules:
    - stateful services are actors on `DispatchSerialQueue` executors (`unownedExecutor`), so blocking I/O stays off the cooperative pool and `Task.isCancelled` works;
    - thumbnails go through `ThumbnailScheduler` (bounded, newest-first, cancellable);
    - metadata writes go only through `MetadataWriter`.
  - **Data-flow contract:** the store is read by `LibraryStore.loadExistingData()` and scans. UI interactions work on in-memory `PhotoFacts` and must never re-fetch.
  - **Testing:** the test host uses an in-memory store; benchmarks are gated by `PHOCASA_BENCH=1` (add the command); imagebench usage.
  - **Build settings:** objectVersion 77 synchronized folders, so new files need no `pbxproj` edits.

- [ ] **Step 11: Final measurements.** Run everything again and finish the before/after table in `results/30.md`. The full suite passes with zero warnings.

## Acceptance criteria

- `PhotoLibraryViewModel.swift` ≤ 400 lines. No new type exceeds ~400 lines.
- Every test assertion that existed before this task still exists, whether moved or unchanged, and passes.
- The grid keeps its scroll position across opening and closing the detail view (code inspection plus reasoning in the results file).
- No `FileManager.trashItem` calls on the main actor.
- `CLAUDE.md` accurately describes the new structure and conventions.
- Final benchmark table in `results/30.md`. The full suite passes with zero warnings.

## Out of scope

- Schema changes (task 31).
- Replacing `LazyVGrid`, a Metal preview view, colour management, and EXIF-date sorting. List them as recommendations with the evidence from the results files.
