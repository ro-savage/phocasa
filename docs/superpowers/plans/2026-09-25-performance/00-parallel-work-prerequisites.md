# Task 00: Parallel-Work Prerequisites

**Wave:** 0 (runs alone, before everything else) · **Depends on:** none · **Branch:** `perf/00-prerequisites` · **Size:** S

**Goal:** Make it possible for several agents to add files and measure performance in parallel without colliding. This task changes no app behaviour.

**Why:**
- Every new Swift file currently needs a hand-edited `project.pbxproj` entry with a hand-picked object ID (spec §H7). Five parallel agents would pick colliding IDs and conflict on the same sections.
- The benchmark harnesses used for the spec exist only as files in this plan's `assets/` folder.

## Files

- Modify: `Phocasa/Phocasa.xcodeproj/project.pbxproj` (convert to synchronized folders)
- Create: `Phocasa/PhocasaTests/PerformanceBenchmarks.swift` (copied from `assets/PerformanceBenchmarks.swift`)
- Create: `Tools/imagebench/imagebench.swift` (copied from `assets/imagebench.swift`), `Tools/imagebench/README.md`
- Create: `.gitignore` (repo root)
- Delete: `docs/superpowers/plans/2026-09-25-performance/assets/` (once the files are installed)

## Interfaces

- **Produces:**
  - Any `.swift` file placed under `Phocasa/Phocasa/**` builds into the app target, and any file under `Phocasa/PhocasaTests/**` builds into the test target, with **no `project.pbxproj` edits**.
  - `DataPathBenchmarks` test class, gated by `PHOCASA_BENCH=1`.
  - `Tools/imagebench/imagebench.swift`.

## Steps

- [ ] **Step 1: Baseline.** Build and run the full suite (commands in README). Expect `** TEST SUCCEEDED **` with 122 tests.

- [ ] **Step 2: Convert the project to synchronized folders.** Xcode 26.6 is installed, and synchronized groups need objectVersion 77. Edit `project.pbxproj` by hand as follows.

  1. Set `objectVersion = 77;`. In the `PBXProject` object (`F10000004`):
     - remove `compatibilityVersion = "Xcode 14.0";`
     - add `preferredProjectObjectVersion = 77;`
  2. Add a `PBXFileSystemSynchronizedBuildFileExceptionSet` so `Info.plist` isn't copied as a resource. It is still referenced by `INFOPLIST_FILE = Phocasa/Info.plist`, which stays.
     ```
     /* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
     		S10000002 /* Exceptions for "Phocasa" folder in "Phocasa" target */ = {
     			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
     			membershipExceptions = (
     				Info.plist,
     			);
     			target = F10000001 /* Phocasa */;
     		};
     /* End PBXFileSystemSynchronizedBuildFileExceptionSet section */
     ```
  3. Add the synchronized root groups:
     ```
     /* Begin PBXFileSystemSynchronizedRootGroup section */
     		S10000001 /* Phocasa */ = {
     			isa = PBXFileSystemSynchronizedRootGroup;
     			exceptions = (
     				S10000002 /* Exceptions for "Phocasa" folder in "Phocasa" target */,
     			);
     			path = Phocasa;
     			sourceTree = "<group>";
     		};
     		S20000001 /* PhocasaTests */ = {
     			isa = PBXFileSystemSynchronizedRootGroup;
     			path = PhocasaTests;
     			sourceTree = "<group>";
     		};
     /* End PBXFileSystemSynchronizedRootGroup section */
     ```
  4. In the main group `E10000001`, replace the children `E10000002 /* Phocasa */` and `E20000001 /* PhocasaTests */` with `S10000001 /* Phocasa */` and `S20000001 /* PhocasaTests */`. Keep `E10000008 /* Products */`.
  5. Delete the old groups `E10000002`, `E10000003`, `E10000004`, `E10000005`, `E10000006` and `E20000001`.
  6. Delete every `PBXFileReference` for source, plist and asset files, and every `PBXBuildFile`. **Keep** the product references `C10000001 /* Phocasa.app */` and `C20000001 /* PhocasaTests.xctest */`.
  7. In each build phase (`F10000002` Sources, `F10000003` Resources, `T10000004` Sources, `T10000006` Resources), set `files = ( );`. Leave the Frameworks phases alone.
  8. In `F10000001 /* Phocasa */`, add
     ```
     fileSystemSynchronizedGroups = (
     	S10000001 /* Phocasa */,
     );
     ```
     after `dependencies`. In `T10000003 /* PhocasaTests */`, add the same with `S20000001 /* PhocasaTests */`.
  9. Check with `plutil -lint Phocasa/Phocasa.xcodeproj/project.pbxproj` and `$XB -list -project Phocasa/Phocasa.xcodeproj`. Both must succeed.

