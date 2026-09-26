# Coordinator tools

The tools the plan coordinator uses to judge merges (the "Merge gate" in
`docs/superpowers/plans/2026-09-25-performance/README.md`) and to check the real app. They aren't part of any build
target.

| File | What it is |
|---|---|
| `CoordinatorBenchmarks.swift` | A/B benchmark test class. It uses only public app APIs, so the same file runs on `main` and on a task branch. Copy it into `Phocasa/PhocasaTests/` of the checkout you're measuring, and delete it afterwards. |
| `CoordinatorEditBenchmarks.swift`, `CoordinatorEditBenchmarks-Session.swift` | The edit A/B tests (`CoordinatorEditBenchmarks`), in two variants with the same labels. Before task 22 copy the first (view-model editing API); from task 22 on copy the second (`EditSession`). Copy exactly one (`ab.sh` picks it). If task 30 changes the view-model entry points they call (`setModelContext`, `loadExistingData`, `openDetail`, `startEditing`, `editSession`, `stopEditing`), update the session variant. |
| `ab.sh` | `ab.sh <git-ref> <label> [-only-testing:…]`: checks the ref out in the detached bench worktree `$TMPDIR/phocasa-bench` (created on first use), copies the harness in (the right edit variant automatically), runs `DataPathBenchmarks`, `CoordinatorBenchmarks` and `CoordinatorEditBenchmarks` with the real-file and disk-cache env vars, and writes the `BENCH\|`/`COORD\|` lines to `$TMPDIR/phocasa-coord-results/<label>.txt`. About 3 minutes per run. |
| `multi.py` | `multi.py base1.txt base2.txt -- other1.txt other2.txt [--filter REGEX]`: the mean of several base runs against several other runs, per line, flagging (`<<`) a rise over 5% only when the other side's best run is still > 5% above the base's worst. Skips harness-only lines. |
| `runtests.sh` | `runtests.sh <checkout> <label> [xcodebuild args…]`: runs `xcodebuild test` with its own DerivedData (`$TMPDIR/phocasa-dd-coord-<label>`), then prints the result, the test count, errors and source warnings. The log goes to `$TMPDIR/phocasa-coord-<label>.test.log`. |
| `cmp.py` | `cmp.py before.txt after.txt [regex]`: compares `BENCH|`/`COORD|` lines and flags rises over 5%. |
| `app-driver/segs.py` | Lists a JPEG's marker segments and sizes. A rating write must change only APP1/XMP (and APP13); the Exif segment keeps its size (task 23). |
| `app-driver/*.swift` | Tiny CLIs for driving and inspecting the real app. `click x y [n]` posts real mouse clicks (screen points). `drag drag x1 y1 x2 y2 [steps]` / `drag scroll x y lines [n]` post drags and scroll-wheel events. `rating <files>` prints `xmp:Rating` via ImageIO. `orient <files>` lists files with EXIF orientation ≠ 1. Build each with `swiftc -O file.swift -o "$TMPDIR/<name>"`. |

## Quiet A/B protocol

Take these measurements only when no agents or builds are running (check `uptime`). Numbers taken under load are
noise.

```bash
B="$TMPDIR/phocasa-bench"                        # a detached worktree just for measuring
git worktree add --detach "$B" main              # once; later: git -C "$B" checkout -q -- . && git -C "$B" checkout -q --detach <ref>
export IMAGEBENCH_DIR="$TMPDIR/phocasa-imagebench-coord"
(cd Tools/imagebench && swiftc -O -swift-version 5 imagebench.swift -o "$TMPDIR/imagebench-coord") \
  && "$TMPDIR/imagebench-coord" gen && "$TMPDIR/imagebench-coord" copies     # 200 × 24 MP JPEGs, ~3 GB
cp Tools/coordinator/CoordinatorBenchmarks.swift "$B/Phocasa/PhocasaTests/"
cp Tools/coordinator/CoordinatorEditBenchmarks-Session.swift "$B/Phocasa/PhocasaTests/"   # or CoordinatorEditBenchmarks.swift before task 22
export TEST_RUNNER_PHOCASA_BENCH=1 \
       TEST_RUNNER_COORD_BENCH_DATA="$IMAGEBENCH_DIR/data" \
       TEST_RUNNER_COORD_REAL_DIR="$HOME/PhocasaBenchRAW" \
       TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR="$TMPDIR/phocasa-coord-thumbcache"   # task 21's disk cache (temp)
Tools/coordinator/runtests.sh "$B" A-main -only-testing:PhocasaTests/DataPathBenchmarks -only-testing:PhocasaTests/CoordinatorBenchmarks -only-testing:PhocasaTests/CoordinatorEditBenchmarks
grep -hE '^(BENCH|COORD)\|' "$TMPDIR/phocasa-coord-A-main.test.log" > A-main.txt
# …check out the branch in $B, run the same tests, then:
python3 Tools/coordinator/cmp.py A-main.txt B-branch.txt
```

