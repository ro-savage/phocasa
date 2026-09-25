# Task 13: Edit Render Pipeline

**Wave:** 1 · **Depends on:** 00 · **Branch:** `perf/13-edit-render-pipeline` · **Size:** M

**Goal:**
- RAW slider previews take ~30 ms instead of 137 ms.
- Previews never wait behind the full-resolution pass, and stale renders are skipped.
- Pixels are produced off the main thread.
- The filter chains are deduplicated and type-safe.
- `ImageEditingService` becomes an actor.
- **Rendered output must not change.**

**Why:** spec §E1–§E5.

## Files

- Modify: `Phocasa/Phocasa/Services/ImageEditingService.swift` (you own it)
- Modify: `Phocasa/Phocasa/ViewModels/PhotoLibraryViewModel.swift`, **only**:
  - `updateEditPreview()` and `renderFullResEdit(...)`;
  - the prepare `Task { … }` inside `startEditing(photo:isRAW:)`;
  - the properties `previewTask`, `fullResRenderTask` and `renderGeneration`.
- Create: `Phocasa/PhocasaTests/ImageEditingServiceTests.swift`

**Don't touch:** `PhotoDetailView` (task 12), the rest of the view model, `MetadataService`.

## Interfaces

- **Must stay source-compatible for callers:**
  - `processStandard(url:parameters:maxSize:) async -> NSImage?`
  - `processRAW(url:parameters:maxSize:) async -> NSImage?`
  - `prepareRAW(url:) async`, `prepareStandard(url:) async`
  - `exportRAWToJPEG(rawURL:parameters:outputURL:quality:) async -> Bool`
  - `exportStandardToJPEG(sourceURL:parameters:outputURL:quality:) async -> Bool`
  - `clearCache()`: keep it callable **synchronously**, so it becomes `nonisolated`
- **Produces:**
  ```swift
  actor ImageEditingService {
      static let shared: ImageEditingService
      /// Priority lane for renders. Preview renders never queue behind full-resolution ones.
      enum Lane: Sendable { case preview, full }
      func processStandard(url: URL, parameters: EditParameters, maxSize: CGSize? = nil, lane: Lane = .preview) async -> NSImage?
      func processRAW(url: URL, parameters: EditParameters, maxSize: CGSize? = nil, lane: Lane = .preview) async -> NSImage?
      static func rawScaleFactor(nativeSize: CGSize, maxSize: CGSize) -> Float   // pure, ≤ 1
  }
  ```
  Callers already `await` these methods, so converting to an actor doesn't change call sites apart from `clearCache()`.

## Design

- **Two lanes.** Use two actors, or one actor plus a second executor-backed helper: one for `.preview` and one for `.full`. Each runs on its own `DispatchSerialQueue`:
  ```swift
  actor RenderLane {
      private let queue: DispatchSerialQueue
      nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
      init(label: String, qos: DispatchQoS) { queue = DispatchSerialQueue(label: label, qos: qos) }
      // cached CIRAWFilter / CIImage source for this lane
  }
  ```
  - `DispatchSerialQueue` is available on macOS 14.
  - The two lanes may share one `CIContext`, which is thread-safe.
  - Each lane keeps its **own** cached `CIRAWFilter`, because the filter isn't thread-safe.
- **Stale-skip.** Each render method checks `Task.isCancelled` once it's running on its lane, **before** doing any work, and returns `nil` if cancelled. The view model already cancels `previewTask` and `fullResRenderTask` on every tick, so stale queued renders are skipped for free.
- **RAW previews** (spec §E1): when `maxSize != nil`, set
  - `rawFilter.isDraftModeEnabled = true`
  - `rawFilter.scaleFactor = rawScaleFactor(nativeSize: rawFilter.nativeSize, maxSize: maxSize)`

  Then drop the post-decode `scaleToFit` for RAW, unless the output still exceeds `maxSize` by more than 1 px. For full renders set `scaleFactor = 1` and `isDraftModeEnabled = false`. Set both properties **on every render**, because the filter is cached.
