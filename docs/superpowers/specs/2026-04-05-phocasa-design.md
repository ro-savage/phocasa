# Phocasa — macOS Photo Explorer

## Overview

A native macOS app built with Swift and SwiftUI for exploring, rating, tagging, and organizing thousands of photos. Designed for photographers who shoot JPG+RAW and need fast browsing with metadata that travels with the files.

## Core Requirements

1. **Folder-based browsing** — open any folder, recursively scan all subfolders for photos
2. **Grid view** — zoomable grid (2-20 columns) with async thumbnail loading
3. **Detail view** — click a photo to see it full-size with navigation
4. **Star ratings** — 1-5 stars, assignable in grid or detail view
5. **JPG+RAW pairing** — files with the same stem name are combined into one entry
6. **Multi-select** — Cmd+Click or drag to select multiple photos in grid
7. **Batch operations** — apply ratings or delete multiple photos at once
8. **Hierarchical tags** — tags with parent-child relationships (e.g., Country > Japan, Trip > Iceland 2025)
9. **Group by tag** — sidebar grouping by any tag category
10. **Search** — filter photos by tag name
11. **Dual metadata storage** — SwiftData database for speed, write-back to files for portability
12. **Packageable** — distributable as a standalone .app

## Architecture

### Pattern: MVVM

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Views      │────▶│   ViewModels      │────▶│   Services       │
│ (SwiftUI)    │◀────│ (ObservableObject)│◀────│ (ImageIO, FS)    │
└─────────────┘     └──────────────────┘     └─────────────────┘
                            │                         │
                            ▼                         ▼
                    ┌──────────────┐          ┌──────────────┐
                    │  SwiftData    │          │  File System  │
                    │  (SQLite)     │          │  (XMP/IPTC)   │
                    └──────────────┘          └──────────────┘