- Run `main` and each branch back to back. Compare each task's **primary** metrics, and check nothing else rises by
  more than 5%.
- `DataPathBenchmarks` lines `3a`–`3c` and `4` are cached no-ops after task 10 (repeat click or repeat text). Judge
  filter and search on `3e`–`3h` and `4b`.
- Gated benchmarks that live in task test files run with the same `TEST_RUNNER_PHOCASA_BENCH=1`:
  `ThumbnailSchedulerBenchmarks`, `DetailNavigationBenchmarks`, `ImageEditingServiceBenchmarks`, and whatever
  wave 2 adds.
- **The edit tests (`testEdit*`)** live in `CoordinatorEditBenchmarks`. Task 22 moved editing into `EditSession`, so
  there are two variants: the view-model API (`startEditing`, `editParameters` + `updateEditPreview`,
  `editedPreviewImage`, `fullResEditImage`) for code before task 22, and the session API (`vm.editSession`,
  `session.parameters`, whose setter schedules the render, `previewImage`, `fullImage`) from task 22 on.
- **Thumbnail disk cache (task 21 on).** With `PHOCASA_THUMBNAIL_CACHE_DIR` set, the test host's `ImageLoader.shared`
  keeps its disk cache in that temp folder; without it, the test host has none. Cold thumbnail runs empty the folder
  first (after its writes settle); `testThumbRelaunch` keeps it warm and empties only memory. Code without a disk
  cache ignores the variable, so on `main` "relaunch" equals "cold". Check that nothing lands in
  `~/Library/Caches/com.phocasa.app`.
- `~/PhocasaBenchRAW` is the user's read-only folder of 190 real JPG+ARW pairs (16 MP; 12 rotated). The benchmarks
  only read it.

The wave-1 quiet baseline and results are in `docs/superpowers/plans/2026-09-25-performance/results/wave-1-coordinator.md`.

## Checking the real app without touching the user's library

A normal launch opens the user's real SwiftData store: `~/Library/Application Support/Phocasa/Phocasa.store`, where
the first launch of a build from 2026-09-26 on moves `~/Library/Application Support/default.store`. **Never do that.**
Launch a **Debug** build of the binary in one of two ways instead (`LibraryLocation` decides; task B):

- **Development library** (`PHOCASA_DEVELOPMENT_LIBRARY=1`, Debug builds only; a Release build ignores it): the library
  lives on disk in `~/Library/Application Support/Phocasa-Development/Phocasa.store`, its thumbnails in
  `Phocasa-Development/Thumbnails/v1` (or `PHOCASA_THUMBNAIL_CACHE_DIR`). It survives a relaunch. It never reads, moves
  or opens `Application Support/Phocasa/` or a `default.store` (no legacy move runs), and never writes
  `~/Library/Caches/com.phocasa.app`. **Don't also set `XCTestConfigurationFilePath`:** the test host's in-memory store
  wins over the flag.
- **In-memory** (`XCTestConfigurationFilePath=/dev/null/in-memory`): a throwaway store, forgotten on quit, and no disk
  cache unless `PHOCASA_THUMBNAIL_CACHE_DIR` names one. Enough when the check needs no relaunch.

1. **Photos:** make a writable temp copy of some test photos. Include rotated ones (`orient`), and remove one JPG to
   get a RAW-only photo:
   `mkdir -p "$TMPDIR/phocasa-smoke/photos"; cp ~/PhocasaBenchRAW/DSC086{37..50}.* "$TMPDIR/phocasa-smoke/photos/"`.
2. **Build** with `xcodebuild … -configuration Debug -derivedDataPath "$TMPDIR/phocasa-dd-coord-app" build`, and check
   for 0 source warnings. Build Release once too (`-configuration Release`, its own DerivedData): its whole-module
   concurrency check catches errors a Debug build doesn't (task 32's launch code broke it unnoticed until task B).
