# Wave 3: coordinator merge record

**Merged into `main`:** 30, 34 (wave 3A), then 31, 32, 33, 35 (wave 3B), in that order, each with `--no-ff`:

| Merge | Task | Notes |
|---|---|---|
| `c7237ba` | 30 | View model split (`LibraryStore` files, `SelectionModel`, `LibrarySort`), grid kept alive under the detail view, trashing off the main thread, quit flush, CLAUDE.md |
| `a115b08` | 34 | Disk-cache re-key after metadata writes, smaller buckets from larger ones, persisted byte total, `loadFullResolution` removed |
| `605e272` | 31 | `isDeleted` → `isInBin` (`originalName` migration), dead fields dropped, `MigrationTests`, `BinFlagTests` |
| `f427dc2` | 32 | Launch off the main actor, scans and deletes patch the library in memory, the bin survives rescans and relaunches. One conflict, and task 31's rename re-applied (below) |
| `892548f` | 33 | Sort by capture date, stored at scan and backfilled after launch |
| `71ef03f` | 35 | Edit passes and saved edits at viewport size, native on zoom, next saved edit prefetched |

**Skipped:** none. Every task passed the merge gate.

**Also on `main`:**
- `c5f2cda`, `1d91126`: task-file and ownership fixes before each sub-wave (below).
- `c3dffe3`: the coordinator's test runner keeps the display awake (below).
- `73cfedc`, `f89d705`: CLAUDE.md lines from tasks 34, 31, 32, 33 and 35, plus two rules learned while merging.
- `5449cd6`: `MigrationTests` extended to task 33's attribute.
- `808063d`: **integration fix**. The full suite crashed after 32 and 33 were both merged (below).
- `7657c2e` (after the real-app check, branch `fix/delete-key-and-store-folder`):
  - `abe892f`, the Delete key moves the selection to the Bin again (found in the check);
  - `81be5bc`, the library moves to `Application Support/Phocasa/Phocasa.store` (the user's request).

  Both are described below.

## Before dispatch: task-file fixes

- **3A (`c5f2cda`).**
  - `MetadataWriterTests` belonged to 34, but its view-model tests call selection APIs that 30 moved. 30 took those call
    sites (mechanical only), and 34 left those tests alone.
  - 34 wires its re-key seam inside its own files, not in `PhocasaApp`, and keeps `MetadataWriter`'s API (`flush()`
    for 30's quit hook).
  - 34's CLAUDE.md lines go to the coordinator.
  - Sent to 30 mid-task: `LibrarySort` must be the only thing that orders photos, including a future background
    snapshot, and 30 must name an after-launch hook for 33.
- **3B (`1d91126`).** Each task file got "Coordinator notes after task 30 merged", taken from 30's "Layout for wave 3B":
  - **31:** the call sites, plus a failing-first regression test for the bin-flag bug task 30 found.
  - **32:**
    - the incremental insert goes in `+ListEditing`, not `+Mutations`, and new state goes in `LoadingState`/`ScanState`;
    - order only through `LibrarySort` (never `key(creationDate:)`);
    - keep the `waitForScans()` contract;
    - optionally, deletes without a full reload.
  - **33:** the `LibrarySort` API, the insert sites, the one-line hook in `setModelContext`, re-sort in memory, and the
    `isDeleted` collision on its branch.
  - **35:** keep `previewImage`/`fullImage`/`parameters`, and document the no-viewport behaviour, for the harness.
  - README ownership table and the post-3A baseline (495 / 26 / 0).
- **Mid-wave messages** to 32 and 33, after 31 finished: list every `isDeleted` use you add. After the rename,
  `photo.isDeleted` still compiles as SwiftData's own flag: a read returns false, and a predicate crashes at fetch time.

## How it was measured

- **Quiet machine:** no agents or builds running. The display was kept awake (see below). Load 2–8 during runs, from
  the benchmarks themselves (the thumbnail tests use every core). Debug test host. Each benchmark reports the median of
  its own runs.
- **Harness:** `Tools/coordinator/ab.sh` with the six gated classes (`ThumbnailSchedulerBenchmarks`,
  `DetailNavigationBenchmarks`, `ImageEditingServiceBenchmarks`, `EditViewModelBenchmarks`,
  `ThumbnailDiskCacheBenchmarks`, `MetadataSidecarBenchmarks`). `TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR` pointed at a
  temp folder.
- **3A:** main, 30, 34, main, 34, 30, main (7 runs). Then a focused, alternated re-run of 34's thumbnail class against
  its own benchmark-only commit (`23be313`), and of the two lines that rose after 30 merged.
- **3B:** main, 31, 32, 33, 35, main, 35, 33, 32, 31, main (11 runs). Then focused, isolated re-runs of every line over
  5%, on five checkouts, alternated (base ×3, branch ×2). 35's own `EditRenderSizeBenchmarks` ran on real RAW copies,
  the base using its `sed` variant.
- **Final:** pre-wave-3 `main` (`c5f2cda`) and final `main` (`f89d705`), interleaved pre, post, pre, post. Then 33's
  and 35's new gated classes on final `main`. Raw lines: `results/bench/wave-3-main-{1,2}.txt`.
- **Real files:** `~/PhocasaBenchRAW`, read only. Tests that write used temp copies.
  `~/Library/Caches/com.phocasa.app` was checked after every run and never existed.

## Before → after (final `main` against pre-wave-3 `main`, interleaved; 10k photos unless noted; ms)

| Area | Metric | Spec baseline | After wave 2 | **After wave 3** |
|---|---|---|---|---|
| Launch | main actor blocked at launch (`setModelContext`, synchronous part) | ~2,200 | 348 | **0.56** |
| | longest main-actor turn while a big library loads | ~2,200 | 348 (one block) | **12.6** |
| | total main-actor time, launch + load + rescan | ~2,200 | ~356 | 301 (in ~30 short turns) |
| | until the launch rescan ends (`7v`) | n/a | 684 | **379** (−45%) |
| | until the library is on screen | 443 | 352 | 325 (−8%) |
| Scans | 10 new photos in a 10k library, main-actor time (`7u`, new) | n/a | ~316 (full reload) | **20** |
| | unchanged rescan (`7w`) wall / main-actor | n/a | 338 / 7.7 | 333 / 7.8 (unchanged) |
| | first scan of 1k: wall / main-actor (`FIRST` / `7z`) | 1,581–1,655 | 311 / 126 | 304 / 118 |
| | `7x` (now seeds canonical paths, so 10k rows, not 20k) | 2,433 | 642 (20k rows) | 336 (re-baselined) |
| Deletes | permanent delete of one photo from the bin (`8d`, new) | n/a | ~316 (full reload) | **12.7** |
| Library | filter `3e`–`3h`, search `4b`, rating `5a`/`5b`, bin `8a`/`8b`, 50-photo rating `8c` | 343–505 / 400 / 68–101 / 353 / 128 | 1.1–15.4 / 5.0 / 6.8–6.9 / 6.7–7.1 / 14.7 | unchanged (−0.4% … +1.7%) |
| | `loadExistingData()` | 343 | 316 | 320 (+1.4%: 33's column −31's dropped fields) |
| | `findOrCreateTag` ×1000 | | 268 | 247 (−7.7%, 31: `Tag` lost two relationships) |
| Thumbnails after a relaunch | 100 JPEGs rated before quitting: load per photo | n/a | 101 (re-decode) | **0.32** (0 decodes) |
| | grid zoomed out since last launch (@380 / @256) | n/a | 101 / 101 | **1.72 / 0.56** (0 decodes) |
| | first cache trim of a session (10k files) | n/a | 416 | **0.06** |
| | cold paths (fast scroll, single cold, warm exact read) | | | unchanged (−3.4% … +1.5%) |
| Editing | slider pause, the pass: RAW / portrait RAW / real JPG / 24 MP | | 112 / 113 / 54 / 67 | **68 / 60 / 30 / 27** (−39 … −59%) |
| | memory held by that pass | | 61–92 MB | **12–21 MB** |
| | saved RAW edit, browsing at 250 / 60 ms per photo: until shown | | 227 / 187 | **1.2 / 92** |
| | saved edit on navigation: RAW / real JPG / 24 MP | 190 (RAW) | 185 / 66 / 74 | 159 / 50 / 51 |
| | memory per saved-edit render; after a save | | 61–92 MB; 61–92 MB | **≤ 26 MB; 47 MB** |
| | edit ticks idle / during the pass, and first draw (coordinator harness, no viewport) | | 33.7–37.1 / 34.2–39.0 / 38.1–66.1 | unchanged (−3.7% … +3.2%) |
| Capture date | backfill of 10k rows after launch: write chunk median / p99 / max | n/a | n/a | 11.7 / 16.9 / 23.8 ms (4 of 299 over 16 ms) |
| | backfill wall, JPG / RAW-only (background) | | | 9.8 / 11.6 s; re-order 5.4 ms, once |
| | every launch with 10k undated rows (background only) | | | 0.39 s, nothing written |
| Metadata | `readMetadata` real JPG / ARW ×190 | 103.7 / 483 | 82.7 / 441.7 | 84.2 / 443.6 (+1.8% / +0.4%) |

- **The final interleave flags no line.** Lines over +5% in the table's source were:
  - the ~1 ms relaunch "single cold" lines (+0.1–0.3 ms, at the timer's resolution, within `main`'s range);
  - `edit|preview 24MP JPEG (fit)` (+9.8%, ranges overlap; this line swung ±10% all night; `ImageEditingService`
    is unchanged).
- **Launch total main-actor time missed task 32's ≤ 150 ms target** (301 ms). The launch no longer blocks, but the
  grid reads every photo's `id`, so the main context must hold filled-in rows (task 32 measured the floor). See
  follow-ups.

## Per task

### 30: structure and polish, merged

- **Gate (structure):** every acceptance criterion met.
  - `PhotoLibraryViewModel` went from 1,582 to 366 lines; no app file is over 400.
  - The layout 3B needed exists, with `LibrarySort` as the only definition of photo order.
  - 231 assertions moved, none lost.
  - Hosted tests show the grid keeps its scroll position and the hidden grid starts no thumbnail work.
- **Quiet A/B:** every line within noise.
  - After the merge, `scan1k SECOND` main-actor (+7.1%) and the no-disk-cache fast scroll (+6.9%) rose in one run.
  - Focused, alternated re-runs gave +1.0% and +1.5%.
- **Found on the way:** the bin-flag bug on `main` (below, 31).

### 34: thumbnail disk-cache follow-ups, merged

- **Gate (performance):** primary metrics far past the target (table above).
- **One line to check:** the warm exact-bucket disk read, +7.9% in the full A/B. The branch adds one `access()` before
  each probe.
  - A focused A/B against its own benchmark-only commit, 3 alternated runs each: +1.1% (0.58 → 0.59 ms). Noise.
  - Writer throughput +2.6%, cold decode +0.1%.

### 31: schema cleanup, merged

- **Gate (structure/correctness):**
  - `MigrationTests` open a store written with the pre-31 models and keep every value. SwiftData's automatic
    lightweight migration handles it; no migration plan is needed.
  - Without `originalName` the store doesn't open at all (the agent's mutation check).
  - 8 `BinFlagTests` fail on `main`'s code and pass after the rename.
