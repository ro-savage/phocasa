# Post-wave-3 prompt

Hand everything below the line to a new agent, started in `/Users/rowan/www/phocasa`.

---

You're picking up Phocasa after a four-wave performance and cleanup overhaul. Phocasa is a native macOS SwiftUI photo
app in this repo (`/Users/rowan/www/phocasa`). All waves are merged into `main`, and the wave-3 real-app check is done.

I've answered the decisions the wave-3 coordinator left me. Your job is to carry out those answers: three pieces of
work (A, B, C below), each merged into `main` with evidence, then checked in the real app. Keep going without waiting
for me, except for a decision only I can make.

## Read first, in order

1. `CLAUDE.md` (project rules, binding).
2. `docs/superpowers/plans/2026-09-25-performance/results/wave-3-coordinator.md`, especially:
   - "Real-app check" and "After the real-app check";
   - "Decisions for the user", with my answers below;
   - "Follow-ups".
3. `docs/superpowers/plans/2026-09-25-performance/README.md`: the merge gate, the merge protocol and the RAW-file
   rules.
4. `Tools/coordinator/README.md`: the test runner (`runtests.sh`), the A/B tools (`ab.sh`, `multi.py`), and how to
   drive the real app, including the lessons sections.
5. For task A: `results/14.md`, `results/23.md` and decisions 3, 4 and 7 in `results/wave-2-coordinator.md` (the
   metadata write path and its JPEG splice). For task C: `results/35.md`, "Look at fit" and deviation 5.

## My answers to the wave-3 decisions

1. **Checking relaunch behaviour in the real app:** the checks should use their own on-disk library, in a
   `Phocasa-Development` folder, so they never touch the real app's. → **Task B.**
2. **Back up the library:** done. The backup is in `~/Desktop/Phocasa-backup`. Never touch it.
   - I'll run the new build myself. Its first launch moves the store to `Application Support/Phocasa/` and migrates it.
   - You still never open, copy or modify my real library (see Safety).
3. **Task 35's saved-edit prefetch:** keep it; it improves performance. Nothing to do.
4. **Sharpening and clarity at fit:** I don't know which is better or faster. Find out and decide on evidence.
   → **Task C.**
5. **Launch main-actor total:** 300 ms is fine. Drop the ≤ 150 ms target and the grid-identity follow-up from the
   follow-ups list.
6. **Exports strip the camera's metadata:** we must never remove or delete a photo's original metadata. We only ever add
   to it or use sidecars. Deleting a photo's original metadata is a major bug. → **Task A, first priority.**

## Task A: never lose a photo's original metadata (major bug, do first)

**The rule** (already in CLAUDE.md's Metadata section, binding; remove its "known violation" note once this is fixed):
- Phocasa never removes, rewrites or drops the metadata a file came with: the camera's Exif (including MakerNote and
  GPS), IPTC and XMP.
- It only adds to it (new XMP/IPTC spliced in) or writes a sidecar.
- A write that can't keep the original metadata must not happen. Write the change to a sidecar instead.

**What's known to break it today** (confirm each with a failing test first):
- **All three exports write a JPEG with no metadata at all**, because `ImageEditingService.writeJPEG` adds none. The
  exports are "Apply edits permanently to JPG", "Replace existing JPG" and "Create new file (-raw-edit)".
  - "Apply edits permanently" and "Replace existing JPG" overwrite the camera JPG, so its Exif is destroyed for good.
  - The new file also loses its capture date. With capture-date sort, a `-raw-edit` export then sorts as the newest
    photo.
- **The JPEG metadata write's fallback.** For JPEGs the splice can't handle safely, `MetadataService` falls back to
  ImageIO's full rewrite (wave-2 decision 4). Make sure that fallback can't drop anything. If it can, those files get
  their rating and keywords in a sidecar instead, and are read back from it.
- **Audit every other path that writes a photo or sidecar file.** List them in your results, with what each keeps.

**What "kept" means:**
- An export or baked edit has new pixels. Only the tags that describe the pixels may change, and they must match the
  new pixels: orientation (now 1, since the pixels are upright), pixel dimensions, and anything describing the old
  pixels, such as the embedded Exif thumbnail, MPF preview images or the colour profile.
