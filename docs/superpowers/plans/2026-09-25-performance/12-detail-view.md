# Task 12: Detail View

**Wave:** 1 · **Depends on:** 00 · **Branch:** `perf/12-detail-view` · **Size:** L

**Goal:**
- Portrait photos display upright.
- Arrow-key navigation is instant, because neighbours are prefetched.
- A lower-resolution image appears immediately, with full resolution loaded only when zooming.
- Zoom and pan frames no longer re-evaluate the whole view.
- The edit sidebar and tag popover scroll again.
- No full RAW render is wasted.

**Why:** spec §D1–§D5.

## Files

- Create: `Phocasa/Phocasa/Services/FullImageLoader.swift`
- Create: `Phocasa/Phocasa/Views/Detail/`:
  - `DisplayImage.swift`
  - `ZoomableImageView.swift`, which absorbs `ZoomPanState`
  - `MinimapView.swift`
  - `DetailOverlayControls.swift`
  - `ComparisonView.swift`
- Modify: `Phocasa/Phocasa/Views/PhotoDetailView.swift`. It becomes a thin container; keep `struct PhotoDetailView` and its `init(viewModel:photo:)`.
- Create: `Phocasa/PhocasaTests/ImageOrientationTests.swift`, `Phocasa/PhocasaTests/FullImageLoaderTests.swift`

**Don't touch:**
- the view model (read its existing API only);
- `ImageLoader.swift` (task 11: use `loadThumbnail(for:maxSize:)` only);
- `ImageEditingService.swift` (task 13: call `processStandard`/`processRAW` with their existing signatures);
- `EditSidebarView`, `CropOverlayView`, `ContentView`.

## Interfaces

- **Consumes:**
  - `ImageLoader.shared.loadThumbnail(for:maxSize:) async -> NSImage?`
  - `ImageEditingService.shared.processStandard(url:parameters:maxSize:)` and `processRAW(url:parameters:maxSize:)`
  - View-model properties as they exist today: `isEditing`, `editingRAW`, `isCropping`, `showOriginal`, `showSideBySide`, `showJPGComparison`, `editedPreviewImage`, `fullResEditImage`, `jpgComparisonImage`, `cropRect`, `editParameters`, `photos`, `navigateDetail`, `setRating`, `startEditing`, `stopEditing`, `applyCrop`, `cancelCrop`, `updateEditPreview`, `showExportOptions`, `exportRAWToJPG`, `exportJPGPermanent`
- **Produces** (task 22 builds on these):
  ```swift
  /// An image plus the EXIF orientation to apply at display time (no pixel rotation).
  struct DisplayImage {
      let cgImage: CGImage
      let orientation: CGImagePropertyOrientation     // .up for images from the edit pipeline
      var orientedSize: CGSize { get }                  // size after orientation (points == pixels)
      init(cgImage: CGImage, orientation: CGImagePropertyOrientation)
      init?(nsImage: NSImage)                            // orientation .up
  }

  struct OrientedImage: View {                          // renders DisplayImage upright
      init(_ image: DisplayImage, interpolation: Image.Interpolation = .high)
  }

  final class FullImageLoader: @unchecked Sendable {
      static let shared: FullImageLoader
      /// Hardware-path decode; applies no rotation (orientation is returned for display).
      func load(path: String, subsample: Int) async -> DisplayImage?
      func cachedImage(path: String, subsample: Int) -> DisplayImage?
      func prefetch(paths: [String], subsample: Int)     // replaces any previous prefetch set
      static func subsampleFactor(imagePixelSize: CGSize, viewportPixelSize: CGSize) -> Int
  }

  struct ComparisonView: View {
      init(left: (label: String, image: DisplayImage?), right: (label: String, image: DisplayImage?))
  }
  ```

## Key facts (measured, spec §D2)

- `CGImageSourceCreateImageAtIndex` is the **fastest** full decode (48 ms for 24 MP, via the hardware decoder), but it ignores orientation.
- Downsized decodes through `CreateThumbnailAtIndex` are 2–4× **slower**, and rotating pixels on the CPU adds ~200 ms. Don't use either for JPEG.
- `CreateImageAtIndex` + `kCGImageSourceSubsampleFactor: 2` takes 36 ms and produces 22.9 MB, against 91.6 MB at full resolution.
- SwiftUI can apply the orientation at display time: `Image(decorative: cgImage, scale: 1, orientation: Image.Orientation)`. The `CGImagePropertyOrientation` cases map one-to-one by name onto `Image.Orientation`.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite. Build imagebench and run `gen` + `orient` + `detail`, recording the numbers.

