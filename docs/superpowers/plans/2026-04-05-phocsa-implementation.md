# Phocsa Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS SwiftUI photo explorer app with grid browsing, ratings, hierarchical tags, JPG+RAW pairing, and dual metadata storage (SwiftData + file write-back).

**Architecture:** MVVM with SwiftData persistence. Services layer handles file scanning, image loading, and metadata I/O. Views use LazyVGrid for performance with thousands of photos.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, ImageIO, UniformTypeIdentifiers. No third-party dependencies.

---

## File Structure

```
Phocsa/
├── Phocsa.xcodeproj/
│   └── project.pbxproj
├── Phocsa/
│   ├── PhocaApp.swift                    — @main App entry, SwiftData container, window
│   ├── Models/
│   │   ├── PhotoAsset.swift              — SwiftData model for a photo (JPG+RAW pair)
│   │   ├── Tag.swift                     — SwiftData model for hierarchical tags
│   │   └── PhotoLibrary.swift            — SwiftData model for library/folder bookmark
│   ├── ViewModels/
│   │   └── PhotoLibraryViewModel.swift   — Selection, filtering, scanning, batch ops
│   ├── Views/
│   │   ├── ContentView.swift             — NavigationSplitView layout
│   │   ├── SidebarView.swift             — Tag groups, smart filters
│   │   ├── PhotoGridView.swift           — LazyVGrid with zoom
│   │   ├── PhotoGridItemView.swift       — Single grid cell with thumbnail + rating
│   │   ├── PhotoDetailView.swift         — Full-res image view
│   │   ├── RatingView.swift              — Reusable 1-5 star component
│   │   └── TagEditorView.swift           — Tag add/remove/create popover
│   ├── Services/
│   │   ├── FolderScanner.swift           — Recursive file enumeration + pairing
│   │   ├── ImageLoader.swift             — Async thumbnail gen + caching
│   │   └── MetadataService.swift         — IPTC/XMP read/write + sidecar
│   └── Info.plist
```

---

### Task 1: Xcode Project Setup

**Files:**
- Create: `Phocsa/Phocsa.xcodeproj/project.pbxproj`
- Create: `Phocsa/Phocsa/Info.plist`
- Create: `Phocsa/Phocsa/Phocsa.entitlements`

- [ ] **Step 1: Create Xcode project via `swift package init` then convert**

Use the Xcode CLI to generate a proper project, or manually create the pbxproj. The project must:
- Target macOS 14.0+
- Use Swift 6 language mode (with concurrency checking relaxed as needed)
- Link frameworks: SwiftUI, SwiftData, ImageIO, UniformTypeIdentifiers, CoreImage
- App Sandbox OFF (needs full file access for user-selected folders)
- Hardened Runtime ON

- [ ] **Step 2: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Phocsa</string>
    <key>CFBundleDisplayName</key>
    <string>Phocsa</string>
    <key>CFBundleIdentifier</key>
    <string>com.phocsa.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Phocsa</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Create entitlements file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Create minimal PhocaApp.swift to verify build**

```swift
import SwiftUI

@main
struct PhocaApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Phocsa")
        }
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `xcodebuild -project Phocsa.xcodeproj -scheme Phocsa -configuration Debug build`
Expected: BUILD SUCCEEDED

---

### Task 2: SwiftData Models

**Files:**
- Create: `Phocsa/Phocsa/Models/PhotoAsset.swift`
- Create: `Phocsa/Phocsa/Models/Tag.swift`
- Create: `Phocsa/Phocsa/Models/PhotoLibrary.swift`
- Modify: `Phocsa/Phocsa/PhocaApp.swift` — add modelContainer

- [ ] **Step 1: Create PhotoAsset model**

```swift
import Foundation
import SwiftData

@Model
final class PhotoAsset {
    var id: UUID
    var fileName: String
    var jpgPath: String?
    var rawPath: String?
    var rating: Int
    var creationDate: Date?
    var fileSize: Int64
    var thumbnailData: Data?
    var folderPath: String
    var isDeleted: Bool

    @Relationship(inverse: \Tag.photos)
    var tags: [Tag]

