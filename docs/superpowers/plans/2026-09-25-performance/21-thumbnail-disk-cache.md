# Task 21: Persistent Thumbnail Disk Cache

**Wave:** 2 · **Depends on:** 11 (`ThumbnailScheduler`, buckets, `invalidate(path:)`) · **Branch:** `perf/21-thumbnail-disk-cache` · **Size:** M

**Goal:** Thumbnails seen before load from a small on-disk file instead of being re-decoded from the original on every launch. Decoding from the original costs 50–80 ms for a 24 MP JPEG and more for RAW; a small cached thumbnail file costs a fraction of that.

**Why:** spec §C3. Today every thumbnail is re-decoded from the full original on every launch.

## Files

- Create: `Phocasa/Phocasa/Services/ThumbnailDiskCache.swift`
- Modify: `Phocasa/Phocasa/Services/ImageLoader.swift`: integrate the cache into the thumbnail decode path; `invalidate(path:)` also removes entries from disk
- Create: `Phocasa/PhocasaTests/ThumbnailDiskCacheTests.swift`
- Modify, if needed: `Phocasa/PhocasaTests/ImageLoaderTests.swift` (you own `ImageLoader` in this wave)

**Don't touch:** the grid views (task 11, merged), the view model, the detail view.

## Interfaces

- **Consumes** (task 11): `ThumbnailScheduler`, `ImageLoader.thumbnailBucket(forPixels:)`, `ImageLoader.invalidate(path:)`, and the internal `decodeThumbnail(at:maxPixels:preferEmbedded:)`.
- **Produces:**
  ```swift
  final class ThumbnailDiskCache: @unchecked Sendable {
      struct Key: Hashable, Sendable {
          let path: String
          let fileSize: Int64
          let modificationDate: Date
          let bucket: Int
          /// Reads size and mtime for `path`; nil if the file is missing.
          static func current(path: String, bucket: Int) -> Key?
      }
      /// Default location: Caches/<bundle id>/Thumbnails/v1
      static let defaultDirectory: URL
      init(directory: URL, byteLimit: Int = 1 << 30)    // 1 GB
      func image(for key: Key) -> CGImage?               // synchronous; call from the scheduler's work closure
      func store(_ image: CGImage, for key: Key)         // encodes and writes on a private utility queue
      func removeAll(forPath path: String)
      func trimIfNeeded()                                // LRU by access time until under byteLimit
  }
  ```

## Design notes

- **File names:** the SHA-256 hex of `"\(path)|\(fileSize)|\(mtime.timeIntervalSince1970)|\(bucket)"`, from CryptoKit (an Apple framework), plus `.jpg`. Use a two-character subfolder fan-out (`ab/abcdef….jpg`).
  - `removeAll(forPath:)` needs path → files. Keep a small index file (`index.plist`, path → [file names]), updated on the writer queue, or scan the directory. An index is preferred; rebuild it if it's missing or corrupt.
- **Encoding:** JPEG at quality 0.8 via `CGImageDestination`. It decodes fast, and HEIC encoding is slower.
- **LRU:** update the access time on read (`URLResourceValues.contentAccessDate`, or touch the modification date). `trimIfNeeded()` runs after every ~100 stores, on the utility queue, and deletes the oldest files until the total is under `byteLimit`.
- **Staleness:** the key includes file size and mtime.
  - The app's own metadata writes *restore* mtime, but a JPEG rating or keyword write **changes the file size**
    (the embedded XMP grows or shrinks). The key then misses once and that thumbnail is decoded again; the old entry
    stays until LRU trims it. That is correct, just not free. Measure how often it matters, then either accept it
    and document it, or propose something better in your results. Don't weaken the key without evidence.
  - Edit exports do change pixels. Task 30 wires `ImageLoader.invalidate(path:)` into the export success paths.
- **Loader order** inside the scheduler work: memory cache (as today) → disk cache → decode, then `store` to disk.
  These are task 11's hooks (`results/11.md`, "Needs from other tasks"). Put the disk read inside the
  `thumbnailScheduler` work closure, before `decodeThumbnail`, and the disk write next to
  `store(_:for:generation:)`. Keep the generation check: a decode that was running when the path was invalidated must
  not write a stale entry to disk either.