- [ ] **Step 2: Orientation tests first** (`ImageOrientationTests`).
  1. For each of the 8 `CGImagePropertyOrientation` values, write a small **asymmetric** test JPEG (e.g. 30×20: a red top-left quadrant, blue top-right, green bottom-left, white bottom-right) tagged with that orientation.
  2. **Oracle:** `CGImageSourceCreateThumbnailAtIndex` with `WithTransform` + `FromImageAlways` at max 30 px.
  3. **Subject:** render `OrientedImage(DisplayImage(cgImage: rawDecode, orientation: o))` framed at `orientedSize`, using `ImageRenderer` at scale 1.
  4. Assert that the sizes match, and that the colour at the centre of each quadrant matches (±8 per channel, since JPEG compression shifts colours slightly).

  Also test `DisplayImage.orientedSize` swaps width and height for `.left`, `.right`, `.leftMirrored` and `.rightMirrored`. Run them: they must fail to compile.

- [ ] **Step 3: Implement `DisplayImage` and `OrientedImage`** using `Image(decorative:scale:orientation:)` with `.resizable()`. Make the tests pass. Commit.

- [ ] **Step 4: `FullImageLoader` tests first** (`FullImageLoaderTests`), using generated JPEGs in a temp dir.
  - `testLoadReturnsRawPixelsAndOrientation`: a 600×400 JPEG with orientation 6 returns a 600×400 `cgImage`, `.right`, and `orientedSize` 400×600.
  - `testSubsampleHalvesDimensions`: subsample 2 → 300×200.
  - `testSubsampleFactorChoosesLargestThatCoversViewport`:
    - (6000×4000 image, 2800×1800 viewport) → 2
    - (6000×4000, 1400×900) → 4
    - (6000×4000, 5000×3000) → 1
    - never more than 8
  - `testCacheIsBoundedByBytes`: set a small byte limit through an internal init, load 3 images, and check that the oldest is evicted (least recently used first).
  - `testPrefetchPopulatesCache`: after `prefetch` finishes (poll `cachedImage` with a timeout), `cachedImage` is non-nil.
  - `testRAWUsesEmbeddedPreviewFirst`: `XCTSkip` unless the `PHOCASA_TEST_RAW` environment variable names a file. Never search for RAW files, and don't rely on the user's files in committed tests (README, **RAW files**).

