# Task 20: Scan and Launch Path

**Wave:** 2 · **Depends on:** 10 (in-memory library), 14 (metadata reads fixed, `PhotoMetadata: Sendable`) · **Branch:** `perf/20-scan-and-launch` · **Size:** M

**Goal:**
- Launching with an unchanged 10k library blocks the main thread for ≤ 150 ms (from ~2.2 s).
- A first import does its per-file work off the main thread (from ~1.6 ms per photo on main).
- Overlapping scans can no longer create duplicate rows or crash.

**Why:** spec §B1–§B3.

## Files

- Modify: `Phocasa/Phocasa/Services/FolderScanner.swift` (you own it)
- Modify: `Phocasa/Phocasa/ViewModels/PhotoLibraryViewModel.swift`, **only**:
  - `setModelContext`;
  - `// MARK: - File Availability` (`checkFileAvailability`, `refreshAvailability`, `missingPhotoIDs`, `needsAvailabilityCheck`);
  - `// MARK: - Folder Opening` (`openFolder`, `handleFolderSelected`, `rescanCurrentLibrary`, `scanFolder`);
  - `findOrCreateTag`.
- Create: `Phocasa/Phocasa/Library/TagParsing.swift`, holding `Tag.parse(keyword:)` next to the existing `fullName` logic, as an extension on `Tag`
- Modify: `Phocasa/PhocasaTests/FolderScannerTests.swift`
- Create: `Phocasa/PhocasaTests/ScanTests.swift`
- Modify: `Phocasa/PhocasaTests/PerformanceBenchmarks.swift` (only if you need extra lines)

**Don't touch:** filtering and data loading internals (task 10, merged); editing (task 22, running in parallel); `ImageLoader` (task 21, running in parallel).

## Interfaces

- **Consumes:**
  - `loadExistingData()`, the only full reload (task 10);
  - `MetadataService.shared.readMetadata(from:)` with correct ratings (task 14);
  - `MetadataService.PhotoMetadata: Sendable` (task 14).
- **Produces:**
  ```swift
  struct DiscoveredPhoto: Sendable {           // existing fields unchanged, plus:
      let key: String                           // "\(folderPath)/\(fileName)", the identity used for matching
      var metadata: MetadataService.PhotoMetadata?   // filled only for keys not in `knownKeys`
  }

  extension FolderScanner {
      /// Enumerates the folder and reads metadata for new files, concurrently and off the main thread.
      func scan(folderURL: URL, knownKeys: Set<String>) async -> [DiscoveredPhoto]
  }

  extension Tag {
      /// "category:name" → ("category", "name"); "name" → ("", "name"). Inverse of `fullName`.
      static func parse(keyword: String) -> (category: String, name: String)
  }
  ```
  Keep the existing `scan(folderURL:)` as a wrapper that passes an empty `knownKeys`; the existing tests use it.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite and the benchmarks (`N=10000` line `7x`, and `scan1k`). Record the first-scan and rescan times.

- [ ] **Step 2: Failing tests first** (`ScanTests`). These drive the view model against a temp folder and a temp on-disk store. Copy the image and keyword helpers from `PerformanceBenchmarks.testScan1k`, and wait for `isScanning == false` with a timeout.
  - `testScanImportsRatingsAndKeywords`: files written with `MetadataService.writeMetadata(rating: 3, keywords: ["cat:a", "b"])` import with rating 3 and tags `cat:a` and `b`.
  - `testRescanOfUnchangedLibraryDoesNotDirtyStore`: scan, save, then rescan. After the rescan's processing and **before** its save, `context.hasChanges == false`. Expose an internal test hook, or assert that no photo's properties changed by comparing `persistentModelID`s and values.
  - `testOverlappingScansDoNotDuplicate`: call `rescanCurrentLibrary()` three times back to back. Once idle, the store holds exactly one `PhotoAsset` per file.
  - `testScanToleratesExistingDuplicates`: insert two `PhotoAsset`s with the same folder and file name, then scan. No crash, and one of them is kept up to date.
  - `testFilesRemovedFromDiskAreHiddenAfterRescan`: scan, delete one file, rescan. That photo is no longer in `allPhotos`.
  - `testTagParseRoundTripsFullName`