- Everything else survives with the same values, and MakerNote byte for byte.
- List the exceptions in CLAUDE.md.
- Prefer splicing the original's metadata segments into the new file, patching the pixel tags in place, as the
  existing JPEG splice does. Rebuilding the metadata through ImageIO can move or drop MakerNote data.
- **Where the metadata comes from:**
  - baked JPG edits and "Replace existing JPG": the JPG being overwritten, read before it's replaced;
  - a pair's `-raw-edit` export: the paired camera JPG;
  - a RAW-only export: the RAW's own metadata. Record what can and can't carry over from a RAW.
- Phocasa's own rating and keywords are written into the result too.

**Tests:**
- For each path, a test that fails today. It checks that every original property is in the output with the same
  value, apart from the listed exceptions: MakerNote bytes identical, `DateTimeOriginal` present, rating and keywords
  present.
- Use a synthetic JPEG with rich metadata (MakerNote, GPS, IPTC, XMP from another app).
- Add gated tests on real camera files: *copies* named by `PHOCASA_TEST_RAW` (add a JPG equivalent if you need one).
- Keep `MetadataJPEGPreservationTests` and the other metadata tests passing.
- Exports change pixels. They must still call `ImageLoader.shared.invalidate(path:)` and must never go through the
  thumbnail re-key hook (CLAUDE.md, "Thumbnail cache").
- If export code changes, keep `Tools/imagebench` in step where it mirrors that code.

**Tell me in your results:** photos I already exported or baked in earlier builds lost their metadata. A pair's RAW
still has it. Don't look for such photos on disk; suggest what a recovery would take, and I'll decide.

## Task B: a development library for real-app checks

**Today:** the coordinator checks the real app by launching it with `XCTestConfigurationFilePath` set, which gives an
in-memory store. That store forgets everything on quit, so relaunch behaviour can't be checked.

**What I want:** in that test configuration, the app keeps its library on disk under
`~/Library/Application Support/Phocasa-Development/`, so it never overwrites the real app's.
- Its store is `Phocasa-Development/Phocasa.store`. It never reads, moves or opens `Application Support/Phocasa/` or a
  `default.store`, so no `StoreLocation` legacy move runs in this mode.
- Its thumbnail disk cache is separate too, never `~/Library/Caches/com.phocasa.app`. A default under the development
  folder is fine; `PHOCASA_THUMBNAIL_CACHE_DIR` still overrides it.
- Turned on explicitly for a launch, by an environment variable or launch argument; your choice, documented. Honoured
  only in Debug builds.
- A normal Debug launch, which is how I run the app, keeps using my real library. Don't change that.
- The unit-test host stays in-memory: tests must not share state across runs or worktrees.
- Tests with a temp folder in place of Application Support, like `StoreLocationTests`: the development mode resolves to
  its own folder and leaves a real store and a legacy store untouched.
- Update `Tools/coordinator/README.md`'s real-app procedure to use it.
  - Reset the development folder at the start of each check (quote the path, which has a space).
  - Confirm with `lsof` that only the development store is open.
- A permission classifier blocked an arbitrary store-URL override before. This design is a fixed folder, Debug only,
  and I asked for it; say so if you're asked. If it's blocked anyway, stop and tell me.

**Then run the three checks that couldn't be done before:**
- Move to Bin survives a relaunch.
- A library of 500+ photos loads in the background at launch. APFS clones (`cp -c`) of bench copies make one cheaply.
- The capture-date backfill of an existing library. With the app quit, clear `captureDate` in the development store,
  for example with `sqlite3`.

## Task C: sharpening, clarity and noise reduction at fit

**Today:** edits at fit render at screen size (task 35). Sharpness (1.5 px), clarity (20 px) and noise reduction act
in the render's pixels, so a fitted pass shows them at display scale. The same edit zoomed in or exported looks
slightly different, and the slider preview differs about twice as much.

**The alternative:** scale the pixel-radius filters (sharpness, clarity, blur, noise reduction) by the render's scale
in `ImageEditingService`.

**Decide on evidence:**
- **Better:** the fitted pass and the preview match the native render drawn at the same size. Use task 35's metric,
  the mean absolute channel difference.
