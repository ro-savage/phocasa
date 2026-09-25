# Task 23: Metadata and Rating Decisions (from wave 1)

**Wave:** 2 · **Depends on:** 11, 14 (merged) · **Branch:** `perf/23-metadata-rating-decisions` · **Size:** M

**Goal:** implement the behaviour the user decided on after wave 1 (`results/wave-1-coordinator.md`, "Decisions").

| # | Question | User's answer | Work |
|---|---|---|---|
| 1 | RAW sidecar writes replace the whole `.xmp`, dropping third-party XMP (Lightroom, Capture One) | "It shouldn't rewrite everything. Just update." | **A** below |
| 2 | Scans now import ratings embedded in RAW files | "Yes" | None: keep task 14's behaviour. Add a regression test (**D**). |
| 3 | A click on a grid star waits ≈356 ms for double-click detection | "Make it instant." | **C** below |
| 4 | JPG+RAW pairs write ratings only into the JPG | "Rating can go on both." | **B** below |

## Files

- Modify: `Phocasa/Phocasa/Services/MetadataService.swift` (you own it in wave 2)
- Modify: `Phocasa/Phocasa/Services/MetadataWriter.swift` (if needed)
- Modify: `Phocasa/Phocasa/ViewModels/PhotoLibraryViewModel.swift`, **only** `metadataWriteItem(for:)` and `writeMetadataInBackground(_:)`
- Modify: `Phocasa/Phocasa/Views/RatingView.swift`, and in `Phocasa/Phocasa/Views/PhotoGridItemView.swift` the rating row's gesture only
- Modify: `MetadataParsingTests`, `MetadataRoundTripTests`, `MetadataWriterTests`, and the star tests in `PhotoGridItemViewTests`
- Create: new test files as needed

**Don't touch:** `FolderScanner` and the scan code (task 20), `ImageLoader` (task 21), editing and the detail/edit views (task 22). Task 22 calls `MetadataWriter.enqueueEditParameters` and `MetadataService.clearEditParameters(forRAWAt:)`. Keep both working exactly as they are.

## A. Update RAW sidecars in place, never rewrite them

Today `writeSidecarToURL` builds a fresh XMP document with only a rating, keywords and Phocasa's edit parameters. Anything else in the file is lost the first time Phocasa rates, tags or edits that RAW.

- Parse the existing sidecar with ImageIO: `CGImageMetadataCreateFromXMPData`, then `CGImageMetadataCreateMutableCopy`.
- Update only Phocasa's fields:
  - `xmp:Rating`;
  - `dc:subject` (replace the array);
  - `phocasa:EditParameters` (set, or remove when clearing). Register the namespace with `CGImageMetadataRegisterNamespaceForPrefix` (`http://phocasa.app/ns/1.0/`, prefix `phocasa`).
- Serialise with `CGImageMetadataCreateXMPData`, write atomically (temp file in the same folder, then replace), and restore file dates as the image path does.
- No sidecar yet: create one, as today.
- **Existing sidecar that can't be parsed: don't overwrite it.** Skip the write, and make the skip visible to tests (a return value or a debug counter). Losing someone's Lightroom sidecar is exactly what this task prevents.
- **Reads must handle every format.** ImageIO may serialise `xmp:Rating` as an element rather than an attribute, and the current regex readers (`parseXMPSidecar`, `parseEditParameters`, which expect `xmp:Rating="N"`) would then miss it. Read sidecars through ImageIO, or make the parsers accept both forms. Keep `parseXMPSidecar(_:)` and `parseEditParameters(from:)` source-compatible, because `MetadataParsingTests` uses them.
- Semantics stay the same: `writeSidecar(..., editParameters: nil)` still clears only the edit parameters. `writeMetadata` on a RAW path still keeps saved edits (task 14).
- **Tests.** Build sidecars in a temp dir:
  1. a sidecar written by the old Phocasa code;
  2. a Lightroom-style sidecar with `crs:` develop settings, `xmp:Rating` as an attribute, `dc:subject`, and an unrelated namespace;
  3. a sidecar written by ImageIO.

  For each one, after a rating write, a keyword write, an edit-parameter write and a clear:
  - every unrelated property survives, compared through ImageIO before and after;
  - the rating, keywords and edit parameters read back correctly;
  - no temp files are left.

  Also test that an unparseable sidecar is left byte-identical.

