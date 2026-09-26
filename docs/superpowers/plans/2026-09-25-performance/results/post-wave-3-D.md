# Post-wave-3 task D: ratings and keywords inside every non-RAW file

This carries out the user's answers in `../post-wave-3-followup-prompt.md`: Phocasa's rating and keywords go inside
every non-RAW photo file, only ever added; RAW files (DNG included) keep theirs in the `.xmp` sidecar beside them and
are never written. The sidecar stays only as a named, tested last resort.

The work ran as four worktree subagents (JPEG layouts, PNG, TIFF, HEIC/HEIF), each writing a pure container editor
with its own tests, and the coordinator (migration from sidecar mode, the reading rule, the dispatch and its checks,
the integration, docs, benchmarks, the real-app check). Everything merged into `fix/ratings-in-file`, then into `main`.

| Commit | What |
|---|---|
| `1e9db54` | Files leave sidecar mode on their next write; a stale sidecar never hides a file's own values |
| `553d89f` | `MetadataWriteBenchmarks` times PNG and TIFF rating writes |
| `69241ef`, `702489f` | PNG (`PNGMetadata`), merged and wired in, with the container check |
| `01a9c16`, `7799828` | TIFF (`TIFFMetadata`), merged and wired in; unchanged bytes aren't rewritten |
| `828f491`, `a6a2121` | HEIC/HEIF (`HEIFMetadata`), merged and wired in |
| JPEG merge, `5f232de` | The JPEG layouts the splice refused; ImageIO's lossy packet rewrite no longer trusted; a packet that already holds the values is kept |
| `86db66f` | CLAUDE.md's "Metadata" section |
| `947c55c` | The gated real-file tests and the write benchmark make their copies writable |


Merged into `main` as `8a0f33c` (`--no-ff`). The release work that followed (a separate record, `release.md`) merged
on top.

## Suite

| When | Result |
|---|---|
| `main` before (`9c6e3be`) | 668 executed, 45 skipped, 0 failures, 0 source warnings |
| branch, full suite with the gated real-file tests on a copy of `DSC08637` | 801 / 35 / 5: every failure a gated test whose copy of the read-only bench file was read-only (the app correctly leaves those alone). Fixed in the tests (`947c55c`): 99 / 0 / 0 on those classes |
| `main` after the merge (`8a0f33c`), gated tests on | **801 executed, 35 skipped, 0 failures**, 0 source warnings |
| Release build of the branch | succeeded, no warnings |

(The 35 skips are the gated benchmarks. The two `warning:` lines are the AppIntents notices.)

## Where the rating and keywords live now

