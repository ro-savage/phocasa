# Wave 1: coordinator merge record

**Merged into `main`:** 14, 10, 13, 12, 11 (in that order, `--no-ff`), plus one integration fix (`78ebe1b`).
**Skipped:** none. Every task passed the merge gate.

## How it was measured

- Quiet machine (load 1.5–3, no agents or builds running), Debug test host, medians of each benchmark's own runs.
- `main` before the wave (`feed379`) against each branch, then against merged `main` (`f2455da`).
- Data path: `DataPathBenchmarks` with task 10's extended harness (it compiles against the pre-wave code too).
- Image paths: the coordinator's own A/B harness (kept outside the repo), which uses only APIs that exist on both
  sides. It covers:
  - thumbnail fast scroll (cells 2.5 ms apart; a cell > 40 behind the newest is cancelled);
  - slider ticks through the view model;
  - main-thread first draw of the full-res edit;
  - `readMetadata` over real files.
- Real files: `~/PhocasaBenchRAW`, 190 Sony JPG+ARW pairs, 16 MP. Read only.

## Before → after (merged `main`)

| Area | Metric | Before | After |
|---|---|---|---|
| Library (10k) | filter change (`3e`–`3h`) | 343–505 ms | 1.1–15.7 ms |
| | search keystroke (`4b`) | 400 ms | 5.0 ms |
| | sort toggle (`3d`) | 342 ms | 3.9 ms |
| | rating (`5a`/`5b`) | 68 / 101 ms | 6.8 / 6.8 ms |
| | move to bin / restore (`8a`/`8b`) | 353 / 352 ms | 6.6 / 7.0 ms |
| | 50-photo rating (`8c`) | 128 ms | 14.3 ms |
| | `loadExistingData()` | 343 ms | 317 ms |
| | cold `setModelContext` | 440 ms | 397 ms |
| | rescan, unchanged 10k (`7x`) | 2,439 ms | 2,416 ms (task 20) |
| | first scan, 1k (`FIRST`) | 1,631 ms | 1,619 ms (task 20) |
| Thumbnails | synthetic 24 MP, fast scroll, last 20 | 1,506 ms | 259 ms |
| | real ARW, fast scroll, last 20 | 4,977 ms | 8.7 ms |
| | real ARW, single cold | 96.5 ms | 12.1 ms |
| | real JPG, fast scroll / single | 27.1 / 26.7 ms | 27.0 / 26.7 ms (already fast) |
| Detail | arrow-key navigation, 24 MP | 87–104 ms | 0.0–0.1 ms (prefetched) |
| | memory per photo at fit (14" window) | 91.6 MB | 22.9 MB |
| Editing | RAW tick idle / during full pass | 75.6 / 109.7 ms | 37.3 / 37.4 ms |
| | RAW main-thread first draw | 111.8 ms | 35.0 ms |
| | real JPG tick idle / during | 43.9 / 43.3 ms | 35.5 / 35.3 ms |
| | real JPG main-thread first draw | 58.7 ms | 41.2 ms |
| Metadata | `readMetadata` real JPG / ARW, ×190 | 103.7 / 483 ms | 83.6 / 452.5 ms |
| | `readMetadata` synthetic, ×1000 | 193 ms | 163 ms |

Edit ticks include the view model's 30 ms debounce. `3a`–`3c` and `4` are now cached no-ops (repeat click or repeat
text), so filter and search are judged on `3e`–`3h` and `4b`.

### Lines over +5% (none on an app path)

- `6a allPhotos.filter { rating == 3 }`: +49% (8.7 → 13.0 ms). This is the harness's own loop over 10k model objects;
  the app no longer does this.
- `scan1k` "generate 1000 jpegs (harness)": +41%. It includes 500 synchronous calls to the app's metadata write, which
  now writes a temp file and swaps it in atomically (about +0.4 ms per small file). In the app that write runs on
  `MetadataWriter`'s queue, off the main thread.
- Not in these benchmarks: task 11 measured +13% main-thread CPU for window resizes made *right after* a long scroll,
  in exchange for −31% on page scrolls (`results/11.md`, "Grid observations"). Accepted as a trade-off.

## Integration fix (`78ebe1b`)

After 12 merged on top of 10, `DetailViewTests.testDetailViewPrefetchesNeighboursAndUpgradesToFullResolution` failed
every time:
- The test assigned `viewModel.photos` directly.
- Task 10's `index(of:)` is backed by grid bookkeeping that only the in-memory library code updates.
- So `navigateDetail` found no index and returned early.

The fix:
- `photos` is now `private(set)`, so an outside write fails to compile;
- the test seeds its photos through a model context, as the task 10 contract requires.

## Suite, warnings, app check

- Full suite on merged `main`: `Executed 293 tests, with 11 tests skipped and 0 failures`. The skips are all gated
  benchmarks.
- Clean `build` of the app: **0 compiler warnings**. The three older ones are fixed: `ImageLoader.swift:52` by task 11,
  `MetadataService.swift:99` by task 14 and `ViewModelTests.swift:753` by task 10.
- **Real-app check.** The built app was launched with the in-memory-store flag; `lsof` confirmed no `default.store`
  was open. It was driven with real mouse and keyboard events over a temp copy of 24 pairs plus 1 RAW-only photo from
  `~/PhocasaBenchRAW` (11 of them rotated). Checked, with screenshots:
  - folder open and scan, with correct counts;
  - grid thumbnails, including RAW-only and rotated photos;
  - first-click selection;
  - Return opens the detail view with portraits upright;
  - → shows the next (RAW-only, rotated) photo within 150 ms;
  - RAW edit mode with a live exposure slider;
  - the edit sidebar scrolls with the wheel (§D5), and the wheel over the photo still zooms (310%, minimap, full-res
    swap);
  - Escape saves the edit ("Edited" badge);
  - rating by star click and by key;
  - write-back: `xmp:Rating` lands in the camera JPEG, and the ARW sidecar keeps its edit parameters when rated (§F2);
  - no `phocasa-tmp` files are left behind.

## Follow-ups found while merging

- **Task 22:** after saving an edit (Escape), the detail view shows the *unedited* image until you navigate away and
  back. `renderedEditImage` is only refreshed by `loadImages`. This predates wave 1.
- **Task 22:** the `.full` lane for saved-edit and JPG-comparison renders is already automatic: with `lane: nil`, a
  full-size render picks `.full`.
- **Coordinator harness:** AppleScript `keystroke "3"` doesn't reach SwiftUI's `onKeyPress`; `key code` does. This
  is a driver quirk, not an app bug.

## Decisions for the user (from the results files)

1. RAW sidecar rewrites drop any third-party XMP (Lightroom, Capture One develop settings). Existing behaviour.
   Should the app merge into the existing sidecar instead? (`results/14.md`)
2. Scans now import ratings embedded in RAW files (in-camera or Lightroom), where they used to be ignored.
   (`results/14.md`)
3. A click on a grid star still waits ≈356 ms for double-click detection. Making it instant means a double-click on
   a star rates twice. Existing behaviour. (`results/11.md`)
4. JPG+RAW pairs still write ratings only into the JPG. Existing behaviour. (`results/14.md`)