- **Non-deferred output** (spec §E3): `renderToNSImage` uses
  ```swift
  ciContext.createCGImage(image, from: extent, format: .RGBA8,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB), deferred: false)
  ```
  Before switching, confirm that this output matches today's `createCGImage(_:from:)` (see the tests).
- **One CIContext, one Metal command queue.** A `CIContext(mtlDevice:)` owns a single command queue, so GPU work from the two lanes can still serialise there even when the CPU side runs in parallel. Test 8 will show it. If previews still wait, give each lane its own context (`CIContext(mtlCommandQueue:options:)` with identical options), and confirm the characterisation tests still pass.
- **Call sites you don't own must keep compiling unchanged.** `PhotoDetailView` (task 12) and the rest of the view model call `processStandard`/`processRAW` without `lane:`, and `stopEditing` calls `clearCache()` synchronously. If the actor conversion forces an edit outside your ownership, stop and report it instead.
- **Keep:**
  - the working colour space (`CGColorSpaceCreateDeviceRGB()`) and every filter's parameters and **order**;
  - the RAW post-chain order: negative brightness → vibrance → saturation → tone curve → sharpness → clarity → vignette;
  - the standard-chain order: exposure → tone curve → colour controls → temperature/tint → vibrance → sharpness → noise reduction → clarity → vignette.
- **Dedupe** (spec §E5):
  - Replace `applyFilter(_ name: String, …)` with typed filters from `import CoreImage.CIFilterBuiltins` (`CIFilter.exposureAdjust()`, `.toneCurve()`, `.colorControls()`, `.temperatureAndTint()`, `.vibrance()`, `.unsharpMask()`, `.noiseReduction()`, `.gaussianBlur()`, `.vignette()`).
  - Extract the shared steps (vibrance, sharpness, clarity, vignette, tone curve) into small functions that both chains call **in their own order**.
  - Collapse the load → filter → render duplication in `processRAW`, `processStandard` and the two exports into shared helpers.
- **`cacheIntermediates`.** Measure `.cacheIntermediates: true` for the **preview** context usage: it gave a 2× faster JPEG preview (spec §E4). Adopt it only if resident memory after 50 preview renders of a 24 MP image stays within +150 MB of the `false` setting. Record both numbers either way.

## Steps

- [ ] **Step 1: Baseline.**
  1. Run the full suite.
  2. Imagebench: `gen`, then `ci`. Run `raw` only if `IMAGEBENCH_RAW` is set (README, **RAW files**); never look for a RAW file yourself. Record the preview medians and the full-pass time.

- [ ] **Step 2: Characterisation tests first** (`ImageEditingServiceTests`). Write these **before** any refactor, and make sure they pass against the current code.
  1. Generate a 1200×800 JPEG with a gradient and some shapes, plus orientation 6, in a temp dir.
  2. **Frozen reference renderer.** Copy the **current** `applyStandardFilters`, `applyTransform`, `applyToneCurve`, `orientedImage` and `scaleToFit` code verbatim into the test file as a private `ReferenceRenderer` that uses its own `CIContext` with the same options and `createCGImage(_:from:)`. This is the oracle, and it must not be edited later.
  3. **Parameter sets:**
     - default;
     - exposure +1;
     - highlights 50 / shadows 50;
     - contrast −30 + saturation 40;
     - temperature 30 + tint −20;
     - vibrance 60;
     - sharpness 50;
     - noise reduction 40;
     - clarity +50;
     - clarity −50;
     - vignette 60;
     - rotation 10;
     - flip horizontal;
     - crop `(0.1, 0.1, 0.5, 0.6)`;
     - one combined set.
  4. `testStandardRenderMatchesReference`: for each set, compare `processStandard(url:parameters:maxSize: CGSize(width: 600, height: 600))` with the reference. Sizes must be equal, and the max per-channel difference ≤ 1, after drawing both into RGBA8 sRGB bitmaps.
  5. `testStandardFullRenderMatchesReference`: the same with `maxSize: nil`, for three of the sets.
  6. `testRawScaleFactor`, a pure test:
     - (6000×4000, 1600×1100) → ≈ 0.2667
     - (1000×800, 1600×1100) → 1
     - never above 1
  7. `testCancelledRenderReturnsNilWithoutRendering`: start a `Task`, cancel it, and inside it call `processStandard`. It returns `nil`, and an internal debug render counter didn't increase.
  8. `testPreviewNotBlockedByFullLane`: start a `.full` render of a large generated image (6000×4000) and immediately a `.preview` render. The preview completes **before** the full render.

  Commit: `test: characterise edit rendering before refactor`.

