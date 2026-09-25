# Task 22: Extract EditSession

**Wave:** 2 · **Depends on:** 12 (detail view split, `DisplayImage`, `FullImageLoader`), 13 (render lanes), 14 (`MetadataWriter`) · **Branch:** `perf/22-edit-session` · **Size:** L

**Goal:**
- Move all editing state and behaviour out of `PhotoLibraryViewModel` into an `@Observable EditSession` that exists only while editing.
- Route RAW sidecar writes through `MetadataWriter`, so none happen on the main thread or race rating writes.
- Fix the JPG comparison's orientation.

This removes about 15 flags from the view model, along with the manual reset in `stopEditing`.

**Why:** spec §H1, §F3 (edit-parameter races), §G5, §D1 (the JPG comparison still decodes through `loadFullResolution`).

## Files

- Create: `Phocasa/Phocasa/Editing/EditSession.swift`
- Modify: `Phocasa/Phocasa/ViewModels/PhotoLibraryViewModel.swift`. You own:
  - the `// MARK: - Image Editing State` properties and `canExport`;
  - `// MARK: - Image Editing`, `// MARK: - JPG Comparison`, `// MARK: - Crop`, `// MARK: - Export`, `// MARK: - Presets`;
  - `clearRAWSidecarEdits`, `revertEditsForPhoto`, `canCopyFromJPG`;
  - `navigateDetail`'s and `closeDetail`'s calls into editing. Change only the editing calls.
