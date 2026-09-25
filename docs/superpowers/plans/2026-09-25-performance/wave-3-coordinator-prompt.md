# Wave 3 coordinator prompt

Hand everything below the line to a new coordinator agent, started in `/Users/rowan/www/phocasa`.

---

You're coordinating wave 3, the last wave, of a performance and cleanup overhaul of Phocasa. Phocasa is a native macOS
SwiftUI photo app in this repo (`/Users/rowan/www/phocasa`); waves 0–2 are already merged into `main`.

Your job:
- run wave 3 with subagents working in git worktrees;
- merge their work into `main` one branch at a time, fixing whatever breaks and measuring performance after every
  merge;
- finish with a full final check of the whole app.

Keep going without waiting for me, except for a decision only I can make.

## Read first, in order

1. `CLAUDE.md` (project rules, binding).
2. `docs/superpowers/plans/2026-09-25-performance/README.md`: waves, file ownership (the wave 3A and 3B tables),
   commands, RAW-file rules, merge gate and merge protocol.
3. `docs/superpowers/specs/2026-09-25-performance-review.md`: the measured findings behind every task.
4. `docs/superpowers/plans/2026-09-25-performance/results/wave-2-coordinator.md` and `results/wave-1-coordinator.md`:
   what landed, the quiet-machine numbers, my answered decisions, and the follow-ups. Then `results/10.md`–`23.md`,
   especially "Needs from other tasks" and "Follow-ups".
5. The wave-3 task files: `30-structure-and-polish.md`, `34-thumbnail-cache-followups.md`, `31-schema-cleanup.md`,
   `32-launch-and-bin.md`, `33-capture-date-sort.md`, `35-edit-render-sizes.md`.
6. `Tools/coordinator/README.md`: your A/B benchmark tools (`ab.sh`, `multi.py`), the test runner (`runtests.sh`),
   and how to drive the real app. Read its "Protocol that worked in wave 2" and "Driving the app: lessons from wave 2".

## The plan: two sub-waves

- **Wave 3A: tasks 30 and 34 in parallel.**
  - 30 splits the view model into the `LibraryStore` files, `SelectionModel` and `LibrarySort`. It also keeps the grid
    alive under the detail view, moves trashing off the main thread, flushes metadata writes on quit, and rewrites
    CLAUDE.md.
  - 34 is thumbnail disk-cache follow-ups. It owns only services task 30 doesn't touch.
  - Nothing else can run beside 30, because it moves every region of the view model.
- **Wave 3B, after 3A is merged: tasks 31, 32, 33 and 35 in parallel**, each in the files task 30 laid out:
  - 31: schema cleanup, `isDeleted` → `isInBin`;
  - 32: launch off the main actor, incremental imports, and the bin surviving a relaunch (my decision);
  - 33: sort by capture date (my decision);
  - 35: edit renders at viewport size.
- **Merge 3B in the order 31, 32, 33, 35.** 31's rename is mechanical, so the later conflicts are easy.

## How to run each sub-wave

- **Before dispatching, read each task file critically against the merged code.**
  - Check ownership clashes and file names. Before 3B, the file names must match what task 30 actually created:
    `LibraryStore+Loading.swift`, `LibraryStore+Scan.swift`, `LibrarySort.swift`, the insert sites.
  - Also check what task 30's and 34's results files say they left for 3B.
  - Fix the task files and the README ownership table, and **commit that to `main` before dispatching**, so the
    worktrees see it.
- **Launch one subagent per task, in parallel, each with worktree isolation**, so it branches from the current `main`.
- **Give each subagent a self-contained prompt.** It should:
  - name its task file, and tell it to read the README, CLAUDE.md, the spec, `results/wave-2-coordinator.md`, the
    results files its task depends on, and its task file, and to follow the README's "Workflow for each task agent";
  - tell it to commit on its own branch only (`perf/<id>-<slug>`). It must never merge, rebase onto other branches,
    push, or touch `main`, other branches or other worktrees. It writes `results/<task-id>.md`, commits it, and ends
    with its branch name, `git log --oneline main..HEAD` and the full results file;
  - tell it to check its task file's claims against the code and make the changes it judges important within its file
    ownership, recording deviations in its results file. Anything outside its ownership goes under "Needs from other
    tasks", for you to decide;
  - for the performance tasks (32, 34, 35, and 33, which must not regress): measure a baseline before changing
    anything. If measuring or a quick prototype shows the approach won't meaningfully improve things, it should stop
    and report rather than finish;
  - give it its own DerivedData (`$TMPDIR/phocasa-dd-<id>`), its own imagebench data dir and binary if it uses them,
    its own temp data (`$TMPDIR/phocasa-<id>-*`) and its own scratch subfolder;
  - tell it that it must not launch or drive the real app. Several agents share one screen and mouse; you do the
    real-app checks after merging, and hosted-window unit tests are fine;
  - repeat the safety rules below.
