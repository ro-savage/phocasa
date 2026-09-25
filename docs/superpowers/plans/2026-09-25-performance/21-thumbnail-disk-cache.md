# Task 21: Persistent Thumbnail Disk Cache

**Wave:** 2 · **Depends on:** 11 (`ThumbnailScheduler`, buckets, `invalidate(path:)`) · **Branch:** `perf/21-thumbnail-disk-cache` · **Size:** M

**Goal:** Thumbnails seen before load from a small on-disk file instead of being re-decoded from the original on every launch. Decoding from the original costs 50–80 ms for a 24 MP JPEG and more for RAW; a small cached thumbnail file costs a fraction of that.

**Why:** spec §C3. Today every thumbnail is re-decoded from the full original on every launch.

## Files

- Create: `Phocasa/Phocasa/Services/ThumbnailDiskCache.swift`
- Modify: `Phocasa/Phocasa/Services/ImageLoader.swift`: integrate the cache into the thumbnail decode path; `invalidate(path:)` also removes entries from disk
- Create: `Phocasa/PhocasaTests/ThumbnailDiskCacheTests.swift`

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
  - The app's own metadata writes *restore* mtime, but they don't change pixels, so a cached thumbnail stays valid.
  - Edit exports do change pixels. Task 30 wires `ImageLoader.invalidate(path:)` into the export success paths.
- **Loader order** inside the scheduler work: memory cache (as today) → disk cache → decode, then `store` to disk.
- **Test isolation:** the cache directory must be injectable. `ImageLoader` gets an internal initializer that takes a `ThumbnailDiskCache?`. The test host must not write into the real Caches folder while tests run: when `XCTestConfigurationFilePath` is set, `shared` uses a temp directory.

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

- [ ] **Step 6: Full suite, warnings, results file, commit.**

## Acceptance criteria

- All `ThumbnailDiskCacheTests` pass.
- A warm-disk load is ≥ 10× faster than decoding from the original (benchmark).
- Test runs never write to the real `~/Library/Caches/<bundle id>` folder.
- Zero new warnings. The full suite passes.

## Out of scope

- Calling `invalidate(path:)` after exports (task 30).
- A settings UI to clear the cache: follow-up.
