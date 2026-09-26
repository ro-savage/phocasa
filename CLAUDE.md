# Phocasa — macOS Photo Explorer

## Project Overview

Native macOS photo explorer app for browsing, rating, tagging, and organizing thousands of photos. Built with Swift 6 and SwiftUI, targeting macOS 14.0+ (Sonoma).

## Build & Run

```bash
# Build from CLI (requires Xcode installed)
cd /Users/rowan/www/phocasa/Phocasa
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project Phocasa.xcodeproj -scheme Phocasa -configuration Debug build

# Run the built app
open ~/Library/Developer/Xcode/DerivedData/Phocasa-*/Build/Products/Debug/Phocasa.app

# Or open in Xcode
open Phocasa/Phocasa.xcodeproj

# Tests (the test host uses an in-memory store; see Testing)
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project Phocasa.xcodeproj -scheme Phocasa -destination 'platform=macOS' test

# Gated benchmarks (skipped unless PHOCASA_BENCH=1): DataPathBenchmarks, ThumbnailSchedulerBenchmarks,
# DetailNavigationBenchmarks, ImageEditingServiceBenchmarks, EditViewModelBenchmarks, ThumbnailDiskCacheBenchmarks,
# MetadataSidecarBenchmarks; with PHOCASA_TEST_RAW (a copy of a camera RAW, its JPG beside it) also
# EditRenderSizeBenchmarks, MetadataWriteBenchmarks and FitLookBenchmarks. Each prints `BENCH|…` lines.
TEST_RUNNER_PHOCASA_BENCH=1 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project Phocasa.xcodeproj \
  -scheme Phocasa -destination 'platform=macOS' test -only-testing:PhocasaTests/DataPathBenchmarks
```

`Tools/imagebench/` is a standalone ImageIO/CoreImage benchmark (build with `swiftc -O -swift-version 5 imagebench.swift`;
`gen` and `copies` write about 3 GB of test images, `clean` removes them). It mirrors the app's image code by hand, so
keep it in step. See `Tools/imagebench/README.md`.

## Architecture

- **Pattern:** MVVM. `PhotoLibraryViewModel` is a thin coordinator; the library (`LibraryStore`), the selection
  (`SelectionModel`) and the edit in progress (`EditSession`) are their own `@Observable @MainActor` types, and views
  read them directly (`viewModel.library.…`, `viewModel.selection.…`).
- **Persistence:** SwiftData (SQLite-backed) is the primary store, with IPTC/XMP write-back to files for portability.
- **In-memory library:** the store is fetched once. Filtering, search, sort and sidebar counts run in memory over
  plain-value `PhotoFacts`.
- **Image loading:** ImageIO (`CGImageSource`), which handles all RAW formats. Grid thumbnails go through a bounded,
  newest-first scheduler with memory and disk caches; the detail view decodes on the hardware path and applies EXIF
  orientation at display time.
- **Image editing:** CoreImage + `CIRAWFilter`, non-destructive, rendered on Metal-backed `CIContext`s.
- **Edit renders are sized to the screen.** The session's pass after each slider pause and the detail view's saved
  edit are `ImageEditingService`'s sized render (`maxSize` from `EditRenderSize.fitMaxSize`), filling the detail view
  at fit. They go to native resolution only once the view is zoomed in past them (`ZoomableImageView.onNeedsMorePixels`
  → `EditSession.requestNativeResolution()` / `SavedEditState.needsMorePixels`). An `EditSession` without
  `viewportPixelSize` renders its passes natively. Exports are always native. Don't render edits at native size for
  display.
- **Filter radii are in native pixels.** Sharpness (1.5 px), clarity (20 px) and clarity's blur use radius × the
  render's scale against native (`EditPipeline`, 1 for native renders and exports), so a fitted pass or a preview
  looks like the native render drawn at its size (post-wave-3 task C, `FitLookBenchmarks`). Noise reduction has no
  radius and isn't scaled; `CIRAWFilter`'s own sharpening and noise reduction are its own.
- **No third-party dependencies** — all Apple frameworks

### Project Structure

