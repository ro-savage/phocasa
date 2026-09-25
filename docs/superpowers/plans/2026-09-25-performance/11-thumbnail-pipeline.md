# Task 11: Thumbnail Pipeline and Grid Responsiveness

**Wave:** 1 · **Depends on:** 00 · **Branch:** `perf/11-thumbnail-pipeline` · **Size:** M

**Goal:**
- Visible thumbnails should appear about 10× sooner after a fast scroll (≈0.2 s instead of 1.5–2 s).
- RAW thumbnails should decode 11× faster.
- Resizing the window must not restart every thumbnail load.
- Memory must be bounded.
- A single click must select immediately.

**Why:** spec §C1–§C5.

## Files

- Create: `Phocasa/Phocasa/Services/ThumbnailScheduler.swift`
- Modify: `Phocasa/Phocasa/Services/ImageLoader.swift`. You own this file, **except** `loadFullResolution(for:)`, which must keep working unchanged: other files call it until task 12/22 replace them.
- Modify: `Phocasa/Phocasa/Views/PhotoGridView.swift`, `Phocasa/Phocasa/Views/PhotoGridItemView.swift`
- Create: `Phocasa/PhocasaTests/ThumbnailSchedulerTests.swift`, `Phocasa/PhocasaTests/ImageLoaderTests.swift`

**Don't touch:** the view model, `PhotoDetailView`, `MetadataService`, `ImageEditingService`.

## Interfaces