- **Scratchpad.** Subagents share your session scratchpad (in wave 1 one deleted the coordinator's files). Keep yours
  in `scratchpad/coord/`, and tell each agent to use `scratchpad/<task-id>/` and touch nothing else.
- **Usage limits.** If agents stop on a usage limit, resume each with SendMessage once it resets. Tell it where it
  stopped (commits, uncommitted work, whether its last run finished). If you hit the limit yourself, wait for it to
  reset and carry on.
- **Review each branch's diff before merging.** Check ownership, quality, and that tests use only temp dirs and temp or
  in-memory stores. If something is wrong or sloppy, send it back (SendMessage) or fix it yourself on `main` after the
  merge, and say which.

## Deciding what to merge (README "Merge gate")

- **Performance tasks (32, 34, 35):** merge only with a clear, repeatable improvement on the task's primary metrics,
  and no regression over 5% elsewhere.
- **Structure and correctness tasks (30, 31, 33):** merge when their bug tests fail before and pass after, or their
  acceptance criteria are met, and no benchmark regresses more than 5%.
- **My priority is that the enhancements land.** Bug fixes and my two decisions (32's bin fix, 33's capture-date sort)
  land regardless of speed, as long as nothing regresses beyond the gate. If a task is skipped, record why in
  `results/<task-id>.md` on `main`, and adapt the tasks that depend on it.
- **Don't trust numbers a subagent took while other agents were compiling.** Re-run the benchmarks yourself on a quiet
  machine: nothing else running, `uptime` load of about 2–5. Use `Tools/coordinator/ab.sh`, one run per checkout of
  about 3 minutes:
  - `main`, each branch, `main` again;
  - then a second round in reverse order;
  - compare with `multi.py`.

  Each task's own gated benchmark classes run through `ab.sh`'s extra `-only-testing:` arguments.
- **If a line rises over 5% in code the branch doesn't touch,** re-run just that test alternately on both sides before
  judging (README "Protocol that worked in wave 2"). In wave 2 two such lines were suite-order effects.
- **Harness notes.**
  - `DataPathBenchmarks` lines `3a`–`3c` and `4` are cached no-ops; judge filter and search on `3e`–`3h` and `4b`.
  - `7w` is the true unchanged-10k rescan. `7x` rescans 20k rows until task 32 fixes its seed paths, and is
    re-baselined then.
  - Task 30 changes view-model APIs, so it updates `PerformanceBenchmarks.swift` and keeps every line label. If it
    changes the entry points `CoordinatorEditBenchmarks-Session.swift` calls, update that file on `main` in a separate
    commit.
  - The coordinator's thumbnail runs set `TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR` to a temp dir; `ab.sh` does this.

## Merging, and testing after each merge

1. Merge passing branches into `main` one at a time with `git merge --no-ff`.
2. After **each** merge, run:
   - **the full suite** (`Tools/coordinator/runtests.sh /Users/rowan/www/phocasa m<task>`);
   - **the benchmarks on `main`** (`ab.sh main m<task>`), compared with the previous `main` run using `multi.py`.

   Record both in your notes.
3. **Starting point:** `main` after wave 2 reports "Executed 441 tests, with 20 tests skipped and 0 failures", with 0
   compiler warnings on a clean build. The skips are gated benchmarks and gated real-file tests.
4. **A test that passed on its branch can fail after merging.** Find the root cause, fix it at the source and commit
   the fix on `main`. Never amend or reset a merge.
5. **Resolve conflicts using the ownership tables**, then re-run the suite. Task 31's rename will conflict with 32 and
   33; re-apply the rename to their hunks (`grep -rn isDeleted`).
6. **Task 31 changes the schema.** I decided you should **not pause** before merging it. Put a clear reminder in your
   final report that I must back up `~/Library/Application Support/default.store*` before running the new build
   normally. After 33 merges too, re-run `MigrationTests` on merged `main`: 31's V1 → current test must also cover
   33's new attributes.

## After both sub-waves are merged

1. **Apply the CLAUDE.md updates** the 3B tasks listed under "Needs", so CLAUDE.md matches the final code: schema,
   capture-date sort, launch, bin, edit render sizes. Commit.
2. **Do a clean build** (0 warnings) and run the full suite.
3. **Re-run all the benchmarks interleaved:**
   - the pre-wave-3 `main` commit and the final `main`, pre, post, pre, post;
   - plus the gated classes (`ThumbnailSchedulerBenchmarks`, `DetailNavigationBenchmarks`,
     `ImageEditingServiceBenchmarks`, `ThumbnailDiskCacheBenchmarks`, `MetadataSidecarBenchmarks` and whatever wave 3
     adds).

   Compare with `results/wave-2-coordinator.md` and `results/bench/wave-2-main-*.txt`, and with the spec's baseline.
4. **Check the real app by driving it** (`Tools/coordinator/README.md`).
   - **Setup:**
     - launch with the in-memory-store flag and a temp `PHOCASA_THUMBNAIL_CACHE_DIR`;
     - confirm with `lsof` that `default.store` isn't open;
     - use temp copies from `~/PhocasaBenchRAW`: about 17 pairs, one made RAW-only, some rotated, plus a
       Lightroom-style sidecar and a garbage `.xmp`.
   - **Check wave 3:**
     - photos are ordered by capture date, including after a toggle;
     - Move to Bin survives a rescan and a relaunch;
     - the grid keeps its scroll position when you open and close a photo;
     - a permanent delete or empty bin doesn't freeze the UI;
     - quitting right after rating a photo still writes the file;
     - thumbnails after a relaunch come from the disk cache, including photos rated before quitting;
     - an edit at fit is sharp, and zooming into an edited photo gets sharper;
     - a saved edit shows at once on navigation.
   - **Re-check what waves 1–2 fixed:**
     - scan and rescan counts and progress;
     - instant star clicks, and a double-click under the Unrated filter doesn't rate the neighbour;
     - pairs write both files, and RAW-only photos write only the sidecar;
     - Lightroom content survives, and the garbage sidecar is untouched;
     - camera JPG Exif keeps its size (`app-driver/segs.py`);
     - RAW edit of a rotated portrait: JPG comparison upright, crop, the saved edit shown after Escape, export, revert;
     - JPG edit: side-by-side, and "Apply edits permanently";
     - no `.phocasa-tmp` files are left behind;
     - `~/Library/Caches/com.phocasa.app` never appears;
     - `~/PhocasaBenchRAW` is unchanged.
5. **Record everything in `results/wave-3-coordinator.md`** and commit it:
   - what merged or was skipped, and why;
   - the suite after each merge;
   - the per-merge and final benchmark tables;
   - the app check;
   - follow-ups;
   - decisions for me.
6. **Clean up.**
   - Remove the merged agents' worktrees, your bench worktrees and temp photo copies.
   - Ignore, and don't delete, the stale worktree at `.claude/worktrees/agent-a3ba48e2543f6b1d0`: it's old benchmark
     scratch.
   - Never push. Never rewrite `main`'s history.

## Safety

- **My real library.** Never open, copy or modify it (`~/Library/Application Support/default.store*`, or anything else
  under `~/Library/Application Support`).
  - Tests use temp dirs and in-memory or temp-file stores. The test host is already isolated.
  - To run the real app, launch the built binary with `XCTestConfigurationFilePath` set, so it uses an in-memory
    store, and confirm with `lsof` that `default.store` isn't open. The terminal has Accessibility and Screen
    Recording permission.
- **Caches.** Tests, and the app run with the in-memory flag, must never write to `~/Library/Caches/com.phocasa.app`.
  Use `PHOCASA_THUMBNAIL_CACHE_DIR` for a temp cache.
- **Real photos.** `~/PhocasaBenchRAW` holds 190 JPG+ARW pairs, 16 MP, 12 of them rotated, and is read-only.
  - Read it and measure against it freely. Scanning it into a temp store is fine; scans only read.
  - Never write to it. For anything that writes (ratings, sidecars, edits, exports, capture-date backfill tests), copy
    the files you need into a temp dir and write to the copies.
  - Don't search the disk for other photos (no `mdfind` or Spotlight).
- **Xcode.** Stay on Xcode 26.6; don't update Xcode during the overhaul. The imagebench data used by the harness is in
  `$TMPDIR/phocasa-imagebench-coord/data`. If `$TMPDIR` was cleaned, regenerate it as `Tools/coordinator/README.md`
  shows.

## When to stop

Stop when wave 3 is merged, benchmarked and checked in the real app. Then give me a short status:
- each task merged or skipped, and why;
- before and after numbers against wave 2 and the spec's baseline;
- what you checked in the app;
- the reminder to back up my library before running the new build;
- open follow-ups, and any decisions for me.