3. **Reset the development folder**, so each check starts from an empty library (quote the path, it has a space):
   `rm -rf "$HOME/Library/Application Support/Phocasa-Development"`. It's the only folder under Application Support a
   check may write or delete.
4. **Launch the binary directly**, in the background:
   `PHOCASA_DEVELOPMENT_LIBRARY=1 "$TMPDIR/phocasa-dd-coord-app/Build/Products/Debug/Phocasa.app/Contents/MacOS/Phocasa" & PID=$!`.
   Once the window is up, confirm that only the development store is open:
   - `lsof -p $PID | grep "\.store"` lists only `…/Application Support/Phocasa-Development/Phocasa.store` (and its
     `-wal`/`-shm`): `lsof -p $PID | grep -c "Phocasa-Development/Phocasa\.store"` is at least 1, and
     `lsof -p $PID | grep "\.store" | grep -vc "/Phocasa-Development/"` is `0`;
   - `lsof -p $PID | grep -cE "Application Support/(Phocasa/|default\.store|\.default_SUPPORT)"` is `0`.
   If either check fails, `kill $PID` and stop.
   - *In-memory alternative:* `XCTestConfigurationFilePath=/dev/null/in-memory "…/Phocasa" & PID=$!`, and
     `lsof -p $PID | grep -c "\.store"` is `0`. Skip step 3.
