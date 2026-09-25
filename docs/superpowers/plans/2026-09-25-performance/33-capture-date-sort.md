# Task 33: Sort by Capture Date

**Wave:** 3B (in parallel with 31, 32, 35) · **Depends on:** 30 merged · **Branch:** `perf/33-capture-date-sort` · **Size:** M

**Goal (user decision, wave 2, #6):** the grid is ordered by the photo's **capture date** (EXIF `DateTimeOriginal`), not
the file creation date. Copying files between disks changes their creation date, so today's order can change for no
visible reason. Photos without a capture date fall back to the file creation date. "Newest first" / "oldest first"
keeps working.

**Why:** `results/20.md`, the follow-up "Sorting by EXIF `DateTimeOriginal`".

## Files (after task 30's split; re-check the names against merged `main`)

- **You own:**
  - `Library/LibrarySort.swift`, the one definition of photo order;
  - `MetadataService.readMetadata(from:)` and `PhotoMetadata`, to read the capture date;
  - `Models/PhotoAsset.swift`, **only** your new attribute(s);
  - a new `Library/CaptureDateBackfill.swift`, or similar;
  - new `CaptureDateTests`, plus the capture-date parts of `MetadataParsingTests`.
- **You may add one line at each scan insert site** (`ScanPlan.insertInBackground`, `insertScannedPhotos`):
  `asset.captureDate = found.metadata?.captureDate`. Task 32 owns those files, so change nothing else in them.
- **Don't touch:**
  - task 32's loading/scan pipeline, beyond the one-line insert assignments;
  - task 31's rename, `isDeleted` → `isInBin`;
  - editing (35).

## Coordinator notes after task 30 merged (read first)

Task 30's real layout is in `results/30.md`, "Layout for wave 3B → Task 33". In short:
- **`Library/LibrarySort.swift`** is a `struct LibrarySort: Equatable, Sendable { var newestFirst }` with
  `static key(creationDate:)`, `static key(of: PhotoAsset)` (the only per-photo key read in the app), `precedes`,
  `fetch(where:in:)` (the only fetch that orders; both of `loadExistingData`'s fetches use it), `insertionIndex(for:in:)`,
  `merge(_:into:_:)`, `toggle()` and `reorderAfterToggle(_:)`. `LibrarySortTests` pins that they agree.
  - Task 32 may call `sort.fetch(where:in:)` from a **background** `ModelContext` for its off-main launch snapshot, and
    uses `key(of:)`. Keep both signatures. Task 32 was told not to call `key(creationDate:)`, so you may change or
    replace it.
  - If you sort in memory (option b), do it inside `fetch(where:in:)`, so every caller, including task 32's background
    snapshot, gets the new order.
- **Insert sites** (one line each, in task 32's files): `ScanPlan.insertInBackground` in `Library/ScanPlan.swift`, and
  `insertScannedPhotos` in `Library/LibraryStore+Scan.swift`, at `let asset = PhotoAsset(…)`. Task 32 was told to keep
  a single obvious creation point in each.
- **After-launch hook:** one line in `PhotoLibraryViewModel.setModelContext(_:)`
  (`ViewModels/PhotoLibraryViewModel.swift`), after `library.open(context)`, e.g.
  `Task { await library.waitForScans(); <start the backfill> }`. `waitForScans()` returns after the launch rescan;
  task 32 keeps that true if the launch load becomes asynchronous.
- **The backfill** goes in your new `Library/CaptureDateBackfill.swift`. It may be an `extension LibraryStore` or its
  own type. Extensions can't hold stored state; if you need state on the store, follow task 30's pattern (a small
  `struct` declared in your file, plus one stored property line in `LibraryStore.swift`; nobody else edits that file in
  wave 3B).
- **Re-order once at the end in memory, not with `loadExistingData()`.** A full reload costs about 320 ms on the main
  actor at 10k, over your ~16 ms budget. `allPhotos`/`allFacts`/`binPhotos`/`binFacts` have internal setters: re-sort
  them with `LibrarySort` in your file, bump `libraryVersion`/`binVersion`, and call `refreshVisiblePhotos()`. Measure
  that step's main-actor time at 10k.
- **The `isDeleted` collision (spec §H5) is still on your branch.** Task 31 renames it in parallel; the coordinator
  merges 31 first. Until then, saving any change to a **binned** row writes its bin flag back as false (task 30 found
  this). So your backfill, which writes to binned rows too, will take them out of the bin in the store **on your
  branch only**. Write the test "binned rows stay binned across the backfill" anyway. If it fails only because of the
  collision, wrap it in `XCTExpectFailure("fixed by task 31's isInBin rename", strict: false)` and say so under "Needs":
  the coordinator removes the wrapper after merging.
- **New attributes:** prefer optionals, which lightweight migration adds as nil. A non-optional attribute needs a
  default value in its declaration. List every attribute you add under "Needs": the coordinator extends task 31's
  `MigrationTests` (V1 → current) to cover them after both merge.
- **`MetadataService`:** change only `readMetadata(from:)` / `PhotoMetadata`. Leave the write path and
  `restoreFileDates` alone: task 34's thumbnail re-key relies on metadata writes restoring the file date to within
  10 µs.

## Design notes

- **Reading.**
  - Read `kCGImagePropertyExifDateTimeOriginal`, plus `SubsecTimeOriginal` and `OffsetTimeOriginal` when present, from
    the properties `readMetadata` already opens. For a pair that's the JPG, as today.
  - No offset means camera local time: interpret it in the current time zone, and document that.
  - **Don't use `DateFormatter` per file**: it's slow and not thread-safe to share. Parse the fixed
    `yyyy:MM:dd HH:mm:ss` format by hand or with a cached, `Sendable`-safe approach.
  - `readMetadata` runs concurrently (`concurrentPerform`) during scans. It must stay stateless, and no more than 5%
    slower on `scan1k readMetadata x1000` and the coordinator's real JPG/ARW `readMetadata` lines.
- **Schema.**
  - Add `captureDate: Date?` to `PhotoAsset`. It's optional, so lightweight migration adds it as nil.
  - If you need to know that a file has been checked and has no date, so the backfill doesn't re-read it on every
    launch, add a second optional or defaulted attribute, and say why.
  - Task 31 is changing the same model file (a rename and removals) and owns `MigrationTests`. Add only your
    attributes.
- **Order.** Sort key = `captureDate ?? creationDate ?? .distantPast`, everywhere, through `LibrarySort`:
  - the fetch order;
  - in-memory insertion (`insertionIndex`, `relocateByMerging`);
  - `toggleSortOrder`.

  SwiftData can't sort a fetch by a coalesced expression. Either store a non-optional `sortDate` attribute maintained
  on insert and backfill, or sort the fetched snapshot in memory. At 10k, an in-memory sort of the facts costs a few
  ms, but measure `1 loadExistingData` and `COLD setModelContext`. Choose, and record why.
- **Backfill for existing libraries.** Existing rows have no capture date.
  - After launch, read capture dates **off the main actor** for rows that lack one.
  - Apply them on the **main context** in chunks, because a background context must never change a row the main
    context holds (CLAUDE.md, task 20's rule).
  - Then re-order the in-memory library once.
  - Measure:
    - 10k JPG and 10k RAW-only rows, where ARW `readMetadata` is about 2.4 ms per file;
    - the main-actor time per chunk, which must stay small (≤ ~16 ms);
    - the backfill's total wall time.
  - The UI stays responsive, and the order updates once when the backfill finishes.
- **New photos** get their capture date from the scan's metadata read, which already happens (`DiscoveredPhoto.metadata`).

## Steps

- [ ] **Step 1: Baseline.** Run the full suite and `DataPathBenchmarks`, and record `1 loadExistingData`,
  `COLD setModelContext`, `3d toggleSortOrder`, `8a`/`8b`, `scan1k readMetadata x1000` and `FIRST`.
- [ ] **Step 2: Failing tests first.**
  - Parsing: with and without subseconds and offset; a malformed date gives nil; a file with no EXIF date gives nil.
  - Order: photos whose capture dates disagree with their file creation dates are shown in capture order; photos
    without a capture date fall back to their creation date; toggling reverses the order.
  - Moving to the bin and restoring keeps the capture order.
  - A new scan stores capture dates.
  - Backfill: a store whose rows have no capture date gets them filled after launch, and the order is right.
  - Task 10's oracle tests still pass, since the order is part of what they compare.
- [ ] **Step 3: Implement,** then measure the lines from step 1 and the backfill.
- [ ] **Step 4: Full suite, warnings, results file, commit.**

## Acceptance criteria

- The grid order is by capture date, with the fallback, in both directions, including after bin moves, restores and
  scans.
- Existing libraries are backfilled after launch without blocking the main actor for more than ~16 ms at a time.
- No benchmark regresses by more than 5%: filter, search, sort toggle, rating, bin, `readMetadata`, scan and launch.
- Zero new warnings. The full suite passes.
- Put the CLAUDE.md lines you'd add under "Needs from other tasks", for the coordinator.
