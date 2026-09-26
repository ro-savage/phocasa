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
│   ├── AppDelegate.swift           — quit saves open edit sessions (`PhotoLibraryViewModel.saveEditsBeforeQuit`),
│   │                                 then waits for pending metadata writes (at most 5 s, then journals the rest);
│   │                                 launch replays the journal
│   ├── Models/                     — SwiftData models (PhotoAsset, Tag, PhotoLibrary, EditPreset)
│   │                                 + EditParameters struct, NormalizedRect struct; StoreLocation (where the
│   │                                 store lives, and the one-time move of a legacy `default.store`);
│   │                                 LibraryLocation (which store and thumbnail cache a launch uses: the user's,
│   │                                 the test host's in-memory one, or the development library); LibraryLaunch
│   │                                 (lock, legacy move, backup, open), LibraryLock, StoreBackup
│   ├── ViewModels/
│   │   └── PhotoLibraryViewModel   — coordinator: owns LibraryStore, SelectionModel, editSession; UI flags; detail,
│   │                                 delete, selection-wide rating/tagging, editing entry points, presets
│   ├── Library/
│   │   ├── LibraryStore            — the in-memory library: model context, allPhotos/bin + facts, counts, tag
│   │   │                             lists, the grid (`photos`, `index(of:)`), photosDidChange. Extension files:
│   │   │   +Loading                  launch (`open`, a big library loads in the background), loadExistingData,
│   │   │                             file availability
│   │   │   +Scan                     folder opening, the scan queue (every library folder), waitForScans
│   │   │   +Folders                  the library folders: the list, where each is now (bookmark, renamed volume),
│   │   │                             removing one
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
│   │   ├── ScanPlan                — StoredPhoto snapshot (background read) and the pure scan diff: updates, relinks
│   │   │                             of moved photos, new photos, the missing set of the folder's rows
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
│   │   │                             PhotoDetailView (container), LibraryUnavailableView (library locked or unopenable),
│   │   │                             LibraryFoldersSection (the sidebar's library folders)
│   │   └── Detail/                 — DisplayImage (CGImage + orientation), ZoomableImageView (+ZoomPanState),
│   │                                 MinimapView, DetailOverlayControls, ComparisonView
│   └── Services/
│       ├── FolderScanner           — walks a folder, pairs JPG+RAW, reads new photos' metadata concurrently
│       ├── MetadataService         — stateless, thread-safe metadata reads and writes (in-file writes by format,
│       │                             the shared packet update, sidecars, leaving sidecar mode)
│       ├── JPEGStructure, MPFIndex, ExifPatch, PhotoshopIRB, XMPProperties, XMPTextEdit — JPEG segments, the MPF
│       │                             entries' patch, the in-place Exif patch, APP13 resources and IPTC datasets, XMP
│       │                             value comparison, the XMP text edit and its independent XML reading
│       ├── PNGMetadata, TIFFMetadata, HEIFMetadata — the XMP (and TIFF IPTC) inside PNG chunks, TIFF IFD0, HEIF items
│       ├── ExportMetadata          — carries a photo's original metadata into an export's JPEG
│       ├── CaptureDate             — parses and reads EXIF DateTimeOriginal (subseconds, offset) by hand
│       ├── MetadataWriter          — serial, coalescing writer every metadata write goes through (re-keys cached
│       │                             thumbnails after JPEG metadata rewrites)
│       ├── MetadataWriteJournal    — the writes not made yet, on disk next to the store; MetadataWriteProgress
│       ├── VolumeCheck             — a missing file: gone, or on a drive that isn't connected (`/Volumes/<name>`)
│       ├── ImageLoader             — grid thumbnails: size buckets, memory cache, disk cache, invalidation
│       ├── ThumbnailScheduler      — bounded, newest-first, cancellable work scheduler
│       ├── ThumbnailDiskCache      — thumbnails on disk across launches (one JPEG per photo and bucket, LRU)
│       ├── FullImageLoader         — detail-view decodes: subsampled fit, full resolution, prefetch, LRU
│       ├── ImageEditingService     — the edit render pipeline (preview and full lanes)
│       └── FileTrasher             — moves files to the Trash off the main thread, and says what happened to each
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
- **Launch order** (`LibraryLaunch.open`, once per process): lock the library's folder (`LibraryLock`: a `flock` on
  `Phocasa.lock`, held for the process's life; a second Phocasa on the same library, such as a Debug build beside the
  installed app, opens, moves and backs up nothing and says who has it open), then the legacy move, then the backup,
  then open the store. A store that doesn't open (damaged, or a migration that can't be inferred) is never deleted,
  moved or overwritten: the window says where it is, that nothing changed and where the backups are
  (`LibraryUnavailableView`), instead of crashing. SwiftData renames and removes nothing on a failed open, but SQLite
  rewrites the `-shm`, so a file without SQLite's header isn't handed to it. The in-memory test host takes no lock.