- [ ] **Step 3: Convert to an actor with two lanes,** then run the tests. Tests 7 and 8 should now pass, and the others must stay green. Commit.

- [ ] **Step 4: Adopt RAW `scaleFactor` + draft for previews, and `deferred: false` output.** Run the tests. Commit.

- [ ] **Step 5: Typed filters and dedupe.** The characterisation tests must stay green. Commit: `refactor: typed CIFilters, shared filter steps, shared render helpers`.

- [ ] **Step 6: View-model scheduling.** Inside your owned view-model functions:
  - `updateEditPreview()` calls with `lane: .preview`, and `renderFullResEdit(...)` with `lane: .full`.
  - Keep the 30 ms and 300 ms delays and the `renderGeneration` checks.
  - Nothing else changes. `startEditing`'s prepare task calls `prepareRAW`/`prepareStandard` as before; they now warm both lanes' caches.

- [ ] **Step 7: Measure** (the `cacheIntermediates` decision and the imagebench `ci`/`raw` equivalents).
  - Add a gated benchmark (`PHOCASA_BENCH=1`) in `ImageEditingServiceTests` that times the median of 30 preview renders of a generated 6000×4000 JPEG through the real service.
  - Add a gated benchmark for spec §E2: start a `.full` render of a generated 6000×4000 JPEG, request a `.preview` render 10 ms later, and time the preview from request to completion (median of 10). Run it before your changes (on the current single queue) and after. This is the **primary metric for the merge gate** when no RAW file is available.
  - Also measure §E3: the main-thread time to first draw the full-resolution result (draw the returned `NSImage` into a bitmap context on the main actor), with deferred output before and `deferred: false` after.
  - Measure RAW only if `IMAGEBENCH_RAW` is set. Don't commit a test that depends on a real RAW file.
  - Record before/after in the results file.

- [ ] **Step 8: Full suite, warnings, results file, commit.**

## Acceptance criteria

- The characterisation tests pass: rendering is pixel-identical (≤ 1) to the pre-refactor code for every parameter set.
- RAW preview ≤ 40 ms (only if a RAW file was provided; spec: 29 ms). JPEG preview no slower than baseline (≈4.7 ms).
- A preview requested during a full-resolution pass completes in about the time of a standalone preview, not after the full pass (the §E2 benchmark above).
- **Pixels:** full renders (`maxSize == nil`) and exports stay identical (≤ 1). RAW *previews* change slightly, because `scaleFactor` demosaics at a lower resolution. That's the intended exception, and it's preview-only.
- Previews complete while a full render is in flight (test 8). Cancelled renders do no work (test 7).
- `renderToNSImage` uses `deferred: false`.
- `ImageEditingService` has no `@unchecked Sendable`, no `withCheckedContinuation` and no string-named filters.
- Zero new warnings. The full suite passes.

## Out of scope and follow-ups

- Moving edit state into `EditSession` (task 22).
- Colour management (`DeviceRGB` working space): a separate, deliberate change, because it changes output. Record it as a follow-up.
- A Metal-backed preview view (`MTKView` + `CIRenderDestination`): only if previews still feel slow after waves 1–2.
