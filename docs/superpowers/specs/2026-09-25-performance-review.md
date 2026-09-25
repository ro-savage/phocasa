# Phocasa Performance & Maintainability Review

**Date:** 2026-09-25
**Status:** Basis for the plan in `docs/superpowers/plans/2026-09-25-performance/`
**Scope:** All app code (~5,000 lines) was read in full. The hotspots below were then measured.

**Measurement setup**
- Machine: MacBookPro18,1 (M1 Pro, 8 performance + 2 efficiency cores, 32 GB), macOS 27.0, Xcode 26.6.
- Harnesses:
  - `PhocasaTests/PerformanceBenchmarks.swift` (installed by task 00): SwiftData and view-model paths.
  - `Tools/imagebench/imagebench.swift` (installed by task 00): ImageIO and CoreImage paths.
- Test data:
  - Libraries of 2,000 and 10,000 photos: 40 tags across 5 categories, about 2 tags per photo, SQLite on disk.
  - A synthetic 6000×4000 JPEG, 12.6 MB, EXIF orientation 6, with a 160 px embedded thumbnail, plus 200 copies.
  - One local 24 MP `.ARW` (opened read-only).
- Debug and Release builds perform the same on the data path. The cost is inside SwiftData: each property read on a model object costs about 0.65–0.9 µs, plus the fetch itself. Swift code generation isn't the bottleneck.

---

## 1. Where the time goes

| User action | Today (10k photos) | Achievable | Evidence |
|---|---|---|---|
| Filter click, sort toggle, search keystroke | **340–440 ms**, main thread blocked | < 10 ms | §A1 |
| Rating change | 53–102 ms | < 5 ms | §A2 |
| App launch, library unchanged | **~2.2 s**, main thread blocked | ~0.2 s, in the background | §B1 |
| First import | **~1.6 ms per photo** on the main thread (≈16 s freeze for 10k) | background only | §B2 |
| Visible thumbnails after a fast scroll | **1.5–2 s** | 0.2 s | §C1 |
| RAW thumbnail | 173 ms | 15 ms | §C2 |
| RAW slider preview | 137 ms; up to ~330 ms if it lands during the full-res pass | 29 ms | §E1 |

---

## 2. Findings

### A. Library data path (SwiftData)

**A1. Every interaction re-fetches everything.**
- `PhotoLibraryViewModel.loadExistingData()` fetches every photo, the bin, every tag and the libraries, then recounts the sidebar.
- It is called from `applyFilter`, `applyCurrentFilter` (which `ContentView` calls on *every* search keystroke), `toggleSortOrder`, and the bin and delete paths.

| Measured at 10k | Time |
|---|---|
| `loadExistingData` | 341–346 ms (≈185 ms of it is the raw fetch) |
| `applyFilter(.rated(3))` | 386–421 ms |
| `applyFilter(.tag)` | 428–445 ms |
| Search keystroke | 380–398 ms |
| `toggleSortOrder` | 339–345 ms |

| In-memory equivalents at 10k | Time |
|---|---|
| `allPhotos.filter { $0.rating == 3 }` | 7–9 ms |
| Search without a re-fetch | 45–53 ms (it reads model properties) |
| Pure `Set`/array work over a cached `[UUID]` | 0.5–1.3 ms |
| `reversed()` instead of re-fetching sorted | 0.4–1.3 ms |

→ Fetch once. Filter, sort and search in memory over cached plain values ("facts"), not over model objects.

**A2. Counts iterate model objects.** A single pass computing rating, tag, category and file-type counts over 10k model objects takes 79–96 ms. It runs on every rating or tag change (`updateSidebarAfterChange`), and three times over when filters are active (`recomputeCrossFilterCounts`). Most of the `setRating` cost is this recount, not the save.

**A3. Linear lookups by id.** `photos.firstIndex(where:)` costs about 8 ms at 10k. It is used by:
- `navigateDetail`, `rangeSelect`, `navigateGrid`;
- `ContentView.firstSelectedPhoto`;
- `PhotoDetailView`'s overlay, which runs on every body evaluation: every zoom or pan frame and every slider tick.

`selectedPhotosList` is also O(N) and is called several times per operation. Building a `[UUID: Int]` index takes 7.7–10.8 ms; after that, 1,000 lookups cost 0.07–0.15 ms.

**A4. The sidebar re-filters tags per category on every render** (`SidebarView.swift:64`, `allTags.filter { $0.category == category && $0.parent == nil }`). It also reads the `parent` relationship, which is always nil.

