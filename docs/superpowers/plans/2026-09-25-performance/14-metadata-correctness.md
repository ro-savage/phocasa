# Task 14: Metadata Correctness and Serial Writer

**Wave:** 1 · **Depends on:** 00 · **Branch:** `perf/14-metadata-correctness` · **Size:** M

**Goal:** fix three metadata bugs, make writes safe, and put all metadata writes through one serial writer that keeps only the latest write per file.
- JPEG ratings round-trip.
- Rating or tagging a RAW-only photo no longer erases its RAW edits.
- Writes can't land out of order or interleave.
- A failed write can never corrupt the original file.

**Why:** spec §F1–§F5.

## Files

- Modify: `Phocasa/Phocasa/Services/MetadataService.swift` (you own it)
- Create: `Phocasa/Phocasa/Services/MetadataWriter.swift`
- Modify: `Phocasa/Phocasa/ViewModels/PhotoLibraryViewModel.swift`, **only** `metadataWriteItem(for:)` and `writeMetadataInBackground(_:)`
- Modify: `Phocasa/PhocasaTests/MetadataParsingTests.swift`
- Create: `Phocasa/PhocasaTests/MetadataRoundTripTests.swift`, `Phocasa/PhocasaTests/MetadataWriterTests.swift`

**Don't touch:**
- the rest of the view model. In particular, the editing paths that call `writeEditParameters` and `clearRAWSidecarEdits` stay as they are; task 22 routes them through the writer.
- `FolderScanner` (task 20).

## Interfaces

- **Must stay source-compatible:**
  - `MetadataService.shared.readMetadata(from:) -> PhotoMetadata`
  - `writeMetadata(rating:keywords:toImageAt:)`
  - `writeSidecar(rating:keywords:for:editParameters:)`
  - `writeEditParameters(_:forRAWAt:)`, `readEditParameters(forRAWAt:)`
  - `parseXMPSidecar(_:)`, `parseEditParameters(from:)`, `escapeXML(_:)`
  - the free functions `captureFileDates` and `restoreFileDates`
- **Produces:**
  ```swift
  struct MetadataWriteItem: Sendable, Equatable {
      let path: String
      let rating: Int
      let keywords: [String]
  }

  /// Serialises every metadata write. Only the latest pending write per path is kept.
  actor MetadataWriter {
      static let shared: MetadataWriter
      init(service: MetadataService = .shared)
      func enqueue(_ items: [MetadataWriteItem])
      /// RAW edit parameters go through the same queue, so they can't race rating/keyword writes to the same sidecar.
      func enqueueEditParameters(_ params: EditParameters?, forRAWAt path: String)   // nil clears them
      /// Waits until everything enqueued so far has been written. For tests and app termination.
      func flush() async
  }
  ```
  - `MetadataService.PhotoMetadata` gains `Sendable` conformance.
  - `MetadataService.clearEditParameters(forRAWAt path: String)` is new. It rewrites the sidecar with its existing rating and keywords and no edit parameters, which is what the view model's `clearRAWSidecarEdits` does inline today.
  - `metadataWriteItem(for:)` returns `MetadataWriteItem` instead of a tuple. Update its single caller type, `writeMetadataInBackground(_ items: [MetadataWriteItem])`.

## Steps

- [ ] **Step 1: Baseline.** Run the full suite.

- [ ] **Step 2: Failing tests first** (`MetadataRoundTripTests`). Use a temp dir, and generate a 64×64 JPEG with `CGImageDestination`.
  - `testJPEGRatingRoundTrips`: `writeMetadata(rating: 4, keywords: [], toImageAt:)` then `readMetadata` gives rating 4. **This fails today** (spec §F1).
  - `testJPEGKeywordsRoundTrip`: `["cat:a", "b"]`, compared as sets.
  - `testRAWOnlyRatingWritePreservesEditParameters`:
    1. Create a fake RAW path, e.g. `IMG_1.CR3`, containing just a few bytes; only its sidecar matters.
    2. `writeEditParameters(EditParameters(exposure: 1.5), forRAWAt:)`.
    3. `writeMetadata(rating: 3, keywords: ["x"], toImageAt: rawPath)`.
    4. `readEditParameters(forRAWAt:)?.exposure` must be `1.5`, and `readMetadata(from:)` must give rating 3 with keywords `["x"]`.

    **This fails today** (spec §F2).
  - `testWriteSidecarWithExplicitNilClearsEditParameters`: the existing `clearRAWSidecarEdits` behaviour must keep working. An explicit `editParameters: nil` passed to `writeSidecar` clears them.
  - `testFailedWriteLeavesOriginalUntouched`: write metadata to a `.jpg` that actually holds non-image bytes. The file's bytes must be unchanged afterwards, and no temp files are left in the directory.
  - `testWritePreservesFileDates`: set the creation and modification dates to a fixed past date, write a rating, and check that both dates are unchanged (±1 s).

  Run them and confirm which fail.

