# Phocasa Performance & Cleanup Plan

> **For agentic workers:** you are implementing **one** task file from this folder in your own git worktree. Before you start, read, in this order:
> 1. this README;
> 2. `CLAUDE.md` at the repo root (its rules are binding);
> 3. the spec `docs/superpowers/specs/2026-09-25-performance-review.md` (the *why*, with measurements);
> 4. your task file.
>
> Use superpowers:test-driven-development for code changes and superpowers:verification-before-completion before you report. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make Phocasa fast at 10k+ photos (filtering, launch, scanning, scrolling, the detail view, editing) and split the code into focused, testable units, without changing behaviour except for the listed bug fixes.

**Architecture (end state):**
- The library is fetched once. Filtering, search, sort and counts run in memory over plain-value snapshots (`PhotoFacts`).
- Scanning and metadata I/O run off the main thread, through serial, coalescing writers.
- Thumbnails go through a bounded, newest-first, cancellable scheduler with memory and disk caches.
- The detail view decodes on the hardware path, applies EXIF orientation when displaying, and prefetches the photos either side.
- Editing state lives in an `EditSession` that exists only while editing.
- Image services are actors on `DispatchSerialQueue` executors.

**Tech stack:** Swift 6, SwiftUI, SwiftData, ImageIO, CoreImage (Metal), XCTest. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-25-performance-review.md`. Section references like §A1 point into it.

## Global constraints

Every task implicitly includes these.

- `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = minimal`, `MACOSX_DEPLOYMENT_TARGET = 14.0`. Don't change build settings unless your task says so.
- **No third-party dependencies.** Apple frameworks only.
- **SwiftUI first** (see CLAUDE.md for the full list). The known AppKit exceptions are `NSEvent.modifierFlags`, the scroll-wheel monitor and `NSCursor`. `NSViewRepresentable` is allowed only where the task explicitly says so.
- `@Observable`, never `ObservableObject`. View models are `@MainActor`.
- **Never touch the user's real data.**
  - Tests use temp directories and in-memory or temp-file stores.
  - The test host already uses an in-memory store (`PhocasaApp.isTestHost`). Don't undo that.
  - Never open, copy or modify anything under `~/Library/Application Support` or the user's photo folders.
  - Never search the disk for camera RAW files (no `mdfind`, no Spotlight queries). See **RAW files** under Commands.
- **Behaviour doesn't change** beyond what your task lists. In particular, rendered edit output must stay pixel-identical (max channel difference ≤ 1) unless your task says otherwise.
- **Zero new compiler warnings.** The full test suite must pass.
- **Keep other files compiling.** In waves 1–2, keep every existing internal API that another task's files use source-compatible. Add new APIs freely; don't rename or remove existing ones unless your task explicitly owns every call site.

## Commands

Run everything from your worktree root. Use a DerivedData folder unique to your task.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
XB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
DD="$TMPDIR/phocasa-dd-<task-id>"      # e.g. phocasa-dd-10

# Build
$XB -project Phocasa/Phocasa.xcodeproj -scheme Phocasa -configuration Debug -derivedDataPath "$DD" build 2>&1 | tail -5

# Full test suite (look for "** TEST SUCCEEDED **"; count warnings with: grep -c "warning:").
# After task 00 the baseline is "Executed 125 tests, with 3 tests skipped": 122 real tests + 3 gated benchmarks.
# Existing warnings (spec §F5 + one test warning): ImageLoader.swift:52, MetadataService.swift:99, ViewModelTests.swift:753.
$XB -project Phocasa/Phocasa.xcodeproj -scheme Phocasa -destination 'platform=macOS' -derivedDataPath "$DD" test > "$DD.test.log" 2>&1; tail -3 "$DD.test.log"
grep -E "error:|failed \(|Executed [0-9]+ tests" "$DD.test.log" | sort -u

# One test class or method
$XB ... test -only-testing:PhocasaTests/ViewModelTests/testFilterByRating

# Data-path benchmarks (installed by task 00; skipped unless PHOCASA_BENCH=1)
TEST_RUNNER_PHOCASA_BENCH=1 $XB -project Phocasa/Phocasa.xcodeproj -scheme Phocasa -destination 'platform=macOS' \
  -derivedDataPath "$DD" test -only-testing:PhocasaTests/DataPathBenchmarks > "$DD.bench.log" 2>&1
grep '^BENCH|' "$DD.bench.log"

# Image-path benchmarks (installed by task 00). Use a data dir and binary unique to your task:
# parallel agents sharing the default $TMPDIR/phocasa-imagebench would overwrite each other's data.
export IMAGEBENCH_DIR="$TMPDIR/phocasa-imagebench-<task-id>"
IB="$TMPDIR/imagebench-<task-id>"
(cd Tools/imagebench && swiftc -O -swift-version 5 imagebench.swift -o "$IB") \
  && "$IB" gen && "$IB" copies && "$IB" <orient|thumb|detail|conc|ci>
"$IB" clean   # removes about 3 GB of generated test images; always run it before you finish
```