5. **Relaunch** (development library only): quit with Cmd-Q (`key code 12 using command down`, inside the `osascript`
   that sets the app frontmost; not `kill`, which skips the quit-time metadata flush), wait for `$PID` to exit, then
   launch as in step 4 without resetting the folder, and run the `lsof` checks again. The library comes back without
   reopening the folder. To change the store between launches (for example to clear capture dates for the backfill),
   do it with the app quit, on that file only: `sqlite3 "$HOME/Library/Application Support/Phocasa-Development/Phocasa.store"`
   (SwiftData's tables and columns are `Z`-prefixed, e.g. `ZPHOTOASSET`; check with `.schema`).
6. **Drive it.** The terminal needs Accessibility and Screen Recording permission; the user granted both on 2026-09-25.
   - Bring it to the front and size it: `tell application "System Events" to tell process "Phocasa" …`.
   - Open the folder: Cmd-O, then Cmd-Shift-G, type the path, Return, Return.
   - Use **`key code`** for keys (36 Return, 53 Escape, 123/124 arrows, 18–23 digits 1–6). AppleScript `keystroke "3"`
     does **not** reach SwiftUI's `onKeyPress`.
   - Use `app-driver/click` for clicks. System Events' `click at` performs an accessibility press, which SwiftUI tap
     gestures ignore.
   - Take screenshots with `screencapture -x -R<x>,<y>,<w>,<h> out.png` and look at them.
7. **Check write-backs on the copies:** `rating <jpg>` and `grep` in the `.xmp`. Delete the copies afterwards, and
   the development folder (step 3's `rm -rf`).

### Protocol that worked in wave 2

- **Per branch:** `ab.sh main r1-main`, then each branch, then `ab.sh main r1-main2`; then a second round in reverse
  order. Compare each branch against all the `main` runs with `multi.py`. Reference numbers for merged wave-2 `main`
  are in `docs/superpowers/plans/2026-09-25-performance/results/bench/`, but always re-measure `main` yourself.
- **After each merge:** `ab.sh main m-<task>` and compare with the previous `main` run. At the end, interleave the
  pre-wave commit and merged `main`: pre, post, pre, post.
- **A line over 5% that the branch doesn't touch:** re-run just that test alternately on both sides with
  `-only-testing:…/<test> -test-iterations 3`, in two separate worktrees so nothing rebuilds between runs. In wave 2
  two such lines were suite-order effects, not regressions.
- **Edit harness and task 35.** An `EditSession` without `viewportPixelSize` renders its passes natively, so the
  harness (which has no view) measures the same work on every checkout. To measure the viewport-sized passes, set
  `session.viewportPixelSize = CGSize(width: 2894, height: 2130)` after `vm.editSession` (code from task 35 on only);
  `session.fullImageIsNative` says which kind of pass `fullImage` is. Task 35's own gated benchmarks are
  `EditRenderSizeBenchmarks` (needs `TEST_RUNNER_PHOCASA_TEST_RAW`, and optionally `_2`, naming *copies* of real RAWs;
  on older code, apply the `sed` line in its header).
- **Give the suite and the benchmark run different labels.** `runtests.sh` names its DerivedData and log after the
  label, so a suite and an `ab.sh` run with the same label overwrite each other's log.
- **`mdb_txn_commit error: MDB_MAP_FULL`** in test logs is Metal's shader-archive usage database for the bundle id
  (`$(getconf DARWIN_USER_CACHE_DIR)com.phocasa.app/com.apple.metal/archiveUsage.db`) being full after many runs.
  It's a system cache shared with the user's real app; it only stops usage tracking.
- **Keep the display awake.** `runtests.sh` (and so `ab.sh`) runs `xcodebuild` under `caffeinate -d -u`. With the
  display asleep (after the idle display-sleep timeout, e.g. overnight), `GridKeepAliveTests` fail (scroll offset 0) and
  image/GPU lines shift, so runs taken with the display off aren't comparable with runs taken with it on.
- **The "single cold thumbnail" lines** run after a ≥ 300 ms idle pause (the disk-cache settle), so they read higher
  than wave 1's numbers on every checkout. Compare them only within this harness.

### Driving the app: lessons from wave 2

- **Keys need a key window, and only one "Phocasa" process (post-wave-3).**
  - A test host another agent is running (hosted-window tests, `ScaleChecks`) is also a process called "Phocasa":
    `tell process "Phocasa"` may pick it, and a window move, a key or a Cmd-Q goes to the test host (whose in-memory
    library looks like yours gone empty). Check `pgrep -x Phocasa | wc -l` is 1 first.
  - **An app launched from the terminal may be frontmost without its window being key**, and then every key press
    vanishes (clicks still select). Check `value of attribute "AXFocused" of window 1` is `true` before testing keys.
    What made it key here: Open Folder (Cmd-O) and choosing a folder with Open in the panel (Cancel didn't). A long
    detour in the release check came from missing this: it looked like the photo keys were broken after a launch.
    `KeyboardShortcutTests` covers the keys in a key window, the sidebar's list included.
  - Send each key in its own `osascript`: `tell process "Phocasa"`, `set frontmost to true`, the `key code`. Targeting
    by `first process whose unix id is …` delivered typed text but not plain key codes.
- **Focus moves.** Another window can come to the front between commands, or the window can move. Before *every*
  click or key, pin the window in the same shell command:
  `osascript -e 'tell application "System Events" to tell process "Phocasa"' -e 'set frontmost to true' -e 'set position of window 1 to {40, 60}' -e 'set size of window 1 to {1400, 900}' -e 'end tell' -e 'delay 0.3'`.
  Send each `key code` inside that same `osascript`, after a second `set frontmost to true`. A key sent from a
  separate `osascript` call can land in the terminal (wave 3).
- **The toolbar moves.** Selecting a photo adds the Delete button, which shifts Rescan and the sort toggle about
  37 pt to the left; the Bin view adds more. Take a screenshot before clicking a toolbar button.
- **Permanent deletes go to the user's Trash,** which the terminal can't list or clean. Delete only an extra copy
  added for that purpose, and say so in the record.
- **Coordinates.** `screencapture -R40,60,1400,900` gives a 2800×1800 image. A point in it maps to screen points as
  `x = 40 + px/2`, `y = 60 + py/2`. The image viewer may show it scaled; convert with its stated factor.
- **Relaunch with the disk cache.** Use the development library: the library and its thumbnail cache
  (`Phocasa-Development/Thumbnails/v1`, or `PHOCASA_THUMBNAIL_CACHE_DIR=<temp dir>`) both survive the relaunch, so
  there's no need to reopen the folder. Cache files touched after the relaunch (`find <dir> -newermt @<ts>`) prove
  disk hits. (Before task B this took the in-memory launch plus `PHOCASA_THUMBNAIL_CACHE_DIR`, and reopening the
  folder after each relaunch.)
- **Useful fixtures:**
  - a RAW-only photo (delete one JPG from the copy);
  - rotated photos (`orient`);
  - a Lightroom-style sidecar (`PhocasaTests/MetadataSidecarFixtures.swift`, `lightroom`);
  - a garbage `.xmp` (it must stay byte-identical; compare `md5`).
- **After the check:** confirm `~/PhocasaBenchRAW` is unchanged with
  `find ~/PhocasaBenchRAW -type f -newermt "<session start>" | wc -l` (should be 0), and that
  `~/Library/Caches/com.phocasa.app` doesn't exist.
