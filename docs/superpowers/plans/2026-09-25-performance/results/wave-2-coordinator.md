# Wave 2: coordinator merge record

**Merged into `main`:** 23, 22, 20, 21, in that order, each with `--no-ff`:

| Merge | Task | Notes |
|---|---|---|
| `9c4c599` | 23 | Metadata and rating decisions, plus the JPEG camera-metadata fix |
| `5ec843a` | 22 | `EditSession` |
| `87ad531` | 20 | Scan and launch; one conflict, resolved below |
| `be8c3fb` | 21 | Thumbnail disk cache |

**Skipped:** none. Every task passed the merge gate, and no integration fix was needed.

## Before dispatch: task-file fixes (`0da2f79`)

The task files were checked against merged `main` and corrected where the code had moved on:

- **20.**
  - The main-actor fetch of every row costs about 185 ms at 10k, so the old plan alone missed the 150 ms target. The row diff must run off the main actor.
  - Photos whose files are missing are excluded from `allPhotos`, so the diff has to see every row.
  - 20 owns the availability lines inside `loadExistingData`.
- **21.**
  - The test host gets no disk cache unless `PHOCASA_THUMBNAIL_CACHE_DIR` is set.
  - `clearCache()` stays memory-only.
  - The cache must survive its folder being deleted from outside.
  - The cold path must stay within 5%.
  - A JPEG rating write changes the file size, so the key misses once afterwards.
- **22.** It owns `DetailViewTests` and the editing tests in `ViewModelTests`, and must keep the APIs that other callers use.
- **23.**
  - `MetadataService` stays source-compatible.
  - `readMetadata` stays thread-safe and no slower.
  - The click tests had an `NSApp.currentEvent` pitfall.
  - The double-click-on-stars test was flipped to the user's decision.
- **README.** The wave-2 ownership rows were updated, along with the post-wave-1 test baseline.

The coordinator harness gained disk-cache lines (`8310c8b`) and an `EditSession` variant of the edit benchmarks (`56848f3`); see
`Tools/coordinator/README.md`.

Mid-wave, task 21 found that JPEG rating writes drop camera metadata. I sent this to task 23, which confirmed and fixed it. See the JPEG camera metadata section under the per-task results.

## How it was measured