    var displayPath: String {
        jpgPath ?? rawPath ?? ""
    }

    var hasRawPair: Bool {
        jpgPath != nil && rawPath != nil
    }

    init(fileName: String, jpgPath: String? = nil, rawPath: String? = nil,
         folderPath: String, creationDate: Date? = nil, fileSize: Int64 = 0) {
        self.id = UUID()
        self.fileName = fileName
        self.jpgPath = jpgPath
        self.rawPath = rawPath
        self.rating = 0
        self.creationDate = creationDate
        self.fileSize = fileSize
        self.thumbnailData = nil
        self.folderPath = folderPath
        self.isDeleted = false
        self.tags = []
    }
}
```

- [ ] **Step 2: Create Tag model**

```swift
import Foundation
import SwiftData

@Model
final class Tag {
    var id: UUID
    var name: String
    var category: String

    @Relationship
    var parent: Tag?

    @Relationship(inverse: \Tag.parent)
    var children: [Tag]

    var photos: [PhotoAsset]

    var fullName: String {
        "\(category):\(name)"
    }

    init(name: String, category: String, parent: Tag? = nil) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.parent = parent
        self.children = []
        self.photos = []
    }
}
```

- [ ] **Step 3: Create PhotoLibrary model**

```swift
import Foundation
import SwiftData

@Model
final class PhotoLibrary {
    var id: UUID
    var rootFolderPath: String
    var bookmarkData: Data?
    var lastScanDate: Date?

    init(rootFolderPath: String, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.rootFolderPath = rootFolderPath
        self.bookmarkData = bookmarkData
        self.lastScanDate = nil
    }
}
```

- [ ] **Step 4: Update PhocaApp.swift with modelContainer**

```swift
import SwiftUI
import SwiftData

