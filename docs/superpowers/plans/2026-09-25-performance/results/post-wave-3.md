# Post-wave-3: coordinator record

This carries out the user's answers to the wave-3 decisions (`../post-wave-3-prompt.md`). There were three pieces of
work, each merged into `main` with `--no-ff` and then checked in the real app.

| Merge | Branch | What |
|---|---|---|
| `b83deab` | `feat/development-library` | **B.** A development library for real-app checks (`PHOCASA_DEVELOPMENT_LIBRARY=1`, Debug only) |
| `2f2fe1b` | `fix/keep-original-metadata` | **A.** Exports, baked edits and rating writes never lose a photo's original metadata |
| `0a4a526` | `perf/fit-look-scaling` | **C.** Sharpening and clarity radii scale with the render, so an edit at fit looks as it does zoomed in |
| `6878e42` | `fix/release-build` | The Release build compiles again (found by B; outside A–C, a build fix) |
| `8b30d03` | `fix/export-arot` | Exports drop the source's Apple restart-offset table (found in the real-app check) |

- B ran in a worktree subagent beside A (it touches none of A's files) and merged first.
- A was done by the coordinator.
- C started after A merged, because both change `ImageEditingService`.

## Suite after each merge

| After | Result |
|---|---|
| baseline (`b389de4`, from the hand-off) | 627 executed, 41 skipped, 0 failures, 0 source warnings |
| B (`b83deab`) | **640 / 41 / 0**, 0 source warnings |
| A (`2f2fe1b`, clean DerivedData) | **666 / 44 / 0**, 0 source warnings |
| C (`0a4a526`, clean DerivedData) | **667 / 45 / 0**, 0 source warnings |
| Release fix (`6878e42`) | **667 / 45 / 0**; the Release build succeeds, with no warnings |
| AROT fix (`8b30d03`, final `main`) | **668 / 45 / 0**, 0 source warnings |

The skips are the gated benchmarks and the gated real-file tests. The only `warning:` lines are the two AppIntents
tooling notices. `~/Library/Caches/com.phocasa.app` never existed.

## B: development library (merged first)

The report is in `B.md`, written by the subagent and reviewed here before the merge.
- **The flag.** A Debug launch with `PHOCASA_DEVELOPMENT_LIBRARY=1` (exactly `1`) keeps its library in
  `~/Library/Application Support/Phocasa-Development/Phocasa.store`.
  - Its thumbnails go in `Phocasa-Development/Thumbnails/v1`; `PHOCASA_THUMBNAIL_CACHE_DIR` overrides that.
  - It never reads, moves or opens `Application Support/Phocasa/` or a `default.store`: `StoreLocation.prepare`
    isn't called, so no legacy move runs.
  - Release ignores the flag, and a normal Debug launch opens the user's library as before.
- **One decision.** `LibraryLocation.resolve(environment:isDebugBuild:applicationSupport:caches:)` decides both the
  store and the cache, for `PhocasaApp` and `ImageLoader.shared` together.
- **Deviation, accepted.** The test host's in-memory store wins over the flag. The scheme's Test action shares the Run
  action's environment, so a flag set for Run would otherwise put every unit-test run on the shared development
  store. A development launch sets only the flag.
- **13 tests.** 8 failed against a stub first. The other 5 pin today's behaviour; 4 of them were shown to catch
  mutations. The store tests use temp folders standing in for Application Support: a real store and a legacy store
  are left alone, no legacy move runs, and the library survives a relaunch.
- **Docs.** CLAUDE.md, and the coordinator README's real-app procedure: reset the folder, launch with the flag,
  check with `lsof`, relaunch with Cmd-Q.
- **No permission prompt was blocked.**
- **Found by the subagent (older than this work): `main` doesn't build in Release.**
  `LibraryStore+Loading.swift:108` raises "sending 'context' risks causing data races", in whole-module mode only.
  See follow-ups.

## A: never lose a photo's original metadata

### What was wrong, confirmed with failing tests first

- **All three exports wrote a JPEG with no metadata at all.** `ExportMetadataTests` has five tests that go through
  the view model:
  - applying edits permanently;
  - replacing the pair's JPG;
  - a new `-raw-edit` file, exported twice;
  - a RAW-only export;
  - a refusal case.

  All five fail on `main` (258 assertion failures). Every Exif, GPS, IPTC and XMP property of the source is missing
  from the output, including the MakerNote, `DateTimeOriginal`, the rating and the keywords. The refusal test sees
  the file rewritten anyway.
- **Rating writes changed original metadata too** (`MetadataKeepOriginalTests`; 5 of its 7 tests fail on `main`):
  - **IPTC:** ImageIO rebuilt the APP13's IPTC data.
    - It changed the record version (4 → 2).
    - It added `2:55`/`2:60`, derived from the Exif.
    - It dropped a custom dataset (`2:200`) and reordered the rest.
    - A CLI probe of an APP13 without a digest resource also lost a custom Photoshop resource and the thumbnail
      resource.
  - **XMP:** ImageIO's merged rewrite mirrors the Exif into the XMP, overwriting values that disagree. Another app's
    `xmp:CreatorTool` became the camera's firmware version; the new XMP guard caught this.
  - **The fallback:** JPEGs the splice refused (extended XMP, odd layouts) got ImageIO's full rewrite, which drops
    the MakerNote. So did every PNG, TIFF and HEIC. A probe showed a PNG's `eXIf` chunk shrinking from 110 to 88 B.
- Two of `MetadataKeepOriginalTests` pass on `main` too, as guards: another app's XMP kept, and a UTF-8 declaration
  for non-ASCII IPTC keywords.

### What changed

| File | Change |
|---|---|
| `Services/ExportMetadata.swift` (new) | Carries the source's metadata into the export's JPEG. **From a JPEG:** every APPn and COM segment byte for byte, in order, around the new image data; only what describes the old pixels changes (below). **From a RAW:** ImageIO's metadata tree, merged onto the encoded JPEG without re-encoding it. Nil when that can't be done whole. |
| `Services/ExifPatch.swift` (new) | Patches the Exif TIFF in place: orientation 1, the new pixel size (IFD0 and Exif IFD, SHORT or LONG), `ColorSpace`, an Adobe RGB `InteropIndex`. It unlinks IFD1 and zeroes its thumbnail bytes unless they overlap the MakerNote. The MakerNote is never touched, and a structure it can't walk safely is refused. |
| `Services/PhotoshopIRB.swift` (new) | Patches the APP13 resources and IPTC-IIM datasets by hand. Only the `2:25` keywords change; the digest (`0x0425`) is updated; every other resource and dataset stays byte for byte, zero padding included. `1:90` UTF-8 is added only when all existing text is ASCII. Exports also drop the thumbnail resources. |
| `Services/XMPProperties.swift` (new) | XMP values keyed by namespace, to prove a rewrite kept every other value, and the export's pixel-property patch. The patch also removes XMP about data appended after the old image (a motion photo's video, an Ultra HDR gain map). |
| `Services/JPEGStructure.swift` (new) | JPEG segment parsing, moved out of `MetadataService` and shared. |
| `Services/MetadataService.swift` | **Rating writes:** a JPEG gets its own XMP packet with just `xmp:Rating`/`dc:subject` changed (no ImageIO merge), plus the hand-patched APP13, spliced in. Anything that can't be written that way keeps its bytes, and its values go to its sidecar with `phocasa:OverridesEmbedded`, which `readMetadata` then honours. Non-images are left alone, as before. **Sidecar updates:** refused if the re-serialised packet would lose or change another app's value. |
| `Services/ImageEditingService.swift` | Exports encode to memory, compose via `ExportMetadata` (trying `metadataSources` in order), and return an `ExportResult` (`written`, `failed`, `metadataNotKept`). The file is replaced through a temp file on `MetadataWriter`'s queue. |
| `Services/MetadataWriter.swift` | `runExclusively`: exports replace a photo's file between two writes, so a rating write in flight can't swap the old pixels back. |
| `Editing/EditSession.swift` | Picks the metadata source, and enqueues Phocasa's rating and keywords for the written file afterwards, as a normal rating write. |
| `ViewModels/PhotoLibraryViewModel.swift`, `Views/PhotoDetailView.swift` | `exportFailure` and an "Export" alert saying why nothing was written. |
| `CLAUDE.md` | The rule's exceptions, the JPEG-or-sidecar rule for rating writes, and how exports carry metadata. The "known violation" note is removed. |