**Non-wins (measured):**
- `relationshipKeyPathsForPrefetching` for tags made the cold fetch slower (280 vs 223 ms). Cold tag faults only cost about 46 ms at 10k.
- The `fileExists` check itself is cheap on a local SSD (24 ms for 10k). What makes `refreshAvailability` slow is the `loadExistingData` inside it.

### B. Launch and scan

**B1. Launching with an unchanged library blocks the main thread for about 2.2 s.** A rescan of 10k existing photos takes 2.43 s; the background `FolderScanner` accounts for only 0.17 s of it. The rest runs on the main actor:
- Fetch everything.
- **Reassign the same values** to `jpgPath`, `rawPath`, `fileSize` and `isDeleted` on every row (`VM:279-282`). SwiftData marks the rows changed even though nothing changed: after the reassignment `hasChanges == true`, and 1k rows take 111–115 ms to save.
- `needsAvailabilityCheck = true`, so every file is `stat`ed a second time and `loadExistingData` runs again.

At launch this happens twice: `setModelContext` → `loadExistingData` (with a `stat` pass), then `rescanCurrentLibrary`.

**B2. The first scan costs about 1.6 ms per photo on the main actor** (1,000 new photos: 1.58–1.66 s).
- `metadata.readMetadata` runs synchronously on the main actor for every new file: 197–202 ms per 1k.
- `findOrCreateTag` runs one `FetchDescriptor` per keyword: about 0.3 ms per keyword, 295–298 ms per 1k, which is more than the metadata read. A dictionary lookup would cost 0.02–0.18 ms per 1k.

**B3. Scans can run concurrently.** Launch rescan, toolbar Rescan and Open Folder each start a `Task`, with no guard. Two overlapping scans can both insert the same new files. After that, `Dictionary(uniqueKeysWithValues:)` (`VM:271`) traps on the duplicate keys during every later scan, so the app **crashes on launch**.

### C. Thumbnails

**C1. Scheduling.** `ImageLoader` dispatches one block per cell to an unbounded concurrent queue (64 decodes at once when nothing is cached). SwiftUI `.task` cancellation never reaches work already queued, so after a fast scroll the visible cells wait behind every cell that was scrolled past.

200 thumbnails at 600 px:

| Strategy | Last 20 requested done |
|---|---|
| Current | 1,955–2,130 ms |
| Bounded pool (active core count), newest request first | **200–236 ms** after the final request |

Total work is the same (about 2 s); only the ordering changes. Dropping requests for cells that scrolled away would also cut the total.

**C2. Decode options.** The app uses `CreateThumbnailFromImageAlways` for everything.
- **RAW:** the embedded preview (`FromImageIfAbsent`) takes 15 ms at 600×401, against 173 ms for `Always`. Use `IfAbsent` for RAW.
- **JPEG:** `IfAbsent` returns the 160×106 EXIF thumbnail, so keep `Always`. JPEG cost depends on the requested size:

| Requested max pixels | Time | CPU | Likely path |
|---|---|---|---|
| ≤ 750 (long edge ÷ 8) | ~82 ms | ~85 ms | software |
| 751–1500 | ~46 ms | ~13 ms | hardware decoder, which is serialised (one hardware decoder) |

- `kCGImageSourceShouldCache: false` made no difference.

**C3. Cache.**
- `NSCache` has `countLimit = 500` and no cost limit. At 800–1500 px thumbnails that can exceed 1 GB.
- Nothing is cached across launches: every thumbnail is re-decoded from the full original at about 50–80 ms each.
- `PhotoAsset.thumbnailData` exists but is no longer read (after the current uncommitted diff), and `ImageLoader.thumbnailJPEGData` has no callers.

**C4. Size churn** (from the uncommitted diff).
- The grid computes `thumbSize = max(300, cellWidth × scale)` continuously. The cell's `.task(id:)` includes `Int(thumbnailSize)`, so **every pixel of window resize restarts every visible cell's load**.
- The cache key rounds the size *down* to the nearest 100, so whichever size decodes first wins the bucket.
- The grid uses `NSScreen.main?.backingScaleFactor` instead of `@Environment(\.displayScale)`.

**C5. Click latency** *(by reading)*. `.onTapGesture(count: 2)` placed before `.onTapGesture(count: 1)` (`PhotoGridView.swift:32-35`) makes every single click wait out the double-click interval before it selects.

### D. Detail view