| Format | Where | What changes, byte by byte | Stays byte-identical |
|---|---|---|---|
| RAW (DNG included) | the `.xmp` sidecar beside it, in place | only Phocasa's fields in the sidecar | the RAW file, always (SHA-256 checked in the real-app check) |
| JPEG | inside: the last standard XMP segment, the APP13's IPTC keywords and digest, the MPF entries' size/offset fields | the XMP packet by a text edit (values changed where they are, or added in their own `rdf:Description`) or, if that can't, ImageIO's rewrite when an independent XML reading shows every value kept; 2:25 datasets + 0x0425 digest; the MPF first-image size (+ header growth) and secondary offsets (+ growth after the MPF segment) | Exif with the MakerNote, other XMP segments, extended XMP, fill bytes, ICC, APPn, COM, the image data, the MPF previews |
| PNG | inside: the `iTXt XML:com.adobe.xmp` chunk (or ImageMagick's raw XMP profile, in its own form) | that chunk's length, text and CRC; a new chunk before the first `IDAT` if there was none; an XMP chunk after `IDAT` moves before it (ImageIO doesn't read it there) | every other chunk (`eXIf`, `iCCP`, text, private, `IDAT`, APNG chunks) and bytes after `IEND` |
| TIFF | inside: IFD0 tag 700, and 33723 / 34377 IPTC | in place when they fit (padded); else the new value and a copy of IFD0 appended, the header's IFD0 offset repointed | every existing byte stays where it is; the old IFD0 and old values stay in the file, unreferenced |
| HEIC/HEIF | inside: the primary's XMP item | in place (padded), or the packet at the end of the file with only its `iloc` entry changed; a file without one gets a new `infe`, `cdsc` and `iloc` entry, with every offset past `meta` shifted | every other item's bytes (proven reachable and identical), every other box |

Formats by extension (`FolderScanner.standardExtensions`): `jpg`/`jpeg` → JPEG, `png`, `tif`/`tiff` → TIFF, `heic`/`heif`
→ HEIF (any codec: HEVC, AV1, AVC brands). The format is read from the file's bytes, not its name.

### How it's kept safe

- **Every format checks its own output:** PNG walks every chunk and CRC again; TIFF re-parses and checks every
  original byte outside the parts it may change; HEIF proves every item's bytes and every box. Then, before any file
  is replaced, ImageIO must read the new bytes as complete, with the new values and every property the original had
  (`MetadataService.image(_:keepsEverythingIn:reading:_:)`, JPEG `jpeg(_:readsBack:)`).
- **A write that changes nothing leaves the file alone** (the same values write the same bytes: a packet that already
  holds them is kept byte for byte).
- **Leaving sidecar mode** (every PNG, TIFF, HEIC and odd JPEG since `2f2fe1b`): the sidecar gets the new values
  first, still flagged, then the file, then the flag is cleared, so a reader never sees an older value win; if the
  sidecar can't be updated, neither is written. A user's sidecar is never deleted; any existing sidecar of a non-RAW
  file follows each in-file write.
- **Reading:** a flagged sidecar wins as it is; a non-RAW file on its own that holds an `xmp:Rating` is read from the
  file (a stale or left-over sidecar can't hide it); a RAW, a pair's JPG and a file without a rating of its own take
  the sidecar's non-zero rating and non-empty keywords, as before. The scanner says which photos are pairs.

### Found on the way (fixed)

- **ImageIO's parse and serialise of an existing XMP packet silently lost values** in the normal JPEG path shipped
  before task D: empty values (`photoshop:Headline=""`), `rdf:nodeID`, `rdf:datatype`, `parseType="Literal"`,
  qualifiers on write, aliases renamed (`exif:DateTimeOriginal` → `photoshop:DateCreated`), everything after an XML
  error. The old guard compared ImageIO's model with itself, so it passed. Packets are now edited as text first, checked
  by an independent XML reading.
- **The MPF first-image size went stale on every rating write** that inserted an XMP segment before the MPF one (every
  Sony JPEG): 3,692,367 bytes plus the XMP's length on `DSC08637`. Patched now (CIPA DC-007 §5.2.3.3). Files rated by
  earlier builds keep the offset they had (the patch adds the growth; it doesn't rescan the image).

## The last resort (the file keeps its bytes; a flagged sidecar holds the values)

Each is named in code and tested (`MetadataJPEGLayoutTests`, `PNGMetadataTests`, `TIFFMetadataTests`,
`HEIFMetadataTests`, `MetadataSidecarMigrationTests`).

| Format | Case | How often |
|---|---|---|
| JPEG | a standalone marker (TEM, RSTn) in the header (ImageIO decodes neither the image nor its metadata) | very rare |
| JPEG | fill bytes before the XMP segment (ImageIO's XMP reader stops at the first fill byte; fill after it is fine) | rare |
| JPEG | bytes other than 0xFF between segments; an MPF that can't be parsed, or an entry outside the file | damaged files |
| JPEG | extended XMP that holds `xmp:Rating` or `dc:subject` (the extension wins in ImageIO) | very rare |
| JPEG | a packet over 65,502 bytes after the edit | very rare |
| JPEG | several XMP segments whose last isn't a packet; a malformed APP13 | rare |
| JPEG | non-ASCII keywords over IIM text of unknown encoding **with a stale digest** (the IIM would win) | uncommon |
| all | XMP that isn't well-formed or has a DTD; a rating or keywords no technique can place while keeping every value | uncommon (truncated packets, buggy writers) |
| PNG | damaged (bad CRC, truncated, IHDR misplaced, split IDAT), Apple-crushed (`CgBI`), an unknown critical chunk, several XMP chunks, XMP in `tEXt`/`zTXt` (ImageIO ignores it), an unreadable XMP chunk | rare |
| TIFF | BigTIFF (ImageIO reads no metadata from it), out-of-bounds or looping IFDs, a duplicated metadata tag, an unexpected field type, XMP in Photoshop resource 1060, files near 4 GB | rare |
| TIFF | **IPTC that can't be patched** (non-ASCII keywords over IIM text of unknown encoding) | **the likeliest: old scanned or edited TIFFs with Latin-1 captions, when an accented keyword is added** |
| HEIF | **image sequences, bursts, animations (`moov`), Samsung motion photos (`mpvd`), Google motion photos**, unknown top-level boxes | the likeliest HEIF case: a burst or Live-style sequence |
| HEIF | external data, construction method 2, zero-length extents, an ambiguous or encoded XMP item, `iloc` with `index_size` (ImageIO can't read those), fields too small | very rare |

Where the JPEG can't patch the IIM (several APP13 segments, IIM that can't hold the keywords, non-ASCII keywords over
text of unknown encoding with a matching or no digest), the keywords go into the XMP only, in the file: MWG 2.0
§4.2.3.2 has readers prefer XMP then, and ImageIO, Lightroom, Bridge and Photos show the new keywords; tools that read
only the IIM (exiftool's `IPTC:Keywords`) see the old ones. That's not a last resort (the values are in the file).

## Tests

- **Failing first:** every new test failed on the code before it for the reason it names (the file left unchanged and
  a sidecar written; a stale sidecar winning; ImageIO's lossy rewrite; the stale MPF size; a stub refusing everything).
  Per piece: PNG 19 of 20 against a stub; TIFF every test against a stub; HEIF 73 failures across 31 tests against a
  stub; JPEG layouts on the pre-D code; migration 17 failures across 37 tests.
- **Fixtures:** hand-built rich files per format (MakerNote-like blobs with absolute offsets, GPS, IPTC with custom
  datasets and digests, another app's XMP with structs, lang-alts and a custom namespace, ICC, previews, second
  pages, auxiliary images), each with an independent parser in the test target. Gated real-file tests on copies of
  `DSC08637` (and PNG/TIFF made from it with ImageIO).
- **Tests changed deliberately:**
  - `MetadataKeepOriginalTests.testAJPEGWhoseRatingIsInASidecarKeepsItThere` → `…GetsItInTheFileOnTheNextWrite`
    (a flagged sidecar now moves into the file, and stays in step);
  - `…testAJPEGTheSpliceRefusesKeepsItsBytesAndGetsASidecar`: its fixture is now a packet that isn't well-formed (an
    extended-XMP JPEG takes its values in the file now);
  - `…testOtherFormatsKeepTheirBytesAndGetASidecar` → `testAPNGGetsItsValuesInTheFile`, `testATIFFGetsItsValuesInTheFile`,
    `testAHEICGetsItsValuesInTheFile` (no format is left in sidecar mode);
  - `MetadataRoundTripTests.testSidecarRatingStillTakesPrecedenceOverEmbeddedRating`: now makes the RAW file, a real
    pair (a JPG on its own that holds a rating reads from the file);
  - `MetadataJPEGPreservationTests.testSpliceRefusesLayoutsItCantHandleSafely`, `untouchable`,
    `testMPFPreviewStaysReachable` and `MetadataRealFileTests.testRatingARealCameraJPGChangesOnlyItsXMP`: they allow
    exactly the patched MPF fields and check their new values;
  - two `ExportMetadataTests` fixtures that used fill bytes as "can't be carried" now use an Exif that can't be walked
    (exports now carry fill-byte sources: `testASourceWithFillBytesIsCarriedOver`).
- **Mutations**, each caught by at least one test: PNG 33 (CRC check, chunk dropped, placement, compression, UTF-8,
  every refusal); TIFF 32 (bounds, loops, next pointer, header offset, value moved, entry dropped, padding, alignment,
  digest rules); HEIF (offset shift, `cdsc` from-ID, `mdat` resize, padding, `iinf` count, top-level boxes, motion
  photos, entity-group IDs, length update); JPEG M1–M6 (MPF offsets, first-image size, fill bytes dropped, text edit
  duplicating a rating, rewrite without the independent check, XMP-only clearing without an empty Bag); migration
  M1–M5 (sidecar-first update, flag clear, the lone-file rule, the scanner's pair hint, keeping other sidecars in step).

## Benchmarks (quiet machine, load 1.7–3.9)

`ab.sh` alternated `main` (`9c6e3be`) and the branch (`947c55c`), twice each, with `MetadataSidecarBenchmarks` and
`MetadataWriteBenchmarks` (on a writable copy of `DSC08637`). `multi.py` flags nothing, and no line rose more than 5%.

| Line (ms) | `main` | branch | Δ |
|---|---|---|---|
| **JPG rating write (16 MP camera JPG)** | 3.45 | 3.34 | **−3.1%** |
| RAW sidecar rating write | 0.90 | 0.91 | +1.8% |
| PNG rating write (18 MB PNG from the camera JPG) | (sidecar) | 12.73 | new |
| TIFF rating write (48 MB TIFF from the camera JPG) | (sidecar) | 24.84 | new |
| export RAW to a new JPG / apply edits permanently (native) | 192.9 / 46.2 | 190.4 / 47.5 | −1.3% / +2.9% (ranges overlap) |
| `readMetadata` real JPG / ARW ×190 | 86.4 / 447.7 | 88.3 / 444.0 | +2.3% / −0.8% |
| `readMetadata` ×200: no sidecar / old Phocasa / Lightroom sidecar | 13.8 / 48.3 / 73.0 | 13.5 / 47.8 / 72.9 | −2.4% / −1.1% / 0.0% |
| `5a`/`5b` setRating, N=10k | 6.90 / 7.45 | 6.73 / 6.82 | −2.4% / −8.5% |
| `8c` 50-photo rating, N=10k / 2k | 14.46 / 9.39 | 14.28 / 9.34 | −1.2% / −0.5% |

**Gate:** a correctness change; nothing regresses more than 5%. Merged.

## The metadata audit: every path that writes a photo or sidecar file (as of `main` after the merge)

| Path | Writes | Keeps |
|---|---|---|
| Rating/keyword write, any non-RAW file (`MetadataWriter` → `writeMetadata` → `writeToImageFile` → `fileWritingRatingAndKeywords`) | the file itself, per the table above | every byte of metadata outside Phocasa's fields, per format; checked by the format and by ImageIO before the file is replaced; temp file + `replaceItemAt`; dates, permissions, xattrs, symlinks kept; unchanged bytes not rewritten |
| same, a file in the last resort | its `.xmp` sidecar, flagged | the file byte-identical |
| same, a file with a sidecar (flagged or not) | the file, then the sidecar kept in step (flag cleared) | the sidecar's other content (checked value by value); a sidecar that can't be updated stops the move out of sidecar mode |
| Rating/keyword write, RAW, and a pair's RAW half | the sidecar, in place | everything other apps wrote; unparseable sidecars skipped, byte-identical; the RAW untouched |
| RAW edit parameters (`RAWEditStore` → `MetadataWriter`) | the sidecar, in place | only `phocasa:EditParameters` changes |
| Exports and baked edits (`ImageEditingService` → `ExportMetadata`) | a new JPEG, or the JPG it replaces | the source's metadata but the listed pixel exceptions (unchanged by task D); then Phocasa's values like any rating write |
| Permanent delete, file-type delete (`FileTrasher`), `restoreFileDates`, the thumbnail cache, `StoreLocation` | as in `post-wave-3.md` (the release work since changed the deletes; see `release.md`) | |

## Real-app check (development mode, 2026-09-26, 15:05–15:16)

A Debug build of `main` (`e479de7`, task D plus the first release fixes), `PHOCASA_DEVELOPMENT_LIBRARY=1`, the
development folder reset first. `lsof`: only `Phocasa-Development/Phocasa.store` open. Photos: temp copies built from a
copy of `DSC08637.JPG` (`~/PhocasaBenchRAW` only read):
- `normal` (the camera JPG), `fill` (fill bytes between Exif and MPF), `extended` (a main packet with
  `xmpNote:HasExtendedXMP` and an extension segment), `xmpaftermpf` (an XMP segment after the MPF one, the MP offsets
  patched in the fixture), `twoxmp` (two XMP segments rating 1 and 2), `lossyxmp` (an empty value and a
  `parseType="Resource"` struct), `latin1iptc` (an APP13 with a Latin-1 caption and no 1:90);
- `shot-png`, `shot-tiff`, `shot-heic` made from it with `sips` (ImageIO), and `legacy.png` with a flagged sidecar as a
  pre-D build left it (rating 2, keyword `from-sidecar`);
- `DSC08638` RAW-only and `DSC08639` a pair (copies).

Rated each (a different rating per file) and added `from-sidecar` to all 13 from the context menu, and `food:cafa` and
`food:café` to `latin1iptc` (AppleScript types "café" as "cafa"; the second came through the clipboard).

| Check | Result |
|---|---|
| Read before any write | `legacy` 2 stars and its tag from the flagged sidecar; `twoxmp` 2 (ImageIO reads the last packet); `xmpaftermpf` 1 |
| In the file, read by ImageIO from the file's bytes (no sidecar involved) | all 8 JPEGs, the PNG, TIFF and HEIC, and `legacy.png`: the rating set in the app and `dc:subject` = `{IPTC}` Keywords |
| Sidecars | only `DSC08638.xmp` and `DSC08639.xmp` (the RAWs', with their values) and `legacy.xmp`: kept, the same values, **no flag**. No JPEG, PNG, TIFF or HEIC got a sidecar |
| Every ImageIO property, every XMP value, the decoded pixels (`propcmp` against the pristine copies) | all kept, pixels identical, for all 12 files |
| JPEG structure (a segment walker against the pristine copies) | every segment but XMP/APP13, fill bytes and the extended-XMP segment included, byte-identical; image data identical; MPF previews identical and reachable; the MPF first-image size grew by exactly the header's growth |
| `twoxmp` | the first packet byte-identical; the last one's `xmp:Rating` changed in place (2 → 5) |
| `lossyxmp` | the empty `photoshop:Headline` and the `parseType="Resource"` struct kept verbatim; the rating and keywords in `rdf:Description`s of their own |
| `latin1iptc` with `food:café` | XMP and ImageIO's `{IPTC}` view: `food:café`, `from-sidecar`, `food:cafa`; the IIM keeps the last ASCII keywords and the Latin-1 caption byte-identical (XMP only; no digest in this file, so MWG readers prefer XMP) |
| RAW files | SHA-256 unchanged (both) |
| Relaunch (Cmd-Q, relaunch) | the 13 photos came back with their ratings and tags, no folder reopened; a daily backup of the development store appeared (`Backups/2026-09-26-151204`, release work) |
| A second copy launched on the same library | "Phocasa is already open with this library", naming the other copy; it opened no store (release work) |
| After | no `.phocasa-tmp` files; no `~/Library/Caches/com.phocasa.app`; `~/PhocasaBenchRAW` unchanged; only `Phocasa-Development/` under Application Support |

**A scare, and a lesson:** after the first relaunch a window showed "No Photos" and "Saving to files… 93,342 left".
It was a subagent's `ScaleChecks` test host (an in-memory library rating 150k photos), also a process called
"Phocasa": `tell process "Phocasa"` had picked it, and my Cmd-Q quit it. My own app, targeted by its process ID, showed
the library intact. The coordinator README now says to target the app by process ID.

## Follow-ups

- **HEIC and Lightroom Classic:** forum evidence (not official) says Lightroom Classic 8–10 wrote `.xmp` sidecars for
  HEIC and may read them; LrC 13 may write inside HEIC (unconfirmed). Phocasa now writes inside the HEIC and keeps an
  existing sidecar in step, but doesn't create one (sidecars are for RAW only, the user's rule).
- **Windows ratings:** IFD0 `Rating`/`RatingPercent` (0x4746/0x4749) that Windows writes stay as they are (only
  Phocasa's fields change), so Windows may keep showing an old rating.
- **MWG checksum:** MWG says a changer "MUST create" the IPTC digest when both XMP and IIM are present; Phocasa
  updates one that exists and never creates one.
- **TIFF growth:** after an append the old IFD0 and older keyword lists stay in the file as unreferenced bytes (by
  design: nothing moves). Growth is bounded.
- **PNG/TIFF/HEIC with an `x:xapmeta` or bare `rdf:RDF` packet** that needs a description added go to the last resort
  (ImageIO's standalone parser rejects those forms); JPEG handles them by reading the written file back.
- **HEIF `MiPr` brand** is kept while an appended packet sits at the end of the file (readers find items by `iloc`).
- **Other cameras:** the real-app check used Sony files and ImageIO-made PNG/TIFF/HEIC; Canon/Sony `.HIF`, Samsung
  HEIF and other makers' JPEGs are covered by the synthetic tests and the refusals only.

## Decisions for the user

None blocking. Two to know:
1. **IIM-only readers** (exiftool's `IPTC:Keywords`, old DAM tools) may see older keywords where Phocasa could only
   write the XMP (several APP13 segments, or accented keywords over IPTC text of unknown encoding). Lightroom, Bridge,
   Photos and ImageIO show the new ones.
2. **HEIC sidecars for Lightroom:** Phocasa writes the rating inside the HEIC. If you use an older Lightroom Classic
   that reads HEIC ratings only from a sidecar, Phocasa could also create one for HEIC files; today it doesn't.