- [ ] **Step 3: Prove the conversion works.**
  - Build, then check that the app still has its icon and its generated `Info.plist`:
    ```bash
    ls "$DD/Build/Products/Debug/Phocasa.app/Contents/Resources/"          # expect Assets.car and AppIcon.icns
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DD/Build/Products/Debug/Phocasa.app/Contents/Info.plist"
    grep -i "info.plist" "$DD.build.log" | grep -i warning                 # expect nothing
    ```
  - Prove that new files get picked up automatically:
    1. Create `Phocasa/Phocasa/ZZProbe.swift` containing `#error("probe")`. The build must now **fail** with `probe`.
    2. Delete the file. The build must succeed again.
    3. Do the same with `Phocasa/PhocasaTests/ZZProbe.swift`, using `test`.
  - Run the full suite. It must pass with 122 tests, as in step 1.

- [ ] **Step 4: Commit.** `git commit -am "build: convert project to Xcode synchronized folders"`.

- [ ] **Step 5: Install the data-path benchmarks.**
  1. `git mv docs/superpowers/plans/2026-09-25-performance/assets/PerformanceBenchmarks.swift Phocasa/PhocasaTests/PerformanceBenchmarks.swift`
  2. Run the full suite. The three `DataPathBenchmarks` tests must be **skipped** (`XCTSkipUnless`).
  3. Run with `TEST_RUNNER_PHOCASA_BENCH=1` (README command) and check that `BENCH|` lines are printed for `N=2000`, `N=10000` and `scan1k`. Expect roughly the spec's numbers: `3a applyFilter(.rated(3))` at 10k should be about 350–450 ms.
  4. The harness still has a 2 s `Task.sleep` "settle" delay at the top of each suite. It was only needed while the test host opened the real store, so remove it.
  5. Commit: `test: add opt-in data-path benchmarks (PHOCASA_BENCH=1)`.

- [ ] **Step 6: Install imagebench.**
  1. `mkdir -p Tools/imagebench && git mv docs/superpowers/plans/2026-09-25-performance/assets/imagebench.swift Tools/imagebench/imagebench.swift`
  2. Create `Tools/imagebench/README.md` covering:
     - what the tool measures: thumbnail decode options, detail decode, concurrency ordering, CoreImage preview chains, RAW;
     - how to build it: `swiftc -O -swift-version 5 imagebench.swift -o "$TMPDIR/imagebench"`;
     - the subcommands: `gen`, `copies`, `orient`, `thumb`, `detail`, `conc [px]`, `ci`, `raw`, `clean`;
     - that data goes to `$IMAGEBENCH_DIR`, or by default `$TMPDIR/phocasa-imagebench` (about 2.5 GB), and that `clean` removes it;
     - that `raw` uses `mdfind` to find a local camera RAW file and opens it **read-only**.
  3. Build it. Run `gen`, `copies` and `orient`: expect `CreateImageAtIndex` to report 6000×4000 and the transform thumbnail 4000×6000. Then run `clean`.
  4. Delete the now-empty `assets/` folder.
  5. Commit: `tools: add imagebench`.

- [ ] **Step 7: Add `.gitignore`** at the repo root:
  ```
  .DS_Store
  xcuserdata/
  *.xcuserstate
  DerivedData/
  .build/
  .claude/worktrees/
  ```
  Then `git rm --cached -r --ignore-unmatch .DS_Store Phocasa/.DS_Store` and commit: `chore: add .gitignore`.

## Acceptance criteria

- `project.pbxproj` has no `PBXFileReference` or `PBXBuildFile` entries for source files. Both targets use `fileSystemSynchronizedGroups`.
- Clean build succeeds with no new warnings. The app bundle contains `Assets.car` and the correct `Info.plist`.
- The full suite passes with 122 tests; the 3 benchmark tests are skipped.
- The probe files proved auto-inclusion for both targets, and they have been deleted.
- `PHOCASA_BENCH=1` runs print `BENCH|` lines. Save them in the results file as the **baseline**.
- `Tools/imagebench` builds and `orient` reproduces spec §D1.

## Out of scope

- Any Swift source change other than removing the settle delay from the benchmark file.