**D1. Portrait photos display sideways (bug, confirmed).** `CGImageSourceCreateImageAtIndex` ignores `kCGImageSourceCreateThumbnailWithTransform`. The 6000×4000 orientation-6 test image comes back as 6000×4000 (landscape) where 4000×6000 is correct. The grid thumbnails and the edit path (`CIImage.oriented`) are correct, so the image also jumps when editing starts.

**D2. Decode cost vs memory.** Detail images decoded with the options below:

| Decode | Time | Output | Size |
|---|---|---|---|
| Full-res `CreateImageAtIndex` (hardware) | 48 ms | 6000×4000 | 91.6 MB |
| Thumbnail at 2560 px | 100 ms | 1707×2560 | 16.7 MB |
| Thumbnail at 3840 px | 202 ms | 2560×3840 | 37.5 MB |
| Thumbnail at 6000 px (full-res, oriented) | 241 ms | 4000×6000 | 91.6 MB |
| Full-res decode, then rotate on the CPU | 254 ms | 4000×6000 | 91.6 MB |
| `CreateImageAtIndex` + `kCGImageSourceSubsampleFactor: 2` | **36 ms** | 3000×2000 | 22.9 MB |

- → Keep the hardware decode and **apply the orientation when displaying** (view transform), not by rotating pixels.
- Use subsample 2 for fit-to-screen and full resolution only when zooming in.
- Today every navigation decodes about 92 MB with no cache and no prefetch of the photos either side.

**D3. Body re-evaluation.** The whole `PhotoDetailView` body re-runs on every scroll-wheel, drag and pinch frame, because it reads `zoomState` directly. It also re-runs on every slider tick (`.onChange(of: viewModel.editParameters)`), and each run includes the O(N) `firstIndex` from §A3.

**D4. Wasted RAW render.** When a photo has both JPG and RAW saved edits, `loadImages` renders the full RAW, which takes seconds, then discards the result (`PhotoDetailView.swift:211-218`).

**D5. Scroll events hijacked** *(by reading)*. `ZoomPanState` installs an app-wide local `.scrollWheel` monitor that consumes every scroll event while the detail view is open. The edit sidebar's `ScrollView` and the tag popover's `List` can't be scrolled.

### E. Editing pipeline

**E1. RAW previews.** Rendered to fit 1600 px, including the post-RAW filter chain:

| CIRAWFilter settings | Median | First render |
|---|---|---|
| Full decode, then scale | 157 ms | 281 ms |
| **Draft mode, then scale (today)** | **137 ms** | 267 ms |
| `scaleFactor` set to the target size | 38.5 ms | 207 ms |
| Draft mode + `scaleFactor` | **29 ms** | 180 ms |

Toggling draft mode on the cached filter did not lose cached state: the next preview after a full pass took 138 ms.

**E2. The full-res pass blocks previews** (from the uncommitted diff).
- 300 ms after the last slider tick, the same chain renders at native resolution on the *same* serial queue.
- That pass takes 192 ms for RAW and ≈58 ms for a 24 MP JPEG. A slider tick that lands during it waits up to ~330 ms for RAW.
- Work already queued can't be cancelled, so stale previews also pile up behind each other; the `renderGeneration` check only runs after the render finishes.
- A render at about 3000 px on the long edge costs 11 ms, against 58 ms at native size.

**E3. Deferred rendering.** For large outputs `CIContext.createCGImage(_:from:)` returns in about 4.5 ms but hasn't produced the pixels yet. They are produced when the image is first drawn, probably on the main thread (≈58 ms at full resolution). Use `createCGImage(_:from:format:colorSpace:deferred: false)`.

**E4. JPEG previews are already fast.** A cached `CIImage(contentsOf:)` source renders in 4.7 ms (median).
- `.cacheIntermediates: true` brings that to 2.6 ms.
- **Pre-shrinking the source makes it slower** (7.6 ms), because a CGImage-backed source is re-uploaded to the GPU on every render. Do not do it.

**E5. Structure.**
- `processRAW`, `processStandard` and the two export functions repeat the same load → filter → render sequence.
- `applyPostRAWFilters` and `applyStandardFilters` share vibrance, sharpness, clarity and vignette code, in a different order.
- Filters are addressed by string name through key-value coding.

### F. Metadata

**F1. JPEG ratings are never read back (bug, confirmed).** `writeToImageFile` writes `xmp:Rating`, but `readMetadata` reads `kCGImagePropertyTIFFDictionary["Rating"]`, which ImageIO never fills. Of 500 files written with rating 3, all came back as 0. Keywords survive the round trip.