**RAW files:** never search for, open or copy camera RAW files on this machine: they live in the user's photo
folders. `imagebench raw` runs only when `IMAGEBENCH_RAW` is set to an explicit file path, and a test that needs a
real RAW must `XCTSkip` unless `PHOCASA_TEST_RAW` (set via `TEST_RUNNER_PHOCASA_TEST_RAW`) names a file. Only the
coordinator sets these, and only to a file the user has provided. If neither is set, skip the RAW measurement and
say so in your results; the spec's RAW numbers stand as the reference.

The user has provided a **read-only** folder of real camera files, `~/PhocasaBenchRAW` (190 JPG+ARW pairs, 16 MP,
4912×3264; 12 are rotated: 2 with EXIF orientation 6, 10 with orientation 8). The coordinator passes its path to the tasks that need it. Treat the folder itself as read-only input, so every
run reads identical files: never write, rename or create files in it (it is `chmod a-w`), and never commit a test or
benchmark that depends on it. The user is happy for these test photos to be written to, so for any check that writes
(rating and keyword round-trips on real camera files, RAW sidecars, saved edits, exports), copy the files you need into
your own temp directory, write to the copies, and delete them when you're done.

Running the tests launches `Phocasa.app` as the test host, and a window will flash. That's expected.

## Waves and dependencies

Tasks in the same wave run **in parallel** in separate worktrees. A wave starts only after the previous wave has been merged into `main`, and every worktree branches from that merge.

| Wave | Task | Title | Depends on | Size |
|---|---|---|---|---|
| 0 | [00](00-parallel-work-prerequisites.md) | Synchronized project folders, benchmark harnesses, .gitignore | none | S |
| 1 | [10](10-library-data-path.md) | In-memory library: fetch once, filter/search/sort/count in memory | 00 | L |
| 1 | [11](11-thumbnail-pipeline.md) | Thumbnail scheduler, decode options, cache, grid click latency | 00 | M |
| 1 | [12](12-detail-view.md) | Detail view: orientation, progressive decode, prefetch, body split, scroll fix | 00 | L |
| 1 | [13](13-edit-render-pipeline.md) | Edit render pipeline: RAW scaleFactor, stale-skip, non-blocking full pass, actor | 00 | M |
| 1 | [14](14-metadata-correctness.md) | Metadata: rating read-back, RAW edit loss, atomic writes, serial writer | 00 | M |
| 2 | [20](20-scan-and-launch.md) | Scan and launch path off the main thread; no redundant writes; scan guard | 10, 14 | M |
| 2 | [21](21-thumbnail-disk-cache.md) | Persistent thumbnail disk cache | 11 | M |
| 2 | [22](22-edit-session.md) | Extract `EditSession` from the view model; sidecar I/O off main | 12, 13, 14 | L |
| 2 | [23](23-metadata-and-rating-decisions.md) | User decisions: update sidecars in place, ratings on both files of a pair, instant star clicks | 11, 14 | M |
| 3 | [30](30-structure-and-polish.md) | Split the remaining view model, keep grid alive, off-main trashing, dedupe, CLAUDE.md | all of waves 1–2 | L |
| 3 | [31](31-schema-cleanup.md) | Schema cleanup: `isInBin`, drop dead fields, migration test | 30 | S |

