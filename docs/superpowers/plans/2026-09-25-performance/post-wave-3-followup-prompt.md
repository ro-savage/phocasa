# Post-wave-3 follow-up prompt: ratings inside every file

Hand everything below the line to a new agent, started in `/Users/rowan/www/phocasa`.

---

You're picking up Phocasa, a native macOS SwiftUI photo app in this repo (`/Users/rowan/www/phocasa`). A long
performance and cleanup overhaul is finished and merged into `main`. The last piece of it made Phocasa never erase or
change a photo's original metadata.

Your job is one piece of work, **task D** below: put Phocasa's ratings and keywords inside every non-RAW photo file,
only ever added. Merge it into `main` with evidence, check it in the real app, and record it. Keep going without
waiting for me, except for a decision only I can make.

## Read first, in order

1. `CLAUDE.md` (project rules, binding). The "Metadata" section especially.
2. `docs/superpowers/plans/2026-09-25-performance/results/post-wave-3.md`. Read all of it, especially:
   - section A (what was fixed, and the metadata audit table);
   - "Decisions for the user" (my answers, at the top of that section).
3. `docs/superpowers/plans/2026-09-25-performance/post-wave-3-prompt.md`: the protocol this work followed (branches,
   the merge gate, the quiet A/B, the real-app check, safety). The same protocol applies to you.
4. `Tools/coordinator/README.md`:
   - the test runner (`runtests.sh`);
   - the A/B tools (`ab.sh`, `multi.py`);
   - driving the real app in development mode (`PHOCASA_DEVELOPMENT_LIBRARY=1`), and the lessons sections.
5. The code, before you change anything:
   - `Phocasa/Phocasa/Services/MetadataService.swift`: `writeMetadata`, `writeToImageFile`,
     `jpegWritingRatingAndKeywords`, `xmpPacket(rating:keywords:updating:)`, `spliceJPEGMetadata(original:xmp:keywords:)`,
     `sidecarOverridesEmbedded`, `sidecarFields`, `readMetadata`, `updateSidecar`;
   - `Services/JPEGStructure.swift`, `Services/PhotoshopIRB.swift`, `Services/XMPProperties.swift`,
     `Services/MetadataWriter.swift`;
   - the tests `MetadataKeepOriginalTests`, `MetadataJPEGPreservationTests`, `RichMetadataFixtures.swift`
     (`RichJPEG`, `TIFFWriter`, `KeptMetadata.assertKeeps`, an independent Exif reader) and `MetadataRoundTripTests`.

## Where things stand

- `main` is at `f4662b2` or later. The full suite is **668 executed, 45 skipped, 0 failures, 0 source warnings**
  (`Tools/coordinator/runtests.sh`). The skips are the gated benchmarks and the gated real-file tests.