- **Faster:** the pass time (`EditRenderSizeBenchmarks`, the coordinator's edit harness).
- Measure both versions on real RAW and JPG copies, at several strengths of each filter. Noise reduction may not scale
  linearly; check it separately.
- Adopt the scaling if it clearly reduces the difference and the pass isn't more than 5% slower. Native renders and
  exports must stay byte-identical (`testStandardExportMatchesReference`).
- Record the numbers and the choice either way, and add the rule to CLAUDE.md if adopted.
- Afterwards, check by eye in the real app that an edit with clarity looks the same at fit and zoomed in.

## How to work

- **Order:**
  - A first.
  - B touches none of A's files, so it may run alongside A in a worktree subagent.
  - C only after A is merged: both change `ImageEditingService`.
- **For each piece:**
  - read the code its claims depend on before you change anything;
  - test first (red, then green);
  - work on its own branch (`fix/…`, `feat/…`);
  - run the full suite with `Tools/coordinator/runtests.sh`. The baseline is 627 executed, 41 skipped, 0 failures,
    0 source warnings;
  - then merge into `main` with `git merge --no-ff`, one branch at a time, running the full suite after each merge.
- **Performance:**
  - Any change that can affect speed gets the quiet-machine A/B from the README: nothing else running, load about
    2–5, `ab.sh` runs for `main` and the branch, compared with `multi.py`. That includes A's write paths, measured with
    `MetadataSidecarBenchmarks` and `DataPathBenchmarks`' rating lines.
  - The merge gate: bug fixes land regardless, as long as nothing regresses more than 5%. Re-check any line over 5%
    in untouched code alternately before judging.
- **Real-app check at the end,** in task B's development mode, on temp copies from `~/PhocasaBenchRAW`.
  - Tasks A, B and C: A on every export path (`segs.py` for segments, plus a check of the capture date and the
    rating), B's three relaunch checks, C by eye.
  - Then re-check what wave 3 checked (the list in the wave-3 record).
- **Docs:** CLAUDE.md (the metadata rule's exceptions, development mode, the fit-look choice) and the coordinator
  README.
- **Record everything in `docs/superpowers/plans/2026-09-25-performance/results/post-wave-3.md`,** and commit it:
  - what merged, and why;
  - the suite after each merge;
  - benchmark tables;
  - the metadata audit;
  - the real-app check;
  - follow-ups, and decisions for me.

  In the wave-3 record, mark decisions 3 and 5 as answered and drop the grid-identity follow-up.
- Never push. Never amend, reset or rewrite `main`'s history.

## Safety

- **My real library:** never open, copy, move or modify it. That's `~/Library/Application Support/Phocasa/` (the store,
  its `-wal`, `-shm` and `.Phocasa_SUPPORT`), any leftover `default.store*` or `.default_SUPPORT` in
  `~/Library/Application Support`, and the backup in `~/Desktop/Phocasa-backup`.
  - The only place under Application Support you may write is `Phocasa-Development/`: through the app in development
    mode, or to reset it.
  - Tests use temp folders and in-memory or temp-file stores.
- **Caches:** tests, and the app in development mode, never write `~/Library/Caches/com.phocasa.app`.
- **Real photos:** `~/PhocasaBenchRAW` holds 190 JPG+ARW pairs, 16 MP, 12 of them rotated. It's read-only.
  - Read it and measure against it freely; scanning it is fine.
  - Anything that writes (ratings, sidecars, edits, exports, backfill tests) works on temp copies.
  - Don't search the disk for other photos (no `mdfind` or Spotlight).
- **The Trash:** a permanent delete in the real app moves files to my Trash, which the terminal can't list or clean.
  Delete only an extra copy added for that, and tell me.
- **Driving the app:**
  - Several agents share one screen, so only you drive the real app, never a subagent. Hosted-window unit tests are
    fine.
  - Send keys inside the same `osascript` that sets the app frontmost.
  - It needs an unlocked screen. If the screen is locked, carry on with other work and do the check when it's
    unlocked.
- **Xcode:** stay on Xcode 26.6. `runtests.sh` keeps the display awake, which the hosted-window tests need.

## When to stop

Stop when A, B and C are merged (or C recorded as not adopted, with numbers), checked in the real app and recorded.
Then give me a short status:
- what merged, and why;
- the metadata audit, and what now keeps what;
- the fit-look numbers and the choice;
- what the development-mode relaunch checks showed;
- open follow-ups, and any decisions for me.
