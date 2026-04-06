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
│ (SwiftUI)    │◀────│  (@Observable)    │◀────│ (ImageIO, FS)    │
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

**PhotoLibrary**
- `id: UUID`
- `rootFolderPath: String`
- `bookmarkData: Data?` — security-scoped bookmark for persistent access
- `lastScanDate: Date?`

**EditPreset**
- `id: UUID`
- `name: String`
- `parametersData: Data` — JSON-encoded EditParameters
- `createdDate: Date`

**EditParameters** (Codable struct, not a SwiftData model)
- Light: exposure, highlights, shadows, brightness, contrast
- Color: temperature, tint, saturation, vibrance
- Detail: sharpness, noiseReduction, colorNoiseReduction
- Effects: clarity, vignetteAmount
- RAW-specific: localToneMap, moireReduction, enableLensCorrection, enableGamutMapping
- Transform: cropRect (NormalizedRect?), rotation, flipHorizontal, flipVertical

### Services

**FolderScanner**
- Recursively enumerates a directory for supported file extensions
- Groups files by stem name to detect JPG+RAW pairs
- Supported extensions:
  - Standard: `.jpg`, `.jpeg`, `.png`, `.tiff`, `.tif`, `.heic`, `.heif`
  - RAW: `.cr2`, `.cr3`, `.nef`, `.arw`, `.dng`, `.raf`, `.orf`, `.rw2`, `.pef`, `.srw`, `.3fr`, `.iiq`, `.rwl`, `.raw`, `.mrw`, `.dcr`
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
- **Sync timing:** Write-back on each rating/tag change via `Task.detached` (fire-and-forget background I/O)
- **Tag encoding in IPTC:** Tags stored as `category:name` strings (e.g., "country:Japan") so hierarchy is preserved in flat keyword lists

**ImageEditingService**
- Non-destructive image editing using CoreImage filter chains
- RAW processing via `CIRAWFilter` with exposure, white balance, noise reduction, lens correction
- Standard (JPG/PNG) processing via `CIColorControls`, `CIExposureAdjust`, `CITemperatureAndTint`, `CIUnsharpMask`, etc.
- Metal-backed `CIContext` for GPU-accelerated rendering
- Source caching: RAW filter and standard CIImage cached per-file to avoid re-reading from disk on slider changes
- Draft mode for preview renders (lower quality, faster); full quality for export
- Export: RAW → JPEG and JPG overwrite with `CGImageDestination`
- Transform: rotation, flip, crop via `CIImage.transformed(by:)` and `.cropped(to:)`
- Preview debounce: 30ms delay before rendering to batch rapid slider changes

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
- Full-resolution image with zoom (scroll wheel, pinch, double-click)
- ZoomPanState: separate @Observable for magnification, offset, clamping, minimap
- Left/right arrow navigation
- Star rating overlay, tag display, edit mode buttons (JPG/RAW)
- Side-by-side comparison (original vs edited, JPG vs RAW edit)
- Minimap overlay when zoomed in (shows visible rect, click-to-navigate)

**EditSidebarView**
- Collapsible sections: Light, Color, Detail, Effects, RAW, Transform, Presets
- Reusable `EditSlider` component with label, value display, double-click to reset
- Crop/rotate button, side-by-side toggle, JPG comparison toggle, export button
- Preset save/load/delete

**CropOverlayView**
- Dim overlay with crop window cut-out (Canvas with even-odd fill)
- Rule-of-thirds grid, draggable handles (corners, edges, center)
- Aspect ratio constraints (Free, 1:1, 4:3, 3:2, 16:9)
- Rotation slider, apply/cancel buttons

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
| ← → ↑ ↓ | Navigate grid (with Shift to extend selection) or detail view |
| ⌘A | Select all in grid |
| ⌫ | Delete selected / move to bin |
| Space | Toggle detail view |
| Enter | Open selected in detail view |
| Escape | Cancel crop → stop editing → close detail → clear selection (layered) |
| \\ (hold) | Show original image while editing |
| ⌘O | Open folder (menu command) |

### File Access

- SwiftUI `.fileImporter` to select root folder
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
- SwiftData predicates for initial fetch (deleted vs non-deleted); in-memory filtering for sidebar filters, tags, and search
- Image detail view loads full resolution only when displayed
- Folder scan runs on background actor, UI shows progress

### Project Structure

```
Phocasa/
├── PhocasaApp.swift              — App entry point, FocusedValues, menu commands
├── Models/
│   ├── PhotoAsset.swift         — SwiftData model (JPG+RAW pair, edit params)
│   ├── Tag.swift                — SwiftData model (hierarchical tags)
│   ├── PhotoLibrary.swift       — SwiftData model (folder bookmark)
│   ├── EditPreset.swift         — SwiftData model (saved edit presets)
│   └── EditParameters.swift     — Codable struct (exposure, color, crop, etc.) + NormalizedRect
├── ViewModels/
│   └── PhotoLibraryViewModel.swift
├── Views/
│   ├── ContentView.swift        — Main layout
│   ├── PhotoGridView.swift      — Grid display
│   ├── PhotoGridItemView.swift  — Single grid cell
│   ├── PhotoDetailView.swift    — Full image view + ZoomPanState
│   ├── EditSidebarView.swift    — Edit sliders (light, color, detail, effects, RAW, transform, presets)
│   ├── CropOverlayView.swift    — Crop/rotate overlay with aspect ratio constraints
│   ├── RatingView.swift         — Star rating widget
│   ├── TagEditorView.swift      — Tag management
│   └── SidebarView.swift        — Sidebar navigation with faceted filter counts
├── Services/
│   ├── FolderScanner.swift      — File discovery + JPG+RAW pairing
│   ├── ImageLoader.swift        — Thumbnail generation + caching (NSCache)
│   ├── MetadataService.swift    — IPTC/XMP read/write + sidecar management
│   └── ImageEditingService.swift — CIRAWFilter + CIFilter chain, Metal CIContext, export
└── Info.plist
```

### Deployment Target

- macOS 14.0+ (Sonoma) — required for SwiftData
- Swift 6.x
- No third-party dependencies — all Apple frameworks

### Frameworks Used

- **SwiftUI** — UI
- **SwiftData** — persistence
- **ImageIO** — image loading, thumbnail generation, metadata read/write
- **CoreImage** — non-destructive image editing filter chains, CIRAWFilter for RAW processing
- **Metal** — GPU-accelerated CIContext for image rendering
- **UniformTypeIdentifiers** — file type detection
- **AppKit** — NSImage, NSCache, NSEvent (scroll wheel zoom, modifier keys in tap gestures)