**Where the metadata comes from:**
- baked JPG edits: the JPG itself;
- "Replace existing JPG": the JPG being replaced, read before it's replaced, and nothing else;
- a new `-raw-edit` file: the pair's camera JPG (the photo's JPG unless it's the export itself, else the JPG with
  the RAW's stem), then the RAW if the camera JPG's metadata can't be carried;
- a RAW-only export: the RAW.

Phocasa's rating and keywords are then written into the result like any rating write.

**If the metadata can't be carried whole:** nothing is written, and an alert explains. For "Apply edits permanently"
the edit stays a saved edit. For "Replace existing JPG" the alert suggests "Create new file".

### The exceptions: what may change in an export

These describe the old pixels. They change to match the new ones, and are listed in CLAUDE.md:
- **Orientation:** 1 (the pixels are upright).
- **Pixel dimensions:** Exif `PixelXDimension`/`PixelYDimension`, IFD0 `ImageWidth`/`ImageLength`.
- **Colour space and codec aids:** `ColorSpace` and an Adobe RGB `InteropIndex`. The old ICC profile, Adobe APP14
  segment and Apple restart-offset table (APP10 `AROT`, since `8b30d03`) are replaced by the encoder's.
- **The same properties in the XMP.** `photoshop:ICCProfile`, `xmp:Thumbnails`, and the Google `Container`, motion
  photo (`GCamera:MotionPhoto*`, `MicroVideo*`) and Ultra HDR (`hdrgm`) properties are removed.