Tasks 30 and 31 run **one after the other**, not in parallel. Both touch the view model broadly.

## File ownership

This is what prevents merge conflicts. You may edit only the files and regions your task owns. If you need something outside your ownership:
- don't edit it;
- work around it in your own files if you can;
- list it under **"Needs from other tasks"** in your report.

### Benchmark harness

`Phocasa/PhocasaTests/PerformanceBenchmarks.swift` calls many view-model APIs (listed in `results/00.md`). Whoever
renames or removes one of them updates the harness in the same branch. Adding lines: task 10 in wave 1, task 20 in
wave 2, task 30/31 in wave 3. Other tasks put their gated benchmarks in their own test files.

### Wave 1

| File / region | 10 | 11 | 12 | 13 | 14 |
|---|---|---|---|---|---|
| `ViewModels/PhotoLibraryViewModel.swift`: `SidebarFilter`, Data Loading, file availability (read only), Filtering, Sorting, Selection, Navigation, Grid Keyboard Navigation, Deletion/Bin, Tags, Lightweight Tag Refresh, Rating | **owns** | | | | |
| VM: `updateEditPreview`, `renderFullResEdit`, the prepare `Task` in `startEditing`, `previewTask`/`fullResRenderTask`/`renderGeneration` | | | | **owns** | |
| VM: `metadataWriteItem(for:)`, `writeMetadataInBackground(_:)` | | | | | **owns** |
| VM: everything else (scan, editing state, crop, export, presets) | | | | | |
| `Views/ContentView.swift`, `Views/SidebarView.swift` | **owns** | | | | |
| `Views/PhotoGridView.swift`, `Views/PhotoGridItemView.swift`, `Services/ImageLoader.swift` | | **owns** | | | |
| `Views/PhotoDetailView.swift` | | | **owns** | | |
| `Services/ImageEditingService.swift` | | | | **owns** | |
| `Services/MetadataService.swift` | | | | | **owns** |
| New files | `Library/*` | `Services/Thumbnail*` | `Services/FullImageLoader.swift`, `Views/Detail/*` | none (tests only) | `Services/MetadataWriter.swift` |
| Tests | `ViewModelTests`, new `PhotoQueryTests` | new `ThumbnailSchedulerTests`, `ImageLoaderTests` | new `ImageOrientationTests`, `FullImageLoaderTests` | new `ImageEditingServiceTests` | `MetadataParsingTests`, new `MetadataRoundTripTests`, `MetadataWriterTests` |

### Wave 2

| File / region | 20 | 21 | 22 | 23 |
|---|---|---|---|---|
| VM: `setModelContext`, availability, folder opening, `rescanCurrentLibrary`, `scanFolder`, `findOrCreateTag` | **owns** | | | |
| VM: editing state and editing, JPG comparison, crop, export, presets | | | **owns** | |
| VM: `metadataWriteItem(for:)`, `writeMetadataInBackground(_:)` | | | | **owns** |
| `Services/FolderScanner.swift` | **owns** | | | |
| New `Library/TagParsing.swift` | **owns** | | | |
| `Services/ImageLoader.swift`, new `Services/ThumbnailDiskCache.swift` | | **owns** | | |
| `Services/MetadataService.swift`, `Services/MetadataWriter.swift` | | | | **owns** |
| `Views/RatingView.swift`; `Views/PhotoGridItemView.swift` rating-row gesture only | | | | **owns** |
| `Views/EditSidebarView.swift`, `Views/CropOverlayView.swift`, new `Editing/*` | | | **owns** | |
| `Views/PhotoDetailView.swift` and `Views/Detail/*`: edit-related references only | | | **owns** | |
| `Views/ContentView.swift`: edit-related lines only (key handling, `EditSidebarView` presence) | | | **owns** | |
| `PhocasaTests/PerformanceBenchmarks.swift` (add lines only) | **owns** | | | |
| Tests | `FolderScannerTests`, new `ScanTests` | new `ThumbnailDiskCacheTests` | new `EditSessionTests`; the crop and preset tests in `ViewModelTests` | `Metadata*Tests`; the star tests in `PhotoGridItemViewTests` |