- Quiet machine: no agents or builds running, load 2–5 (the user's browser was open during the final runs). Debug test
  host. Each benchmark reports the median of its own runs.
- All checkouts ran with the same harness:
  - `CoordinatorBenchmarks`, the edit benchmarks (view-model variant before 22, session variant from 22);
  - task 20's `PerformanceBenchmarks.swift`, with its main-actor hook stubbed out where the hook doesn't exist;
  - `TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR` set to a temp folder, so task 21's cold runs include the cache writes.
- **Per branch:** two rounds, main → 20 → 21 → 22 → 23 → main, then reversed. Each branch was compared with the four
  `main` runs.
- **Merged `main`:** pre-wave `main` (`56848f3`) and merged `main` (`be8c3fb`), interleaved pre, post, pre, post. That
  comparison is the table below.
- Real files: `~/PhocasaBenchRAW` (190 Sony JPG+ARW pairs, 16 MP), read only. `~/Library/Caches/com.phocasa.app` was
  checked after every run and never existed.

## Before → after (merged `main`, interleaved, ms)

| Area | Metric | Spec baseline | After wave 1 | After wave 2 |
|---|---|---|---|---|
| Scan (10k) | rescan, harness `7x` (20k rows, see note) | 2,433 | 2,488 | **640** (−74%) |
| | main-actor time within `7x` | ~2,250 | ~2,300 | **14.6** |
| | rescan of an unchanged 10k library (`7w`, new) | n/a | 1,995 | **334** (−83%) |
| | main-actor time within `7w` | n/a | ~1,850 | **7.8** |
| Launch (10k) | until the launch rescan ends (`7v`, new) | n/a | 2,353 | **687** (−71%) |
| | main-actor time: synchronous `setModelContext` + rescan | ~2,200 | ~2,200 | **350 + 7.9** |
| | `COLD setModelContext` (no library) | 443 | 408 | **348** (−15%, no `stat` pass) |
| First scan (1k) | `scan1k FIRST` (wall) | 1,581–1,655 | 1,654 | **316** (−81%) |
| | main-actor time (`7z`, new) | ~1,500 | ~1,600 | **129** |
| | `SECOND` (unchanged) wall / main-actor | 198 | 185 | **33.7 / 1.4** |
| Thumbnails after a relaunch | synthetic 24 MP single / fast scroll last 20 | n/a | 92.7 / 253 | **1.55 / 0.0** |
| | real JPG single / fast scroll last 20 | n/a | 26.9 / 27.5 | **1.0 / 0.0** |
| | real ARW single / fast scroll last 20 | n/a | 12.2 / 8.7 | **1.2 / 0.0** |
| | committed benchmark: 100 × 24 MP @512, warm disk vs cold decode | n/a | 102 (cold decode) | **0.57–0.73** (140–176×) |
| Thumbnails, first launch | synthetic fast scroll, last 20 | 1,506 (wave 1 "before") | 252 | 246 (−2.4%) |
| | real JPG / ARW fast scroll, last 20 | | 27.5 / 8.3 | 27.8 / 8.5 (+1.1% / +2.4%) |
| Editing | slider tick idle: RAW / real JPG / 24 MP | | 37.0 / 35.3 / 36.1 | 37.2 / 35.9 / 34.8 |
| | tick during the full pass: RAW / real JPG / 24 MP | | 37.7 / 35.2 / 34.2 | 39.3 / 35.2 / 34.8 |
| | main-thread first draw: RAW / real JPG / 24 MP | | 37.6 / 41.7 / 64.5 | 38.1 / 43.4 / 62.2 |
| Metadata | `readMetadata` real JPG / ARW ×190 | 103.7 / 483 | 84.8 / 455 | 82.1 / 454 |
| | `scan1k readMetadata x1000` | 203 | 163 | 167 (+2.4%) |
| Library (10k) | filter `3e`–`3h`, search `4b` | 343–505 / 400 | 1.1–15.7 / 5.0 | unchanged (−2.7% … +2.9%) |
| | rating `5a`/`5b`, bin `8a`/`8b`, 50-photo rating `8c` | | 6.9–15.0 | unchanged (−5.5% … +2.1%) |

Notes:
- **`7x` rescans 20k rows, on every checkout.** The harness seeds `/var/…` paths, but the folder enumerator reports
  `/private/var/…`, so `7x`'s warm-up run duplicates the library. The spec's 2,433 ms was measured the same way. `7w`
  (task 20) seeds canonical paths and is the true unchanged rescan.
- **Launch main-actor time is now almost all `loadExistingData()`**: the fetch plus building facts, about 330 ms at
  10k. It was out of scope for task 20; task 30 should take it (below).
- **Edit ticks include the 30 ms debounce.**
- **The "single cold" thumbnail lines rose from wave 1's numbers, on both sides.**
  - The cold runs now wait for the disk-cache folder to settle, so every cold decode starts after a ≥ 300 ms idle
    pause. For example, real JPG single cold reads 55–65 ms on every checkout, against 27 ms in wave 1.
  - Compare these lines only within this harness.

### Lines over +5%: checked, none attributable

1. **Synthetic cold fast scroll, "all tasks finished": +8.2%** (374 → 405 ms). The user-visible "last 20" line is
   −2.4%.
   - On task 21's own branch it was within `main`'s range (376 / 379 against 367–395).
   - A focused, isolated run (`testThumbSynthetic` alone, 6 samples per side) gave:

     | Variant | "all tasks finished" |
     |---|---|
     | pre-wave | 392.4 ms |
     | merged, disk cache off | 399.4 ms |
     | merged, disk cache on | 399.8 ms |

   - That is +1.8%, and the disk cache adds nothing. The +8% appears only in the full suite, as an ordering or state
     effect.
2. **Real JPG single cold: +5.9%.** The `main` runs alone spread from 48.6 to 62.2 ms (the idle-pause artifact above);
   noise.
3. **Task 22's branch alone: real ARW fast scroll +5–7%** (about 0.5 ms on 8 ms).
   - A focused alternating run (9 samples each) gave median 8.1 → 8.5 ms (+4.9%).
   - Nothing task 22 changed runs in that benchmark, which calls `ImageLoader` directly, and the per-image ARW decode
     is unchanged.
   - On merged `main` the line is +2.4%. Recorded as noise at this line's resolution.

## Per task

### 20: scan and launch, merged

- **Gate:** clear wins on every primary metric.
  - `7x` main-actor time is 14 ms, from about 2.3 s.
  - `7w` takes 331 ms.
  - The first scan takes 308 ms (124 ms main-actor), from 1,574 ms.
- **The regressions the agent reported under load were not real.** Quietly, `3g`, `3h`, `5b` and `8a`–`8c` are all
  within ±3% of `main`.
- **Bug fixes:**
  - The `Dictionary(uniqueKeysWithValues:)` launch crash on duplicate rows is gone: the test crashes the host on
    `main`.
  - Scans run one at a time.
- **Design:**
  - Stored rows are read as plain values through a read-only background `ModelContext`.
  - The diff is off the main actor.
  - The main actor writes only changed fields, and an unchanged rescan leaves `hasChanges == false` and doesn't
    reload.
  - New photos **without** keywords are inserted through a background context. A probe showed that background links
    to a tag which the main context holds are lost, so photos with keywords go through the main context.
  - Metadata is read with `concurrentPerform`.
- **Merge conflict:** the stored-property block, where task 22 had removed `previewTask`/`fullResRenderTask` next to
  task 20's new scan state. Resolved by ownership: task 20's block, without the two removed properties.

### 21: thumbnail disk cache, merged

- **Gate:** the primary metric improved by far more than the target.
  - After a relaunch a thumbnail loads in 1.0–1.7 ms, against 12–92 ms to decode it, and the fast scroll finishes in
    about 0 ms.
  - The cold path with an empty cache stays within noise. The harness gives +1.3% / +0.6% / −4.2%. The branch's own
    in-process benchmark gives +5.8% in round 1, −4.2% in round 2 and −1.8% on merged `main`.
- **Layout:** one folder per photo (the SHA-256 of its path), holding `<bucket>-<size>-<mtime>.jpg`, with no index
  file.
- **Behaviour:**
  - LRU by mtime touch.
  - Queued stores are bounded to 64 MB.
  - Truncated files are detected by the missing JPEG end marker and deleted.
  - Survives outside deletion.
- **Test host:** only the `PHOCASA_THUMBNAIL_CACHE_DIR` folder is used.

### 22: EditSession, merged

- **Gate (structure and correctness):**
  - 13 editing properties and the render tasks left the view model.
  - No direct sidecar writes remain in `ViewModels/` or `Editing/`.
  - Four bug tests fail on `main` and pass on the branch:
    - JPG comparison orientation;
    - the unedited image after a save;
    - RAW edit writes bypassing `MetadataWriter`;
    - a new one: navigating while editing saved the previous photo's parameters onto the next photo.
  - Edit ticks and first draw are within noise.
- **Design:**
  - `EditSession` is one per photo, with `RAWEditStore` for saves still queued in the writer.
  - After a save, the saved edit is handed back to the detail view. A finished full-resolution render is reused;
    otherwise it re-renders on `.full`.
  - Exports call `photosDidChange` and `ImageLoader.invalidate(path:)`, which was task 30's planned item.

### 23: metadata and rating decisions, merged

- **Gate:** every part's tests fail on `main` and pass on the branch.
  - **A:** third-party XMP survives, and an unparseable sidecar is left byte-identical.
  - **B:** pairs write both files, and RAW edits survive.
  - **C:** a star click rates instantly; a double-click rates once and doesn't open the photo; under a rating filter
    the neighbour isn't rated.
  - **D:** a regression test for embedded RAW ratings; it passes on both sides.
  - `readMetadata` and the rating lines are within ±1%.
- **JPEG camera metadata (found by task 21, fixed by task 23).** On `main`, and since the first commit, every rating
  write to a camera JPG rebuilt its Exif through ImageIO and dropped:
  - the Sony MakerNote (38,972 B);
  - the Interop IFD and several IFD0/IFD1 tags;
  - ImageIO's `{PictureStyle}`;
  - COM and unknown APPn segments.

  The fix splices only ImageIO's new XMP (and IPTC) segments into the original bytes, so everything else stays
  byte-identical. Anything unusual falls back to today's write, and every result is read back before it replaces the
  file. In the real app, a rated camera JPG kept its 50,832-byte Exif segment and gained only a 4,506-byte XMP segment.

## Suite, warnings, app check

- **Suite after each merge** (the skips are gated benchmarks and gated real-file tests):

  | After | Result |
  |---|---|
  | 23 | 347 executed, 16 skipped, 0 failures |
  | 22 | 381 / 17 / 0 |
  | 20 | 411 / 18 / 0 |
  | 21 | **441 / 20 / 0** |

- **Clean build of merged `main`: 0 compiler warnings.** The AppIntents tooling notice is the only `warning:` line.
- **Real-app check.**
  - Setup:
    - the built app was launched with the in-memory-store flag and `PHOCASA_THUMBNAIL_CACHE_DIR` pointing at a temp
      folder;
    - `lsof` showed no `default.store` open;
    - `~/Library/Caches/com.phocasa.app` never appeared;
    - the photos were a temp copy of 17 pairs from `~/PhocasaBenchRAW`, one of them made RAW-only, with three
      rotated, plus a Lightroom-style sidecar and an unparseable sidecar.
  - It was driven with real mouse and keyboard events, with screenshots. Checked:
    - **Scan (20):**
      - "Reading metadata for 17 new photos…" progress text;
      - correct counts: 17 photos, 16 JPG, 17 RAW;
      - rotated photos upright;
      - the Lightroom sidecar imported rating 2 and only its `dc:subject` keywords.
    - **Rescan (20):**
      - after a pair was added and one deleted on disk, the toolbar Rescan showed the new pair and hid the deleted
        one;
      - ratings were kept.
    - **Stars (23):**
      - a grid star click showed the rating within 50 ms;
      - a double-click on a star rated once and didn't open the photo;
      - under Unrated, a double-click rated the photo and its neighbour, which slid into place, stayed unrated.
    - **Pair and RAW-only writes (23):**
      - a pair wrote `xmp:Rating` to the JPG and a new `.xmp`;
      - the RAW-only photo wrote only its sidecar, and the ARW's SHA-256 is unchanged.
    - **Lightroom sidecar (23):** rated 2 → 5, all 18 third-party properties kept (`crs:`, `lr:`, `acme:`, …).
    - **Unparseable sidecar (23):** byte-identical, while its JPG got the rating.
    - **Editing (22):**
      - RAW edit of a rotated portrait: live exposure preview, upright render;
      - the JPG comparison's JPG side is upright (on `main` it was sideways);
      - crop and apply;
      - Escape saves, and the saved edit stays on screen with the "Edited" badge (on `main` the unedited photo came
        back);
      - the sidecar got `phocasa:EditParameters` through the writer;
      - re-entering edit mode loads the saved parameters;
      - export "Create new file" wrote an upright, cropped 2448×4912 JPG, and the grid thumbnail updated;
      - Revert removed the edit parameters and the badge;
      - JPG edit, side-by-side, and "Apply edits permanently" rewrote the file, reset the sliders and showed the baked
        file.
    - **Relaunch (21):**
      - after quitting, relaunching and reopening the folder, every thumbnail was on screen 0.6 s later;
      - 18 cached thumbnails were touched on read, so they came from the disk cache.
  - `~/PhocasaBenchRAW` is unchanged: read-only, 380 files, none modified this session.

## Decisions for the user (answered 2026-09-25)

The user's answers, in order: 1 → fix it in wave 3 (task 32); 2 → keep; 3 → keep; 4 → keep the rating writes; 5 → keep
the current behaviour; 6 → sort by capture date in wave 3 (task 33). On task 31's schema change, the coordinator
merges without pausing and reminds the user in its final report to back up `~/Library/Application Support/default.store*`.


1. **Move to Bin doesn't survive a relaunch (existing bug, task 20).** Every scan, including the launch rescan, takes a
   binned photo back out of the bin if its file still exists. It is kept as on `main`, and pinned by a test.
   Recommendation: leave binned photos in the bin. That's a small change in `ScanPlan`.
2. **Clearing a rating by clicking the current star waits the double-click interval** (task 23). Setting a rating is
   instant. The alternative is an instant clear, where a double-click on the current star flashes 3 → 0 → 3 and the
   photo drops out of a rating filter.
3. **Unparseable sidecars are never written, and nothing tells the user** (task 23). Seen in the app: such a sidecar's
   old rating, read by the text fallback, then wins over the JPG's newer rating on the next import (a pair rated 3 came
   back as 1). The alternatives are:
   - surface the skip in the UI;
   - back the file up and replace it;
   - ignore unparseable sidecars when reading.