- **How a rating or keyword write works today** (`MetadataService.writeMetadata`, always through `MetadataWriter`):
  - **A normal JPEG:** its own XMP packet gets just `xmp:Rating` and `dc:subject` changed. Every other XMP value is
    proven kept. Its IPTC keywords (`2:25`) are patched by hand into its APP13. Both are spliced into the original
    bytes; everything else stays byte-identical, including the camera's MakerNote and the MPF preview. This works,
    and the real-app check confirmed it.
  - **A RAW file** (and a pair's RAW half): its `.xmp` sidecar is updated in place. **This stays as it is.**
  - **Everything else:** the file keeps its bytes, and the rating and keywords go to its `.xmp` sidecar, flagged
    `phocasa:OverridesEmbedded` so that `readMetadata` prefers them. This covers:
    - JPEGs the splice refuses: fill bytes or standalone markers in the header; several XMP or APP13 segments;
      extended XMP; an XMP or APP13 segment after the MPF one; an XMP packet ImageIO can't parse or re-serialise
      without changing a value; non-ASCII keywords over IPTC text of unknown encoding;
    - every PNG, TIFF and HEIC/HEIF, because the only writer used for those was ImageIO's full rewrite, which drops
      data;
    - any file whose sidecar already has the flag ("stays in the sidecar").

  **Other apps (Lightroom included) don't read sidecars for JPG, PNG, TIFF or HEIC,** so they can't see those ratings.
  That's what task D fixes.

## My answers (binding)

1. Ratings and keywords must be **inside the photo file itself**, for every non-RAW format, so other apps can read
   them.
   - **Only ever add.** Never erase or change the original metadata: the camera's Exif (including MakerNote and GPS),
     IPTC, XMP, ICC, previews, and any other chunk, box or segment. Only Phocasa's own fields change: `xmp:Rating`,
     `dc:subject`, and the IPTC keywords.
2. RAW files (DNG included) keep their rating in the `.xmp` sidecar next to them. The RAW file is never modified.
3. Exports keep other apps' develop settings (`crs:`) in the XMP, as today. Don't change that.
4. After a crop, the MakerNote and its AF data are kept, as today.

## Task D: ratings and keywords inside every non-RAW file, additive only

### The goal

After task D, a rating or keyword write puts the values inside the file for every format below. Every original byte
of metadata is kept, apart from the XMP packet (and, for a JPEG, the APP13 keywords and digest), where only Phocasa's
fields change.

The sidecar fallback remains **only** as a last resort for a file that truly can't take the values without losing
something. Each such case must be:
- named in the code;
- tested;
- listed in CLAUDE.md;
- reported to me with how often it can happen.

### Per format: techniques to evaluate

Check each claim against the code and the file format before relying on it. Prefer the technique that changes the
fewest bytes.

**JPEG**, the cases the splice refuses today:
- **Fill bytes (`FF FF …`) or standalone markers between header segments.** They're legal. Make the parser keep them,
  and keep them byte for byte in the output.
- **Extended XMP.** Change only the main (standard) packet, and keep `xmpNote:HasExtendedXMP` and every extension
  segment byte-identical. The extension's GUID is the MD5 of the extended part, so it doesn't change. Keep the main
  packet within one segment (65,502 bytes of packet).
- **An XMP or APP13 segment after the MPF segment.** The MP entries' offsets count from the MPF header. When a segment
  between that header and the secondary images changes size, patch those offsets. Test that the preview stays
  byte-identical and reachable (`MetadataJPEGPreservationTests.mpfSecondImage`).
- **Several XMP or APP13 segments** (non-standard). Find out which one ImageIO reads, and decide on evidence: update
  that one, or keep the last-resort sidecar. Report which.
- **An XMP packet ImageIO can't parse, or can't re-serialise without changing a value.** Find out whether a safe
  textual edit is possible (for example, add the two properties in their own `rdf:Description`, but only when the
  packet has none of them already). If not, keep the last-resort sidecar.
- **Non-ASCII keywords where the existing IPTC text has an unknown encoding.** Decide on evidence. Options: write
  Latin-1 when the keywords can be represented in it, or leave the IIM keywords alone and write only the XMP. Record
  what the major readers then show (ImageIO's merged view says "XMP wins").

**PNG**
- Put the XMP in an `iTXt` chunk with the keyword `XML:com.adobe.xmp`, the standard place.
  - Update an existing one with the same XMP-packet updater as JPEG.
  - Otherwise insert a new one, before the first `IDAT`.
- Every other chunk stays byte-identical, including `eXIf`, `tEXt`, `iCCP` and ancillary chunks. Compute the chunk
  CRC-32 yourself, with no third-party code.

**TIFF** (standard `.tif`/`.tiff`, not RAW)
- The XMP goes in IFD0's tag 700 (XMLPacket).
- Don't move any existing data: MakerNotes and other private tags hold absolute offsets.
- If the new packet fits in the old tag 700's space, overwrite it in place, padded.
- Otherwise:
  - append the new packet and a new copy of IFD0, with the updated tag 700 entry, at the end of the file;
  - repoint the header's IFD0 offset;
  - keep the rest of the chain (next-IFD pointer, SubIFDs, Exif and GPS IFD pointers) exactly as it was.
- The old IFD0 and the old packet stay in the file, unreferenced. Say so in the record.

**HEIC/HEIF**
- In ISO BMFF, XMP is an item (`mime`, `application/rdf+xml`) in the `meta` box (`iinf`, `iloc`, `iref`).
- Adding or growing one can shift the `mdat` data, which `iloc` addresses by absolute offsets. iPhone files also
  carry auxiliary images: depth, and HDR gain maps.
- Implement this only if you can prove it lossless: every original item's bytes identical and still reachable, and
  the decode identical.
- Otherwise keep the last-resort sidecar for HEIC, and report it with what a writer would take.

**Other standard formats in `FolderScanner.standardExtensions`:** say what happens to each.

### Files already in sidecar mode

Builds from `2f2fe1b` on flagged some sidecars with `phocasa:OverridesEmbedded`.
- Once a file can take its values in-file, the next write puts them in the file.
- It keeps the sidecar consistent: same values, flag cleared. Never delete a user's file.
- Reading must never let a stale sidecar hide newer in-file values. Design this, and test it.
- A pair's RAW sidecar still gets the pair's values, as today.

### Tests

Test first: each failing test must fail on today's code for the reason it names.
- **For each case above, a test on a hand-built file with rich metadata.** Extend `RichMetadataFixtures`: MakerNote,
  GPS, IPTC with custom datasets, XMP from another app, ICC, previews. It must show:
  - every original property is kept with the same value, and every byte outside the parts that may change is kept
    (per format, say exactly which parts those are);
  - the rating and keywords are **read back from the file by ImageIO without the sidecar.** Delete or move the
    sidecar first; `readMetadata` prefers the sidecar, so it isn't enough.
  - the image data is untouched, and the decode identical.
- **Repeated writes** stay stable, and don't grow the file without bound.
- **The migration** from sidecar mode.
- **Guards:** the normal-JPEG path is unchanged (`MetadataJPEGPreservationTests`, `MetadataKeepOriginalTests`), RAW
  files still use only their sidecar, and exports still carry metadata (`ExportMetadataTests`,
  `ExportMetadataCompositionTests`).
- **Tests that encode the old sidecar-fallback behaviour** must be changed deliberately, not deleted. In
  `MetadataKeepOriginalTests`:
  - `testAJPEGTheSpliceRefusesKeepsItsBytesAndGetsASidecar`;
  - `testAJPEGWhoseRatingIsInASidecarKeepsItThere`;
  - `testOtherFormatsKeepTheirBytesAndGetASidecar`.

  Say in the record what each now checks.
- **Gated real-file tests**, on copies only (see Safety). Use the camera JPGs from `~/PhocasaBenchRAW`, and PNG and
  TIFF made from them with ImageIO, with metadata.
- **Mutations:** break each safeguard once and show a test catches it. For example: skip the MPF offset patch, drop
  a PNG chunk, move a TIFF tag's data.

### Performance

- `MetadataWriteBenchmarks` (gated: `PHOCASA_BENCH=1` and `PHOCASA_TEST_RAW` naming a copy of a RAW with its JPG):
  - the JPG rating-write line must not regress more than 5%;
  - add PNG and TIFF lines.
- Run the quiet A/B from the coordinator README: `main` against the branch, alternated, with nothing else running,
  including `MetadataSidecarBenchmarks` and `DataPathBenchmarks`' rating lines. Compare with `multi.py`.
- Re-check any line over 5% in untouched code alternately before judging.

### Docs

- **CLAUDE.md's "Metadata" section:**
  - the new rule (in-file for every non-RAW format, additive; sidecars for RAW only);
  - the technique per format;
  - the last-resort cases.
- **The metadata audit table** in a new record: `docs/superpowers/plans/2026-09-25-performance/results/post-wave-3-D.md`.

## How to work

- **Branch.** Work on your own branch (`fix/ratings-in-file` or similar). Read the code a claim depends on before you
  change anything, and test first. Commit in small logical steps.
- **Before merging:** run the full suite with `Tools/coordinator/runtests.sh`. It must pass with 0 source warnings.
  Build Release once too, with `-configuration Release` and its own DerivedData; Release catches concurrency errors
  that Debug doesn't.
- **Merging:** merge into `main` with `git merge --no-ff`, then run the full suite again.
- **Never push.** Never amend, reset or rewrite `main`'s history.
- **The merge gate:** this is a correctness change, so it lands if its failing tests pass and no benchmark regresses
  more than 5%.
- **Real-app check at the end,** in development mode (`PHOCASA_DEVELOPMENT_LIBRARY=1`; the procedure is in the
  coordinator README), on temp copies:
  - rate and tag a normal camera JPG, a JPEG of each formerly refused kind, a PNG and a TIFF (and a HEIC if you
    support it);
  - confirm with ImageIO (the sidecar moved aside) that the values are in each file;
  - confirm every original byte is kept: `Tools/coordinator/app-driver/segs.py` for JPEG segments, plus your own
    checks per format;
  - rate a RAW-only photo and a pair, and confirm the RAW files are untouched (same SHA-256);
  - relaunch and confirm the ratings come back.
- **Keep the record:** what merged and why; the suite after the merge; the benchmark tables; the per-format results;
  the audit; the real-app check; follow-ups; and decisions for me. Commit it.

## Safety (binding)

- **My real library:** never open, copy, move or modify it:
  - `~/Library/Application Support/Phocasa/` (store, `-wal`, `-shm`, `.Phocasa_SUPPORT`);
  - any `default.store*` or `.default_SUPPORT` in `~/Library/Application Support`;
  - my backup in `~/Desktop/Phocasa-backup`.

  The only place under Application Support you may write is `Phocasa-Development/`, through the app in development
  mode or to reset it (quote the path; it has a space). Tests use temp folders and in-memory or temp-file stores.
- **Caches:** tests and the app in development mode never write `~/Library/Caches/com.phocasa.app`.
- **Real photos:** `~/PhocasaBenchRAW` holds 190 JPG+ARW pairs (Sony, 16 MP, 12 rotated) and is read-only.
  - Read and measure it freely.
  - Anything that writes works on temp copies. Give `PHOCASA_TEST_RAW` a *copy*.
  - Don't search the disk for other photos: no `mdfind`, no Spotlight.
- **The Trash:** a permanent delete in the real app moves files to my Trash, which the terminal can't list or empty.
  Delete only an extra copy added for that, and tell me.
- **Driving the app:**
  - only you drive the real app, never a subagent. Hosted-window unit tests are fine;
  - send keys inside the same `osascript` that sets the app frontmost;
  - it needs an unlocked screen. If the screen is locked, carry on with other work, and do the check once it's
    unlocked.
- **Xcode:** stay on Xcode 26.6.

## Out of scope

Note these as follow-ups; don't do them:
- a `-raw-edit` export becoming a separate photo on the next rescan;
- the JPG edit's export dialog titled "Export RAW Edit";
- recovering files exported in earlier builds;
- the rest of the follow-up list in `results/post-wave-3.md`.

## When to stop

Stop when task D is merged, checked in the real app and recorded, or earlier if a format can't be written
losslessly and needs my decision. Then give me a short status:
- what merged, and why;
- per format, where the rating now lives, and what stays byte-identical;
- the last-resort cases, and how often they can happen;
- the benchmark numbers;
- what the real-app check showed;
- open follow-ups, and any decisions for me.