### Wave 3

Task 30 owns everything. Task 31 owns the models, the `isDeleted` call sites and the migration tests.

## Workflow for each task agent

1. Confirm you're in your worktree on a fresh branch: `git checkout -b perf/<task-id>-<slug>`.
2. Build and run the full test suite once **before** changing anything. Record the pass count, so you know the baseline is green.
3. If your task has benchmark targets, run the relevant benchmark before changing anything and keep the numbers.
4. Work through the steps. Test first where feasible: write the failing test, watch it fail, implement, watch it pass.
5. Commit in small logical commits on your branch. **Don't** merge, rebase onto other branches, or push.
6. Before reporting:
   - Run the full test suite: it must pass, with no new warnings.
   - Re-run your benchmarks.
   - Write `docs/superpowers/plans/2026-09-25-performance/results/<task-id>.md` containing:
     - what changed, as a file list with one line each;
     - tests added;
     - before/after numbers;
     - deviations from the task file, and why;
     - **Needs from other tasks**;
     - follow-ups.
   - Commit that file.
7. Your final message: the branch name, the commit list (`git log --oneline main..HEAD`) and the contents of your results file.

## Merge gate: is a task worth merging?

Task files are guidelines. Agents should check their claims against the code and change the approach where they see a better one, recording deviations in the results file. What decides a merge is evidence:

- **Performance tasks (10, 11, 12, 13, 20, 21):** the task's primary benchmark metrics must improve measurably, and nothing else may regress by more than 5%.
  - The coordinator **re-runs the relevant benchmarks itself** on `main` and on the task branch, with no other builds or agents running. Numbers taken while other agents are compiling are noise. The coordinator's tools and protocol (A/B harness, test runner, real-app check) are in `Tools/coordinator/README.md`.
  - If the improvement isn't there, the task is **skipped**: its branch isn't merged, and the reason goes in `results/<task-id>.md` on `main`.
  - A subagent that finds early, by measuring or prototyping, that its approach won't help should stop and report instead of finishing.
- **Mixed tasks:** task 12 includes bug fixes (orientation, scroll hijack, wasted RAW render). If its performance changes don't pay off, keep and merge the bug fixes and drop the rest.
- **Correctness, enabler and structure tasks (00, 14, 22, 30, 31):** these aren't judged on speed. They must:
  - show their bug tests failing before and passing after, or meet their structural acceptance criteria;
  - not regress any benchmark by more than 5%.
- **Dependencies:** if a task is skipped, re-check the tasks that depend on it (see the waves table). Adapt them to what actually landed, or skip them too.

## Merge protocol (coordinator)

- Worktrees branch from `main`. Everything merges back into `main`.
- After a wave's agents finish, apply the merge gate to each branch. Merge the passing ones one at a time with `git merge --no-ff perf/<task>`, running the full test suite after each merge.
- Resolve conflicts using the ownership tables: the owning task wins inside its region, and both sides' intent is kept elsewhere. Re-run the suite after resolving.
- Re-run the benchmarks on the merged `main`.
- Start the next wave's worktrees only after that, so they branch from the merged `main`.
- **Before merging task 31** (schema change), stop and ask the user to back up `~/Library/Application Support/default.store*`.
- Never push.