**F2. Rating or tagging a RAW-only photo erases its saved RAW edits (bug, by reading).**
- `writeMetadata(rating:keywords:toImageAt:)` calls `writeSidecar(rating:keywords:for:)`, whose `editParameters` defaults to `nil`, so the sidecar is rewritten without `<phocasa:EditParameters>`.
- `metadataWriteItem(for:)` uses `displayPath`, which is the RAW path for RAW-only photos.
- `hasRawEdits` stays `true`, so the grid still shows the "edited" badge.

**F3. Writes can land out of order.** `writeMetadataInBackground` starts a new `Task.detached` per change, with no ordering. Pressing 3 then 4 quickly can leave 3 in the file, and two concurrent writes to one file can interleave. Edit-parameter sidecar writes happen on the main thread and can race the background rating writes to the same sidecar.

**F4. The JPEG metadata write targets the file it is reading** *(risk, by reading)*. `CGImageDestinationCreateWithURL(url…)` is pointed at the same URL as the open `CGImageSource`. Write to a temporary file in the same directory, then `FileManager.replaceItemAt`.

**F5. Warnings.** `kUTTypeJPEG` is deprecated (`MetadataService.swift:99`). There is also a non-`Sendable` `NSString` captured in a `@Sendable` closure (`ImageLoader.swift:52`).

### G. Other correctness issues

- **G1. Availability.** Availability was computed once and then acted as an allow-list, so photos inserted or restored after the check were hidden. This broke 28 tests. **Fixed on 2026-09-25**, before the plan: `missingPhotoIDs` replaced `availablePhotoIDs`, and regression tests were added.
- **G2. Test runs touched the real library.** The test host app opened and rescanned the user's real store on every test run. **Fixed on 2026-09-25:** `PhocasaApp` uses an in-memory store when `XCTestConfigurationFilePath` is set.
- **G3. Space/Return open an arbitrary photo.** They open `selectedPhotos.first`, which is arbitrary order for a `Set`, so with several photos selected a random one opens.
- **G4. Leaving the detail view loses the grid scroll position** *(by reading)*. `ContentView.mainContent` swaps the whole `NavigationSplitView` out for the detail view, so returning rebuilds the grid at the top.
- **G5. Main-thread file I/O.** `trashItem` runs on the main thread (for example, Empty Bin with many photos). Sidecar reads and writes for edit parameters also run on the main thread.

### H. Structure and maintainability

- **H1. `PhotoLibraryViewModel` is 1,241 lines** mixing library loading, filtering and counting, selection, tags, bin, scanning, metadata write-back, editing state, render scheduling, crop, export and presets.
- **H2. Duplicated logic:**
  - filter grouping (`applyActiveFilters` vs `applyFilterGroup`);
  - counting (`recomputeSidebarCounts` vs `recomputeCrossFilterCounts`);
  - three near-identical ImageIO blocks in `ImageLoader`;
  - `sideBySideView` vs `jpgComparisonView`;
  - sidecar trashing (`trashRAWFile` vs `confirmPermanentDelete`);
  - `category:name` keyword parsing inline in `scanFolder`, which is the inverse of `Tag.fullName`.
- **H3. String-typed `SidebarFilter.filterCategory`.** Should be an enum.
- **H4. Dead code:**
  - `PhotoAsset.thumbnailData`;
  - `ImageLoader.thumbnailJPEGData`;
  - the `Tag.parent`/`children` hierarchy. Nothing ever sets a parent, so the sidebar's child rows never render.
- **H5. `PhotoAsset.isDeleted` hides SwiftData's `PersistentModel.isDeleted`** (confirmed in the macOS SDK's `SwiftData.swiftinterface`). It means "in the bin", which invites confusion.
- **H6. Boilerplate concurrency.** About ten `withCheckedContinuation` + `queue.async` wrappers with `@unchecked Sendable`, and none of them is cancellation-aware. macOS 14 supports actors on a `DispatchSerialQueue` executor, which removes the boilerplate and makes `Task.isCancelled` checks work.
- **H7. Every new file needs a hand-written `project.pbxproj` entry** (objectVersion 56, explicit file references). Parallel work would collide on object IDs. Xcode 16+ synchronized folders fix this.

---

## 3. Measured non-wins (do not implement)

- Pre-shrinking JPEG edit sources: slower (§E4).
- Prefetching tag relationships: slower (§A).
- Downsized thumbnail decodes for the JPEG detail view: 2–4× slower than the hardware full decode (§D2).
- `kCGImageSourceShouldCache: false`: no effect (§C2).
- Release vs Debug builds: no difference on the data path.
