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
```

## Architecture

- **Pattern:** MVVM
- **Persistence:** SwiftData (SQLite-backed) for speed + IPTC/XMP write-back to files for portability
- **Image loading:** ImageIO framework (CGImageSource) — handles all RAW formats natively
- **Image editing:** CoreImage + CIRAWFilter for non-destructive editing, Metal-backed CIContext for GPU rendering
- **No third-party dependencies** — all Apple frameworks

### Project Structure

```
Phocasa/
├── Phocasa.xcodeproj/
└── Phocasa/
    ├── PhocasaApp.swift            — @main entry, SwiftData container, FocusedValues, menu commands
    ├── Models/                     — SwiftData models (PhotoAsset, Tag, PhotoLibrary, EditPreset)
    │                                 + EditParameters struct, NormalizedRect struct
    ├── ViewModels/                 — PhotoLibraryViewModel (selection, filtering, scanning, editing, batch ops)
    ├── Views/                      — All SwiftUI views (ContentView, Grid, Detail, Sidebar, EditSidebar, CropOverlay, etc.)
    └── Services/                   — FolderScanner, ImageLoader, MetadataService, ImageEditingService
```

## Key Design Decisions

- **JPG+RAW pairing:** Files with the same stem name are combined into one PhotoAsset entry
- **Dual metadata:** SwiftData DB is the primary store; ratings/tags are also written back to IPTC keywords (JPG) or XMP sidecar files (RAW) for portability
- **Tags stored as `category:name`** in IPTC keywords to preserve hierarchy in flat keyword lists
- **Folder access:** Uses SwiftUI `.fileImporter` for folder selection, security-scoped bookmarks for persistent access
- **Menu commands:** Uses SwiftUI `FocusedValues` to communicate between App-level commands and views
- **Concurrency:** ViewModel is `@MainActor`; stateless services (FolderScanner, MetadataService) are `Sendable`; services with mutable caches (ImageLoader, ImageEditingService) use `@unchecked Sendable` with internal synchronization via serial dispatch queues
- **Edit parameters:** Stored as JSON-encoded `EditParameters` struct — in SwiftData for JPGs, in XMP sidecar (base64) for RAW files

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

### Swift 6 Concurrency

- The project uses Swift 6 with `SWIFT_STRICT_CONCURRENCY = minimal` (relaxed, but code should be concurrency-safe)
- ViewModels are `@MainActor`
- Stateless services (FolderScanner, MetadataService) conform to `Sendable`
- Services with mutable cached state (ImageLoader, ImageEditingService) use `@unchecked Sendable` with internal synchronization via serial/concurrent dispatch queues
- File I/O is dispatched to background queues via `withCheckedContinuation` + `DispatchQueue.global()`
- Don't use `FileManager.enumerator` `for-in` loops in async contexts — use `nextObject()` in a sync wrapper
- Module-level free functions (`captureFileDates`, `restoreFileDates`) are used for shared utilities across services

### Build Settings

- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = minimal`
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- App Sandbox OFF, Hardened Runtime ON (Release only)