- **The bug it fixes (found by 30, wider than thought):** on `main`, any later save of a binned row wrote the bin flag
  back as false, so a photo rated or tagged in the bin reappeared in the library after the next reload or launch. A
  photo binned in an earlier session lost the flag on its second save.
- **Quiet A/B:** `7x` main-actor +5.8% in the full A/B, +0.5% isolated.
- **Merge:** clean.

### 32: launch and bin, merged

- **Gate (performance + user decision):**
  - the launch blocks the main actor for 0.56 ms, not 348;
  - the launch rescan ends 45% sooner;
  - a scan inserting 10 photos costs 20 ms on the main actor, not ~316;
  - a permanent delete costs 12.7 ms, not ~316;
  - the bin survives rescans and relaunches (tests through a real relaunch on a temp store, both launch paths).
  - The ≤ 150 ms total main-actor target is missed, for the reason above.
- **Design choice kept:** the launch snapshot is read in parallel (ordered fetch plus two halves). The grid appears
  about 7% sooner than before, against about 40 ms more total main-actor time than a one-context read, which would
  show it about 80 ms later than before.
- **Merge:**
  - One conflict: `applyScanUpdates`' restore-from-bin block, renamed by 31 and removed by 32. Resolved to 32's side.
  - Task 31's rename was re-applied to 32's three new uses: `LibrarySnapshot.read`'s two predicates and
    `ScanTests.storedBinNames`. All three still compiled as SwiftData's own `isDeleted`.
  - The stale collision comments were removed.
  - All of this is in the merge commit.