- **Must stay source-compatible:**
  - `ImageLoader.shared.loadThumbnail(for path: String, maxSize: CGFloat) async -> NSImage?` (used by `PhotoDetailView`'s minimap; task 12 also uses it for an instant placeholder);
  - `ImageLoader.shared.loadFullResolution(for:)`;
  - `ImageLoader.shared.clearCache()`.
- **Produces:**
  ```swift
  /// Bounded, newest-first, cancellable work scheduler with in-flight de-duplication.
  final class ThumbnailScheduler<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
      init(maxConcurrent: Int, qos: DispatchQoS.QoSClass = .userInitiated)
      /// Runs `work` for `key` at most once at a time. Callers with the same key share one execution.
      /// If every caller waiting on a key is cancelled before its work starts, the work never runs and callers get nil.
      func value(for key: Key, work: @escaping @Sendable () -> Value?) async -> Value?
  }

  extension ImageLoader {
      /// Size buckets in pixels (long edge). Requests are rounded UP to the next bucket, so a
      /// cached thumbnail is never smaller than requested.
      static let thumbnailBuckets: [Int] = [256, 384, 512, 768, 1024, 1536]
      static func thumbnailBucket(forPixels pixels: CGFloat) -> Int
      /// Evicts every cached size of `path`. Task 21 wires this to the disk cache; task 30 calls it after exports.
      func invalidate(path: String)
  }
  ```

## Things to measure before committing to a design

- **JPEG decode paths (spec §C2):** requests at ≤ 750 px (long edge ÷ 8) go through a software path of about 82 ms of CPU each, which runs in parallel across cores. Requests between 751 and 1500 px use the hardware decoder, about 46 ms each but serialised because there is only one. So a bucket just above 750 px isn't automatically faster under load. Measure throughput at the buckets the grid actually requests (`conc <px>` at, e.g., 512 and 768) before choosing bucket edges or `maxConcurrent`.

## Steps

- [ ] **Step 1: Baseline.**
  1. Run the full suite.
  2. Build imagebench and run `gen`, `copies`, `conc 600`. Record "last 20 done".
  3. Run `raw` only if `IMAGEBENCH_RAW` is set in your environment (README, **RAW files**). Never look for a RAW file yourself. If it isn't set, say so in your results.

- [ ] **Step 2: Scheduler tests first** (`ThumbnailSchedulerTests`). Use a `ThumbnailScheduler<Int, Int>` whose work closure records start order into a lock-protected array, and blocks on semaphores where a test needs to control timing.
  - `testNeverExceedsMaxConcurrent`: 20 requests, `maxConcurrent: 3`, track the peak concurrency with an atomic counter. The peak must be ≤ 3.
  - `testRunsNewestRequestFirst`: `maxConcurrent: 1`. Request 0 blocks on a semaphore; enqueue 1…5; release. The start order after 0 must be `[5, 4, 3, 2, 1]`.
  - `testCancelledBeforeStartNeverRuns`: `maxConcurrent: 1` with a blocker. Enqueue key 7 in a `Task` and cancel that task; release the blocker. Key 7's work never ran, and its caller got `nil`.
  - `testSameKeySharesOneExecution`: two concurrent callers for key 1. The work runs once and both callers get the value.
  - `testCancellingOneWaiterDoesNotCancelTheOther`: two callers for the same key; cancel one. The work still runs and the other caller gets the value.

  Run them: they must fail to compile.

- [ ] **Step 3: Implement `ThumbnailScheduler`.**
  - State, protected by an `NSLock` or `OSAllocatedUnfairLock`:
    - a LIFO stack of pending keys;
    - `[Key: Entry]`, where each `Entry` holds waiting continuations keyed by a per-caller token, plus a `started` flag;
    - a running count.
  - `value(for:work:)` uses `withTaskCancellationHandler` around `withCheckedContinuation`.
    - On cancel: remove that caller's continuation and resume it with `nil`. If the entry has no callers left and hasn't started, drop it from the stack.
  - A pump dequeues the **newest** pending key while `running < maxConcurrent`, then runs the work on `DispatchQueue.global(qos:)`. On completion it resumes all remaining waiters and pumps again.
  - Make the tests pass. Commit: `feat: add bounded LIFO cancellable ThumbnailScheduler`.

- [ ] **Step 4: `ImageLoader` tests first** (`ImageLoaderTests`). Generate test images into a temp dir with `CGImageDestination`.
  - `testBucketRoundsUp`:
    - `thumbnailBucket(forPixels: 1)` → 256
    - `300` → 384
    - `384` → 384
    - `385` → 512
    - `5000` → 1536
  - `testThumbnailRespectsBucketAndOrientation`: write a 1200×800 JPEG with orientation 6. `loadThumbnail(for:maxSize: 300)` returns an image whose long edge is 384 and whose height is greater than its width.
  - `testRAWStylePathFallsBackWhenEmbeddedPreviewTooSmall`: write a 2000×1500 JPEG with `kCGImageDestinationEmbedThumbnail: true` (a small embedded preview). Call the internal decode function with `preferEmbedded: true` and max 512. The result's long edge must be 512, meaning it fell back to a full decode.
  - `testCacheHitReturnsSameInstance`
  - `testInvalidateEvictsAllSizes`

- [ ] **Step 5: Rework `ImageLoader`'s thumbnail path.**
  - **Cache:**
    - `NSCache<ThumbnailCacheKey, NSImage>`, where `ThumbnailCacheKey` is a small `final class: NSObject` with `path` and `bucket`, and overrides `hash`/`isEqual`. This also removes the non-`Sendable` `NSString` capture warning (spec §F5).
    - `totalCostLimit = 512 * 1024 * 1024`, and cost = `cgImage.bytesPerRow * cgImage.height`. Remove `countLimit`.
  - **Flow:** check the cache; call `scheduler.value(for: key) { decode }`; store the result in the cache.
    - The scheduler is `ThumbnailScheduler<ThumbnailCacheKey-equivalent Sendable struct, CGImage>` with `maxConcurrent: ProcessInfo.processInfo.activeProcessorCount`.
    - Wrap the `CGImage` into an `NSImage` on return.
  - **Decode** (`func decodeThumbnail(at path: String, maxPixels: Int, preferEmbedded: Bool) -> CGImage?`). Common options: `kCGImageSourceThumbnailMaxPixelSize: maxPixels`, `kCGImageSourceCreateThumbnailWithTransform: true`, `kCGImageSourceShouldCacheImmediately: true`.
    - **RAW** (`FolderScanner.rawExtensions.contains(ext)`) → `preferEmbedded: true`. First try `kCGImageSourceCreateThumbnailFromImageIfAbsent: true`. If the result's long edge is less than `0.75 × maxPixels`, retry with `kCGImageSourceCreateThumbnailFromImageAlways: true`.
    - **Everything else** → `kCGImageSourceCreateThumbnailFromImageAlways: true`. For JPEG, the embedded EXIF thumbnail is only 160 px (spec §C2).
  - **Cleanup:**
    - Delete `thumbnailJPEGData(for:maxSize:)` (no callers).
    - Extract the shared `CGImageSource` boilerplate so `loadFullResolution` reuses it without changing its behaviour.
  - Commit: `perf: schedule thumbnails newest-first with bounded concurrency; RAW uses embedded previews`.

- [ ] **Step 6: Grid.**
  - **Size churn:** in `PhotoGridView`, replace `NSScreen.main?.backingScaleFactor` with `@Environment(\.displayScale) private var displayScale`. Compute the bucket once per layout: `ImageLoader.thumbnailBucket(forPixels: cellWidth * displayScale)`. Pass the **bucket** (an `Int`) to `PhotoGridItemView`, whose `.task(id:)` must key on `displayPath` + bucket only. A window resize within a bucket then no longer restarts loads (spec §C4).
  - **Click latency (spec §C5):** single-click selection must not wait for double-click detection. Keep `.onTapGesture(count: 2) { open }`, and move selection to a simultaneous gesture:
    ```swift
    .onTapGesture(count: 2) { viewModel.openDetail(for: photo) }
    .simultaneousGesture(TapGesture().onEnded { handleSelectionClick(photo) })
    ```
    `handleSelectionClick` holds today's modifier logic (`NSEvent.modifierFlags` is an allowed exception). A double-click therefore selects on the first click and then opens, like Finder.
  - **Cell body:** keep `PhotoGridItemView` cheap. Give the thumbnail area a fixed square frame from the cell width, so `LazyVGrid` doesn't measure variable-height content.
  - Commit: `perf: bucket grid thumbnail sizes; select on first click`.

- [ ] **Step 7: Measure.**
  - Write `Tools/imagebench` output for `conc 600` (unchanged tool; it shows the strategy) into your results file.
  - Add a scheduler benchmark to `ThumbnailSchedulerTests`, gated on `PHOCASA_BENCH=1`: 200 synthetic 80 ms "decodes" requested 2.5 ms apart. Measure the time from the last request until the last 20 requested are done. The target is ≤ 300 ms, against ~1,500 ms with a FIFO unbounded queue, which you can simulate in the same test for comparison.

- [ ] **Step 8: Full suite, warnings, results file, commit.**

## Acceptance criteria

- The scheduler tests pass, including cancellation and de-duplication.
- The scheduler benchmark shows "last 20" ≤ 300 ms.
- A RAW thumbnail takes ≤ 25 ms at 600 px (the spec measured 15 ms). This is measured only if the coordinator provides `IMAGEBENCH_RAW`. Otherwise show in code that RAW takes the `IfAbsent` path, with the fallback test.
- No cell's `.task` restarts while resizing within a bucket. Show this in the code, or with a debug counter in a test.
- The `NSString` Sendable warning is gone, and there are zero new warnings.
- `loadThumbnail` and `loadFullResolution` signatures are unchanged.

## Out of scope and follow-ups

- The disk cache (task 21).
- `PhotoDetailView`'s use of `loadFullResolution` (task 12).
- The context-menu tag filtering (task 30).
- Replacing `LazyVGrid` with an `NSCollectionView`: only if profiling after waves 1–2 still shows grid layout as the bottleneck. Note your observations in the results file.
