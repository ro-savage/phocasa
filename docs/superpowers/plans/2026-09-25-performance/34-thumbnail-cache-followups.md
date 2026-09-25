# Task 34: Thumbnail Disk-Cache Follow-ups

**Wave:** 3A (in parallel with task 30) · **Depends on:** 21 merged · **Branch:** `perf/34-thumbnail-cache-followups` · **Size:** S–M

**Goal:** fewer re-decodes from the original after a relaunch.
- **Re-key after metadata-only rewrites.** A JPG rating or keyword write changes the file size, so today its cached
  thumbnail misses once and the photo is decoded again on the next launch. Pairs now write both files (task 23), so
  every rated pair's JPG is affected.
- **Serve smaller buckets from larger ones on disk,** as the memory cache already does (up to 2× larger). A grid zoomed
  out since the last launch then doesn't miss once per photo.
- **Persist the byte total,** so the first automatic trim of a session doesn't rescan the whole cache (434 ms per 10k
  files on the utility queue).
- **Remove `ImageLoader.loadFullResolution(for:)`,** which has no app callers since task 22. Update
  `DetailNavigationBenchmarks` ("old" path) and `ImageLoaderTests`.

**Why:** `results/21.md` "Follow-ups", and `results/wave-2-coordinator.md`.

## Files

- **You own:**
  - `Services/ImageLoader.swift`, `Services/ThumbnailDiskCache.swift`, `Services/MetadataWriter.swift` (the write
    hook only);
  - `ImageLoaderTests`, `ThumbnailDiskCacheTests`, `MetadataWriterTests`, `DetailNavigationBenchmarks`.
- **Don't touch:** everything else. Task 30 is restructuring the view model and views at the same time.
  `MetadataService` stays as it is: task 33 edits it in wave 3B.

## Design notes

- **Re-keying.**
  - `MetadataWriter.perform` stats the file before and after a successful `writeMetadata(…toImageAt:)`. The file must
    be a JPEG or other standard image; RAW sidecar writes don't touch the RAW. It then tells the disk cache to rename
    that photo's entries from the old size and mtime to the new ones.
  - The metadata write is lossless (task 23's splice or ImageIO's `CopyImageSource`), so the pixels are unchanged.
  - Keep it safe:
    - re-key only when the old key matches what's on disk;
    - never re-key after an export or anything else that changes pixels (those call `invalidate(path:)`);
    - never let a re-key race a store for the same path (use the cache's queue ordering).
  - `MetadataWriter` doesn't know about `ImageLoader` today. Choose a clean seam: an injected callback, or a
    notification-free protocol. Keep `MetadataWriter`'s test fake working.
- **Smaller from larger:** if the exact bucket misses, try buckets up to 2× larger on disk, and decode them down to the
  requested size, or serve them as is (the memory cache serves them as is). Measure the zoom-out case.
- **Byte total:** store it next to the cache (a small file written on the utility queue), and trust it on the next
  launch only if it's plausible. Rescan when it's missing or implausible.
- **Test host:** unchanged. No disk cache unless `PHOCASA_THUMBNAIL_CACHE_DIR` is set, and never `~/Library/Caches`.
  List `~/Library/Caches/com.phocasa.app` before and after your runs, as task 21 did.

## Steps

- [ ] **Step 1: Baseline.**
  - Run the full suite and the thumbnail benchmarks: `ThumbnailDiskCacheBenchmarks`, `ThumbnailSchedulerBenchmarks`,
    and the coordinator's `CoordinatorBenchmarks` thumbnail tests with `TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR` set
    (see `Tools/coordinator/README.md`).
  - Add gated benchmarks for your cases: rate 100 JPEGs and then "relaunch" (count decodes and time the loads); and a
    zoom-out after a relaunch.
- [ ] **Step 2: Failing tests first:**
  - after a rating write, a new loader with the same cache directory makes **0** original decodes;
  - after an export-like pixel change, it decodes again;
  - a smaller bucket is served from a larger cached one;
  - the byte total survives a relaunch, and a corrupt total triggers a rescan;
  - `loadFullResolution` is gone and its callers are updated.
- [ ] **Step 3: Implement.** Measure again, and stop and report if a change doesn't pay off.
- [ ] **Step 4: Full suite, warnings, results file, commit.**

## Acceptance criteria

- After rating N JPGs and relaunching, their thumbnails load from disk: 0 decodes (benchmark and test).
- The zoom-out-after-relaunch case is served from disk.
- The cold fast scroll and single cold decode stay within 5% of `main`, re-measured by the coordinator.
- Rating write cost on the main thread (`5a`/`5b`/`8c`) is unchanged, and writer throughput is within 5%.
- Tests and the test host never write to `~/Library/Caches`. Zero new warnings. The full suite passes.