- **Test isolation:** the cache directory must be injectable. `ImageLoader` gets an internal initializer that takes a
  `ThumbnailDiskCache?`. The test host must never write into the real Caches folder. When `XCTestConfigurationFilePath`
  is set, `shared` works like this:
  - **No disk cache by default.** Existing `ImageLoaderTests` and the coordinator's cold-thumbnail benchmarks use
    `ImageLoader.shared` and `clearCache()`, and expect a real decode.
  - **If `PHOCASA_THUMBNAIL_CACHE_DIR` is set** (tests get it as `TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR`), `shared`
    uses that directory. The coordinator uses this for its A/B runs and for the real-app relaunch check, where the app
    is launched with the in-memory-store flag.
  - A normal launch always uses `defaultDirectory`.
- **`clearCache()` stays memory-only.** It has no app callers. The coordinator's "relaunch" benchmark relies on it:
  memory emptied, disk kept. Tests clear the disk through `ThumbnailDiskCache` itself.
- **Robust against outside deletion.** Someone else may empty or delete the cache directory while the app runs: the
  user clearing `~/Library/Caches`, or the coordinator's harness between cold runs. Reads must then miss without
  crashing, later stores must recreate folders, the index must heal itself, and trimming must tolerate files that are
  already gone. Add a test.
- **The cold path must not get slower.** On a miss, the cache now also encodes and writes a JPEG. That work runs on
  a utility queue, but it competes with thumbnail decodes for the same cores during a fast scroll. Measure the cold
  fast scroll with the disk cache enabled against `main` (see Step 5). It must not regress by more than 5%.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite.

- [ ] **Step 2: Failing tests first** (`ThumbnailDiskCacheTests`, using a temp cache directory and generated images).
  - `testStoreThenReadRoundTrips`: same size, and pixels close (JPEG: ±12 per channel).
  - `testKeyChangesWhenFileChanges`: rewrite the source with different bytes. `Key.current` differs, and the old key misses.
  - `testRemoveAllForPathRemovesEveryBucket`
  - `testTrimEvictsLeastRecentlyUsed`: with a limit of about 3 files, store A, B and C, read A, store D, trim. B is gone; A, C and D remain.
  - `testCorruptFileIsTreatedAsMissAndDeleted`
  - `testLoaderUsesDiskCacheOnSecondLaunch`:
    1. Create `ImageLoader` #1 with a temp disk cache, load a thumbnail and flush.
    2. Create `ImageLoader` #2 with the same directory (an empty memory cache).
    3. Load again. `decodeThumbnail` must not be called; use a debug counter.

- [ ] **Step 3: Implement `ThumbnailDiskCache`** and make its tests pass. Commit.

- [ ] **Step 4: Integrate it into `ImageLoader`** and make the loader test pass. `invalidate(path:)` now also calls `removeAll(forPath:)`. Commit.

- [ ] **Step 5: Measure.** Add a benchmark gated on `PHOCASA_BENCH=1`: 100 thumbnails at bucket 512 from generated 6000×4000 JPEGs, cold decode vs a warm disk cache (with a fresh memory cache). Record the medians in your results file. The target is a warm-disk load ≥ 10× faster than a cold decode.
  - Also measure, with a temp disk cache enabled:
    - the **cold** fast scroll (task 11's protocol: cells 2.5 ms apart, a cell more than 40 behind cancelled), with
      the disk cache empty before each run;
    - the **relaunch** fast scroll: disk warm, memory empty.
  - Measure both on `main` and on your branch.
  - Also run on real files if the coordinator gives you `~/PhocasaBenchRAW`: 190 JPG+ARW pairs, read only. ARW
    thumbnails already take about 12 ms from the embedded preview and real JPGs about 27 ms, so the win there is
    smaller than on synthetic 24 MP files. Report it honestly.
  - If a quick prototype shows the warm-disk path isn't meaningfully faster than decoding, stop and report instead of
    finishing.

- [ ] **Step 6: Full suite, warnings, results file, commit.**

## Acceptance criteria

- All `ThumbnailDiskCacheTests` pass.
- A warm-disk load is ≥ 10× faster than decoding from the original (benchmark).
- The cold fast scroll with the disk cache enabled is within 5% of `main`.
- Test runs, and the app launched with the in-memory-store flag, never write to the real `~/Library/Caches/<bundle id>` folder.
- Zero new warnings. The full suite passes.

## Out of scope

- Calling `invalidate(path:)` after exports (task 30).
- A settings UI to clear the cache: follow-up.