- [ ] **Step 3: `FolderScanner.scan(folderURL:knownKeys:)`.**
  - After grouping the files, collect the discovered photos whose `key` isn't in `knownKeys`.
  - Read their metadata with `DispatchQueue.concurrentPerform(iterations:)`, in chunks of about 64, writing into a pre-sized array. Call `MetadataService.shared.readMetadata(from: jpgPath ?? rawPath)` for each.
  - Keep using `nextObject()` in the synchronous enumerator (CLAUDE.md rule).
  - Drop the final `results.sort`: the view model sorts on fetch.
  - Update `FolderScannerTests` for the new API: known keys skip the metadata read, and new keys get it.

- [ ] **Step 4: Rework `scanFolder`** (on the main actor).
  1. **One scan at a time.** Keep `private var scanTask: Task<Void, Never>?` and `private var rescanRequested = false`. If a scan is running, set `rescanRequested = true` and return. When a scan finishes and the flag is set, clear it and scan once more.
  2. **Existing rows:** fetch all `PhotoAsset`s once and build `[String: PhotoAsset]` with `Dictionary(_:uniquingKeysWith: { first, _ in first })`. That removes the `uniqueKeysWithValues` trap.
  3. **Scan:** `await scanner.scan(folderURL:knownKeys: Set(existing.keys))`.
  4. **Existing photos:** assign a field **only if its value differs** (`if p.jpgPath != d.jpgPath { p.jpgPath = d.jpgPath }`, and the same for `rawPath`, `fileSize` and `isDeleted`). An unchanged rescan must leave `context.hasChanges == false`.
  5. **New photos:** build the tag lookup once, as `var tagsByFullName: [String: Tag]` from a single `FetchDescriptor<Tag>()`. For each keyword, use `Tag.parse(keyword:)` and look it up or create it; don't fetch per keyword. Insert the assets.
  6. **Availability:** photos under the scanned root that weren't discovered go into `missingPhotoIDs`; everything discovered is available. Don't run a separate `stat` pass after a scan, and drop `needsAvailabilityCheck` from this path.
  7. Save once if `context.hasChanges`, then call `loadExistingData()` exactly once.
  8. **Progress:** update `scanProgress` with counts at least at "Scanning…", "Reading metadata for N new photos…" and "Found X photos (Y new)". Update the counts in the scanner using an `AsyncStream`, or poll `ProgressReporter`-style; keep it simple.
- [ ] **Step 5: Launch.**
  - `setModelContext` shows the library immediately from the store, trusting the last scan: no `stat` pass. Then it starts the background rescan, which computes `missingPhotoIDs`.
  - `refreshAvailability()` stays available and keeps its current semantics for tests and a manual refresh.
  - Existing tests that depend on the launch behaviour must pass unchanged.
  - `findOrCreateTag` stays public and behaves the same: `ViewModelTests` uses it.

- [ ] **Step 6: Measure.** Run the benchmarks again. Add `7z first scan of 1k new photos: main-actor time`: time the synchronous main-actor section of `scanFolder` with a `ContinuousClock` accumulator, exposed through an internal test hook.

- [ ] **Step 7: Full suite, warnings, results file, commit.**

## Acceptance criteria

| Benchmark | Before | Target |
|---|---|---|
| `7x` rescan of an unchanged 10k library (wall) | 2,433 ms | **≤ 400 ms** |
| main-actor time within `7x` | ~2,250 ms | **≤ 150 ms** |
| `scan1k` first scan (wall) | 1,581–1,655 ms | **≤ 600 ms** |
| main-actor time within `scan1k` | ~1,500 ms | **≤ 150 ms** |

- All `ScanTests` pass, including duplicates and concurrency. `FolderScannerTests` pass, updated for the new API only.
- No per-keyword `FetchDescriptor` remains in the scan path.
- Zero new warnings. The full suite passes.

## Out of scope and follow-ups

- **Sorting by EXIF `DateTimeOriginal`** instead of file creation date. It's nearly free now that metadata is read during the scan, but it changes the user-visible order, so propose it in your results file and don't implement it.
- Scoping photos to the current library root when the user switches roots: note today's behaviour in your results file.
