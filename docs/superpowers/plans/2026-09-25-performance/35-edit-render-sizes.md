# Task 35: Edit Renders at Viewport Size

**Wave:** 3B (in parallel with 31, 32, 33) · **Depends on:** 30 merged · **Branch:** `perf/35-edit-render-sizes` · **Size:** M · **Performance task: merge only with a clear win**

**Goal:** stop rendering whole photos at native resolution when nobody is looking at them at that size.
- **The 300 ms full pass.** After every slider pause, the edit session renders the whole photo at native size on the
  `.full` lane: about 40 ms for a 24 MP JPEG, and about 190 ms for a 16 MP RAW.
  - At fit, that pass is only what makes a large Retina window sharp: the 1600×1100 preview is smaller than a 16"
    window's 3456 px.
  - Render a **viewport-sized** pass instead, and render native resolution only when the user zooms in beyond it.
- **Saved edits in the detail view.** They are rendered at full resolution on every navigation to an edited photo:
  about 190 ms for RAW, and up to 92 MB each.
  - Render at the viewport size first, then native resolution on zoom, using the same "needs more pixels" hook the
    loader's images use (`ZoomableImageView.onNeedsMorePixels`).

**Why:** `results/22.md` "Follow-ups", `results/12.md` (the zoom upgrade hook), `results/13.md` (lanes, `scaleFactor`).

## Files (re-check against merged `main`)

- **You own:**
  - `Editing/*` (`EditSession`, `SavedEdit`, `RAWEditStore`);
  - the saved-edit and edit-related parts of `Views/PhotoDetailView.swift` and `Views/Detail/*`;
  - `EditSessionTests`;
  - the edit and saved-edit tests in `DetailViewTests`.
- **Don't touch:**
  - `ImageEditingService` internals. It already takes `maxSize` and `lane`; use those. If you need a new parameter,
    put it under "Needs".
  - The library/store code (30–33) and `ImageLoader` (34).

## Constraints

- **Pixels.** Rendered output at a given size stays pixel-identical (≤ 1) to what `ImageEditingService` produces for
  that size today. Exports stay at native resolution and unchanged.
- **Slider responsiveness.** The debounced 1600×1100 preview on the `.preview` lane stays as it is, or gets faster. The
  coordinator's `CoordinatorEditBenchmarks-Session` tick lines (idle, during the pass, first draw) must not regress by
  more than 5%.
- **The after-save hand-off** (task 22) keeps working: the detail view shows the saved edit at once, never the unedited
  photo.
- **Zooming in on an edit** must end up sharp at native resolution: preview, then the viewport pass, then the native
  pass on demand.

## Steps

- [ ] **Step 1: Baseline.**
  - Run the full suite, `CoordinatorEditBenchmarks-Session` (copy it in temporarily; see `Tools/coordinator/README.md`)
    and `ImageEditingServiceBenchmarks`.
  - Add gated benchmarks for your metrics:
    - **the cost of each slider pause** (CPU and GPU time or wall time of the pass) at fit, in a 1728×1117 pt window at
      2×;
    - **navigation to a photo with a saved RAW edit**: time until the edit is shown, and the bytes held;
    - **memory** after a save.

  Use real files by copying from `~/PhocasaBenchRAW` into a temp dir (read-only source), plus generated 24 MP JPEGs.
- [ ] **Step 2: Measure a quick prototype.** If the viewport pass isn't meaningfully cheaper than the native pass (for
  example, it's within 20%), **stop and report**.
- [ ] **Step 3: Tests first:**
  - after a pause at fit, the session's image is viewport-sized, not native;
  - zooming in past it produces a native render;
  - a saved edit is shown at viewport size on navigation, and at native size after zoom;
  - the after-save hand-off still shows the edit;
  - pixels at each size match `ImageEditingService`'s output (≤ 1).
- [ ] **Step 4: Implement,** then measure again.
- [ ] **Step 5: Full suite, warnings, results file, commit.**

## Acceptance criteria

- The slider-pause cost at fit and the time to show a saved RAW edit on navigation drop clearly (report both). Memory
  per saved-edit render drops.
- No edit-tick or first-draw regression over 5%. Zooming in reaches native sharpness.
- Zero new warnings. The full suite passes.