- Modify: `Phocasa/Phocasa/Views/EditSidebarView.swift`, `Phocasa/Phocasa/Views/CropOverlayView.swift` (bindings only)
- Modify: `Phocasa/Phocasa/Views/PhotoDetailView.swift` and `Views/Detail/*`: **edit-related references only**. Task 12 already restructured these, so read them first.
- Modify: `Phocasa/Phocasa/Views/ContentView.swift`: edit-related lines only (the `\` key, Escape handling, the `EditSidebarView` presence)
- Modify: `Phocasa/PhocasaTests/ViewModelTests.swift`: move the crop and preset tests to `EditSessionTests`, keeping their assertions. Other `ViewModelTests` that use the editing API may be updated to the session API, with their assertions kept.
- Modify, if needed: the saved-edit tests in `Phocasa/PhocasaTests/DetailViewTests.swift` (`renderSavedEdit`)
- Create: `Phocasa/PhocasaTests/EditSessionTests.swift`

**Don't touch:** the scan and availability code (task 20, running in parallel), `ImageLoader` (task 21, running in parallel), `ImageEditingService` internals (task 13, merged), `MetadataService` / `MetadataWriter` (task 23, running in parallel).

**Keep these working for other callers:**
- `setModelContext` (task 20's region) calls `loadPresets()`.
- `PhotoGridView`, which no wave-2 task owns, calls `editPresets`, `applyPresetToSelection(_:)` and
  `revertEditsForPhoto(_:)`.
- `DetailOverlayControls` calls `isEditing`, `editingRAW`, `startEditing` and `stopEditing`. You own its edit-related
  references, so you may move it to the session API.
- `Tools/coordinator/CoordinatorBenchmarks.swift` isn't yours. The coordinator will update its edit tests to your API.
  Keep the render scheduling the same: 30 ms preview debounce, 300 ms `.full` pass, `lane: .preview` for sized
  renders and `.full` for full-size ones. The coordinator compares slider-tick latency and first draw against
  `main`, and they must not regress by more than 5%.

## Interfaces

- **Consumes:**
  - `ImageEditingService.shared.processStandard/processRAW(url:parameters:maxSize:lane:)`, `prepareRAW/prepareStandard`, `exportRAWToJPEG`, `exportStandardToJPEG`, `clearCache()` (task 13)
  - `MetadataWriter.shared.enqueueEditParameters(_:forRAWAt:)`, `flush()` (task 14)
  - `MetadataService.shared.readEditParameters(forRAWAt:)`
  - `FullImageLoader.shared.load(path:subsample:)`, `DisplayImage`, `OrientedImage`, `ComparisonView` (task 12)
- **Produces:**
  ```swift
  @Observable @MainActor
  final class EditSession {
      let photo: PhotoAsset
      let isRAW: Bool
      var parameters: EditParameters          // setting it schedules a preview render
      private(set) var previewImage: NSImage?
      private(set) var fullImage: NSImage?
      var showOriginal: Bool
      var showSideBySide: Bool                  // turning on turns showJPGComparison off
      private(set) var showJPGComparison: Bool
      private(set) var jpgComparisonImage: DisplayImage?
      var isCropping: Bool
      var cropRect: NormalizedRect
      var showExportOptions: Bool
      var canExport: Bool { get }
      var canCopyFromJPG: Bool { get }

      init(photo: PhotoAsset, isRAW: Bool, modelContext: ModelContext?)
      func begin() async                        // loads saved params, warms caches, first render
      func resetAllParameters()
      func revert()                             // clears saved edits too
      func copyJPGSettings()
      func toggleJPGComparison()
      func enterCropMode(); func applyCrop(); func cancelCrop()
      func save()                               // JPG → model; RAW → MetadataWriter + hasRawEdits
      func exportRAWToJPG(replaceExisting: Bool) async -> Bool
      func exportJPGPermanent() async -> Bool
      func end(save: Bool)                      // cancels renders, clears the service cache
      func apply(_ preset: EditPreset)
  }

  // PhotoLibraryViewModel
  private(set) var editSession: EditSession?
  var isEditing: Bool { editSession != nil }        // kept for the views and tests
  func startEditing(photo: PhotoAsset, isRAW: Bool)  // same signature as today
  func stopEditing(save: Bool = true)                // same signature as today
  ```
  - Presets stay in the view model: `editPresets`, `presetNameInput`, `loadPresets`, `savePreset`, `deletePreset`, `applyPresetToSelection`. `savePreset` reads `editSession?.parameters`. `applyPreset(_:)` forwards to `editSession?.apply(_:)`.

## What waves 1 changed (read before step 1)

- **Task 14's `MetadataWriter`:** `enqueue` and `enqueueEditParameters(_:forRAWAt:)` are **synchronous and `nonisolated`**. Call them directly, with no `await` and no `Task`. `nil` clears the edits. `await MetadataWriter.shared.flush()` reliably sees every earlier enqueue, so use it in tests. `MetadataService.clearEditParameters(forRAWAt:)` exists; it replaces `clearRAWSidecarEdits`'s inline body.
- **Task 12's detail view:**
  - `PhotoDetailView` is a thin container. It still holds `.onChange(of: viewModel.editParameters)` and the `currentImage` precedence.
  - `ComparisonView(left:right:)` takes `DisplayImage?`.
  - `FullImageLoader.shared.load(path:subsample:)` / `loadFit(path:viewportPixelSize:)` return an oriented `DisplayImage`. Use one of them for the JPG comparison (it's sideways for portrait JPGs today).
  - `loadImages` calls `MetadataService.readEditParameters(forRAWAt:)` on the main actor. Move that read off the main thread.
- **Task 10:** after `exportRAWToJPG` sets `photo.jpgPath`, call `viewModel.photosDidChange([photo])`. Otherwise the JPG count and filter miss the new file until the next reload. `EditSession` doesn't know the view model, so either let the view model do it after the export returns, or give the session a callback.
- **Task 13 (check what merged):** saved-edit renders in `PhotoDetailView.loadImages` and the JPG comparison render are full-resolution. If the lanes exist, run them on `.full`, so they never delay previews.
- **Bug found in the wave-1 app check (existing):** after an edit is saved (Escape, or the edit button), the detail view shows the *unedited* image until you navigate away and back. `renderedEditImage` is only refreshed by `loadImages`. Fix it: when a session ends with a save, the detail view shows the saved edit, from the session's last full render or a fresh `.full` render. Add a test.
- **Don't edit `MetadataService` or `MetadataWriter`:** task 23 owns them in this wave and is changing how sidecars are written. Call `MetadataWriter.shared.enqueueEditParameters(_:forRAWAt:)` and `MetadataService.readEditParameters(forRAWAt:)` as they are.
- After this task `ImageLoader.loadFullResolution(for:)` has no app callers. Only `DetailNavigationBenchmarks` (its "old" path) uses it. Leave it; task 30 decides.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite. Read the merged `PhotoDetailView` and `Views/Detail/*` from task 12, and the `ImageEditingService` from task 13.

- [ ] **Step 2: Tests first** (`EditSessionTests`), using a temp-file SwiftData store and generated JPEGs.
  - **Port** the crop tests and preset tests from `ViewModelTests` verbatim in meaning. Replace `viewModel.editParameters` with `session.parameters` and `viewModel.enterCropMode()` with `session.enterCropMode()`. Keep every assertion, then delete the originals.
  - `testSettingParametersProducesPreview`: change the exposure. Within 2 s, `previewImage` is non-nil and fits in 1600×1100.
  - `testRapidParameterChangesKeepLatestResult`: set 10 different exposures quickly. The final `previewImage` corresponds to the last value; compare it against a direct `processStandard` call.
  - `testSaveJPGPersistsToModel` and `testSaveRAWGoesThroughWriter`: use a fake RAW path with just a sidecar, `await MetadataWriter.shared.flush()`, then `readEditParameters` round-trips and `hasRawEdits == true`.
  - `testRevertClearsSavedEdits`
  - `testJPGComparisonImageIsOriented`: the paired JPG has orientation 6 → `jpgComparisonImage?.orientation == .right`.
  - `testEndCancelsPendingRenders`: after `end(save: false)`, no image is assigned later.

- [ ] **Step 3: Implement `EditSession`.**
  - Move the code in from the view model, including render scheduling: the 30 ms preview debounce, the 300 ms full-lane pass and the generation checks.
  - Setting `parameters` schedules the render (a `didSet` on the stored property, or an explicit setter), so views no longer need `.onChange(of: editParameters)`.
  - The JPG comparison uses `FullImageLoader` (at a subsample chosen for the viewport, or 2 by default) when there are no saved JPG edits. Otherwise it uses `processStandard`, wrapped as `DisplayImage(nsImage:)`.
  - All RAW sidecar writes go through `MetadataWriter.shared.enqueueEditParameters`: `save()`, `revert()`, and the view model's `revertEditsForPhoto` and `applyPresetToSelection`. Reading a sidecar may stay synchronous (it's a small file).

- [ ] **Step 4: Slim the view model.**
  - Delete the moved properties and methods, and `clearRAWSidecarEdits`.
  - `startEditing` saves any current session, then creates and begins a new one.
  - `stopEditing(save:)` calls `editSession?.end(save:)` and sets `editSession = nil`.
  - `navigateDetail` saves the session before moving, as today.
  - `closeDetail` stops editing, as today.

- [ ] **Step 5: Views.**
  - `EditSidebarView(session: EditSession, viewModel:)` binds to `$session.parameters.…`. Use `@Bindable var session`.
  - `ContentView` shows `EditSidebarView` when `viewModel.editSession` is non-nil. Its key handling (`\` for show original, Escape for crop cancel or stop editing) goes through the session.
  - The detail container and subviews read the session for previews, comparison and crop. Remove the `.onChange(of: viewModel.editParameters)` hop.
  - `CropOverlayView` bindings become `$session.cropRect` and `$session.parameters.rotation`.

- [ ] **Step 6: Full suite, warnings, results file, commit.** Build and click through by reasoning, since there's no UI test target:
  - enter an edit, move sliders, crop, apply, compare side-by-side or with the JPG, export, revert, switch photos while editing, exit;
  - list anything you could not verify in the results file.

## Acceptance criteria

- The view model no longer declares `editParameters`, `editedPreviewImage`, `fullResEditImage`, `showOriginal`, `showSideBySide`, `showJPGComparison`, `jpgComparisonImage`, `isCropping`, `cropRect`, `showExportOptions`, `previewTask`, `fullResRenderTask` or `renderGeneration`.
- `grep -n "writeEditParameters\|writeSidecar" Phocasa/Phocasa/ViewModels Phocasa/Phocasa/Editing` finds no direct calls: everything goes through `MetadataWriter`.
- The ported crop and preset tests pass with their original assertions. The new `EditSessionTests` pass.
- The JPG comparison is oriented correctly.
- Zero new warnings. The full suite passes.

## Out of scope and follow-ups

- Colour management.
- A Metal preview view.
- Rendering at native resolution only when zoomed.

Note all three in your results file if you observe a need.