```

### Data Models (SwiftData)

**PhotoAsset**
- `id: UUID`
- `fileName: String` — stem name (e.g., "IMG_001")
- `jpgPath: String?` — path to JPG/HEIC/PNG/TIFF file
- `rawPath: String?` — path to RAW file
- `rating: Int` (0-5, 0 = unrated)
- `creationDate: Date?`
- `fileSize: Int64`
- `thumbnailData: Data?` — cached thumbnail JPEG
- `tags: [Tag]` — many-to-many relationship
- `folderPath: String` — parent folder for grouping
- `isDeleted: Bool` — soft delete flag

**Tag**
- `id: UUID`
- `name: String`
- `category: String` — grouping key (e.g., "country", "trip", "genre")
- `parent: Tag?` — optional parent for hierarchy
- `children: [Tag]`
- `photos: [PhotoAsset]`

**Library**
- `id: UUID`
- `rootFolderPath: String`
- `bookmarkData: Data` — security-scoped bookmark for persistent access
- `lastScanDate: Date`

### Services

**FolderScanner**
- Recursively enumerates a directory for supported file extensions
- Groups files by stem name to detect JPG+RAW pairs
- Supported extensions:
  - Standard: `.jpg`, `.jpeg`, `.png`, `.tiff`, `.tif`, `.heic`, `.heif`
  - RAW: `.cr2`, `.cr3`, `.nef`, `.arw`, `.dng`, `.raf`, `.orf`, `.rw2`, `.pef`, `.srw`, `.3fr`, `.iiq`
- Priority for display: JPG > HEIC > PNG > TIFF > RAW (when paired)
- Returns list of discovered photo groups with paths

**ImageLoader**
- Generates thumbnails asynchronously using `CGImageSource` (ImageIO framework)
- Thumbnail size: 300px on longest edge for grid, full resolution for detail
- In-memory cache: `NSCache` with ~500 thumbnail limit
- Disk cache: thumbnail JPEG stored in SwiftData model
- RAW rendering: `CGImageSource` with `kCGImageSourceCreateThumbnailFromImageAlways`
- All operations on background actors to keep UI responsive

**MetadataService**
- **Read:** On import, reads IPTC keywords and XMP rating from files/sidecars
- **Write to JPG/HEIC/TIFF:** Uses `CGImageSource` + `CGImageDestination` to write:
  - `xmp:Rating` — star rating (1-5)
  - IPTC keywords — tags as flat strings (e.g., "country:Japan", "trip:Iceland 2025")
- **Write to RAW:** Creates/updates XMP sidecar file (`.xmp`) alongside the RAW file
  - Standard XMP format readable by Lightroom, Capture One, Bridge, etc.
- **Sync timing:** Write-back on each rating/tag change, debounced (0.5s) to batch rapid changes
- **Tag encoding in IPTC:** Tags stored as `category:name` strings (e.g., "country:Japan") so hierarchy is preserved in flat keyword lists

### Views

**MainView (ContentView)**
```
┌──────────────────────────────────────────────────┐
│ Toolbar: [Open Folder] [Search 🔍] [Zoom ◀━━▶]  │
├────────────┬─────────────────────────────────────┤
│ Sidebar    │                                     │
│            │                                     │
│ ▸ All      │        Photo Grid                   │
│ ▸ Unrated  │        (LazyVGrid)                  │
│ ▸ ★★★★★   │                                     │
│ ▸ Country  │   [img] [img] [img] [img]          │
│   Japan    │   [img] [img] [img] [img]          │
│   Iceland  │   [img] [img] [img] [img]          │
│ ▸ Trip     │                                     │
│   Summer25 │                                     │
│            │                                     │
├────────────┴─────────────────────────────────────┤
│ Status: 1,234 photos │ 3 selected │ ★★★☆☆       │
└──────────────────────────────────────────────────┘
```

**PhotoGridView**
- `LazyVGrid` with adaptive columns based on zoom slider
- Each cell shows: thumbnail, filename, star rating overlay
- Selection: Cmd+Click for individual, Shift+Click for range, Cmd+A for all
- Right-click context menu: Rate, Tag, Delete
- Drag to select multiple

**PhotoDetailView**
- Full-resolution image with zoom (pinch/scroll)
- Left/right arrow navigation
- Star rating overlay
- Tag display and editor
- Info panel (EXIF data, file size, dimensions)

**RatingView**
- Reusable star rating component
- Click to set, click same star to clear
- Keyboard: 1-5 to rate, 0 to clear

**TagEditorView**
- Popover for adding/removing tags
- Autocomplete from existing tags
- Create new tag with category assignment
- Shows tag hierarchy

**SidebarView**
- Smart filters: All, Unrated, by star rating
- Tag categories as expandable groups
- Click a tag to filter grid to those photos
- Tag counts shown

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| 1-5 | Set star rating |
| 0 | Clear rating |
| ← → | Navigate in detail view |
| ⌘A | Select all in grid |
| ⌫ | Delete selected (with confirmation) |
| Space | Quick Look / toggle detail view |
| ⌘+/⌘- | Zoom grid in/out |
| ⌘F | Focus search |
| Enter | Open selected in detail view |
| Escape | Back to grid / clear selection |
| T | Open tag editor for selection |

### File Access

- `NSOpenPanel` to select root folder
- Store `security-scoped bookmark` for persistent access across launches
- Bookmark stored in SwiftData `Library` model
- Resolve bookmark on app launch to regain access

### Deletion

- **Soft delete:** Marks `isDeleted = true` in database, hides from grid
- **Hard delete:** Moves files to Trash via `FileManager.trashItem(at:resultingItemURL:)`
- Confirmation dialog for hard delete
- Batch delete respects multi-selection

### Performance Considerations

- Thumbnail generation is async on background threads
- Grid uses `LazyVGrid` — only renders visible cells
- SwiftData queries with predicates for filtering (not in-memory filtering)
- Image detail view loads full resolution only when displayed
- Folder scan runs on background actor, UI shows progress

### Project Structure

```
Phocasa/
├── PhocasaApp.swift              — App entry point
├── Models/
│   ├── PhotoAsset.swift         — SwiftData model
│   ├── Tag.swift                — SwiftData model
│   └── Library.swift            — SwiftData model
├── ViewModels/
│   └── PhotoLibraryViewModel.swift
├── Views/
│   ├── ContentView.swift        — Main layout
│   ├── PhotoGridView.swift      — Grid display
│   ├── PhotoGridItemView.swift  — Single grid cell
│   ├── PhotoDetailView.swift    — Full image view
│   ├── RatingView.swift         — Star rating widget
│   ├── TagEditorView.swift      — Tag management
│   └── SidebarView.swift        — Sidebar navigation
├── Services/
│   ├── FolderScanner.swift      — File discovery
│   ├── ImageLoader.swift        — Thumbnail generation
│   └── MetadataService.swift    — IPTC/XMP read/write
└── Info.plist
```

### Deployment Target

- macOS 14.0+ (Sonoma) — required for SwiftData
- Swift 6.x
- No third-party dependencies — all Apple frameworks

### Frameworks Used

- **SwiftUI** — UI
- **SwiftData** — persistence
- **ImageIO** — image loading, thumbnail generation, RAW support
- **UniformTypeIdentifiers** — file type detection
- **CoreImage** — image processing (detail view zoom)