- [ ] **Step 3: Fix the reads.** In `readMetadata`, read the rating via
  ```swift
  if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
     let value = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?,
     let r = Int(value) { rating = r }
  ```
  - Remove the dead TIFF `"Rating"` lookup.
  - If there are no IPTC keywords, fall back to XMP `dc:subject`: `CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString)`, whose value is an array of `CGImageMetadataTag`; take each element's string value.
  - Keep the sidecar precedence exactly as today. Note that `readMetadata(from: "x.jpg")` also reads `x.xmp`, which for a JPG+RAW pair is the RAW's sidecar. That's today's behaviour, so keep it.

- [ ] **Step 4: Fix RAW edit loss.**
  - `writeMetadata`'s RAW branch must read the existing edit parameters (`readEditParameters(forRAWAt:)`) and pass them through to `writeSidecar`.
  - `writeSidecar`'s own contract stays: `nil` means clear.
  - Add a doc comment on `writeSidecar` stating that.

- [ ] **Step 5: Atomic image writes** (spec §F4). `writeToImageFile`:
  1. Creates the destination at a temp URL in the **same directory** (`.<name>.phocasa-tmp-<uuid>.<ext>`).
  2. Checks the `Bool` returned by `CGImageDestinationCopyImageSource`. On failure it removes the temp file and returns, leaving the original untouched.
  3. On success: `_ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)`, then `restoreFileDates`.

  Also replace `kUTTypeJPEG` with `UTType.jpeg.identifier as CFString` (`import UniformTypeIdentifiers`); that fixes the deprecation warning (spec §F5). Run the step-2 tests: all green. Commit: `fix: read xmp:Rating, preserve RAW edits on rating writes, write images atomically`.

- [ ] **Step 6: `MetadataWriter` tests first** (`MetadataWriterTests`). Inject a fake service through a small protocol:
  ```swift
  protocol MetadataWriting: Sendable {
      func writeMetadata(rating: Int, keywords: [String], toImageAt path: String)
      func writeEditParameters(_ params: EditParameters, forRAWAt path: String)
      func clearEditParameters(forRAWAt path: String)
  }
  extension MetadataService: MetadataWriting { ... }
  ```
  - Keep the `MetadataWriter.init(service: MetadataService = .shared)` convenience from the interface.
  - Add an internal `init(writer: any MetadataWriting)` for tests. The fake records calls and can block on a semaphore.

  Tests:
  - `testCoalescesToLatestPerPath`: while the first write for `a.jpg` is blocked, enqueue ratings 2, 3, 4 and 5 for `a.jpg`; unblock; `flush()`. Expect at most 2 calls for `a.jpg`, the last one with rating 5.
  - `testPreservesOrderAcrossPaths`: `a`, `b`, `a` → `a`'s last write wins, and `b` is written.
  - `testWritesAreSerial`: the fake's peak concurrency is 1.
  - `testEditParametersAndRatingForSameSidecarAreSerialised`: enqueue a rating for `x.cr3`, then edit parameters for `x.cr3`. Both calls happen, in order.
  - `testFlushWaitsForPendingWrites`

- [ ] **Step 7: Implement `MetadataWriter`.**
  - Make it an actor on its own `DispatchSerialQueue` executor (`qos: .utility`), so file I/O never runs on the cooperative pool:
    ```swift
    private let queue = DispatchSerialQueue(label: "com.phocasa.metadata-writer", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    ```
  - Pending work is an ordered dictionary keyed by path; a later enqueue for the same path replaces the payload in place.
  - A single drain loop writes one item at a time, re-checking for newer payloads between writes.
  - `flush()` suspends until the queue is empty and no write is in progress.
  - Make the tests pass. Commit: `feat: add serial coalescing MetadataWriter`.

- [ ] **Step 8: Wire up the view model** (your two functions only):
  ```swift
  private func writeMetadataInBackground(_ items: [MetadataWriteItem]) {
      guard !items.isEmpty else { return }
      Task { await MetadataWriter.shared.enqueue(items) }
  }
  ```
  Also update `metadataWriteItem(for:)` to return `MetadataWriteItem`. Its callers (in regions task 10 owns) pass the value straight through with `.map { metadataWriteItem(for: $0) }`, so they need no textual change. If the compiler requires one, keep it to the type name only and mention it in your report.

- [ ] **Step 9: Full suite, warnings, results file, commit.**

## Acceptance criteria

- All the new round-trip and writer tests pass. `testJPEGRatingRoundTrips` and `testRAWOnlyRatingWritePreservesEditParameters` failed before your change.
- No temp files are left behind after a failed or successful write.
- The `kUTTypeJPEG` deprecation warning is gone, with zero new warnings.
- The view model contains no `Task.detached` for metadata writes.

## Out of scope and follow-ups

- Routing `saveCurrentEditParameters` and `clearRAWSidecarEdits` through `MetadataWriter.enqueueEditParameters` (task 22).
- Reading metadata during scans (task 20).
- Flushing pending writes on app termination: note it as a follow-up for task 30. `NSApplication.willTerminateNotification` is an allowed AppKit exception only if no SwiftUI equivalent exists; check `scenePhase` first.
- Writing ratings to the RAW sidecar as well, for JPG+RAW pairs: that's a behaviour decision for the user, so don't change it.