- [ ] **Step 5: Implement `FullImageLoader`.**
  - **Decode:** `CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceSubsampleFactor: f])`, where `f` is 1, 2, 4 or 8 and the key is omitted for 1. Read the orientation from `CGImageSourceCopyPropertiesAtIndex` (`kCGImagePropertyOrientation`).
  - **RAW paths** (`FolderScanner.rawExtensions`): the first stage uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageIfAbsent` + `WithTransform` + `ThumbnailMaxPixelSize` = viewport long edge. That returns the embedded preview, already oriented, so its orientation is `.up`. A full RAW decode happens only when zoom needs it. Time it with imagebench `raw` only if `IMAGEBENCH_RAW` is set (README, **RAW files**). Otherwise note that RAW timing wasn't measured.
  - **Cache:** an LRU keyed by `(path, subsample)` with a byte limit of 512 MB, where cost = `bytesPerRow × height`, behind an `NSLock`.
  - **Decode queue:** a serial `DispatchQueue(qos: .userInitiated)` for foreground loads and another at `.utility` for prefetch. A new prefetch set cancels queued prefetches that haven't started (a generation counter checked when each item starts).
  - Make the tests pass. Commit: `perf: add FullImageLoader (hardware decode, subsampling, LRU, prefetch)`.

- [ ] **Step 6: Split `PhotoDetailView`.**
  - **`PhotoDetailView`** (container) keeps the image-loading state (`displayedImage`, `originalImage`, `renderedEditImage` become `DisplayImage?`), the `.task(id:)`, the popover, the confirmation dialog and `.onChange(of: viewModel.editParameters)`. It chooses the current image with the same precedence as today's `currentImage`, and renders:
    - `ZoomableImageView(image:, isCropping:, onDisplayRectChange:)`, which **alone** owns and observes `ZoomPanState` together with its minimap. Zoom and pan frames therefore invalidate only this subtree.
    - `DetailOverlayControls(viewModel:photo:onShowTags:)`, which holds the file name, index, tags, edit buttons, rating and chevrons. The `viewModel.photos.firstIndex` lookup moves in here so it no longer runs on zoom frames; task 30 swaps it for `index(of:)`.
    - `ComparisonView` for both side-by-side and JPG comparison. Delete the two duplicated views. The JPG comparison image comes from `viewModel.jpgComparisonImage`, an `NSImage`, wrapped with `DisplayImage(nsImage:)`; its orientation is fixed in task 22.
    - `CropOverlayView`, unchanged, fed `imageDisplayRect`. Compute that rect from **`orientedSize`**.
  - **Edit images** from the view model are `NSImage` and already oriented. Wrap them with `DisplayImage(nsImage:)`.
  - Zoom and fit maths use `orientedSize` everywhere they used `image.size`.

- [ ] **Step 7: Progressive loading and prefetch** in `loadImages()`.
  1. **Instantly:** show a thumbnail placeholder, oriented `.up`, if one is available before the fit image. `ImageLoader` has no cache-only lookup, and you don't own it, so don't wait for `loadThumbnail` before starting the fit decode. Run them concurrently and show the thumbnail only if it arrives first. List a cache-only `ImageLoader` lookup under "Needs from other tasks".
  2. **Fit image:**
     ```swift
     let f = FullImageLoader.subsampleFactor(imagePixelSize: <from properties>,
                                             viewportPixelSize: viewport * displayScale)
     ```
     Use `@Environment(\.displayScale)`. Load at `f` and show it. Keep the existing `withAnimation(.easeInOut(duration: 0.15))` crossfade.
  3. **Prefetch:** `FullImageLoader.shared.prefetch(paths:subsample:)` for index ±1, plus +2 in the direction of the last navigation. Get the neighbours from `viewModel.photos` (one `firstIndex` per navigation is fine here).
  4. **Full resolution on zoom:** when `magnification × fitSize × displayScale` exceeds the loaded image's pixel size, load subsample 1 and swap it in without resetting zoom or pan.
  5. **Wasted RAW render (spec §D4):** render saved RAW edits only when there's no JPG edit render, i.e. `renderedEditImage == nil`.

- [ ] **Step 8: Scroll-wheel monitor (spec §D5).**
  - In `ZoomPanState.startMonitoring()`, capture `weak var hostWindow = NSApp.keyWindow`.
  - Record the image viewport's frame in `.global` coordinates from `ZoomableImageView`'s `GeometryReader`.
  - Handle, and consume, a scroll event **only** when `event.window === hostWindow` and the flipped `locationInWindow` falls inside that frame. Flip with `contentHeight - y`, where `contentHeight = window.contentView.bounds.height`. Otherwise return the event untouched.
  - Put the decision in a pure static function, `static func shouldHandleScroll(locationInWindow: CGPoint, contentHeight: CGFloat, viewportFrame: CGRect) -> Bool`, and unit-test it: inside → true, outside → false, and a bottom-left-origin conversion case.

- [ ] **Step 9: Full suite, warnings, results file, commit.**

## Acceptance criteria

- The orientation tests pass for all 8 orientations.
- The detail view uses `orientedSize` for fit, zoom, minimap and the crop display rect.
- `FullImageLoader` tests pass. Imagebench `detail` confirms the subsample-2 decode is ≤ 45 ms and ~23 MB.
- `ZoomPanState` is referenced only from `ZoomableImageView` and its minimap.
- A scroll event outside the image viewport, or in another window, is not consumed (pure-function test).
- With both JPG and RAW saved edits, only the JPG render runs (code inspection plus a comment).
- No view-model or `ImageLoader` changes. The full suite passes with zero new warnings.

## Notes

- `loadImages()` renders saved edits with `processStandard`/`processRAW` at full resolution. After task 13 these calls default to the `.preview` lane. Don't add `lane:` (it doesn't exist on your branch). Record it as a follow-up for task 22, which should move them to `.full`.

## Out of scope and follow-ups

- The JPG comparison image's orientation, and moving edit state out of the view model (task 22).
- Swapping `firstIndex` for `index(of:)` (task 30).
- The edit render pipeline itself (task 13).