```
Phocasa/
├── Phocasa.xcodeproj/              — objectVersion 77, synchronized folders (see Build Settings)
├── Phocasa/
│   ├── PhocasaApp.swift            — @main entry, SwiftData container (in-memory in the test host), menu commands
│   ├── AppDelegate.swift           — quit waits for pending metadata writes (at most 5 s)
│   ├── Models/                     — SwiftData models (PhotoAsset, Tag, PhotoLibrary, EditPreset)
│   │                                 + EditParameters struct, NormalizedRect struct; StoreLocation (where the
│   │                                 store lives, and the one-time move of a legacy `default.store`);
│   │                                 LibraryLocation (which store and thumbnail cache a launch uses: the user's,
│   │                                 the test host's in-memory one, or the development library)
│   ├── ViewModels/
│   │   └── PhotoLibraryViewModel   — coordinator: owns LibraryStore, SelectionModel, editSession; UI flags; detail,
│   │                                 delete, selection-wide rating/tagging, editing entry points, presets
│   ├── Library/
│   │   ├── LibraryStore            — the in-memory library: model context, allPhotos/bin + facts, counts, tag
│   │   │                             lists, the grid (`photos`, `index(of:)`), photosDidChange. Extension files:
│   │   │   +Loading                  launch (`open`, a big library loads in the background), loadExistingData,
│   │   │                             file availability
│   │   │   +Scan                     folder opening, serialised scans, waitForScans
│   │   │   +Mutations                rating, tags, bin, deletes (files trashed via FileTrasher), metadata write-back
│   │   │   +ListEditing              in-memory list edits: bin moves, scan inserts/removals, deletes
│   │   │   +Filtering                filters, search, sort toggle, tag lists
│   │   ├── LibrarySort             — THE definition of photo order: capture date, then creation date (fetch,
│   │   │                             key, insertion index, merge, toggle, re-order)
│   │   ├── LibrarySnapshot         — the library as plain values, read in background contexts (launch of a big
│   │   │                             library): order, facts, counts, stored rows
│   │   ├── CaptureDateBackfill     — after launch, fills in missing capture dates and re-orders once
│   │   ├── SelectionModel          — selection, range/select-all, primary photo, grid keyboard navigation
│   │   ├── PhotoQuery              — SidebarFilter, PhotoFacts, pure filtering/search/facet counts
│   │   ├── ScanPlan                — StoredPhoto snapshot (background read) and the pure scan diff
│   │   └── TagParsing              — `Tag.parse(keyword:)`, the inverse of `Tag.fullName`
│   ├── Editing/
│   │   ├── EditSession             — one photo's edit: parameters, renders, comparison, crop, export, save/revert
│   │   ├── RAWEditStore            — RAW edit parameters: saves via MetadataWriter, reads see queued saves
│   │   ├── EditRenderSize          — how large an edit render must be on screen (fit maxSize from viewport, crop,
│   │   │                             rotation)
│   │   └── SavedEdit               — renders the saved edit for the detail view; the session's hand-off;
│   │                                 SavedEditState (fitted render, native on zoom, next photo prefetched)
│   ├── Views/                      — ContentView (keys, search, alerts), MainContentView (grid kept alive under
│   │   │                             the detail view), LibraryToolbar, StatusBarView, SidebarView, PhotoGridView,
│   │   │                             PhotoGridItemView, RatingView, TagEditorView, EditSidebarView, CropOverlayView,
│   │   │                             PhotoDetailView (container)
│   │   └── Detail/                 — DisplayImage (CGImage + orientation), ZoomableImageView (+ZoomPanState),
│   │                                 MinimapView, DetailOverlayControls, ComparisonView
│   └── Services/
│       ├── FolderScanner           — walks a folder, pairs JPG+RAW, reads new photos' metadata concurrently
│       ├── MetadataService         — stateless, thread-safe metadata reads and writes (JPEG splice, sidecars)
│       ├── JPEGStructure, ExifPatch, PhotoshopIRB, XMPProperties — JPEG segments, the in-place Exif patch, APP13
│       │                             resources and IPTC datasets, XMP value comparison (for the two below)
│       ├── ExportMetadata          — carries a photo's original metadata into an export's JPEG
│       ├── CaptureDate             — parses and reads EXIF DateTimeOriginal (subseconds, offset) by hand
│       ├── MetadataWriter          — serial, coalescing writer every metadata write goes through (re-keys cached
│       │                             thumbnails after JPEG metadata rewrites)
│       ├── ImageLoader             — grid thumbnails: size buckets, memory cache, disk cache, invalidation
│       ├── ThumbnailScheduler      — bounded, newest-first, cancellable work scheduler
│       ├── ThumbnailDiskCache      — thumbnails on disk across launches (one JPEG per photo and bucket, LRU)
│       ├── FullImageLoader         — detail-view decodes: subsampled fit, full resolution, prefetch, LRU
│       ├── ImageEditingService     — the edit render pipeline (preview and full lanes)
│       └── FileTrasher             — moves files to the Trash off the main thread
├── PhocasaTests/                   — XCTest; PerformanceBenchmarks.swift holds the gated DataPathBenchmarks
Tools/
├── imagebench/                     — standalone image-path benchmark (see Build & Run)
└── coordinator/                    — the plan coordinator's A/B harness and real-app driver (not in any target)
```