### 33: capture-date sort, merged

- **Gate (user decision, must not regress):**
  - order by capture date with the creation-date fallback, both directions, after bin moves, restores, scans and the
    backfill;
  - the backfill chunks stay about 12 ms;
  - fetch-bound lines +2.1–3.4% isolated (the new column's cost; an attribute-only checkout measures the same);
  - in-memory lines ±1%.
  - In the final interleave, `loadExistingData` is +1.4% overall, as 31's dropped fields offset it.
- **One attribute:** `captureDate: Date?`. A second "checked" flag cost +5–13% on every fetch and save, so undated files
  are re-read in the background on each launch instead (0.39 s per 10k, nothing written).
- **Merge:** clean textually. The full suite then **crashed the test host** (next section).

### 35: edit render sizes, merged

- **Gate (performance):**
  - the slider-pause pass is 39–59% faster, with 30–86% less CPU;
  - its memory drops from 61–92 MB to 12–21 MB;
  - browsing saved RAW edits takes 1.2 ms, not 227 ms;
  - every render is `ImageEditingService`'s own output for its size (≤ 1);
  - exports are unchanged;
  - the coordinator's edit harness (no viewport, so native passes) is within ±3%.
- **Beyond the task file, kept:** the next photo's saved edit is prefetched (`3d8f270`, self-contained). Rendering at
  fit alone cut a saved RAW's wait by only about 12%, because the RAW decode dominates.
- **Merge:** clean.

## Integration problems found while merging

1. **The display slept (01:39) and the screen locked.** The hosted-window `GridKeepAliveTests` then read a scroll
   offset of 0 and failed: the hosted window never lays out with the display asleep. Image and GPU lines also shifted.
   - Confirmed: with the display asleep the tests fail alone; after `caffeinate -u` (display on, still locked) they
     pass.
   - Fix at the source: `runtests.sh` (and so `ab.sh`) runs `xcodebuild` under `caffeinate -d -u` (`c3dffe3`).
   - The first `m30` benchmark run, taken with the display off, was discarded and re-taken.
2. **Crash after 32 and 33 were both merged** (`808063d`).
   - The suite stopped at 149 tests: `EXC_BREAKPOINT` in SwiftData, from `LibraryStore.backfillCaptureDates()` reading
     `modelContext.container`.
   - Cause:
     - three of 32's `ScanTests` hooks captured their own view model (`vm → library → hook → vm`), so those libraries
       outlived `tearDown`, which released their containers;
     - two seconds later, 33's after-launch backfill read the released container, which traps (a `ModelContext`
       doesn't keep its container alive).
     - Neither branch alone had both halves.
   - Reproduced with `ScanTests` alone. Breaking the cycles stopped it.
   - Fix:
     - the backfill holds its container weakly and gives up if it's gone (a new test crashes the host without it);
     - six hooks now capture unowned.
   - In the app the container lives as long as the app, so users couldn't hit it. CLAUDE.md now has both rules.
3. **`postmerge.sh` label collision:** the suite and the benchmark run shared a label, so the benchmark overwrote the
   suite's log. Fixed in the scratch tool; noted in `Tools/coordinator/README.md`.
4. **`mdb_txn_commit error: MDB_MAP_FULL`** in late test logs, on base runs too: Metal's shader-archive usage database
   for the bundle id (`$(getconf DARWIN_USER_CACHE_DIR)com.phocasa.app/com.apple.metal/archiveUsage.db`) is full. It's
   a system cache shared with the user's real app, so it was left alone.

## Suite, warnings

| After | Result |
|---|---|
| 30 (`c7237ba`, display awake) | 464 executed, 20 skipped, 0 failures |
| 34 (`a115b08`) | 495 / 26 / 0 |
| 31 (`605e272`) | 506 / 26 / 0 |
| 32 (`f427dc2`) | 525 / 26 / 0 |
| 33 (`892548f` + `5449cd6`) | **host crash at 149**, then 576 / 31 / 0 after `808063d` |
| 35 (`71ef03f`) | 616 / 41 / 0 |
| final (`f89d705`, clean DerivedData) | **616 / 41 / 0**, no host restarts |
| `7657c2e` (Delete key, store location; clean DerivedData) | **627 / 41 / 0**, 0 source warnings, no host restarts |

- **Clean build of final `main`: 0 compiler warnings.** The AppIntents tooling notice (app and test host) is the only
  `warning:` line.
- **`MigrationTests` on merged `main`** (after 33): 4 tests.
  - The V1 → current test now also checks that `captureDate` comes up nil.
  - A new test checks that a migrated store keeps capture dates across a relaunch and orders by them.
  - All pass, with `BinFlagTests` and the backfill tests (20 / 20).
- **The skips** are gated benchmarks and gated real-file tests.

## Real-app check

Done on 2026-09-26, 09:32–09:55, with the screen unlocked, on a build of `237abbd` (final wave-3 `main`).

- **Setup:**
  - the built binary, launched with `XCTestConfigurationFilePath` (in-memory store) and a temp
    `PHOCASA_THUMBNAIL_CACHE_DIR`; `lsof` showed no store file open, on both launches;
  - temp copies of 17 pairs from `~/PhocasaBenchRAW`, copied in reverse order so creation order is the opposite of
    capture order: `DSC08640` RAW-only, three rotated (orientations 6 and 8), a Lightroom-style sidecar and a garbage
    `.xmp`. One more pair was added mid-check for the rescan and the permanent delete.
- **Wave 3, all as intended:**
  - **Capture-date order.** Newest capture first, the reverse of creation order, and oldest first after the toggle.
    The RAW-only photo sits at its capture time.
  - **Bin across a rescan.** The binned photo stayed in the Bin through a rescan, which added the new pair at its
    capture-date place. Counts were right throughout.
  - **Grid scroll.** Opening and closing a photo left the grid pixel-identical. The first click on a partly hidden
    cell scrolls it into view, as designed.
  - **Permanent delete.** The photo left the Bin at once, and a click straight after the confirmation was handled.
  - **Quit.** Rating a photo and pressing Cmd-Q at once still wrote the JPG and the sidecar; the app quit at once.
  - **Relaunch.** No thumbnail was decoded again: no new cache files, and each photo's thumbnail was read from disk.
    That includes the photo rated just before quitting, whose cache entry was re-keyed to the file's new size.
  - **Edits at screen size** (RAW edit of the rotated portrait `DSC08753`, +2.5 EV):
    - sharp at fit at full screen resolution;
    - zoomed to 579%, the native render shows per-pixel sensor noise.
  - **Saved edits.** The saved edit showed at once after Escape. Navigating away and back showed it within 0.15 s,
    pixel-identical to the settled frame.
- **Waves 1–2, re-checked, all as before:**
  - scan progress ("Adding 190 new photos…" on `~/PhocasaBenchRAW`) and counts;
  - instant star clicks; a double-click under Unrated rated once and left the neighbour alone;
  - rating write-backs:
    - pairs write the JPG's XMP and the sidecar, and the RAW-only photo only its sidecar;
    - the Lightroom sidecar kept every field (ImageIO re-serialises it);
    - the garbage sidecar stayed byte-identical;
    - the camera JPG's Exif segment kept its size (`segs.py`);
  - RAW edit of the rotated portrait:
    - the JPG comparison, the crop and the export are upright;
    - the export is native (2558×4055 after the crop);
    - Revert removed the edit from the sidecar and kept the rating;
  - JPG edit of a rotated JPG: side by side upright; "Apply edits permanently" baked upright pixels
    (3264×4912, no orientation tag), and the grid thumbnail refreshed;
  - no `.phocasa-tmp` files, no `~/Library/Caches/com.phocasa.app`, and `~/PhocasaBenchRAW` unchanged (0 files newer
    than the check's start).
- **Not checkable with the in-memory store:** the Bin across a relaunch, the background load of a 500+ library and
  the backfill of an existing library (decision 1). Unit tests on temp on-disk stores cover all three.
- **Side effect:** the permanent delete put the extra pair's two copies (`DSC08652.JPG`, `DSC08652.ARW`, 19 MB) in
  the user's Trash. The terminal can't list the Trash, so they're still there.
- **Found (older than wave 3):**
  1. **The Delete key did nothing.** ⌫ sends U+007F, but SwiftUI's `.delete` is U+0008 and `.deleteForward` U+F728.
     The line dates from the first commit. Fixed after the check (below).
  2. **Exports and "Apply edits permanently" write no metadata.** `writeJPEG` has never added any, and wave 1 kept
     its output byte-identical. So an export has no Exif, capture date, rating or keywords. "Apply edits permanently"
     also strips the camera's Exif from the original JPG, which can't be undone. Decision 6 below.
  3. **An export becomes a separate photo on the next rescan.** A `-raw-edit` export becomes the pair's JPG. Pairing
     is by file stem, so a rescan makes it a photo of its own, and the pair goes back to its own JPG. Having no
     capture date, the export sorts as the newest photo.
  4. **The export dialog of a JPG edit** is titled "Export RAW Edit" and offers the two RAW exports too.

## After the real-app check (`7657c2e`)

- **Delete key** (`abe892f`). The key handler also matches U+007F.
  - `KeyboardShortcutTests` sends the keyboard's own key-downs to a hosted `ContentView`.
  - ⌫ fails before the change. ⌦ and a digit key pass before and after, which shows the harness delivers keys.
- **Store location** (`81be5bc`, the user's request: a bare `default.store` says nothing about Phocasa, and every
  non-sandboxed SwiftData app that keeps the default shares it).
  - The library is now `~/Library/Application Support/Phocasa/Phocasa.store`.
  - `StoreLocation.prepare` runs before the container opens. It moves a `default.store` whose metadata names
    `PhotoAsset`, with its `-wal`, `-shm` and `.default_SUPPORT` external-data folder, renamed to match.
    - The store file moves last, so a launch that stops part way finishes the move next time.
    - Another app's `default.store` is left alone.
    - A store whose metadata can't be read is opened where it is, as before.
    - The test host keeps its in-memory store and never calls it.
  - `StoreLocationTests`, 8 tests on temp folders standing in for Application Support:
    - a pre-task-31 store moves with every file, and opens with every value, including the externally stored edit
      data;
    - an existing Phocasa store wins;
    - another app's store stays;
    - an unreadable store stays;
    - an interrupted move is finished;
    - SwiftData names the external-data folder after the store, which the move relies on.
  - Two mutations (skip the external-data folder; move another app's store) each fail the tests meant to catch them.
  - Launch cost: two `fileExists` checks. The metadata read and the move run once. No benchmark covers the launch
    of a real store, and none was needed.
  - A store's SQLite files can't be compared byte for byte in tests. SwiftData checkpoints them when it likes, even
    after its container is released, through a moved file's handle too. The tests compare file names, the external
    data's bytes, and the contents by opening the store; CLAUDE.md now says so.
- **Docs:** CLAUDE.md (store location, the Core Data metadata read, the testing rule) and the coordinator README (the
  new path, `lsof … grep -c "\.store"`, and three app-driving lessons).

## Decisions for the user

**Answered on 2026-09-26.** The work is handed over in `../post-wave-3-prompt.md`.
1. Real-app checks get their own on-disk library in `Application Support/Phocasa-Development` (task B there).
2. Backup done (`~/Desktop/Phocasa-backup`).
3. Keep the prefetch.
4. Decide on evidence (task C).
5. 300 ms is fine: the ≤ 150 ms target and the grid-identity follow-up are dropped.
6. Never remove a photo's original metadata; only add to it or use sidecars. A major bug (task A, and now a rule in
   CLAUDE.md).

The decisions as asked:

1. **Checking relaunch behaviour in the real app.** The in-memory store the app uses under the test flag forgets the
   library on quit. So a real-app check can't show Move to Bin surviving a relaunch, a 500+ photo library loading in
   the background, or the capture-date backfill of an existing library.
   - All three are covered by tests on temp on-disk stores.
   - I tried to add a `PHOCASA_STORE_URL` override (honoured only with the test flag, so a normal launch couldn't be
     redirected). The permission classifier blocked it as security-weakening, and I didn't pursue it.
   - Options: allow it, or check these three yourself on a copy of your library.
2. **Back up your library before running this build normally.** Quit Phocasa, then copy
   `~/Library/Application Support/default.store`, `default.store-wal`, `default.store-shm` and the hidden
   `.default_SUPPORT` folder, if present, somewhere safe.
   - The first launch moves them to `~/Library/Application Support/Phocasa/`. It then migrates them in place: task
     31's rename and 33's new attribute. A failed migration stops the app at launch, and the backup is the only way
     back.
   - The migration and store-location tests pass, including a pre-task-31 store moved and then migrated.
   - Task 31's probe showed an older build still opens a migrated store. An older build now looks for `default.store`
     and finds none, so going back means moving the files back as well.
3. **Task 35's saved-edit prefetch** (`3d8f270`) wasn't in the task file. It's what makes arrowing through edited RAWs
   instant; keep it unless you'd rather not spend up to 26 MB on one render ahead.
4. **Sharpening and clarity at fit** now apply at screen scale, so an edit at fit looks slightly different from the
   same edit zoomed in. The difference is about half of what the slider preview already shows. Alternative: scale the
   pixel-radius filters by the render's scale in `ImageEditingService` (a deliberate pixel change).
5. **Launch main-actor total ≤ 150 ms** needs the grid to take photo identity from `library.shownIDs`, not the models
   (a `PhotoGridView` change; task 32's follow-up). Today the launch no longer blocks, but it spends about 300 ms of
   main-actor time in ≤ 13 ms turns.
6. **Metadata in exports and "Apply edits permanently"** (found in the real-app check; older than wave 3).
   - Today the written JPEG has no metadata. "Apply edits permanently" strips the camera's Exif from the original
     JPG, including the capture date, and its rating and keywords.
   - Suggested: copy the source's metadata into the written file, with the orientation reset to 1 (the pixels are
     already upright), and re-apply Phocasa's rating and keywords.
   - That changes the bytes of every export, which wave 1 kept identical on purpose. Your call.

## Follow-ups

- **Launch:** the grid identity change above; `7u` would halve with a higher patch limit for inserts.
  `loadExistingData()` is still one ~320 ms block when it runs: `refreshAvailability`, a load that overtook a scan.
- **Capture dates:**
  - re-run the backfill after scans that change the missing set (an offline drive back);
  - read XMP-sidecar capture dates (Lightroom's "Edit Capture Time") and `DateTimeDigitized` for scans;
  - consider marking undated files without a column.
- **Duplication:** `LibrarySnapshot` builds `PhotoFacts` off the main actor by duplicating `PhotoFacts(_:tags:)`;
  `testSnapshotReadsWhatAFullLoadBuilds` pins them. A nonisolated builder in `PhotoQuery.swift` would remove it.
- **`FullImageLoader.clear()` doesn't clear `infoCache`.** After "Apply edits permanently" bakes a crop into a JPG, the
  loader reports the old pixel size until relaunch (task 35's note).
- **Edit hand-off:** release it once the saved edit has been re-rendered for the wider viewport (21 MB). Key-repeat
  browsing through edited RAWs still waits ~92 ms per photo (the RAW decode).
- **Thumbnail cache:** restore the exact `st_mtimespec` in `restoreFileDates` (`utimensat`) instead of rounding
  through `Date`. The re-key tolerates 10 µs today.
- **Quit** waits for metadata writes only; a running trash batch is cut off (its rows stay until the next scan).
- **In-app backup before a schema migration** (task 31's follow-up): copy the store aside once when its model differs
  from the app's. The store is now `Phocasa/Phocasa.store` with its companions.
- **Exports** (real-app check): a `-raw-edit` export becomes a separate photo on the next rescan, and the pair goes
  back to its own JPG (pairing is by stem). The JPG edit's export dialog is titled "Export RAW Edit" and offers the
  two RAW exports. Crop mode shows the unedited original.
- **Harness:**
  - rename the `1a`/`1b` labels (they still say `isDeleted`);
  - the "single cold" thumbnail lines mostly measure CPU wake-up after a 300 ms pause;
  - the full-suite ordering adds about 6% to the no-disk-cache fast scroll on some branches (not seen in isolation).
- **Flake to watch:** task 33 saw `GridKeepAliveTests.testClosingTheDetailViewKeepsTheGridScrollPosition` read
  5289.5 against 5297.5 pt (the scroll animation not settled) in some full runs, on `main` too. It didn't recur in the
  coordinator's runs once the display was kept awake.
- Recommendations carried from 30: `LazyVGrid` replacement, a Metal preview view, colour management (evidence in
  `results/30.md`).
