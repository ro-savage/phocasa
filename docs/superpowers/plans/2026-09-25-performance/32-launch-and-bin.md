# Task 32: Launch Off the Main Actor, Incremental Imports, Bin Survives Relaunch

**Wave:** 3B (in parallel with 31, 33, 35) · **Depends on:** 30 merged · **Branch:** `perf/32-launch-and-bin` · **Size:** M

**Goal:**
- Launching with a 10k library blocks the main actor for **≤ 150 ms**. Today it's about 350 ms, almost all of it
  `loadExistingData()`.
- A scan that inserts a few new photos into a big library doesn't do a full reload. Today it's about 330 ms at 10k.
- **User decision (wave 2, #1):** "Move to Bin" survives a relaunch. Today every scan, including the launch rescan,
  takes a binned photo back out of the bin if its file still exists.

**Why:** spec §B1, and the follow-ups in `results/20.md` and `results/wave-2-coordinator.md`.

## Files (after task 30's split; re-check the names against merged `main`)

- **You own:**
  - `Library/LibraryStore+Loading.swift`: `loadExistingData`, building facts, availability;
  - `Library/LibraryStore+Scan.swift`: `performScan`, `applyScanUpdates`, `insertScannedPhotos`, the scan queue;
  - `Library/ScanPlan.swift` and `Services/FolderScanner.swift`;
  - `ScanTests` and `FolderScannerTests`;
  - `PhocasaTests/PerformanceBenchmarks.swift` (additions, plus the `7x` seed fix below).
- **You may add** a small incremental-insert entry point to `LibraryStore+ListEditing.swift`, next to `relocate` (see
  the coordinator notes above). Keep it additive: task 33 edits the sort in `LibrarySort.swift`.
- **Don't touch:**
  - `LibrarySort.swift` (task 33). **Always order through it**, never by `creationDate` directly, so that task 33's
    change applies to your paths too.
  - `Models/*` (31, 33) and `MetadataService` (33).
  - Editing (35).
  - `isDeleted` naming: task 31 renames it to `isInBin` in parallel. Keep your edits away from the lines it renames
    where you can; the coordinator merges 31 first and resolves the rest.

## Coordinator notes after task 30 merged (read first)

Task 30's real layout is in `results/30.md`, "Layout for wave 3B → Task 32". In short:
- **Launch** is `LibraryStore.open(_:)` in `Library/LibraryStore+Loading.swift`: it sets the context, runs
  `loadExistingData()`, then starts `rescanCurrentLibrary()`. `PhotoLibraryViewModel.setModelContext(_:)` calls it.
- **State.** Swift extensions can't add stored properties. Loading state lives in `LibraryStore.LoadingState`
  (declared in `+Loading`, stored as `loading`), scan state in `LibraryStore.ScanState` (declared in `+Scan`, stored as
  `scanning`). Add your new state there, so you don't need to edit `LibraryStore.swift`.
- **The incremental insert goes in `Library/LibraryStore+ListEditing.swift`**, next to `relocate` (not
  `+Mutations`, as the table used to say). Its helpers `insertIntoList(_:facts:inBin:)` and `relocateByMerging` are
  private to that file; they place photos with `sort.insertionIndex(for:in:)` and `sort.merge(_:into:_:)`. Facts for a
  new row come from `PhotoFacts(photo, tags: &tagFacts)`. Afterwards call `refreshVisiblePhotos()` and
  `sortTagCategories()`.
- **Order only through `LibrarySort`** (task 33 changes it in parallel). Fetch ordered photos with
  `sort.fetch(where:in:)`, which works with any `ModelContext`, including a background one, and read a model's key
  with `LibrarySort.key(of:)`. **Don't call `LibrarySort.key(creationDate:)`**, never build a `SortDescriptor` on
  `creationDate`, and never sort by `creationDate` yourself: task 33 may change what the key is made of. If your
  background snapshot needs the order, keep the order the fetch returned.
- **`waitForScans()` is task 33's after-launch hook** (`Task { await library.waitForScans(); … }` in
  `setModelContext`). Keep its contract: it returns only once no scan is running or queued, **and**, if you make the
  launch load asynchronous, once that load has been applied. Keep `ScanTests.testWaitForScansWaitsForTheLaunchRescanAndQueuedScans`
  passing, and extend it to cover the async load.