## Key Design Decisions

- **Store location:** the library is `~/Library/Application Support/Phocasa/Phocasa.store` (with its `-wal`, `-shm`
  and `.Phocasa_SUPPORT` external-data folder). Builds before 2026-09-26 left it at SwiftData's default,
  `Application Support/default.store`, which every non-sandboxed app with the default shares. `StoreLocation.prepare`
  moves such a store into the Phocasa folder once, before the container opens (companions first, the store file
  last), only when its metadata names Phocasa's `PhotoAsset` entity; another app's `default.store` is left alone, and
  one whose metadata can't be read is opened where it is.
- **Development library:** a Debug launch with `PHOCASA_DEVELOPMENT_LIBRARY=1` (Release ignores it) keeps its library
  in `Application Support/Phocasa-Development/Phocasa.store` and its thumbnails in `Phocasa-Development/Thumbnails/v1`
  (`PHOCASA_THUMBNAIL_CACHE_DIR` overrides the cache), for real-app checks that relaunch. It never reads, moves or
  opens `Application Support/Phocasa/` or a `default.store` (no legacy move), nor `Caches/com.phocasa.app`.
  `LibraryLocation.resolve` decides the store and the cache for `PhocasaApp` and `ImageLoader.shared` together.
- **JPG+RAW pairing:** Files with the same stem name are combined into one PhotoAsset entry
- **Dual metadata:** the SwiftData DB is the primary store. Ratings and tags are also written back to the files:
  XMP (`xmp:Rating`, `dc:subject`) and IPTC keywords inside JPGs, the `.xmp` sidecar for RAW files (and for files
  that can't take them without losing metadata; see "Metadata"), and both files of a JPG+RAW pair.
- **Tags stored as `category:name`** in keywords to preserve hierarchy in flat keyword lists (`Tag.fullName` /
  `Tag.parse(keyword:)`)
- **Folder access:** Uses SwiftUI `.fileImporter` for folder selection, security-scoped bookmarks for persistent access
- **Menu commands:** Uses SwiftUI `FocusedValues` to communicate between App-level commands and views
- **Data flow:** the library is fetched from the store only by `LibraryStore.loadExistingData()`, the launch's
  background load and scans. UI interactions (filters, search, sort, rating, tags, bin) work on the in-memory library
  and its `PhotoFacts` and must never re-fetch: mutations patch the lists, the grid and the counts in place. Scans and
  deletes patch the in-memory library too (`updateLibrary(adding:facts:removing:)`, `fileTypeDeleteDidFinish`,
  `relocate` in `+ListEditing`) instead of reloading; a scan that finds a full load ran meanwhile
  (`loading.generation`) reloads instead. Code that changes a photo's rating, tags, file paths or file name outside
  `LibraryStore` calls `photosDidChange(_:)`.
- **Photo order:** `LibrarySort` is the only definition of photo order: capture date (`PhotoAsset.captureDate`,
  EXIF `DateTimeOriginal`) falling back to the file creation date, newest first by default, ties broken by creation
  date (`LibrarySort.Key`). The store sorts by `(captureDate, creationDate)` and `fetch(where:in:)` merges the dated and
  undated runs in memory. Fetches, insertion, merges, the toggle and the backfill's re-order all go through it; don't
  sort photos anywhere else, and don't compare `key(of:)` dates yourself (use `sortKey(of:)`/`precedes`).
- **Capture dates:** scans store `found.metadata?.captureDate` at both insert sites. After launch (2 s after the launch
  scans) `CaptureDateBackfill` reads the dates of rows that have none, off the main actor, writes them on the main
  context in chunks of about 12 ms, and re-orders the in-memory library once (no reload). Rows without a date are
  re-read on each launch, in the background; empty files (`fileSize == 0`) are skipped.
- **Launch:** `LibraryStore.open` loads a store of more than 500 photos in the background, as the first job of the scan
  queue (`isScanning` is true, and `waitForScans()` waits for it). `LibrarySnapshot` is read off the main actor while
  the main actor fetches the rows as models, 400 per turn (the grid needs filled-in models; each turn stays under a
  frame). The library then appears whole in one turn, and the launch rescan, queued behind it, reuses the snapshot's
  rows and a walk started at launch. Smaller stores load synchronously; `loadExistingData()` stays synchronous; a full
  load since `open` drops the background load.
- **Bin:** a scan never takes a photo out of the bin (user decision); it still updates a binned photo's paths and size.
- **Scans:** run one at a time (`scanFolder` queues requests; the latest folder wins). The walk, the read of the stored
  rows, the diff and the metadata reads run off the main actor; the main actor only writes changed fields and inserts
  photos, so an unchanged rescan writes nothing and changes nothing in memory. One that adds k photos costs
  O(k log n) on the main actor, or one merge for many.
- **Thumbnail disk cache** (`Services/ThumbnailDiskCache.swift`): one JPEG per photo and size bucket under
  `Caches/<bundle id>/Thumbnails/v1/<h0h1>/<sha256(path)>/<bucket>-<size>-<mtime>.jpg`, LRU by mtime, 1 GB. The test
  host has none unless `PHOCASA_THUMBNAIL_CACHE_DIR` is set.
- **Grid under the detail view:** `MainContentView` keeps the grid in the hierarchy, hidden, while the detail view is
  open, so it keeps its scroll position; its cells start no thumbnail loads meanwhile.
- **Edit parameters:** stored as JSON-encoded `EditParameters` — in SwiftData for JPGs, in the XMP sidecar
  (`phocasa:EditParameters`, base64) for RAW files. Editing state lives in an `EditSession` that exists only while
  editing; RAW edit parameters are written only through `RAWEditStore` → `MetadataWriter`.

## Development Rules

### Always use SwiftUI first

**This is critical.** Always look for SwiftUI-native APIs before reaching for AppKit or older patterns:

- Use `.fileImporter` / `.fileExporter` instead of `NSOpenPanel` / `NSSavePanel`
- Use `.alert` / `.confirmationDialog` instead of `NSAlert`
- Use `.onKeyPress` instead of `NSEvent` key monitoring
- Use `FocusedValues` / `.focusedSceneValue` instead of `NotificationCenter` for menu command → view communication
- Use `@Observable` instead of `ObservableObject` + `@Published`
- Use SwiftData instead of Core Data
- Use `NavigationSplitView` / `NavigationStack` instead of `NSSplitViewController`
- Use `.searchable` instead of custom search fields
- Use `.toolbar` instead of `NSToolbar`
- Use `.popover` / `.sheet` instead of `NSPopover` / `NSPanel`
- Use `AsyncImage` patterns / `.task` instead of manual GCD image loading where possible

If a SwiftUI equivalent doesn't exist, then AppKit is fine — but verify first.

**Known AppKit exceptions** (no SwiftUI equivalent exists):
- `NSEvent.modifierFlags` for checking Cmd/Shift on tap gestures (SwiftUI `onTapGesture` doesn't expose modifiers)
- `NSEvent.addLocalMonitorForEvents(.scrollWheel)` for pinch-to-zoom in detail view
- `NSCursor.pointingHand.push()/.pop()` for sidebar hover cursors
- `NSApp.currentEvent?.clickCount` in `RatingView`, so a double-click on the stars rates once (SwiftUI tap gestures
  don't expose the click count)
- `@NSApplicationDelegateAdaptor` with `applicationShouldTerminate` → `.terminateLater`, so quit waits for pending
  metadata writes (SwiftUI has no termination hook on macOS; `scenePhase` doesn't report quitting)

### Swift 6 Concurrency

- The project uses Swift 6 with `SWIFT_STRICT_CONCURRENCY = minimal` (relaxed, but code should be concurrency-safe)
- View models and the library, selection and edit-session types are `@MainActor`
- Stateless services (FolderScanner, MetadataService) conform to `Sendable`; `MetadataService.readMetadata` is called
  from `DispatchQueue.concurrentPerform` during scans, so it must stay stateless and thread-safe
- Serial work is an `actor` on its own `DispatchSerialQueue` executor (`unownedExecutor`): `MetadataWriter`,
  `FileTrasher`, and `ImageEditingService`'s two render lanes (`.preview` and `.full`, each with its own queue,
  `CIContext` and `CIRAWFilter` cache; the service itself is an actor that routes to them). Prefer this over
  `withCheckedContinuation` + queue wrappers for new code.
- `ThumbnailScheduler` is bounded (active core count), newest first (LIFO) and cancellable: a cancelled caller is
  resumed at once, and work nobody waits for any more is dropped before it starts
- `ImageLoader`, `FullImageLoader`, `ThumbnailScheduler` and `ThumbnailDiskCache` are `@unchecked Sendable` and
  synchronise with locks (`NSLock`); `ThumbnailDiskCache` writes on its own utility queue
- **Metadata writes go only through `MetadataWriter`:** serial, coalescing per file (a newer payload replaces a
  waiting one), with a synchronous `enqueue` / `enqueueEditParameters` that never blocks and an async `flush()`. A
  pair's item writes the JPG and the RAW's sidecar.
- One-off background reads use `withCheckedContinuation` + `DispatchQueue.global()` (the scan's `StoredPhoto` read,
  `FolderScanner`, `FullImageLoader`)
- Don't use `FileManager.enumerator` `for-in` loops in async contexts — use `nextObject()` in a sync wrapper
- Module-level free functions (`captureFileDates`, `restoreFileDates`) are used for shared utilities across services

### SwiftData

- **Background contexts:** a background `ModelContext` may read, and may insert rows that have no relationships. It
  must never change, or link to, a row the main context may hold (the main context's later save loses those links).
  Scans insert photos without keywords through a background context and photos with keywords on the main actor.
- The bin flag is `PhotoAsset.isInBin`, stored with `@Attribute(originalName: "isDeleted")` (task 31: the old name
  collided with SwiftData's own `PersistentModel.isDeleted`, spec §H5, so saves of binned rows wrote it back as false).
  Never name a stored property after a `PersistentModel` / `NSManagedObject` member (`isDeleted`, `isInserted`,
  `isUpdated`, `hasChanges`, `isFault`, `objectID`, `entity`, `modelContext`). `photo.isDeleted` still compiles, but it
  is SwiftData's "deleted from the context" flag, and `#Predicate { $0.isDeleted }` crashes at fetch time.
- **Schema changes** migrate the user's library in place at launch, by SwiftData's automatic lightweight migration
  (there is no `SchemaMigrationPlan`): new attributes must be optional or have a default value, and renames use
  `@Attribute(originalName:)`. `MigrationTests` keeps the models as they were before task 31 (`PhocasaSchemaV1`, never
  edit it) and opens a V1 store with the live models; extend it for every schema change. If a change can't be
  inferred, move `PhocasaSchemaV1` into `Models/`, add a V2 for the live models and pass `migrationPlan:` in
  `PhocasaApp` (keep the in-memory test-host branch).
- Every `PhotoAsset` attribute costs every fetch and save: one `Date?` measured +2–4% on the fetch-bound benchmarks at
  10k. Measure before adding one.
- **A `ModelContext` doesn't keep its container alive,** and reading `context.container` once the container is gone
  traps. The app's container lives as long as the app. Work that runs later against a stored context (a delayed task)
  holds the container weakly and gives up if it's gone (see `backfillCaptureDatesAfterScans`).
- A main-context save costs about 7 ms at 10k loaded photos however few rows it writes, plus about 0.13 ms per row.
  Bulk writes on the main context go in chunks sized by time, with a pause between them (see `CaptureDateBackfill`).
- `StoreLocation` reads a store's metadata with Core Data's `NSPersistentStoreCoordinator.metadataForPersistentStore`
  (SwiftData has no API to read a store without opening, and so migrating, it). That's the only Core Data use.
- A store's SQLite files change whenever SQLite checkpoints, which SwiftData does when it likes, even after its
  container is released. Tests check a store's contents by opening it, never by comparing its files' bytes.

### Metadata

- **Never lose a photo's original metadata (user rule, 2026-09-26).** Phocasa never removes, rewrites or drops the
  metadata a file came with: the camera's Exif (including MakerNote and GPS), IPTC and XMP. It only adds to it (new
  XMP/IPTC spliced in) or writes a sidecar. A write that can't keep the original metadata must not happen: the change
  goes to a sidecar instead. Losing original metadata is a major bug.
- **Rating and keyword writes** (`MetadataService.writeMetadata`, via `MetadataWriter`):
  - a JPEG gets its own XMP packet with just `xmp:Rating` and `dc:subject` changed (`xmpPacket`; never ImageIO's
    merged rewrite, which overwrites XMP values that disagree with the Exif) and its IPTC keywords patched into its
    APP13 (`PhotoshopIRB`: only the 2:25 datasets change, every other resource and dataset stays byte for byte, the
    digest is updated), both spliced into the original bytes. Everything else, MakerNote and MPF included, is
    byte-identical. Writes go through a temp file and `replaceItemAt`;
  - a JPEG the splice can't handle (odd layout, several XMP/APP13 segments, extended XMP, an XMP packet ImageIO can't
    parse or re-serialise without changing a value, IPTC text of unknown encoding), and every PNG, TIFF and HEIC
    (whose only writer is ImageIO's lossy rewrite), keeps its bytes: the values go to its `.xmp` sidecar with
    `phocasa:OverridesEmbedded`, and `readMetadata` then takes that sidecar's rating and keywords as they are (0 and
    none included), for the file and for a pair's RAW. A file whose sidecar has the flag stays in the sidecar.
- Sidecars are updated in place, never rewritten wholesale: only Phocasa's fields change, and everything other apps
  wrote is kept (an update that would lose or change another value is refused). A sidecar that can't be parsed safely
  is skipped, left byte-identical.
- **Exports and baked edits** ("Apply Edits to x.jpg…", "Replace x.jpg…", "Save as New JPG") carry
  the original metadata into the new JPEG (`ExportMetadata`), then get Phocasa's rating and keywords like any rating
  write. The source: the JPG being overwritten, read before it's replaced; for a new `-raw-edit` file, the pair's
  camera JPG, else the RAW; for a new `-edit` file, the photo's own file.
- **What an export may overwrite:** only a JPEG by its bytes (`ImageEditingService.isJPEGFile`; a HEIC, PNG or TIFF,
  whatever its name, is never replaced: `ExportDestination.replacing` refuses with `.notAJPEG`), and only once a copy
  of it is in the Trash (put there with the library's `fileTrasher`; if that fails, `.originalNotTrashed` and nothing
  is written). The dialog offers "Replace…" / "Apply Edits…" only for such files, and asks again. "Save as New JPG"
  (`.newFile`) never overwrites: it takes the first free `<stem>-raw-edit[-n].jpg` (`-edit` from a non-RAW file) that
  no file in the folder and no library row has, leaves the photo's own paths alone, and adds the export to the library
  as a photo of its own (`LibraryStore.addExportedPhoto`, the key a scan would give it) with the photo's rating, tags
  and capture date.
- **Presets are a look only** (`EditParameters.look`): no crop, rotation or flips when saved, and applying one keeps
  each photo's own transform (`applyingLook(of:)`), old presets included. From a JPEG every APPn and COM segment is carried over byte for byte, in order, around the
  new image data; from a RAW, ImageIO's metadata tree (it has no MakerNote to write). **The exceptions**, which
  describe the old pixels and change to match the new ones: orientation (1), pixel dimensions, `ColorSpace` and an
  Adobe RGB `InteropIndex`, the same properties in the XMP (plus `photoshop:ICCProfile`, `xmp:Thumbnails` and the
  XMP describing data appended after the image, a motion photo's video or an Ultra HDR gain map, removed); the Exif
  IFD1 thumbnail (unlinked, its bytes zeroed unless they overlap the MakerNote), MPF preview images,
  the ICC profile, Adobe APP14 segment and Apple restart-offset table (APP10 `AROT`; the encoder's describe the new
  pixels), JFIF and JFXX thumbnails and
  Photoshop thumbnail resources (0x0409, 0x040C). From a RAW, also the tags of its own pixel encoding
  (`Compression`, `CFAPattern`, …). The MakerNote is never changed. If the metadata can't be carried over whole,
  nothing is written (`ExportResult.metadataNotKept`, shown in an alert; a new `-raw-edit` file falls back to the
  RAW's metadata). Exports replace the file on `MetadataWriter`'s queue (`runExclusively`), so no rating write can
  interleave.
- Capture dates come from the metadata tree `readMetadata` already copies: ImageIO shows `DateTimeOriginal` as
  `photoshop:DateCreated` (ISO 8601, subseconds merged in) and the offset as `exif:OffsetTimeOriginal`. No offset means
  local time, in the time zone current when the file is read. Parse by hand (`CaptureDate`), never with
  `DateFormatter`.

### Thumbnail cache

- **Re-key rule:** rating and keyword writes into an image file go through `MetadataWriter` (never call
  `MetadataService.writeMetadata` directly). It runs each one inside `MetadataRewriteObserver`
  (`MetadataWriter.shared` → `ImageLoader.shared`), which renames the photo's cached thumbnails to the file's new size,
  because the pixels didn't change. Anything that changes a file's pixels (exports, "apply permanently") must call
  `ImageLoader.shared.invalidate(path:)`, and must never go through that hook or call `ThumbnailDiskCache.rekey`.
  The re-key needs metadata writes to restore the file's modification date (to within 10 µs), as
  `restoreFileDates` does.
- **Bucket reuse:** a thumbnail request is served from its bucket or one up to 2× larger: in memory as is, on disk
  decoded down to the requested size (nothing new is stored).
- **Byte total:** the disk cache keeps its running byte total in `<cache dir>/byte-total`, updated on every change.
  It is trusted on launch if intact and a full scan confirmed it within 7 days; otherwise the first trim rescans.
  Deleting the file forces a rescan. One `ThumbnailDiskCache` instance per directory.

### Testing

- `MigrationTests` and `BinFlagTests` use temp store files they delete; never point a test at the real store.
- `library.loading.backgroundLoadThreshold` (and `pageSize`) put small test stores on the background launch path.
- Test hooks stored on a `LibraryStore` (`scanWillSave`, `loading.backgroundLoadDidApply`,
  `captureDates.didApplyChunk`) capture their view model or library `[unowned]`/`[weak]`: a strong capture is a retain
  cycle that keeps the library alive after the test, and its after-launch work then runs against a released
  container.
- Hosted-window tests (`GridKeepAliveTests`) need the display awake: run `xcodebuild test` under `caffeinate -d -u`.
- The test host (`XCTestConfigurationFilePath` set) uses an in-memory SwiftData store, and `ImageLoader.shared` has no
  disk cache unless `PHOCASA_THUMBNAIL_CACHE_DIR` names a folder (pass `TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR`).
  Tests must never open or modify anything under `~/Library/Application Support` (the user's real library) or write to
  `~/Library/Caches/com.phocasa.app`. `StoreLocationTests` pass a temp folder in place of Application Support.
- The test host stays in memory even with `PHOCASA_DEVELOPMENT_LIBRARY=1` (the scheme's Test action shares the Run
  action's environment). Development-library tests pass temp folders to `LibraryLocation.resolve`.
- Tests use temp directories and in-memory or temp-file stores. Tests that delete files give `LibraryStore` a
  `FileTrasher` that moves them into a temp folder, never the user's Trash.
- Gated benchmarks need `PHOCASA_BENCH=1` (see Build & Run); tests on a real camera RAW are skipped unless
  `PHOCASA_TEST_RAW` names a *copy* of one. Never search the disk for photos.
- Hosted-window tests (grid clicks, the detail view, the grid under the detail view) flash a window; that's expected.

### Build Settings

- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = minimal`
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- App Sandbox OFF, Hardened Runtime ON (Release only)
- The project is objectVersion 77 with synchronized folders: any file under `Phocasa/Phocasa/` or
  `Phocasa/PhocasaTests/` is built into its target automatically. Never hand-edit `project.pbxproj` to add files.