## B. Ratings (and keywords) go to both files of a JPG+RAW pair

- A rating or tag change on a pair writes the JPG's embedded XMP (as today) **and** the RAW's sidecar.
- Keywords travel in the same write item, so the sidecar gets them too. Otherwise its keywords would go stale next to the new rating. Record this reading of the decision in your results.
- The RAW sidecar write goes through A, and it keeps saved RAW edits.
- **Keep the callers unchanged.** They are `[metadataWriteItem(for: photo)]` and `.map { metadataWriteItem(for: $0) }` in regions no wave-2 task owns. For example, let one item carry both paths, or let `writeMetadataInBackground` expand it. Both writes go through `MetadataWriter`, so they stay serial and coalesced per path.
- Note: `x.jpg` and `x.arw` share the sidecar `x.xmp`, and `readMetadata(from: jpg)` also reads it (non-zero sidecar rating wins). Check that a pair reads back consistently from either file.
- **Tests:**
  - rating a pair writes both files;
  - rating a RAW-only photo writes only its sidecar;
  - rating a JPG-only photo writes only the JPG;
  - a pair's RAW edits survive a rating write.

## C. Instant star clicks in the grid

- Remove the rating row's no-op `highPriorityGesture(TapGesture(count: 2))` in `PhotoGridItemView`, so a click on a star rates immediately.
- **Careful:** `RatingView` clears the rating when you click the star that is already set (`star == rating → onRate(0)`). Without a guard, a double-click on ★3 would set 3 and then clear it to 0. The user expects a double-click to leave the rating set. So:
  - the second click of a double-click on the same star must **not** clear the rating (for example, ignore the toggle-off when `NSApp.currentEvent?.clickCount ≥ 2`, or when it lands within `NSEvent.doubleClickInterval` of the click that set it);
  - a deliberate single click on the current star still clears it.
- A double-click on the stars must not open the detail view. The user was rating, not opening.
- A click on a star still doesn't select the photo (today's behaviour). A click elsewhere on the cell still selects on the first click, and a double-click there still opens.
- **Tests:** extend `PhotoGridItemViewTests` with synthesised clicks:
  - a star click rates in < 50 ms;
  - a double-click on ★3 leaves 3;
  - a single click on the current star clears it;
  - a double-click on a star doesn't open the detail view;
  - the thumbnail's click and double-click behave as before.

  The detail view's `RatingView` has no double-click gesture. Check that it still works.

## D. Embedded RAW ratings (decision 2)

- Add a test: a RAW-only file whose embedded XMP has `xmp:Rating` 4 and no sidecar imports with rating 4 through `readMetadata` (and the scan, if task 20's API makes that easy without touching its files).
- A generated TIFF or DNG-like file with embedded XMP is enough. `readMetadata` only cares about the path extension being in `FolderScanner.rawExtensions` for the sidecar logic.

## Acceptance criteria

- Third-party XMP in a sidecar survives every Phocasa write (tests A1–A3). An unparseable sidecar is never overwritten.
- For pairs, rating and keywords land in both the JPG and the RAW sidecar, and RAW edits survive.
- A grid star click rates at once. A double-click on a star leaves it set and doesn't open the photo.
- The full suite passes, with zero new warnings, and no benchmark regresses by more than 5%. `5a`/`5b` measure the main-thread cost, which must not grow; the extra sidecar write runs on `MetadataWriter`'s queue.
- **Check in the real app** (see `Tools/coordinator/README.md`), on temp copies of `~/PhocasaBenchRAW`: rate a pair and a RAW-only photo, then inspect both files. Put a Lightroom-style sidecar next to a copy, rate it, and check its `crs:` content survives.