4. **JPEGs the splice can't handle safely still get ImageIO's lossy rewrite** (task 23). The alternative is to skip the
   write for them.
5. **Navigating while editing** saves and starts a fresh edit on the next photo, and ends edit mode if that photo has no
   file of the kind being edited (task 22).
6. **Sort by capture date** (`DateTimeOriginal`) instead of file creation date (task 20's proposal; a schema change).
7. **Existing: "Create new file (-raw-edit)" points the photo's JPG at the export,** and the next scan undoes it: the
   export becomes its own photo and the pair gets its original JPG back (seen in the app).

## Follow-ups and how wave 3 must adapt

No task was skipped, so tasks 30 and 31 go ahead as planned, with these changes:

- **Task 30:**
  - **Launch.** The remaining main-actor time is `loadExistingData()`, about 330 ms at 10k. It could build the snapshot
    off the main actor, or add an incremental "photos inserted" path for scans that insert.
  - **`ImageLoader.invalidate(path:)` after exports is done** (task 22). `loadFullResolution(for:)` has no app callers;
    decide whether to keep it.
  - **CLAUDE.md.** Document:
    - `Editing/`: `EditSession`, `RAWEditStore`, `SavedEdit`;
    - `MetadataWriter`: serial and coalescing, with a synchronous enqueue and pair writes;
    - sidecars updated in place, and JPEG writes that change only XMP/IPTC;
    - the thumbnail disk cache and `PHOCASA_THUMBNAIL_CACHE_DIR`;
    - the background-`ModelContext` rule: it may read, and may insert rows without relationships, but never change or
      link a row the main context holds;
    - `NSApp.currentEvent?.clickCount` as an AppKit exception.
  - **Disk cache:**
    - re-key entries after a metadata-only rewrite, since JPEG rating writes change the size;
    - serve smaller buckets from larger ones on disk;
    - persist the byte total.
  - **Editing:** saved-edit renders in the detail view are still full resolution (about 190 ms per RAW navigation), and
    so is the 300 ms full pass at fit.
- **Task 31 (`isDeleted` rename):** also update `StoredPhoto.fetchAllNow`'s predicate, `applyScanUpdates` and the
  harness. Stop before merging so the user can back up `~/Library/Application Support/default.store*`.
- **Harness:** `7x`'s seed paths could be made canonical, which re-baselines it.
- **Flake to watch:** `ImageEditingServiceTests.testStandardExportMatchesReference` failed once in task 21's baseline
  (max channel difference 4). The test itself notes ImageIO JPEG-encoder non-determinism.
