# imagebench

A standalone command-line benchmark for Phocasa's image paths. It reproduces what `Services/ImageLoader.swift` and
`Services/ImageEditingService.swift` do with ImageIO and CoreImage, and only measures. It doesn't link against the app,
so keep it in step by hand when those services change. The numbers in
`docs/superpowers/specs/2026-09-25-performance-review.md` (§C1–C2, §D, §E) came from this tool.

## What it measures

- **Thumbnail decode options:** `CreateThumbnailFromImageAlways` against `IfAbsent`, at several sizes, with and
  without `kCGImageSourceShouldCache` (spec §C2).
- **Detail decode:** full-resolution `CreateImageAtIndex` against downsized thumbnails, subsampling and CPU rotation,
  with time, CPU and decoded bytes for each (§D2).
- **Orientation:** which ImageIO and CoreImage paths apply EXIF orientation (§D1).
- **Concurrency ordering:** the current one-block-per-cell GCD pattern against a bounded newest-first pool, cold and
  warm (§C1).
- **CoreImage preview chains:** the edit filter chain rendered to fit 1600×1100, the delayed full-resolution pass,
  and `createCGImage` deferral (§E2–E4).
- **RAW:** embedded-preview against full thumbnail decode, and `CIRAWFilter` draft mode and `scaleFactor`
  (§C2, §E1). Runs only on a file you name explicitly (see [RAW files](#raw-files)).

## Build

```bash
cd Tools/imagebench
swiftc -O -swift-version 5 imagebench.swift -o "$TMPDIR/imagebench"
```

If several agents run it at once, give each its own binary and data directory, for example
`-o "$TMPDIR/imagebench-<task-id>"` and `IMAGEBENCH_DIR="$TMPDIR/phocasa-imagebench-<task-id>"`.

## Subcommands

Run `gen` and `copies` first. Every other subcommand reads the generated images.

| Subcommand | What it does |
|---|---|
| `gen [noiseAmp] [quality]` | Writes `master.jpg`: a synthetic 6000×4000 JPEG with EXIF orientation 6 and a 160×106 embedded EXIF thumbnail. Defaults: `noiseAmp` 14, `quality` 0.9, which give about 15.0 MB (the spec quotes 12.6 MB). Its last line, `embedded thumbnail (IfAbsent, no max, no transform)`, prints 6000x4000 because ImageIO doesn't return the embedded thumbnail when no max size is given. `thumb` shows it (106x160 for `IfAbsent`). |
| `copies` | Writes 200 real copies of `master.jpg` (not APFS clones), so decodes don't share cached pages. |
| `orient` | Output size of each decode path on the orientation-6 image. `CreateImageAtIndex` reports 6000x4000 (unrotated); the thumbnail with transform reports 4000x6000. |
| `thumb` | Thumbnail decode time at 400, 800 and 1200 px for each mode and cache option. |
| `thumbsizes <px>...` | The app's thumbnail options at each size given, in order. |
| `detail` | Detail-view decode options: time, CPU and decoded memory. |
| `conc [px]` | 200 thumbnail requests, current GCD pattern against a bounded newest-first pool. `px` is the thumbnail size (default 600). Evicts the copies from the page cache for the cold runs. |
| `ci` | CoreImage preview variants and the delayed full-resolution pass. |
| `cidiag` | Diagnostic: whether `createCGImage` defers rendering, against `deferred: false` and `render(toBitmap:)`. |
| `raw` | RAW thumbnail and `CIRAWFilter` preview variants on the file named by `$IMAGEBENCH_RAW`. Skipped when it isn't set. |
| `clean` | Deletes the generated images. |

Tables are printed as Markdown, so they can be pasted into a results file.

## Data directory

Generated images go to `$IMAGEBENCH_DIR/data`. When `IMAGEBENCH_DIR` isn't set, the default is
`$TMPDIR/phocasa-imagebench`. After `gen` and `copies` it holds about 3 GB (201 files of about 15 MB).

**Always run `clean` when you're done.** It removes `$IMAGEBENCH_DIR/data` (use the same `IMAGEBENCH_DIR` you
generated with).

```bash
export IMAGEBENCH_DIR="$TMPDIR/phocasa-imagebench-00"
IB="$TMPDIR/imagebench-00"
(cd Tools/imagebench && swiftc -O -swift-version 5 imagebench.swift -o "$IB")
"$IB" gen && "$IB" copies && "$IB" orient
"$IB" clean
```

## RAW files

`raw` never searches the disk for camera RAW files. Those live in the user's photo folders. It opens exactly one
file, the one named by `$IMAGEBENCH_RAW`, and only reads it (through `CGImageSource` and `CIRAWFilter`). It never writes,
copies or moves it.

- If `IMAGEBENCH_RAW` isn't set, `raw` prints that it was skipped and exits.
- If it names something that isn't a local, readable regular file (including a cloud file that hasn't been
  downloaded), `raw` is skipped too.

Only set `IMAGEBENCH_RAW` to a file the user has explicitly provided for benchmarking.

```bash
IMAGEBENCH_RAW=/path/to/provided/file.ARW "$IB" raw
```