- **Previews of the old pixels:** the Exif IFD1 thumbnail (unlinked, its bytes zeroed), MPF preview images (the
  segment and the images after the old EOI), JFIF and JFXX thumbnails, and Photoshop thumbnail resources.
- **From a RAW only:** what describes the RAW's own encoding (`Compression`, `PhotometricInterpretation`,
  `CFAPattern`, `CompressedBitsPerPixel`, …).

Everything else survives with the same value, and the MakerNote survives byte for byte.

**From a RAW (`testRealRAWOnlyExportCarriesTheRAWsMetadata`, two real ARWs):**

| ImageIO dictionary | Carried over |
|---|---|
| `{Exif}` | 33 of 35 keys (31 plus the two new dimensions for the rotated one). Lost: `CFAPattern`, `CompressedBitsPerPixel` (the RAW's encoding) |
| `{TIFF}` | 5 of 7 (4 plus orientation 1 for the rotated one). Lost: `Compression`, `PhotometricInterpretation` |
| `{ExifAux}` | 4 of 5. Lost: `ImageStabilization`, which ImageIO derives from the MakerNote |
| `{PictureStyle}` | 0 of 4. Derived from Sony's MakerNote |
| MakerNote | **Can't carry over.** ImageIO has no MakerNote to write. Its internal offsets count from the ARW's own TIFF header, so it can't be moved byte for byte either. It stays in the RAW. |

The capture date, rating and keywords carry over on both files.

### Tests

- **`ExportMetadataTests`:**
  - the five above;
  - a new `-raw-edit` file falls back to the RAW's metadata when the camera JPG's can't be carried (written after
    its code; a mutation that drops the fallback makes it fail);
  - two gated real-file tests.
- **`ExportMetadataCompositionTests`** (10), on hand-built inputs:
  - a big-endian Exif with SHORT dimensions;
  - the codec segments and image data are the encoder's;
  - an Exif structure that can't be walked is refused;
  - a JPEG without metadata;
  - a JFIF thumbnail is dropped;
  - a thumbnail inside the MakerNote is unlinked, not zeroed;
  - IPTC text of unknown encoding isn't rewritten;
  - a malformed resource block isn't rewritten;
  - a padded APP13 is patched;
  - phone XMP about appended data is dropped.

  The last two failed first when their fixes were stashed. The rest use new APIs, so they couldn't compile on `main`.
- **`MetadataKeepOriginalTests`** (7):
  - every Photoshop resource and IPTC dataset kept;
  - UTF-8 declared for non-ASCII keywords;
  - other apps' XMP kept;
  - a JPEG the splice refuses keeps its bytes and gets a sidecar that wins, clearing included;
  - a JPEG stays in its sidecar;
  - PNG, TIFF and HEIC keep their bytes;
  - the override wins for a pair's RAW.
