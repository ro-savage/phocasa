# Coordinator tools

The tools the plan coordinator uses to judge merges (the "Merge gate" in
`docs/superpowers/plans/2026-09-25-performance/README.md`) and to check the real app. They aren't part of any build
target.

| File | What it is |
|---|---|
| `CoordinatorBenchmarks.swift` | A/B benchmark test class. It uses only public app APIs, so the same file runs on `main` and on a task branch. Copy it into `Phocasa/PhocasaTests/` of the checkout you're measuring, and delete it afterwards. |
| `runtests.sh` | `runtests.sh <checkout> <label> [xcodebuild args…]`: runs `xcodebuild test` with its own DerivedData (`$TMPDIR/phocasa-dd-coord-<label>`), then prints the result, the test count, errors and source warnings. The log goes to `$TMPDIR/phocasa-coord-<label>.test.log`. |
| `cmp.py` | `cmp.py before.txt after.txt [regex]`: compares `BENCH|`/`COORD|` lines and flags rises over 5%. |
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
export TEST_RUNNER_PHOCASA_BENCH=1 \
       TEST_RUNNER_COORD_BENCH_DATA="$IMAGEBENCH_DIR/data" \
       TEST_RUNNER_COORD_REAL_DIR="$HOME/PhocasaBenchRAW"
Tools/coordinator/runtests.sh "$B" A-main -only-testing:PhocasaTests/DataPathBenchmarks -only-testing:PhocasaTests/CoordinatorBenchmarks
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
- **The edit tests (`testEdit*`) use the view model's editing API:** `startEditing`, `editParameters`,
  `updateEditPreview`, `editedPreviewImage`, `fullResEditImage`, `stopEditing`. Task 22 moves that into
  `EditSession`. Once it merges, update these tests to `vm.editSession?.parameters` / `previewImage` / `fullImage`,
  and keep the pre-22 variant for the "before" side.
- `~/PhocasaBenchRAW` is the user's read-only folder of 190 real JPG+ARW pairs (16 MP; 12 rotated). The benchmarks
  only read it.

The wave-1 quiet baseline and results are in `docs/superpowers/plans/2026-09-25-performance/results/wave-1-coordinator.md`.

## Checking the real app without touching the user's library

A normal launch opens the user's real SwiftData store (`~/Library/Application Support/default.store`). **Never do
that.** When `XCTestConfigurationFilePath` is set, the app uses a throwaway in-memory store instead.

1. **Photos:** make a writable temp copy of some test photos. Include rotated ones (`orient`), and remove one JPG to
   get a RAW-only photo:
   `mkdir -p "$TMPDIR/phocasa-smoke/photos"; cp ~/PhocasaBenchRAW/DSC086{37..50}.* "$TMPDIR/phocasa-smoke/photos/"`.
2. **Build** with `xcodebuild … -derivedDataPath "$TMPDIR/phocasa-dd-coord-app" build`, and check for 0 source warnings.
3. **Launch the binary directly**, in the background:
   `XCTestConfigurationFilePath=/dev/null/in-memory "$TMPDIR/phocasa-dd-coord-app/Build/Products/Debug/Phocasa.app/Contents/MacOS/Phocasa"`.
   Confirm with `lsof -p <pid> | grep -c default.store` that it's `0`.
4. **Drive it.** The terminal needs Accessibility and Screen Recording permission; the user granted both on 2026-09-25.
   - Bring it to the front and size it: `tell application "System Events" to tell process "Phocasa" …`.
   - Open the folder: Cmd-O, then Cmd-Shift-G, type the path, Return, Return.
   - Use **`key code`** for keys (36 Return, 53 Escape, 123/124 arrows, 18–23 digits 1–6). AppleScript `keystroke "3"`
     does **not** reach SwiftUI's `onKeyPress`.
   - Use `app-driver/click` for clicks. System Events' `click at` performs an accessibility press, which SwiftUI tap
     gestures ignore.
   - Take screenshots with `screencapture -x -R<x>,<y>,<w>,<h> out.png` and look at them.
5. **Check write-backs on the copies:** `rating <jpg>` and `grep` in the `.xmp`. Delete the copies afterwards.
