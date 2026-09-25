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
# MetadataSidecarBenchmarks. Each prints `BENCH|…` lines.
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
- **No third-party dependencies** — all Apple frameworks

### Project Structure

```
Phocasa/
├── Phocasa.xcodeproj/              — objectVersion 77, synchronized folders (see Build Settings)
├── Phocasa/
│   ├── PhocasaApp.swift            — @main entry, SwiftData container (in-memory in the test host), menu commands
│   ├── AppDelegate.swift           — quit waits for pending metadata writes (at most 5 s)
│   ├── Models/                     — SwiftData models (PhotoAsset, Tag, PhotoLibrary, EditPreset)
│   │                                 + EditParameters struct, NormalizedRect struct
│   ├── ViewModels/
│   │   └── PhotoLibraryViewModel   — coordinator: owns LibraryStore, SelectionModel, editSession; UI flags; detail,
│   │                                 delete, selection-wide rating/tagging, editing entry points, presets
│   ├── Library/
│   │   ├── LibraryStore            — the in-memory library: model context, allPhotos/bin + facts, counts, tag
│   │   │                             lists, the grid (`photos`, `index(of:)`), photosDidChange. Extension files:
│   │   │   +Loading                  launch (`open`), loadExistingData, file availability
│   │   │   +Scan                     folder opening, serialised scans, waitForScans
│   │   │   +Mutations                rating, tags, bin, deletes (files trashed via FileTrasher), metadata write-back
│   │   │   +ListEditing              moving photos between library and bin in memory
│   │   │   +Filtering                filters, search, sort toggle, tag lists
│   │   ├── LibrarySort             — THE definition of photo order (fetch sort, key, insertion index, merge, toggle)
│   │   ├── SelectionModel          — selection, range/select-all, primary photo, grid keyboard navigation
│   │   ├── PhotoQuery              — SidebarFilter, PhotoFacts, pure filtering/search/facet counts
│   │   ├── ScanPlan                — StoredPhoto snapshot (background read) and the pure scan diff
│   │   └── TagParsing              — `Tag.parse(keyword:)`, the inverse of `Tag.fullName`
│   ├── Editing/
│   │   ├── EditSession             — one photo's edit: parameters, renders, comparison, crop, export, save/revert
│   │   ├── RAWEditStore            — RAW edit parameters: saves via MetadataWriter, reads see queued saves
│   │   └── SavedEdit               — renders the saved edit for the detail view; the session's hand-off
│   ├── Views/                      — ContentView (keys, search, alerts), MainContentView (grid kept alive under
│   │   │                             the detail view), LibraryToolbar, StatusBarView, SidebarView, PhotoGridView,
│   │   │                             PhotoGridItemView, RatingView, TagEditorView, EditSidebarView, CropOverlayView,
│   │   │                             PhotoDetailView (container)
│   │   └── Detail/                 — DisplayImage (CGImage + orientation), ZoomableImageView (+ZoomPanState),
│   │                                 MinimapView, DetailOverlayControls, ComparisonView
│   └── Services/
│       ├── FolderScanner           — walks a folder, pairs JPG+RAW, reads new photos' metadata concurrently
│       ├── MetadataService         — stateless, thread-safe metadata reads and writes (JPEG splice, sidecars)
│       ├── MetadataWriter          — serial, coalescing writer every metadata write goes through
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

- **JPG+RAW pairing:** Files with the same stem name are combined into one PhotoAsset entry
- **Dual metadata:** the SwiftData DB is the primary store. Ratings and tags are also written back to the files:
  XMP (`xmp:Rating`, `dc:subject`) and IPTC keywords inside JPGs, the `.xmp` sidecar for RAW files, and both files
  of a JPG+RAW pair.
- **Tags stored as `category:name`** in keywords to preserve hierarchy in flat keyword lists (`Tag.fullName` /
  `Tag.parse(keyword:)`)
- **Folder access:** Uses SwiftUI `.fileImporter` for folder selection, security-scoped bookmarks for persistent access
- **Menu commands:** Uses SwiftUI `FocusedValues` to communicate between App-level commands and views
- **Data flow:** the library is fetched from the store only by `LibraryStore.loadExistingData()` and by scans. UI
  interactions (filters, search, sort, rating, tags, bin) work on the in-memory library and its `PhotoFacts` and must
  never re-fetch:
  mutations patch the lists, the grid and the counts in place. Code that changes a photo's rating, tags, file paths
  or file name outside `LibraryStore` calls `photosDidChange(_:)`.
- **Photo order:** `LibrarySort` is the only definition of photo order. Fetches, insertion into sorted lists, merges
  and the sort toggle all go through it; don't sort photos anywhere else.
- **Scans:** run one at a time (`scanFolder` queues requests; the latest folder wins). The walk, the read of the stored
  rows, the diff and the metadata reads run off the main actor; the main actor only writes changed fields and inserts
  photos, so an unchanged rescan writes nothing and doesn't reload.
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
- `PhotoAsset.isDeleted` means "in the bin" and collides with SwiftData's own `isDeleted` (spec §H5): reading it
  returns false after a save, and saving any later change to a binned row writes the flag back as false (a probe in
  task 30: rating a photo in the bin takes it out of the bin in the store). Read bin membership through a
  `#Predicate { $0.isDeleted }` fetch, never the property.

### Metadata

- Sidecars are updated in place, never rewritten wholesale: only Phocasa's fields change, and everything other apps
  wrote is kept. A sidecar that can't be parsed safely is skipped, left byte-identical.
- JPEG writes splice only ImageIO's new XMP/IPTC segments into the original bytes (the camera's MakerNote and other
  segments survive), falling back to ImageIO's full rewrite for files the splice can't handle. Writes go through a
  temp file and `replaceItemAt`.

### Testing

- The test host (`XCTestConfigurationFilePath` set) uses an in-memory SwiftData store, and `ImageLoader.shared` has no
  disk cache unless `PHOCASA_THUMBNAIL_CACHE_DIR` names a folder (pass `TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR`).
  Tests must never open or modify anything under `~/Library/Application Support` (the user's real library) or write to
  `~/Library/Caches/com.phocasa.app`.
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
