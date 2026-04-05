# Phocsa — macOS Photo Explorer

## Project Overview

Native macOS photo explorer app for browsing, rating, tagging, and organizing thousands of photos. Built with Swift 6 and SwiftUI, targeting macOS 14.0+ (Sonoma).

## Build & Run

```bash
# Build from CLI (requires Xcode installed)
cd /Users/rowan/www/phocsa/Phocsa
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project Phocsa.xcodeproj -scheme Phocsa -configuration Debug build

# Run the built app
open ~/Library/Developer/Xcode/DerivedData/Phocsa-*/Build/Products/Debug/Phocsa.app

# Or open in Xcode
open Phocsa/Phocsa.xcodeproj
```

## Architecture

- **Pattern:** MVVM
- **Persistence:** SwiftData (SQLite-backed) for speed + IPTC/XMP write-back to files for portability
- **Image loading:** ImageIO framework (CGImageSource) — handles all RAW formats natively
- **No third-party dependencies** — all Apple frameworks

### Project Structure

```
Phocsa/
├── Phocsa.xcodeproj/
└── Phocsa/
    ├── PhocaApp.swift              — @main entry, SwiftData container, menu commands
    ├── Models/                     — SwiftData models (PhotoAsset, Tag, PhotoLibrary)
    ├── ViewModels/                 — PhotoLibraryViewModel (selection, filtering, scanning, batch ops)
    ├── Views/                      — All SwiftUI views (ContentView, Grid, Detail, Sidebar, etc.)
    └── Services/                   — FolderScanner, ImageLoader, MetadataService
```

## Key Design Decisions

- **JPG+RAW pairing:** Files with the same stem name are combined into one PhotoAsset entry
- **Dual metadata:** SwiftData DB is the primary store; ratings/tags are also written back to IPTC keywords (JPG) or XMP sidecar files (RAW) for portability
- **Tags stored as `category:name`** in IPTC keywords to preserve hierarchy in flat keyword lists
- **Folder access:** Uses SwiftUI `.fileImporter` for folder selection, security-scoped bookmarks for persistent access
- **Concurrency:** ViewModel is `@MainActor`, services use `@unchecked Sendable` with internal synchronization

## Development Rules

### Always use SwiftUI first

**This is critical.** Always look for SwiftUI-native APIs before reaching for AppKit or older patterns:

- Use `.fileImporter` / `.fileExporter` instead of `NSOpenPanel` / `NSSavePanel`
- Use `.alert` / `.confirmationDialog` instead of `NSAlert`
- Use `.onKeyPress` instead of `NSEvent` key monitoring
- Use `@Observable` instead of `ObservableObject` + `@Published`
- Use SwiftData instead of Core Data
- Use `NavigationSplitView` / `NavigationStack` instead of `NSSplitViewController`
- Use `.searchable` instead of custom search fields
- Use `.toolbar` instead of `NSToolbar`
- Use `.popover` / `.sheet` instead of `NSPopover` / `NSPanel`
- Use `AsyncImage` patterns / `.task` instead of manual GCD image loading where possible

If a SwiftUI equivalent doesn't exist, then AppKit is fine — but verify first.

### Swift 6 Concurrency

- The project uses Swift 6 with strict concurrency enabled
- ViewModels are `@MainActor`
- Services that are singletons use `@unchecked Sendable`
- File I/O is dispatched to background queues via `withCheckedContinuation` + `DispatchQueue.global()`
- Don't use `FileManager.enumerator` `for-in` loops in async contexts — use `nextObject()` in a sync wrapper

### Build Settings

- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = minimal` (relaxed for practical reasons, but code should be concurrency-safe)
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- App Sandbox OFF, Hardened Runtime ON (Release only)