- **The check they share** (`RichMetadataFixtures.swift`):
  - A hand-built camera JPEG (`RichJPEG`): IFD0, an Exif IFD with a 200-byte MakerNote, GPS, Interop, IFD1 with a
    thumbnail, XMP from another app, an Adobe RGB ICC, a Photoshop APP13 (custom dataset, digest, thumbnail and custom
    resources), APP9, COM, and an MPF preview.
  - `KeptMetadata.assertKeeps` checks that every ImageIO dictionary key and every XMP value is kept, apart from the
    exceptions.
  - It also checks: the MakerNote byte for byte (an Exif reader written apart from the app's); no IFD1, no old
    thumbnail or MPF bytes, no old ICC; every other APPn and COM segment; every other Photoshop resource and IPTC
    dataset; `DateTimeOriginal`; and the rating and keywords.
- **Mutations:** skipping the thumbnail zeroing fails four export tests; dropping the RAW fallback fails its test.
- **Real camera files** (gated, copies of `DSC08637` and the rotated portrait `DSC08753`, pair and RAW-only):
  - all three exports pass `assertKeeps` against the camera JPG;
  - `MetadataRealFileTests` (4) and `testRealRAWEditSaveAndExport` pass;
  - `~/PhocasaBenchRAW` is unchanged.
- **`MetadataJPEGPreservationTests`:** the two splice unit tests moved to the new signature (an XMP packet in place
  of ImageIO's rewrite); all its other tests pass unchanged.
- **Thumbnails:** exports still call `ImageLoader.shared.invalidate(path:)`, and the export itself never goes through
  the re-key hook. The rating write that follows an export is a metadata-only rewrite, which the re-key's generation
  check keeps safe.

### Benchmarks (quiet machine, load 1.7–5)

`ab.sh` ran `main` (`b83deab`) and the branch (`836e18e`) alternately, twice each, with the standard harness plus
`MetadataSidecarBenchmarks`. `multi.py` flags no line. The lines A's write paths touch (ms):

| Line | `main` | branch | Δ |
|---|---|---|---|
| `5a` setRating, N=10k / 2k | 6.87 / 1.92 | 6.79 / 2.00 | −1.2% / +4.0% (ranges touch) |
| `5b` setRating, N=10k / 2k | 6.92 / 1.92 | 6.94 / 1.95 | +0.3% / +1.6% |
| `8c` 50-photo rating, N=10k / 2k | 15.15 / 9.63 | 14.50 / 9.72 | −4.3% / +0.9% |
| `readMetadata` real JPG / ARW ×190 | 87.8 / 462.1 | 88.6 / 446.1 | +0.9% / −3.5% |
| `readMetadata` ×200: no sidecar / old Phocasa / Lightroom | 13.6 / 48.3 / 73.1 | 13.5 / 48.2 / 74.1 | −0.7% / −0.3% / +1.4% |

`MetadataWriteBenchmarks` is new and gated. It times the writes themselves on copies of `DSC08637`, in two worktrees
built once each, 3 alternating rounds per side (medians of medians, ms):

| Line | `main` | branch (final) | Δ |
|---|---|---|---|
| JPG rating write (16 MP camera JPG) | 6.42 | **3.92** | **−39%** (no ImageIO rewrite any more) |
| RAW sidecar rating write | 0.956 | 0.961 | +0.5% (the guard is skipped when the sidecar holds only Phocasa's fields) |
| RAW export to a new JPG (native) | 187.9 | 194.4 | +3.4% (reading the camera JPG, composing, checking) |
| "Apply edits permanently" (native) | 46.4 | 47.9 | +3.4% (ranges overlap: 45.7–47.6 against 45.6–48.1) |

The first branch build put the RAW sidecar write at +21%: the keep-everything guard re-parsed every rewritten
sidecar. With the re-parse skipped when there's nothing else to keep, it's +0.5%. A sidecar with other apps' content
(Lightroom's) still pays about 0.2 ms more per write.

**Gate:** a bug fix, and nothing regresses more than 5%. Merged.

### The metadata audit: every path that writes a photo or sidecar file

| Path | Writes | Keeps |
|---|---|---|
| Rating/keyword write, JPEG (`MetadataWriter` → `writeMetadata` → `writeToImageFile`) | the JPEG | Its XMP packet with 2 properties changed (other values proven kept), and the IPTC keywords and digest in its APP13; every other byte identical: Exif and MakerNote, MPF, ICC, other APPn, COM, image data. Temp file + `replaceItemAt`; dates, permissions, xattrs and symlinks kept. |
| same, a JPEG the splice can't handle, and every PNG/TIFF/HEIC/HEIF | its `.xmp` sidecar (flagged) | The image file byte-identical. (Before: ImageIO's full rewrite, which lost the MakerNote and more.) |
| same, a JPEG whose sidecar is already flagged | the sidecar | The image file byte-identical. |
| Rating/keyword write, RAW, and a pair's RAW half | the sidecar, in place | Everything other apps wrote (checked value by value after re-serialising, else not written); unparseable sidecars skipped, byte-identical; the RAW untouched. |
| RAW edit parameters save / clear (`RAWEditStore` → `MetadataWriter`) | the sidecar, in place | Only `phocasa:EditParameters` changes; same guard. |
| Exports, all three (`ImageEditingService` → `ExportMetadata`) | a new JPEG, or the JPG it replaces | The source's metadata, apart from the exceptions above; nothing written if it can't be kept (a new `-raw-edit` falls back to the RAW's). Then Phocasa's rating and keywords, by a normal rating write. |
| Permanent delete (`FileTrasher`) | moves the files to the Trash | The files themselves, whole (the user's delete). |
| `restoreFileDates` | file dates | Put back after metadata writes. Exports keep the replaced file's dates, as before. |
| Thumbnail cache (`ThumbnailDiskCache`) | its own folder | No photo files. |
| `StoreLocation` | moves the store | No photo files. |

`MetadataService.writeSidecar` has no app caller (tests only). Scans, the capture-date backfill and every read path
only read.

### Photos exported or baked in earlier builds

- **Which lost metadata.** Photos exported or baked before this fix lost it:
  - "Apply edits permanently" and "Replace existing JPG" wrote over the JPG without any;
  - `-raw-edit` files never had any.
- **Where it survives.** A pair's RAW (and its sidecar) still has the camera's metadata. So does the camera JPG
  beside a `-raw-edit` file. I didn't look for such photos on disk.
- **What a recovery would take** (the user's decision):
  1. **Find them.** Candidates are JPGs without an Exif `DateTimeOriginal` (the capture-date backfill already
     leaves those undated, so the library can list them), and `*-raw-edit.jpg` files. Exif-less JPGs from other
     sources would need weeding out by hand.
  2. **`-raw-edit` files beside their camera JPG:** copy the camera JPG's metadata in, without re-encoding: the
     transplant above, with the camera JPG as the source. Exporting again now does the same, but re-renders.
  3. **Baked or replaced JPGs with a RAW:** write the RAW's metadata into them without re-encoding, as a RAW-only
     export does. That restores Exif, GPS, capture date and XMP, but not the JPEG's MakerNote (not in the RAW in
     that form). Then Phocasa's rating and keywords.
  4. **Baked JPGs without a RAW:** only a copy from before the bake can help, such as Time Machine, the camera card,
     or another library. Its segments could be transplanted with the same code.
  - All of this is a one-off action over the library, with a list to confirm first. The code for steps 2–4 exists
    (`ExportMetadata`); it needs a UI or a command.

## C: sharpening, clarity and noise reduction at fit

### The question and the measure

Since task 35, edits at fit render at screen size, so sharpness (1.5 px), clarity (20 px) and clarity's blur acted
in the render's pixels. The alternative: scale those radii by the render's scale against native. I measured both
with `FitLookBenchmarks` (new, gated), on real copies of `DSC08637` (landscape) and `DSC08753` (rotated portrait),
ARW and JPG each:
- **Metric:** task 35's, the mean absolute RGB channel difference (0–255) of the fitted pass (viewport 2894×2130)
  and of the slider preview (1600×1100) against the native render drawn at their sizes, with high-quality
  interpolation.
- **Settings:** exposure +0.3 plus each filter at several strengths.

Before touching the pipeline, a scratch experiment on the real JPG tried the variants:
- radius × scale, for sharpness, clarity and blur;
- noise reduction's level × 1, × s or × √s, with and without scaling its sharpness.

Noise reduction (`CINoiseReduction`) has no radius. Scaling its level was mixed: ±0.05 at the pass, and −0.3 to −0.45
on the preview only with both parameters scaled. That isn't a clear gain, so it stays as it is. On a RAW, noise
reduction and the RAW's own sharpening happen inside `CIRAWFilter`, and the numbers show no difference at fit.

### Look at fit: current code against scaled radii (MAD; lower is closer to native)

| Source | Setting | Pass now | Pass scaled | Preview now | Preview scaled |
|---|---|---|---|---|---|
| ARW | exposure only | 1.79 | 1.79 | 2.45 | 2.45 |
| ARW | sharpness 25 / 50 / 100 | 2.20 / 2.74 / 3.95 | 2.09 / 2.41 / 3.12 | 3.10 / 4.19 / 6.61 | 2.69 / 2.94 / 3.49 |
| ARW | clarity 30 / 60 / 100 | 2.84 / 4.01 / 5.42 | 2.24 / 2.67 / 3.19 | 4.53 / 6.89 / 9.64 | 3.08 / 3.67 / 4.39 |
| ARW | clarity −50 / −100 (blur) | 2.12 / 2.86 | 1.08 / 0.74 | 4.89 / 6.47 | 1.73 / 1.17 |
| ARW | noise reduction 30 / 60 / 100 | 1.78 / 1.80 / 1.79 | same | 2.46 / 2.87 / 2.46 | same |
| ARW | sharpness 40 + clarity 30 | 3.67 | 2.88 | 5.89 | 3.57 |
| JPG | exposure only | 1.52 | 1.52 | 2.16 | 2.16 |
| JPG | sharpness 25 / 50 / 100 | 1.89 / 2.38 / 3.46 | 1.78 / 2.06 / 2.65 | 2.81 / 3.89 / 6.28 | 2.33 / 2.52 / 2.94 |
| JPG | clarity 30 / 60 / 100 | 2.63 / 3.91 / 5.36 | 1.89 / 2.25 / 2.68 | 4.59 / 7.23 / 10.03 | 2.66 / 3.15 / 3.75 |
| JPG | clarity −50 / −100 (blur) | 1.97 / 3.10 | 0.97 / 0.74 | 4.87 / 7.48 | 1.64 / 1.26 |
| JPG | noise reduction 30 / 60 / 100 | 1.44 / 1.40 / 1.40 | same | 2.51 / 2.67 / 2.77 | same |
| JPG | sharpness 40 + clarity 30 | 3.36 | 2.44 | 5.89 | 3.04 |
| portrait ARW | sharpness 100 / clarity 100 / clarity −100 | 10.17 / 7.94 / 3.14 | 8.93 / 7.17 / 1.01 | 14.02 / 9.97 / 5.16 | 7.80 / 8.49 / 1.43 |
| portrait JPG | sharpness 100 / clarity 100 / clarity −100 | 3.94 / 4.91 / 3.55 | 2.75 / 2.60 / 0.52 | 7.46 / 7.50 / 6.82 | 2.41 / 3.16 / 0.73 |

- Every radius setting on every source gets closer to native: the pass by 3–85%, the preview by 4–89%. Nothing gets
  further. (The merge message's "5–85% / 13–89%" left out the portrait ARW's smallest gains.)
- The portrait ARW gains least on clarity: at its scale (0.43) the RAW's draft-mode demosaic dominates the difference
  (4.1 with exposure alone).
- The full lines are `BENCH|fitlook|…` in `$TMPDIR/phocasa-coord-results/C-look-{base,scaled}.txt`, summarised here.

### Speed (quiet machine, `ab.sh`, `main` `2f2fe1b` against the branch `7dbae9c`, 3 alternating rounds each)

| Line (ms) | `main` | branch | Δ |
|---|---|---|---|
| slider pause, the pass: real ARW / portrait ARW | 69.6 / 65.3 | 70.4 / 65.0 | +1.1% / −0.4% |
| slider pause, the pass: real JPG / 24 MP JPG | 30.4 / 31.5 | 30.7 / 30.9 | +0.9% / −1.9% |
| coordinator edit ticks (previews): ARW idle / during the pass | 36.5 / 38.1 | 37.1 / 38.8 | +1.6% / +1.8% |
| coordinator edit ticks (previews): JPG / 24 MP, idle | 35.1 / 34.1 | 35.6 / 33.4 | +1.3% / −2.0% |

- `multi.py` flagged one line in code C doesn't touch: the relaunch "single cold thumbnail 380px", 1.47 → 1.60 ms.
  Re-run alone, alternately, in two worktrees: `main` 1.5 / 1.5 / 1.5 ms, branch 1.7 / 1.5 / 1.5 ms. That's noise
  at the timer's resolution, a known line.
- Everything else is within ±3%.

### Decision: adopted

The scaling clearly reduces the difference, and the pass isn't slower (within ±2%).
- Native renders and exports have scale 1, so their filter graph is unchanged: the full-resolution reference tests
  and `testStandardExportMatchesReference` pass unchanged.
- The test reference renderer now scales the radii for sized renders. Its four sized cases with a radius filter
  failed until the pipeline followed.
- CLAUDE.md has the rule ("Filter radii are in native pixels"), and `Tools/imagebench` is kept in step.

## The Release build (`6878e42`, outside A–C)

- **The error.** B's subagent found that `main` didn't build in Release: "sending 'context' risks causing data
  races" at `LibraryStore+Loading.swift:108`.
  - Task 32's background launch compared the model context by identity inside a local async function, which
    captured the non-Sendable `ModelContext`.
  - Release's whole-module concurrency check rejects that; Debug and the tests don't.
- **The fix.** It compares `ObjectIdentifier`s. The context stays alive for the whole function, so the meaning is
  the same.
- **Checks.** The Release build now succeeds with no warnings, and the suite passes (667 / 45 / 0).
- **Speed.** One identity comparison per load turn, so there's nothing to measure.
- **Docs.** The coordinator README's real-app procedure now builds Release once.

## Real-app check

Done on 2026-09-26, 12:25–13:20, with the screen unlocked, on a Debug build of `6878e42`, in **task B's development
mode**. It was the first check to use it.

**Setup:**
- `rm -rf "$HOME/Library/Application Support/Phocasa-Development"`, then launch with `PHOCASA_DEVELOPMENT_LIBRARY=1`.
- On every one of the seven launches, `lsof` showed only `Phocasa-Development/Phocasa.store` (and its `-wal`/`-shm`),
  with no other store and nothing under `Application Support/Phocasa/`.

**Photos, temp copies from `~/PhocasaBenchRAW`:**
- **The small folder:** 19 pairs, copied in reverse capture order, including rotated `DSC08650` (orientation 8),
  `DSC08663` (8) and `DSC08753` (6). `DSC08640` was made RAW-only, `DSC08641` got a Lightroom-style sidecar and
  `DSC08642` a garbage one.
- **The big folder:** 570 photos, APFS clones (`cp -c`) of all 190 pairs in three prefixes, with creation dates set
  in the opposite order to capture.
- Two small scripts compared the files: `exifcmp.py` (MakerNote bytes, `DateTimeOriginal`, orientation, IFD1,
  segments) and `propcmp` (every ImageIO dictionary key).

### A: every export path

| Path | Photo | Result |
|---|---|---|
| Apply edits permanently | `DSC08650` (orientation 8), 3 stars, +2.1 EV | Exif segment the same size (45,712 B), MakerNote byte-identical, `DateTimeOriginal` kept. Orientation 1, 3264×4912 upright; IFD1 unlinked; MPF gone; XMP added with the rating. `propcmp`: every key kept but the pixel ones (`{PictureStyle}` from the MakerNote too). Baked upright; the grid thumbnail refreshed; no alert. |
| Create new file (-raw-edit), pair | `DSC08649`, 4 stars, +0.8 EV, clarity 64 | Every ImageIO key kept (34/34 Exif, 9/9 TIFF, `{PictureStyle}` 4/4), MakerNote identical, `DateTimeOriginal` kept, 4 stars inside. The camera JPG changed only by the rating's XMP (its Exif byte-identical). |
| Replace existing JPG | `DSC08648`, 5 stars, +1.3 EV | Every key kept, MakerNote identical, 5 stars inside; the grid thumbnail refreshed to the RAW render. |
| RAW-only export | `DSC08640`, 2 stars | Carries what the gated test recorded: Exif 33/35 (not `CFAPattern`, `CompressedBitsPerPixel`), TIFF 5/7, `{ExifAux}` 4/5, `{PictureStyle}` 0/4 (MakerNote-derived); `DateTimeOriginal`, 2 stars. |
| Cropped export of a rotated RAW | `DSC08753` (orientation 6), crop, +1.3 EV | Upright and native after the crop (2604×3997), orientation 1, every key kept but the pixel ones, MakerNote identical, 3 stars inside. The crop overlay and the JPG comparison were upright. |

- **Capture date and sort.** After the next launch rescan the two `-raw-edit` exports became photos of their own (the
  known pairing-by-stem follow-up). They now sort **at their capture dates**, beside their originals, not as the
  newest photos. Their ratings (4 and 2 stars) were read back from the files.
- **Found:** a RAW-only export carries ImageIO's APP10 `AROT` segment, Apple's restart-offset table.
  - Probes: ImageIO decodes identically with bytes inserted before the scan (so the rating splice is safe) and with a
    stale table from another file.
  - Still, the transplant kept a source's table beside new image data. Fixed and merged: `8b30d03`, with a test that
    failed first.

### B: the three relaunch checks

- **Move to Bin survives a relaunch.** `DSC08652` went to the Bin with ⌫, then Cmd-Q and relaunch: the library came
  back without reopening the folder, and the Bin still held it. Four more relaunches too.
- **A 500+ library loads in the background at launch.**
  - With 590 photos, a burst of status-bar screenshots after launch shows the window up with "Loading library..."
    and a spinner, then "590 photos" in the next frame. Whole, in capture order, Bin 1.
  - The thumbnail cache after a relaunch: 0 files created, 24 read (their modification dates touched). No decode.
- **The capture-date backfill of an existing library.**
  - With the app quit, `sqlite3` on `Phocasa-Development/Phocasa.store` (only) set `ZCAPTUREDATE` to NULL on all
    591 rows.
  - On relaunch the grid first showed creation order: the exports, then ascending names.
  - A few seconds later it showed capture order: `a/b/c_DSC08826` first.
  - After quitting, 591 rows were dated and 0 missing. Twice.

### C: clarity at fit against zoomed in

- **The edit:** RAW `DSC08649` with clarity 64. I put the same region side by side: from the fit view (enlarged) and
  zoomed to 438% (the native render).
- **Result:** the clarity halos (the lighter band along the pillar edges, and how far it reaches into the sky) have
  the same width relative to the structures, and the same tone.
- Before C, a fitted render's 20 px radius was about 1.7× wider in image terms at this scale (the table in C).

### Wave-3 items re-checked

- **Capture-date order:** newest first, and oldest first after the toggle. Equal capture times order by creation
  date (c_, b_, a_, then the original).
- **Bin across rescans:** the launch rescans kept `DSC08652` in the Bin.
- **Grid scroll:** open a photo and close it, and the grid is at the same scroll offset. The only pixel differences
  are the new selection's highlight, the delete button and "1 selected".
- **Permanent delete:** of an extra pair added for it (`x_DSC08654`, via "Delete Forever" on the selection). The
  confirmation named 1 photo; both files left the folder; the Bin went back to 1.
- **Quit:** 2 stars then Cmd-Q at once. The app quit in about 200 ms, and the JPG and the sidecar both had rating 2.
  No `.phocasa-tmp` files.
- **Relaunch thumbnails:** see B.
- **Saved edits:** `DSC08649`'s saved RAW edit showed 0.6 s after opening, and 0.15 s after navigating away and
  back, looking the same.
- **Edits at screen size:** sharp at fit; zoomed in, the native render.
- **Write-backs:**
  - The Lightroom sidecar (`DSC08641`, rated 4) kept every value; ImageIO compared 24 before and after, and only
    `xmp:Rating` changed.
  - The garbage sidecar (`DSC08642`, rated 1) stayed byte-identical (same md5), while its JPG got the rating with its
    Exif segment unchanged (`segs`).
  - Pairs wrote the JPG and the sidecar.
  - The RAW-only photo wrote only its sidecar.
- **Revert** (on `DSC08753`) removed the edit from the sidecar and kept the rating.
- **Not re-checked this time:** the double-click on stars under the Unrated filter (unchanged code, covered by the
  click tests).

### Safety

- After the check:
  - no `.phocasa-tmp` files;
  - no `~/Library/Caches/com.phocasa.app`;
  - `~/PhocasaBenchRAW` unchanged (`find -newermt` from the check's start: 0 files);
  - only `Phocasa-Development/` written under Application Support.
- **Your Trash:** the permanent delete put the extra copy `x_DSC08654.JPG` and `x_DSC08654.ARW` (about 20 MB, copies
  of `DSC08654`) there. The terminal can't list or empty it.

## Follow-ups

- **Metadata:**
  - Some files keep their rating and keywords only in a sidecar: PNG, TIFF, HEIC, and JPEGs the splice can't
    handle. Other apps don't read sidecars for those formats, so they won't see the rating (decision 2).
  - Sidecar and export refusals are still silent in the grid, as sidecar skips were: the file just doesn't change.
    Only exports show an alert.
  - An export keeps Exif `SubjectArea` and the MakerNote's AF points in the original framing, after a crop or a
    rotation too. The user's rule keeps the MakerNote byte for byte, and some cameras' MakerNotes hold a preview of
    the original framing (decision 4).
  - A recovery for earlier exports: see A, "Photos exported or baked in earlier builds" (decision 1).
  - The real-app check used only `DSC086xx`/`DSC087xx` copies, all Sony. Other cameras' MakerNotes and phone JPEGs
    (motion photos, Ultra HDR) are covered by the synthetic tests only.
- **Exports** (from the wave-3 check, still open):
  - a `-raw-edit` export becomes a separate photo on the next rescan (pairing is by stem); it now sorts at its
    capture date;
  - the JPG edit's export dialog is titled "Export RAW Edit" and offers the two RAW exports.
- **Development mode** shares the app's `UserDefaults` domain (only SwiftUI's window frame is stored there).
- **Carried from wave 3** (the grid-identity item is dropped, as decided):
  - capture-date backfill after scans that change the missing set;
  - XMP-sidecar capture dates;
  - `LibrarySnapshot`'s duplicated `PhotoFacts` builder;
  - `FullImageLoader.clear()` keeps `infoCache`;
  - releasing the edit hand-off;
  - exact `st_mtimespec` in `restoreFileDates`;
  - quit cuts off a running trash batch;
  - an in-app backup before a schema migration;
  - the harness labels;
  - the `LazyVGrid` / Metal / colour-management recommendations.

## Decisions for the user

**Answered on 2026-09-26.** The work is handed over in `../post-wave-3-followup-prompt.md`.
1. Recovering earlier exports: not asked for separately. The user's point was the same as 2: other apps must be able
   to read the ratings.
2. **Ratings and keywords go inside the files themselves**, only ever added: no original metadata erased or changed.
   Sidecars stay for RAW files only. This replaces the sidecar fallback for unusual JPGs, PNG, TIFF and HEIC.
3. Keep other apps' develop settings (`crs:`) in exported and baked JPGs, as today.
4. Keep the MakerNote and its AF data after a crop, as today.
- Also asked: RAW ratings stay in the `.xmp` sidecar next to the RAW (DNG included); the RAW file is never modified.

The decisions as asked:

1. **Recovering photos exported or baked in earlier builds** (their metadata is gone from those files). The
   options, and what each can restore, are in A, "Photos exported or baked in earlier builds". The code exists
   (`ExportMetadata`); it needs a command or a UI, and a list for you to confirm first.
2. **Ratings that live only in a sidecar.** PNG, TIFF, HEIC, and odd JPEGs (extended XMP, several XMP or APP13
   segments, XMP ImageIO can't rewrite losslessly) now keep their bytes. Their rating and keywords go to a sidecar
   Phocasa reads first, as your rule requires. Other apps ignore sidecars for those formats. Before, they got the
   rating inside the file, at the cost of their MakerNote and other metadata. Nothing to do unless you'd rather know
   about these files (a mark in the UI).
3. **Other apps' develop settings in exported XMP.** A camera JPG that Lightroom edited and saved metadata into
   carries `crs:` settings, which describe how to render its pixels. An export or baked edit keeps them, as your
   rule says; Lightroom would then apply them on top of the new pixels. The alternative: treat them as describing
   the old pixels and drop them from exports.
4. **What the MakerNote may still show.** It's kept byte for byte. Some cameras store a small preview of the
   original framing in it, and AF points in its coordinates, so a crop doesn't remove what the MakerNote holds.
   The bench photos' Sony MakerNote (38,972 B) holds no embedded JPEG (no SOI marker in it), so for this camera only
   the AF data refers to the old framing. Keep as is (my recommendation), or strip MakerNote previews from exports
   for cameras that have them?