@main
struct PhocaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [PhotoAsset.self, Tag.self, PhotoLibrary.self])
    }
}
```

- [ ] **Step 5: Build and verify**

---

### Task 3: FolderScanner Service

**Files:**
- Create: `Phocsa/Phocsa/Services/FolderScanner.swift`

- [ ] **Step 1: Implement FolderScanner**

Recursive directory enumeration, extension detection, JPG+RAW pairing by stem name.

Supported extensions:
- Standard: jpg, jpeg, png, tiff, tif, heic, heif
- RAW: cr2, cr3, nef, arw, dng, raf, orf, rw2, pef, srw, 3fr, iiq

Pairing logic: Group by filename stem (case-insensitive). If multiple files share a stem, the standard format is used for display and the RAW path is stored separately.

Returns: `[(fileName: String, jpgPath: String?, rawPath: String?, folderPath: String, fileSize: Int64, creationDate: Date?)]`

- [ ] **Step 2: Build and verify**

---

### Task 4: ImageLoader Service

**Files:**
- Create: `Phocsa/Phocsa/Services/ImageLoader.swift`

- [ ] **Step 1: Implement ImageLoader**

- Uses `CGImageSource` from ImageIO for all formats including RAW
- Thumbnail generation: `kCGImageSourceCreateThumbnailFromImageAlways`, max 300px
- `NSCache` for in-memory thumbnails (keyed by file path)
- Async loading on background tasks
- Full-resolution loading for detail view
- Returns `NSImage` for both thumbnail and full-res

- [ ] **Step 2: Build and verify**

---

### Task 5: MetadataService

**Files:**
- Create: `Phocsa/Phocsa/Services/MetadataService.swift`

- [ ] **Step 1: Implement metadata reading**

Read IPTC keywords and XMP rating from image files using `CGImageSource`.
Read XMP sidecar files for RAW images.
Parse `category:name` tag format from IPTC keywords.

- [ ] **Step 2: Implement metadata writing**

For JPG/HEIC/TIFF: Use `CGImageSource` + `CGImageDestination` to write rating and keywords into file.
For RAW: Write/update XMP sidecar file with standard XMP XML format.
Debounce writes (0.5s) to batch rapid changes.

- [ ] **Step 3: Build and verify**

---

### Task 6: PhotoLibraryViewModel

**Files:**
- Create: `Phocsa/Phocsa/ViewModels/PhotoLibraryViewModel.swift`

- [ ] **Step 1: Implement core ViewModel**

Properties:
- `photos: [PhotoAsset]` — current filtered set
- `selectedPhotos: Set<UUID>` — multi-selection
- `searchText: String`
- `gridColumns: Int` (2-20)
- `currentFilter: FilterType` (all, unrated, rated, byTag)
- `isScanning: Bool`
- `selectedDetailPhoto: PhotoAsset?`

Methods:
- `openFolder()` — NSOpenPanel, scan, create/update PhotoAssets in SwiftData
- `setRating(_:for:)` — single photo rating + metadata write-back
- `setRatingForSelection(_:)` — batch rating
- `deletePhotos(_:)` — soft or hard delete with confirmation
- `addTag(_:to:)` / `removeTag(_:from:)` — tag management
- `filterByTag(_:)` / `groupByCategory(_:)` — filtering/grouping

- [ ] **Step 2: Build and verify**

---

### Task 7: RatingView and SidebarView

**Files:**
- Create: `Phocsa/Phocsa/Views/RatingView.swift`
- Create: `Phocsa/Phocsa/Views/SidebarView.swift`

- [ ] **Step 1: Implement RatingView**

Reusable star rating: 5 stars, click to set, click same to clear. Works in compact (grid) and full (detail) sizes.

- [ ] **Step 2: Implement SidebarView**

Smart filters (All, Unrated, 1-5 stars), tag categories as expandable groups with counts.

- [ ] **Step 3: Build and verify**

---

### Task 8: PhotoGridView and PhotoGridItemView

**Files:**
- Create: `Phocsa/Phocsa/Views/PhotoGridView.swift`
- Create: `Phocsa/Phocsa/Views/PhotoGridItemView.swift`

- [ ] **Step 1: Implement PhotoGridItemView**

Single cell: async thumbnail, filename, rating overlay, selection highlight, RAW badge.

- [ ] **Step 2: Implement PhotoGridView**

LazyVGrid with adaptive columns from zoom slider. Multi-select (Cmd+Click, Shift+Click). Right-click context menu. Keyboard shortcuts for rating.

- [ ] **Step 3: Build and verify**

---

### Task 9: PhotoDetailView and TagEditorView

**Files:**
- Create: `Phocsa/Phocsa/Views/PhotoDetailView.swift`
- Create: `Phocsa/Phocsa/Views/TagEditorView.swift`

- [ ] **Step 1: Implement PhotoDetailView**

Full-resolution image, left/right navigation, rating overlay, tag display, zoom with magnification gesture, escape to go back.

- [ ] **Step 2: Implement TagEditorView**

Popover with: current tags list, autocomplete search for existing tags, create new tag with category, remove tags. Works for single or multi-selection.

- [ ] **Step 3: Build and verify**

---

### Task 10: ContentView — Main Layout

**Files:**
- Create: `Phocsa/Phocsa/Views/ContentView.swift`

- [ ] **Step 1: Implement ContentView**

NavigationSplitView with sidebar + detail. Toolbar: Open Folder button, search field, zoom slider, delete button. Status bar with photo count, selection count. Wires up all child views with ViewModel.

- [ ] **Step 2: Build and verify**

---

### Task 11: Final Integration and Keyboard Shortcuts

**Files:**
- Modify: `Phocsa/Phocsa/PhocaApp.swift` — add commands
- Modify: Various view files for keyboard handling

- [ ] **Step 1: Add keyboard shortcuts**

1-5 rating, 0 clear, Delete, Cmd+A select all, Space for detail toggle, Cmd+/- zoom, Cmd+F search, arrow navigation, T for tag editor, Escape.

- [ ] **Step 2: Add menu bar commands**

File > Open Folder, Edit > Select All, View > Zoom In/Out

- [ ] **Step 3: Final build and verification**

Run: `xcodebuild -project Phocsa.xcodeproj -scheme Phocsa -configuration Debug build`
Expected: BUILD SUCCEEDED

---

### Task 12: Polish and Verify

- [ ] **Step 1: Test with actual photos**
- [ ] **Step 2: Fix any compiler warnings**
- [ ] **Step 3: Final clean build**