- **Optional, recommended: deletes that end in a full reload.** After their files are trashed, `deleteFileType` and
  `deletePermanently` in `Library/LibraryStore+Mutations.swift` each call `loadExistingData()` (about 320 ms on the
  main actor at 10k), so a permanent delete or Empty Bin freezes a large library briefly. If your incremental-insert
  work makes an in-memory removal cheap, you may replace **those two calls only** with it (put the removal next to
  `relocate` in `+ListEditing`), with an oracle-style test that the state equals a fresh load, and a harness line. Task
  31 renames `isDeleted` in `+Mutations` at the same time; don't touch other lines there.
- Task 31 renames `isDeleted` → `isInBin` in your files at the same time (a mechanical identifier rename). The
  coordinator merges 31 first and re-applies it to your hunks. Don't reformat those lines.

## Coordination with task 33 (capture date)

- **Insert sites.** Task 33 adds `asset.captureDate = found.metadata?.captureDate` (one line) to each scan insert site:
  `ScanPlan.insertInBackground` and `insertScannedPhotos`.
  - If you restructure inserts, keep a single obvious place where a new `PhotoAsset` is created from a
    `DiscoveredPhoto`.
  - Say where it is in your results.
- **Backfill.** Task 33 also backfills capture dates for existing rows, as updates applied on the main context in
  chunks. If it reuses your scan update path, it will ask under "Needs"; don't anticipate it.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite and `DataPathBenchmarks`, in particular:
  - `7v` launch, synchronous part and until the rescan ends;
  - `7w` unchanged rescan;
  - `COLD setModelContext`;
  - `1 loadExistingData`;
  - `scan1k FIRST`/`SECOND`/`7z`.
- [ ] **Step 2: Measure where the launch time goes**, before designing anything:
  - the photo fetch (≈185 ms at 10k);
  - facts (≈66 ms);
  - the bin fetch, tags, counts and the grid.

  **If a quick prototype shows you can't get the synchronous launch part well below today's ~350 ms, stop and report**
  rather than finish.
- [ ] **Step 3: Launch off the main actor.**
  - One approach to evaluate: read plain values (facts, `persistentModelID`s, the order) through a background context
    (task 20's `StoredPhoto` pattern). On the main actor, materialise the models cheaply with
    `context.model(for:)`, which gives registered models or faults, not a full fetch.
  - Measure that; faults fire when cells read properties.
  - `loadExistingData()` must keep a **synchronous** form with today's semantics. Tests, the harness and task 10's
    oracle tests call it.
  - The launch path may use a new async variant. The grid can appear a few frames after launch; the UI must never show
    a half-built state (counts from one snapshot, photos from another).
- [ ] **Step 4: Incremental insert after scans.** A scan that inserted *k* new photos appends them through the
  in-memory library's insert path in O(k log n), instead of calling `loadExistingData()`. Add a harness line `7u`: a
  rescan that finds 10 new files in a 10k library, measuring its wall time and main-actor time.
- [ ] **Step 5: Bin survives relaunch (user decision).**
  - `ScanPlan` no longer emits `restoresFromBin`. A binned photo found on disk stays in the bin; its paths and size
    still update.
  - Invert `testScanRestoresBinnedPhotoWhoseFileExists`.
  - Add a test: move to bin, then relaunch (a new view model on the same store, with its launch rescan) — the photo is
    still in the bin.
- [ ] **Step 6: Harness.**
  - `7x` rescans 20k rows, because its seed stores `/var/…` paths while the enumerator reports `/private/var/…`
    (`results/20.md`, deviation 1). Seed canonical paths, as `7w` does, and note in your results that `7x` is
    re-baselined.
  - Keep every other line label and meaning unchanged.
- [ ] **Step 7: Full suite, warnings, results file, commit.**

## Acceptance criteria

| Benchmark | After wave 2 | Target |
|---|---|---|
| `7v` launch with a 10k library: main-actor time (synchronous part + rescan) | ~350 + 8 ms | **≤ 150 ms** |
| `7u` scan inserting 10 photos into a 10k library: main-actor time | ≈ 330 ms (full reload) | **≤ 50 ms** |
| `7w` unchanged rescan, `scan1k FIRST`, filter/search/rating lines | see `results/wave-2-coordinator.md` | no regression > 5% |

- Binned photos stay binned across rescans and relaunches (tests).
- Task 10's oracle tests pass. Zero new warnings, and the full suite passes.