- **Backups** (`StoreBackup`): at launch, with no process holding the SQLite files, the store, its `-wal`, `-shm` and
  `.Phocasa_SUPPORT` are copied (APFS clones) into `Backups/<yyyy-MM-dd-HHmmss>/` in the library's folder
  (`Application Support/Phocasa/Backups/`, or the development library's own), at most once a day, through a hidden
  `.partial` folder so an interrupted copy never looks complete. Only a launch that opened the store prunes, to the
  newest 5, so failing launches never push out the good copies. A failed copy is logged and the launch goes on; the
  live store is only ever read. Never backed up: a `default.store` still opened in place (it may be another app's).
  **Restoring:** quit Phocasa, move `Phocasa.store`, `-wal`, `-shm` and `.Phocasa_SUPPORT` out of the library's
  folder, and copy the backup's files in their place.
- **One window, one library:** the app's only scene is a `Window` (no New Window, no tabs), and `PhocasaApp` owns the
  `PhotoLibraryViewModel`; `setModelContext` is a no-op for the context it already has. A `WindowGroup` built a
  library per window on the same store: a second scan beside the first inserted every photo twice. Closing the
  window quits the app (a `Window` primary scene does), through `AppDelegate`'s quit path.
- **Development library:** a Debug launch with `PHOCASA_DEVELOPMENT_LIBRARY=1` (Release ignores it) keeps its library
  in `Application Support/Phocasa-Development/Phocasa.store` and its thumbnails in `Phocasa-Development/Thumbnails/v1`
  (`PHOCASA_THUMBNAIL_CACHE_DIR` overrides the cache), for real-app checks that relaunch. It never reads, moves or
  opens `Application Support/Phocasa/` or a `default.store` (no legacy move), nor `Caches/com.phocasa.app`.
  `LibraryLocation.resolve` decides the store and the cache for `PhocasaApp` and `ImageLoader.shared` together.
- **JPG+RAW pairing:** Files with the same stem name are combined into one PhotoAsset entry. A photo's identity is its
  path (`folderPath/stem`, `DiscoveredPhoto.key`); a scan that finds a stored photo's files elsewhere relinks the row
  (see "Moved photos") rather than adding the photo again.
- **Dual metadata:** the SwiftData DB is the primary store. Ratings and tags are also written back to the files:
  inside every non-RAW file (JPEG, PNG, TIFF, HEIC/HEIF: XMP `xmp:Rating`, `dc:subject`, and IPTC keywords where the
  file has IPTC), the `.xmp` sidecar for RAW files (and, as the last resort, for a file that can't take them without
  losing metadata; see "Metadata"), and both files of a JPG+RAW pair.
- **Tags stored as `category:name`** in keywords to preserve hierarchy in flat keyword lists (`Tag.fullName` /
  `Tag.parse(keyword:)`)
- **Folder access:** Uses SwiftUI `.fileImporter` for folder selection, security-scoped bookmarks for persistent access
  (and to find a library folder that moved; resolved `.withoutUI, .withoutMounting`)
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
- **Capture dates:** scans store `found.metadata?.captureDate` at both insert sites (`ScanPlan.newRow(for:)`, which
  also sets `hasRawEdits` for a RAW whose sidecar holds a saved edit). After launch (2 s after the launch
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
- **Deletes change only what reached the Trash:** `FileTrasher` reports each file (trashed, already gone, volume not
  mounted, failed with a reason). A photo whose file couldn't be moved, or whose drive isn't connected, stays (in the
  bin, less the files that went); `deleteProblem` says how many and why (an alert).
- **The detail view acts on the photo on screen**, never on the hidden grid's selection: ⌫ and the toolbar
  (`deleteSelectionOrCurrent`, `restoreSelectionOrCurrent`), ratings, the tag popover (`tagEditorEditsSelection`); then
  it moves to the next photo (`moveDetailOff`). ⌘A and Return do nothing there. A photo that left the grid (rated out
  of the filter) keeps its place (`LibraryStore.gridPlace(of:)`), which ←/→ and the grid's arrows move on from.
- **Deletes that trash files ask first:** with the RAW or JPG filter on, a delete takes that file off each pair
  (`FileTypeDelete`, confirmed; a RAW's `.xmp` goes with it unless the JPG's values live there, `OverridesEmbedded`).
- **Scans:** run one at a time, one library folder each (`queueScan(of:)`: every folder asked for is scanned in turn; a
  request for a folder already waiting joins it). The walk, the read of the stored rows, the diff, the match of moved
  photos and the metadata reads run off the main actor; the main actor only writes changed fields, relinks and
  inserts photos (a chunk a turn), so an unchanged rescan writes nothing and changes nothing in memory. One that adds
  k photos costs O(k log n) on the main actor, or one merge for many. A scan checks (stats) only its own folder's rows
  and rows under no library folder; the other folders' rows keep their missing state (`ScanPlan.missingSet(after:)`).
- **Library folders:** every folder the owner opens is a library folder (a `PhotoLibrary` row each, no schema change;
  `LibraryStore.libraryFolders`, sorted by path; `currentLibrary` is the first). Rescan and launch scan each
  (`rescanCurrentLibrary()`). Opening a folder that is, or is inside, a library folder scans that one; opening one
  above library folders replaces them (their photos' paths are inside it). The sidebar lists them
  (`LibraryFoldersSection`: a mark for one that isn't there, `folderIssues`; Rescan, Show in Finder, "Remove from
  Library…"). Removing one (confirmed, never while a scan or a delete runs, on the scan queue) deletes its photos' rows
  (library, bin and missing ones, not another library folder's) from the store and memory, a chunk a turn, then the
  folder row; files are never touched. Stores from before this kept one folder: photos of folders opened earlier
  are under no library folder until that folder is opened again (their rows are matched by path, no duplicates).
- **Moved photos** (`ScanPlan.relinks`, REL-5): before inserting a "new" photo, a scan looks for a stored row that is
  the same photo whose files are gone (in the library, the bin, hidden, under any folder), and points it at the files
  found (paths, folder, name, size), keeping its rating, tags, edits, bin state and dates. Strongest first: (a) the
  library folder moved (`LibraryStore.location(of:)`: its recorded path is gone and its bookmark finds it elsewhere,
  not in a Trash; or Open Folder chose it there, found by its bookmark or as the same path on its drive mounted as
  "Name 1", `VolumeCheck.isSameFolderOnRenamedVolume`): the same path inside it; then the folder is recorded there.
  (b) After the metadata read: the same file names (JPG and RAW) and capture date; a row stored without a capture date
  needs the same size and creation date instead (size isn't asked otherwise: an in-file rating write changes it, and
  the row keeps the old size until a rescan). Only one-to-one matches relink: ambiguous ones insert as before. Renamed
  files aren't matched. A recorded path that exists wins over the bookmark (a same-named backup drive there). A
  metadata write waiting in the journal for a photo's old path isn't moved to the new one.
- **What a scan walks:** not hidden files, not package insides (`.skipsPackageDescendants`), not other apps'
  libraries by extension (`.photoslibrary`, `.lrdata`, …) nor NAS/Windows thumbnail, recycle and snapshot folders by
  name (`FolderScanner.skippedFolderExtensions` / `skippedFolderNames`, each with its reason). The chosen folder itself
  is scanned whatever its name. Rows imported from inside such folders by older builds are hidden by the plan.
- **A store read that fails is never an empty library:** `StoredPhoto.fetchAll`, `LibrarySort.fetch` and
  `LibrarySnapshot.read` throw (`fetchCount` answers `NSNotFound` for an unreadable store). A scan that can't read the
  rows stops before inserting (`scanIssue`, in the status bar); a load that fails keeps what's shown and sets
  `libraryReadFailure` (the grid says so). Don't reintroduce `(try? fetch) ?? []` on a path that feeds a diff or a load.
- **A library folder that isn't there** (drive unplugged, folder moved) isn't walked or diffed: nothing is added,
  changed or found missing, and the other folders still scan. Its photos are hidden (by stored path, no stat) until a
  Rescan finds it; the sidebar marks it (`folderIssues`), the status bar says so (`scanIssue`, the first such folder
  after a scan that went through), and an empty grid says "“Photos” isn't connected" or "can't be found" with the
  path. There's no volume-mount watcher: Rescan brings it back.
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
  pair's item writes the JPG and the RAW's sidecar. What it hasn't written is in its journal
  (`Application Support/Phocasa/PendingMetadataWrites.jsonl`, or the development library's folder; none in the test
  host), saved on take-in and about once a second, and replayed first at launch (`resumeJournaledWrites()`). A write
  for a file on an unmounted volume waits in the journal (`retryWaitingWrites()` after a scan) instead of failing.
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
- **Ratings and keywords go inside every non-RAW file, only ever added (user rule, 2026-09-26, task D)**, so other
  apps can read them; RAW files (DNG included) are never written, their values go to the `.xmp` sidecar beside them.
  `MetadataService.writeMetadata` (always via `MetadataWriter`) → `writeToImageFile` → `fileWritingRatingAndKeywords`,
  which picks the format from the file's bytes, not its name. Only Phocasa's fields change: `xmp:Rating`, `dc:subject`
  and the IPTC keywords (2:25, with the IPTC digest); every other byte of metadata stays. Writes go through a temp file
  and `replaceItemAt`, restore the file dates, and are skipped when the new bytes equal the old.
  - **The packet** (`updatedXMPPacket`, shared by every format): none → a new one from ImageIO; else a **text edit**
    (`XMPTextEdit`: the two values changed where they are, or added in an `rdf:Description` of their own, checked by
    an independent XML reading, `XMPPacketScan`); else ImageIO's rewrite, accepted only when both ImageIO and that
    independent reading find every other value (ImageIO's parse and serialise alone silently drop empty values,
    qualifiers, `rdf:nodeID`, datatypes, literal XML, and rename aliases). A packet that already holds exactly the
    values is kept byte for byte. Never ImageIO's merged file rewrite, which overwrites XMP that disagrees with the Exif.
  - **JPEG:** the last standard XMP segment (a new one after the leading JFIF/Exif segments), the APP13's 2:25 datasets
    and digest (`PhotoshopIRB`, only with exactly one APP13 whose IIM can hold them; else XMP only, as MWG allows when
    the digest matches or is absent, clearing with an empty `dc:subject` so the IIM can't show through), and the MPF
    entries' first-image size and secondary-image offsets (`MPFIndex`). Fill bytes, extended XMP, other XMP segments,
    Exif with its MakerNote, ICC, the image data and the previews stay byte-identical.
  - **PNG** (`PNGMetadata`): the `iTXt` `XML:com.adobe.xmp` chunk, updated where it is (header and compression kept),
    or a new one before the first `IDAT` (moved there if it was after, where ImageIO doesn't read it); ImageMagick's
    raw XMP profile is updated in its own form. Every other chunk and byte stays; every CRC is checked, in and out.
  - **TIFF** (`TIFFMetadata`): IFD0's tag 700 and its IPTC (33723, 34377), overwritten in place when they fit
    (padded), else appended with a copy of IFD0 and the header repointed. No existing byte moves; the old IFD0 and
    values stay in the file unreferenced. Growth over repeated writes is bounded (slack).
  - **HEIC/HEIF** (`HEIFMetadata`): the primary's XMP item, in place when it fits (padded), else at the end of the file
    (only its `iloc` entry changes); a file without one gets a new `infe`/`cdsc`/`iloc` entry, with every offset past
    `meta` shifted. It proves every original item's bytes reachable and identical before returning.
  - **Checked before any file is replaced:** the format's own self-check, then ImageIO must read the new bytes as a
    complete image with the new values and every property the original had (`image(_:keepsEverythingIn:reading:_:)`;
    JPEG: `jpeg(_:readsBack:)`).
  - **The last resort** (the file keeps its bytes; the values go to its `.xmp` sidecar with
    `phocasa:OverridesEmbedded`), each named in code and tested: damaged or non-standard structure (standalone markers
    or fill bytes before the XMP in a JPEG header, bytes between segments, a bad PNG CRC, a TIFF IFD out of bounds or
    looping, a HEIF box it doesn't know, e.g. image sequences, bursts and motion photos); XMP that isn't well-formed
    or has a DTD, or that no technique can show kept whole; a JPEG packet over 65,502 bytes; extended XMP holding the
    rating or keywords; BigTIFF; TIFF IPTC that can't be patched (non-ASCII keywords over text of unknown encoding;
    JPEG writes the XMP only there). `MetadataJPEGLayoutTests`, `PNGMetadataTests`, `TIFFMetadataTests`,
    `HEIFMetadataTests` list them all.
- **Leaving sidecar mode:** builds from `2f2fe1b` put every PNG, TIFF, HEIC and odd JPEG's values in a flagged sidecar.
  The next write puts them in the file: the sidecar takes the new values first (still flagged), then the file is
  written, then the flag is cleared, so a reader never sees an older value win; if the sidecar can't be updated,
  neither is written. A user's sidecar is never deleted: any existing sidecar of a non-RAW file follows each in-file
  write (same values, no flag).
- **Reading** (`readMetadata(from:pairedWithRAW:)`): a flagged sidecar wins as it is; a non-RAW file on its own (no RAW
  beside it) that holds an `xmp:Rating` is read from the file, so a stale sidecar never hides newer values in it; a
  RAW, a pair's JPG and a file without a rating of its own take a non-zero sidecar rating and non-empty sidecar
  keywords (a pair's JPG reads the RAW's sidecar first). The scanner says which photos are pairs.
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
  is written). The dialog offers "Replace…" / "Apply Edits…" only for such files, and asks again. Replacing the camera
  JPG with the RAW render clears the photo's saved JPG edit (made for the old pixels). "Save as New JPG"
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
  Tests must never open or modify anything under `~/Library/Application Support` (the user's real library;
  `LibraryLaunchTests`, `StoreBackupTests` and `LibraryLockTests` use temp folders) or write to
  `~/Library/Caches/com.phocasa.app`. `StoreLocationTests` pass a temp folder in place of Application Support.
- The test host stays in memory even with `PHOCASA_DEVELOPMENT_LIBRARY=1` (the scheme's Test action shares the Run
  action's environment). Development-library tests pass temp folders to `LibraryLocation.resolve`.
- Tests use temp directories and in-memory or temp-file stores. Tests that delete files, or export over one (a copy
  of the original goes to the Trash), give `LibraryStore` a `FileTrasher` that moves them into a temp folder, never
  the user's Trash. In the test host the default (`LibraryStore.defaultFileTrasher`) trashes nothing.
- A drive that isn't connected is a temp folder passed as `VolumeCheck(volumesDirectory:)` (to `LibraryStore.volumes`,
  `FileTrasher`, `MetadataWriter`) with the "drive" folder removed. A store that can't be read is a temp store whose
  files are moved aside under an open container (`ScanTests.breakStore`); SQLite won't reopen them for a new container
  while that one lives.
- Gated benchmarks need `PHOCASA_BENCH=1` (see Build & Run); tests on a real camera RAW are skipped unless
  `PHOCASA_TEST_RAW` names a *copy* of one. Never search the disk for photos.
- Hosted-window tests (grid clicks, the detail view, the grid under the detail view) flash a window; that's expected.
- Moved photos and library folders (`ScanRelinkTests`, `LibraryFolderTests`) share `LibraryScanTestCase`: temp folders,
  temp stores, JPEGs with capture dates. A renamed library folder or a remounted drive is a temp folder renamed (the
  bookmark follows it); "Photo Drive 1" is a folder in a temp `VolumeCheck(volumesDirectory:)`.

### Build Settings

- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = minimal`
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- App Sandbox OFF, Hardened Runtime ON (Release only)
- The project is objectVersion 77 with synchronized folders: any file under `Phocasa/Phocasa/` or
  `Phocasa/PhocasaTests/` is built into its target automatically. Never hand-edit `project.pbxproj` to add files.
