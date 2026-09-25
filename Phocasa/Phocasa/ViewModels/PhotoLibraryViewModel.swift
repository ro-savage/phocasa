import SwiftUI
import SwiftData

enum SidebarFilter: Hashable {
    case all
    case unrated
    case rated(Int)
    case tag(UUID)
    case tagCategory(String)
    case bin
    case jpgOnly
    case rawOnly

    var filterCategory: String {
        switch self {
        case .all, .bin: return "special"
        case .unrated, .rated: return "rating"
        case .jpgOnly, .rawOnly: return "fileType"
        case .tag, .tagCategory: return "tag"
        }
    }

    func matches(_ photo: PhotoAsset) -> Bool {
        switch self {
        case .all: return true
        case .bin: return photo.isDeleted
        case .unrated: return photo.rating == 0
        case .rated(let stars): return photo.rating == stars
        case .jpgOnly: return photo.jpgPath != nil
        case .rawOnly: return photo.rawPath != nil
        case .tag(let tagId): return photo.tags.contains { $0.id == tagId }
        case .tagCategory(let category): return photo.tags.contains { $0.category == category }
        }
    }
}

@Observable @MainActor
final class PhotoLibraryViewModel {
    var photos: [PhotoAsset] = []
    var allPhotos: [PhotoAsset] = []
    var selectedPhotos: Set<UUID> = []
    var lastSelectedId: UUID?
    var searchText: String = ""
    var gridColumns: Int = 6
    var isScanning: Bool = false
    var scanProgress: String = ""
    var selectedDetailPhoto: PhotoAsset?
    var showingDetail: Bool = false
    var activeFilters: Set<SidebarFilter> = []
    var allTags: [Tag] = []
    var tagCategories: [String] = []
    var showDeleteConfirmation: Bool = false
    var showPermanentDeleteConfirmation: Bool = false
    var photosToDelete: [PhotoAsset] = []
    var currentLibrary: PhotoLibrary?
    var showFolderPicker: Bool = false
    var binCount: Int = 0
    var viewingBin: Bool = false
    var showGridTagEditor: Bool = false
    var tagEditorTarget: PhotoAsset?
    var sortNewestFirst: Bool = true
    var ratingCounts: [Int: Int] = [:]
    var categoryCounts: [String: Int] = [:]
    var jpgCount: Int = 0
    var rawCount: Int = 0
    var tagCounts: [UUID: Int] = [:]

    // MARK: - Image Editing State
    var isEditing: Bool = false
    var editingRAW: Bool = false
    var editParameters: EditParameters = EditParameters()
    var editedPreviewImage: NSImage?
    var fullResEditImage: NSImage?
    var showOriginal: Bool = false
    var showSideBySide: Bool = false
    var showJPGComparison: Bool = false
    var jpgComparisonImage: NSImage?
    var isCropping: Bool = false
    var cropRect: NormalizedRect = .full
    var editPresets: [EditPreset] = []
    var showExportOptions: Bool = false
    var presetNameInput: String = ""
    private var renderGeneration: Int = 0

    var canExport: Bool {
        guard isEditing, let photo = selectedDetailPhoto else { return false }
        if editingRAW { return photo.rawPath != nil }
        return photo.jpgPath != nil
    }

    var selectedPhotosList: [PhotoAsset] {
        photos.filter { selectedPhotos.contains($0.id) }
    }

    func isPartOfMultiSelection(_ photo: PhotoAsset) -> Bool {
        selectedPhotos.count > 1 && selectedPhotos.contains(photo.id)
    }

    private let scanner = FolderScanner()
    private let metadata = MetadataService.shared
    private var modelContext: ModelContext?
    private var availablePhotoIDs: Set<UUID> = []
    private var needsAvailabilityCheck = true
    private var previewTask: Task<Void, Never>?
    private var fullResRenderTask: Task<Void, Never>?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadExistingData()
        loadPresets()
        rescanCurrentLibrary()
    }

    // MARK: - File Availability

    private func checkFileAvailability(for photos: [PhotoAsset]) {
        var available = Set<UUID>()
        let fm = FileManager.default
        for photo in photos {
            let jpgExists = photo.jpgPath.map { fm.fileExists(atPath: $0) } ?? false
            let rawExists = photo.rawPath.map { fm.fileExists(atPath: $0) } ?? false
            if jpgExists || rawExists {
                available.insert(photo.id)
            }
        }
        availablePhotoIDs = available
        needsAvailabilityCheck = false
    }

    func refreshAvailability() {
        needsAvailabilityCheck = true
        loadExistingData()
        applyActiveFilters()
    }

    // MARK: - Data Loading

    func loadExistingData() {
        guard let context = modelContext else { return }

        let sortOrder: SortOrder = sortNewestFirst ? .reverse : .forward
        let photoDescriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { !$0.isDeleted },
            sortBy: [SortDescriptor(\.creationDate, order: sortOrder)]
        )
        let fetchedPhotos = (try? context.fetch(photoDescriptor)) ?? []

        if needsAvailabilityCheck {
            checkFileAvailability(for: fetchedPhotos)
        }

        allPhotos = fetchedPhotos.filter { availablePhotoIDs.contains($0.id) }

        let binDescriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { $0.isDeleted },
            sortBy: [SortDescriptor(\.creationDate, order: sortOrder)]
        )
        let binPhotos = (try? context.fetch(binDescriptor)) ?? []
        binCount = binPhotos.count

        if viewingBin {
            photos = binPhotos
        } else {
            photos = allPhotos
        }

        recomputeSidebarCounts()

        let tagDescriptor = FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.category), SortDescriptor(\.name)])
        allTags = (try? context.fetch(tagDescriptor)) ?? []

        let categories = Array(Set(allTags.compactMap { $0.category.isEmpty ? nil : $0.category }))
        tagCategories = categories.sorted { a, b in
            let countA = categoryCounts[a, default: 0]
            let countB = categoryCounts[b, default: 0]
            if countA != countB { return countA > countB }
            return a < b
        }

        let libDescriptor = FetchDescriptor<PhotoLibrary>()
        currentLibrary = (try? context.fetch(libDescriptor))?.first
    }

    private func recomputeSidebarCounts() {
        var counts: [Int: Int] = [:]
        var catCounts: [String: Int] = [:]
        var tCounts: [UUID: Int] = [:]
        var jpgC = 0
        var rawC = 0
        for photo in allPhotos {
            counts[photo.rating, default: 0] += 1
            if photo.jpgPath != nil { jpgC += 1 }
            if photo.rawPath != nil { rawC += 1 }
            var seenCategories = Set<String>()
            for tag in photo.tags {
                tCounts[tag.id, default: 0] += 1
                if !tag.category.isEmpty && seenCategories.insert(tag.category).inserted {
                    catCounts[tag.category, default: 0] += 1
                }
            }
        }
        ratingCounts = counts
        categoryCounts = catCounts
        tagCounts = tCounts
        jpgCount = jpgC
        rawCount = rawC
    }

    private func updateSidebarAfterChange() {
        if !activeFilters.isEmpty && !viewingBin {
            applyActiveFilters()
        } else {
            recomputeSidebarCounts()
        }
    }

    // MARK: - Folder Opening

    func openFolder() {
        showFolderPicker = true
    }

    func handleFolderSelected(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }

        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        guard let context = modelContext else { return }

        if let library = currentLibrary {
            library.rootFolderPath = url.path
            library.bookmarkData = bookmarkData
        } else {
            let library = PhotoLibrary(rootFolderPath: url.path, bookmarkData: bookmarkData)
            context.insert(library)
            currentLibrary = library
        }

        scanFolder(url: url)
    }

    func rescanCurrentLibrary() {
        guard let library = currentLibrary else { return }

        var isStale = false
        if let bookmarkData = library.bookmarkData,
           let url = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            scanFolder(url: url)
        } else {
            let url = URL(fileURLWithPath: library.rootFolderPath)
            scanFolder(url: url)
        }
    }

    private func scanFolder(url: URL) {
        guard let context = modelContext else { return }
        isScanning = true
        scanProgress = "Scanning folder..."

        Task { @MainActor in
            let discovered = await scanner.scan(folderURL: url)
            scanProgress = "Processing \(discovered.count) photos..."

            let existingDescriptor = FetchDescriptor<PhotoAsset>()
            let existing = (try? context.fetch(existingDescriptor)) ?? []
            let existingByKey = Dictionary(
                uniqueKeysWithValues: existing.map { ("\($0.folderPath)/\($0.fileName)", $0) }
            )

            var newCount = 0
            for photo in discovered {
                let key = "\(photo.folderPath)/\(photo.fileName)"
                if let existingPhoto = existingByKey[key] {
                    existingPhoto.jpgPath = photo.jpgPath
                    existingPhoto.rawPath = photo.rawPath
                    existingPhoto.fileSize = photo.fileSize
                    existingPhoto.isDeleted = false
                } else {
                    let asset = PhotoAsset(
                        fileName: photo.fileName,
                        jpgPath: photo.jpgPath,
                        rawPath: photo.rawPath,
                        folderPath: photo.folderPath,
                        creationDate: photo.creationDate,
                        fileSize: photo.fileSize
                    )

                    let filePath = photo.jpgPath ?? photo.rawPath ?? ""
                    if !filePath.isEmpty {
                        let meta = metadata.readMetadata(from: filePath)
                        asset.rating = meta.rating

                        for keyword in meta.keywords {
                            let parts = keyword.split(separator: ":", maxSplits: 1)
                            let category: String
                            let name: String
                            if parts.count == 2 {
                                category = String(parts[0])
                                name = String(parts[1])
                            } else {
                                category = ""
                                name = keyword
                            }
                            let tag = findOrCreateTag(name: name, category: category, in: context)
                            asset.tags.append(tag)
                        }
                    }

                    context.insert(asset)
                    newCount += 1
                }
            }

            currentLibrary?.lastScanDate = Date()
            try? context.save()

            scanProgress = "Found \(discovered.count) photos (\(newCount) new)"
            needsAvailabilityCheck = true
            loadExistingData()
            isScanning = false
        }
    }

    // MARK: - Rating

    func setRating(_ rating: Int, for photo: PhotoAsset) {
        photo.rating = rating
        try? modelContext?.save()

        writeMetadataInBackground([metadataWriteItem(for: photo)])
        updateSidebarAfterChange()
    }

    func setRatingForSelection(_ rating: Int) {
        guard let context = modelContext else { return }
        for photo in selectedPhotosList {
            photo.rating = rating
        }
        try? context.save()

        writeMetadataInBackground(selectedPhotosList.map { metadataWriteItem(for: $0) })
        updateSidebarAfterChange()
    }

    // MARK: - Selection

    func toggleSelection(for photo: PhotoAsset, addToSelection: Bool) {
        if addToSelection {
            if selectedPhotos.contains(photo.id) {
                selectedPhotos.remove(photo.id)
            } else {
                selectedPhotos.insert(photo.id)
            }
        } else {
            selectedPhotos = [photo.id]
        }
        lastSelectedId = photo.id
    }

    func selectAll() {
        selectedPhotos = Set(photos.map(\.id))
    }

    func clearSelection() {
        selectedPhotos.removeAll()
        lastSelectedId = nil
    }

    func rangeSelect(to photo: PhotoAsset) {
        guard let lastId = lastSelectedId,
              let lastIndex = photos.firstIndex(where: { $0.id == lastId }),
              let currentIndex = photos.firstIndex(where: { $0.id == photo.id }) else {
            selectedPhotos.insert(photo.id)
            lastSelectedId = photo.id
            return
        }

        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        for i in range {
            selectedPhotos.insert(photos[i].id)
        }
        lastSelectedId = photo.id
    }

    // MARK: - Deletion / Bin

    var hasFileTypeFilter: Bool {
        activeFilters.contains(.rawOnly) || activeFilters.contains(.jpgOnly)
    }

    func deleteSelected() {
        let toDelete = selectedPhotosList
        guard !toDelete.isEmpty else { return }

        if viewingBin {
            photosToDelete = toDelete
            showPermanentDeleteConfirmation = true
        } else if hasFileTypeFilter {
            deleteFileTypeOnly(toDelete)
        } else {
            moveToBin(toDelete)
        }
    }

    func deletePhoto(_ photo: PhotoAsset) {
        if viewingBin {
            photosToDelete = [photo]
            showPermanentDeleteConfirmation = true
        } else if hasFileTypeFilter && photo.hasRawPair {
            deleteFileTypeOnly([photo])
        } else {
            moveToBin([photo])
        }
    }

    private func deleteFileTypeOnly(_ photosToRemove: [PhotoAsset]) {
        let deleteRAW = activeFilters.contains(.rawOnly)
        let deleteJPG = activeFilters.contains(.jpgOnly)

        for photo in photosToRemove {
            if deleteRAW && deleteJPG {
                // Both file type filters active — normal soft delete
                photo.isDeleted = true
            } else if deleteRAW && photo.hasRawPair {
                trashRAWFile(for: photo)
            } else if deleteJPG && photo.hasRawPair {
                trashJPGFile(for: photo)
            } else {
                // Non-paired photo: normal soft delete
                photo.isDeleted = true
            }
            selectedPhotos.remove(photo.id)
        }
        try? modelContext?.save()
        loadExistingData()
        applyActiveFilters()
    }

    private func trashRAWFile(for photo: PhotoAsset) {
        if let rawPath = photo.rawPath {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: rawPath), resultingItemURL: nil)
            // Clean up XMP sidecar
            let sidecarURL = URL(fileURLWithPath: rawPath).xmpSidecarURL
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try? FileManager.default.trashItem(at: sidecarURL, resultingItemURL: nil)
            }
        }
        photo.rawPath = nil
        photo.hasRawEdits = false
    }

    private func trashJPGFile(for photo: PhotoAsset) {
        if let jpgPath = photo.jpgPath {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: jpgPath), resultingItemURL: nil)
        }
        photo.jpgPath = nil
        photo.jpgEditParametersData = nil
    }

    private func moveToBin(_ photosToMove: [PhotoAsset]) {
        for photo in photosToMove {
            photo.isDeleted = true
            selectedPhotos.remove(photo.id)
        }
        try? modelContext?.save()
        loadExistingData()
    }

    func restoreFromBin(_ photosToRestore: [PhotoAsset]) {
        for photo in photosToRestore {
            photo.isDeleted = false
            selectedPhotos.remove(photo.id)
        }
        try? modelContext?.save()
        loadExistingData()
    }

    func restoreSelected() {
        restoreFromBin(selectedPhotosList)
    }

    func confirmPermanentDelete() {
        guard let context = modelContext else { return }

        for photo in photosToDelete {
            if let jpgPath = photo.jpgPath {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: jpgPath), resultingItemURL: nil)
            }
            if let rawPath = photo.rawPath {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: rawPath), resultingItemURL: nil)
                // Clean up XMP sidecar
                let sidecarURL = URL(fileURLWithPath: rawPath).xmpSidecarURL
                if FileManager.default.fileExists(atPath: sidecarURL.path) {
                    try? FileManager.default.trashItem(at: sidecarURL, resultingItemURL: nil)
                }
            }
            selectedPhotos.remove(photo.id)
            context.delete(photo)
        }

        try? context.save()
        photosToDelete = []
        loadExistingData()
    }

    func emptyBin() {
        guard let context = modelContext else { return }
        let binDescriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { $0.isDeleted }
        )
        let binPhotos = (try? context.fetch(binDescriptor)) ?? []
        photosToDelete = binPhotos
        showPermanentDeleteConfirmation = true
    }

    // MARK: - Tags

    func findOrCreateTag(name: String, category: String, in context: ModelContext) -> Tag {
        let descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate<Tag> { tag in
                tag.name == name && tag.category == category
            }
        )
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let tag = Tag(name: name, category: category)
        context.insert(tag)
        return tag
    }

    func addTag(name: String, category: String, to photo: PhotoAsset) {
        guard let context = modelContext else { return }
        let tag = findOrCreateTag(name: name, category: category, in: context)
        if !photo.tags.contains(where: { $0.id == tag.id }) {
            photo.tags.append(tag)
            try? context.save()

            writeMetadataInBackground([metadataWriteItem(for: photo)])
        }
        refreshTagLists(newTag: tag)
        updateSidebarAfterChange()
    }

    func addTagToSelection(name: String, category: String) {
        guard let context = modelContext else { return }
        let tag = findOrCreateTag(name: name, category: category, in: context)

        var changed: [PhotoAsset] = []
        for photo in selectedPhotosList {
            if !photo.tags.contains(where: { $0.id == tag.id }) {
                photo.tags.append(tag)
                changed.append(photo)
            }
        }
        try? context.save()
        refreshTagLists(newTag: tag)
        updateSidebarAfterChange()

        writeMetadataInBackground(changed.map { metadataWriteItem(for: $0) })
    }

    func removeTag(_ tag: Tag, from photo: PhotoAsset) {
        photo.tags.removeAll { $0.id == tag.id }
        try? modelContext?.save()

        writeMetadataInBackground([metadataWriteItem(for: photo)])
        updateSidebarAfterChange()
    }

    func toggleTag(_ tag: Tag, for photo: PhotoAsset) {
        if isPartOfMultiSelection(photo) {
            let selected = selectedPhotosList
            let allHave = selected.allSatisfy { $0.tags.contains { $0.id == tag.id } }

            if allHave {
                guard let context = modelContext else { return }
                for p in selected {
                    p.tags.removeAll { $0.id == tag.id }
                }
                try? context.save()
                writeMetadataInBackground(selected.map { metadataWriteItem(for: $0) })
                updateSidebarAfterChange()
            } else {
                addTagToSelection(name: tag.name, category: tag.category)
            }
        } else {
            if photo.tags.contains(where: { $0.id == tag.id }) {
                removeTag(tag, from: photo)
            } else {
                addTag(name: tag.name, category: tag.category, to: photo)
            }
        }
    }

    func contextMenuTagState(_ tag: Tag, for photo: PhotoAsset) -> Bool {
        if isPartOfMultiSelection(photo) {
            return selectedPhotosList.allSatisfy { $0.tags.contains { $0.id == tag.id } }
        } else {
            return photo.tags.contains { $0.id == tag.id }
        }
    }

    func openTagEditorForContextMenu(photo: PhotoAsset) {
        if !isPartOfMultiSelection(photo) {
            selectedPhotos = [photo.id]
            lastSelectedId = photo.id
        }
        tagEditorTarget = photo
        showGridTagEditor = true
    }

    var uncategorizedTags: [Tag] {
        allTags.filter { $0.category.isEmpty }
    }

    private func clearRAWSidecarEdits(for photo: PhotoAsset) {
        photo.hasRawEdits = false
        if let rawPath = photo.rawPath {
            let existing = metadata.readMetadata(from: rawPath)
            metadata.writeSidecar(
                rating: existing.rating,
                keywords: existing.keywords,
                for: URL(fileURLWithPath: rawPath),
                editParameters: nil
            )
        }
    }

    func revertEditsForPhoto(_ photo: PhotoAsset) {
        photo.jpgEditParametersData = nil
        clearRAWSidecarEdits(for: photo)
        try? modelContext?.save()
    }

    var searchSuggestions: [String] {
        guard searchText.count >= 1 else { return [] }
        let query = searchText.lowercased()
        var seen = Set<String>()
        var results: [String] = []

        for category in tagCategories {
            if category.lowercased().contains(query) && seen.insert(category).inserted {
                results.append(category)
            }
        }

        for tag in allTags {
            if tag.name.lowercased().contains(query) && seen.insert(tag.name).inserted {
                results.append(tag.name)
            }
        }

        return Array(results.prefix(10))
    }

    // MARK: - Filtering

    func applyFilter(_ filter: SidebarFilter, isShiftHeld: Bool = false) {
        if filter == .all {
            activeFilters.removeAll()
            viewingBin = false
            loadExistingData()
            applySearch()
            return
        }

        if filter == .bin {
            activeFilters = [.bin]
            viewingBin = true
            loadExistingData()
            return
        }

        // Leaving bin mode
        if viewingBin {
            activeFilters.removeAll()
            viewingBin = false
        }

        if isShiftHeld {
            if activeFilters.contains(filter) {
                activeFilters.remove(filter)
            } else {
                activeFilters.insert(filter)
            }
        } else {
            // Auto-combine: replace within same category, keep different categories
            let newCategory = filter.filterCategory
            activeFilters = activeFilters.filter { $0.filterCategory != newCategory }
            activeFilters.insert(filter)
        }

        loadExistingData()
        applyActiveFilters()
    }

    private func applyActiveFilters() {
        guard !viewingBin, !activeFilters.isEmpty else {
            applySearch()
            return
        }

        var filtered = allPhotos
        let byCategory = Dictionary(grouping: activeFilters) { $0.filterCategory }

        for (_, filters) in byCategory {
            filtered = filtered.filter { photo in
                filters.contains { $0.matches(photo) }
            }
        }

        photos = filtered
        recomputeCrossFilterCounts()
        applySearch()
    }

    /// Recompute badge counts for each filter category based on photos matching the OTHER categories.
    /// This gives faceted-search behavior: selecting "3 stars" updates tag badges to show
    /// how many 3-star photos have each tag, and vice versa.
    private func recomputeCrossFilterCounts() {
        let filters = Array(activeFilters)

        // Rating counts: base = photos filtered by everything EXCEPT ratings
        let nonRating = filters.filter { $0.filterCategory != "rating" }
        let ratingBase = applyFilterGroup(nonRating)
        var newRatingCounts: [Int: Int] = [:]
        for photo in ratingBase {
            newRatingCounts[photo.rating, default: 0] += 1
        }
        ratingCounts = newRatingCounts

        // Tag + category counts: base = photos filtered by everything EXCEPT tags
        let nonTag = filters.filter { $0.filterCategory != "tag" }
        let tagBase = applyFilterGroup(nonTag)
        var newCatCounts: [String: Int] = [:]
        var newTagCounts: [UUID: Int] = [:]
        for photo in tagBase {
            var seenCategories = Set<String>()
            for tag in photo.tags {
                newTagCounts[tag.id, default: 0] += 1
                if !tag.category.isEmpty && seenCategories.insert(tag.category).inserted {
                    newCatCounts[tag.category, default: 0] += 1
                }
            }
        }
        categoryCounts = newCatCounts
        tagCounts = newTagCounts

        // File type counts: base = photos filtered by everything EXCEPT file type
        let nonFileType = filters.filter { $0.filterCategory != "fileType" }
        let fileTypeBase = applyFilterGroup(nonFileType)
        var jpgC = 0
        var rawC = 0
        for photo in fileTypeBase {
            if photo.jpgPath != nil { jpgC += 1 }
            if photo.rawPath != nil { rawC += 1 }
        }
        jpgCount = jpgC
        rawCount = rawC
    }

    private func applyFilterGroup(_ filters: [SidebarFilter]) -> [PhotoAsset] {
        guard !filters.isEmpty else { return allPhotos }

        var filtered = allPhotos
        let byCategory = Dictionary(grouping: filters) { $0.filterCategory }

        for (_, categoryFilters) in byCategory {
            filtered = filtered.filter { photo in
                categoryFilters.contains { $0.matches(photo) }
            }
        }
        return filtered
    }

    func applyCurrentFilter() {
        loadExistingData()
        applyActiveFilters()
    }

    func applySearch() {
        guard !searchText.isEmpty else { return }

        let query = searchText.lowercased()
        photos = photos.filter { photo in
            photo.fileName.lowercased().contains(query) ||
            photo.tags.contains { $0.name.lowercased().contains(query) || $0.category.lowercased().contains(query) }
        }
    }

    // MARK: - Sorting

    func toggleSortOrder() {
        sortNewestFirst.toggle()
        applyCurrentFilter()
    }

    // MARK: - Navigation

    func openDetail(for photo: PhotoAsset) {
        selectedDetailPhoto = photo
        showingDetail = true
    }

    func navigateDetail(direction: Int) {
        guard let current = selectedDetailPhoto,
              let index = photos.firstIndex(where: { $0.id == current.id }) else { return }

        let newIndex = index + direction
        if newIndex >= 0 && newIndex < photos.count {
            // Save edits before navigating
            if isEditing {
                saveCurrentEditParameters()
            }
            selectedDetailPhoto = photos[newIndex]
        }
    }

    func closeDetail() {
        if isEditing {
            stopEditing(save: true)
        }
        if let photo = selectedDetailPhoto {
            selectedPhotos = [photo.id]
            lastSelectedId = photo.id
        }
        showingDetail = false
        selectedDetailPhoto = nil
    }

    // MARK: - Grid Keyboard Navigation

    func navigateGrid(direction: GridDirection, extendSelection: Bool) {
        guard !photos.isEmpty else { return }

        let currentIndex: Int
        if let lastId = lastSelectedId,
           let idx = photos.firstIndex(where: { $0.id == lastId }) {
            currentIndex = idx
        } else {
            let photo = photos[0]
            selectedPhotos = [photo.id]
            lastSelectedId = photo.id
            return
        }

        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = max(0, currentIndex - 1)
        case .right:
            targetIndex = min(photos.count - 1, currentIndex + 1)
        case .up:
            targetIndex = max(0, currentIndex - gridColumns)
        case .down:
            targetIndex = min(photos.count - 1, currentIndex + gridColumns)
        }

        guard targetIndex != currentIndex else { return }

        let targetPhoto = photos[targetIndex]

        if extendSelection {
            let rangeStart = min(currentIndex, targetIndex)
            let rangeEnd = max(currentIndex, targetIndex)
            for i in rangeStart...rangeEnd {
                selectedPhotos.insert(photos[i].id)
            }
        } else {
            selectedPhotos = [targetPhoto.id]
        }
        lastSelectedId = targetPhoto.id
    }

    enum GridDirection {
        case left, right, up, down
    }

    // MARK: - Keyboard Rating Helper

    func setRatingForSelectionOrCurrent(_ rating: Int) {
        if showingDetail, let photo = selectedDetailPhoto {
            setRating(rating, for: photo)
        } else if !selectedPhotos.isEmpty {
            setRatingForSelection(rating)
        }
    }

    // MARK: - Lightweight Tag Refresh

    private func refreshTagLists(newTag: Tag) {
        if !allTags.contains(where: { $0.id == newTag.id }) {
            allTags.append(newTag)
            allTags.sort { ($0.category, $0.name) < ($1.category, $1.name) }
        }
        if !newTag.category.isEmpty && !tagCategories.contains(newTag.category) {
            tagCategories.append(newTag.category)
        }
    }

    // MARK: - Background Metadata Write-back

    private func metadataWriteItem(for photo: PhotoAsset) -> (rating: Int, keywords: [String], path: String) {
        (photo.rating, photo.tags.map(\.fullName), photo.displayPath)
    }

    private func writeMetadataInBackground(_ items: [(rating: Int, keywords: [String], path: String)]) {
        guard !items.isEmpty else { return }
        let metadata = self.metadata
        Task.detached {
            for item in items {
                metadata.writeMetadata(rating: item.rating, keywords: item.keywords, toImageAt: item.path)
            }
        }
    }

    // MARK: - Zoom

    func zoomIn() {
        if gridColumns > 2 {
            gridColumns -= 1
        }
    }

    func zoomOut() {
        if gridColumns < 20 {
            gridColumns += 1
        }
    }

    // MARK: - Image Editing

    func startEditing(photo: PhotoAsset, isRAW: Bool) {
        // Save any current edits first
        if isEditing {
            saveCurrentEditParameters()
        }

        editingRAW = isRAW
        selectedDetailPhoto = photo

        // Load existing edit parameters
        if isRAW, let rawPath = photo.rawPath {
            editParameters = metadata.readEditParameters(forRAWAt: rawPath) ?? EditParameters()
        } else {
            editParameters = photo.jpgEditParameters ?? EditParameters()
        }

        isEditing = true
        showOriginal = false
        showSideBySide = false
        showJPGComparison = false
        jpgComparisonImage = nil
        isCropping = false

        // Pre-load the image into the editing service cache so first slider move is instant
        let path = isRAW ? photo.rawPath : photo.jpgPath
        if let path {
            let url = URL(fileURLWithPath: path)
            Task {
                if isRAW {
                    await ImageEditingService.shared.prepareRAW(url: url)
                } else {
                    await ImageEditingService.shared.prepareStandard(url: url)
                }
                updateEditPreview()
            }
        }
    }

    func stopEditing(save: Bool = true) {
        if save {
            saveCurrentEditParameters()
        }
        isEditing = false
        editedPreviewImage = nil
        fullResEditImage = nil
        fullResRenderTask?.cancel()
        showOriginal = false
        showSideBySide = false
        showJPGComparison = false
        jpgComparisonImage = nil
        isCropping = false
        editParameters = EditParameters()
        ImageEditingService.shared.clearCache()
    }

    func saveCurrentEditParameters() {
        guard let photo = selectedDetailPhoto else { return }

        if editParameters.isDefault {
            if editingRAW {
                clearRAWSidecarEdits(for: photo)
            } else {
                photo.jpgEditParametersData = nil
            }
        } else {
            if editingRAW, let rawPath = photo.rawPath {
                metadata.writeEditParameters(editParameters, forRAWAt: rawPath)
                photo.hasRawEdits = true
            } else {
                photo.jpgEditParameters = editParameters
            }
        }

        try? modelContext?.save()
    }

    /// Reset all sliders to zero without saving to disk yet.
    func resetAllParameters() {
        editParameters = EditParameters()
        updateEditPreview()
    }

    func revertEdits() {
        editParameters = EditParameters()
        if let photo = selectedDetailPhoto {
            if editingRAW {
                clearRAWSidecarEdits(for: photo)
            } else {
                photo.jpgEditParametersData = nil
            }
            try? modelContext?.save()
        }
        updateEditPreview()
    }

    /// When editing RAW, copy the paired JPG's saved edit parameters.
    func copyJPGSettingsToRAW() {
        guard editingRAW, let photo = selectedDetailPhoto else { return }
        if let jpgParams = photo.jpgEditParameters {
            editParameters = jpgParams
        }
        updateEditPreview()
    }

    /// Whether "Copy from JPG" is available (editing RAW + paired JPG has saved edits).
    var canCopyFromJPG: Bool {
        editingRAW && selectedDetailPhoto?.jpgEditParameters != nil
    }

    func updateEditPreview() {
        guard isEditing, let photo = selectedDetailPhoto else { return }

        previewTask?.cancel()
        fullResRenderTask?.cancel()
        fullResEditImage = nil
        renderGeneration += 1
        let generation = renderGeneration
        let params = editParameters
        let isRAW = editingRAW
        let path = isRAW ? photo.rawPath : photo.jpgPath
        guard let path else { return }

        let url = URL(fileURLWithPath: path)
        let maxSize = CGSize(width: 1600, height: 1100)

        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, renderGeneration == generation else { return }

            let result: NSImage?
            if isRAW {
                result = await ImageEditingService.shared.processRAW(url: url, parameters: params, maxSize: maxSize)
            } else {
                result = await ImageEditingService.shared.processStandard(url: url, parameters: params, maxSize: maxSize)
            }

            if renderGeneration == generation {
                editedPreviewImage = result
                renderFullResEdit(url: url, params: params, isRAW: isRAW, generation: generation)
            }
        }
    }

    private func renderFullResEdit(url: URL, params: EditParameters, isRAW: Bool, generation: Int) {
        fullResRenderTask?.cancel()
        fullResRenderTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, renderGeneration == generation else { return }

            let result: NSImage?
            if isRAW {
                result = await ImageEditingService.shared.processRAW(url: url, parameters: params)
            } else {
                result = await ImageEditingService.shared.processStandard(url: url, parameters: params)
            }

            if renderGeneration == generation {
                fullResEditImage = result
            }
        }
    }

    // MARK: - JPG Comparison

    func toggleJPGComparison() {
        showJPGComparison.toggle()
        if showJPGComparison {
            showSideBySide = false
            loadJPGComparisonImage()
        } else {
            jpgComparisonImage = nil
        }
    }

    func loadJPGComparisonImage() {
        guard let photo = selectedDetailPhoto, let jpgPath = photo.jpgPath else { return }

        Task {
            if let params = photo.jpgEditParameters, !params.isDefault {
                let url = URL(fileURLWithPath: jpgPath)
                jpgComparisonImage = await ImageEditingService.shared.processStandard(url: url, parameters: params)
            } else {
                jpgComparisonImage = await ImageLoader.shared.loadFullResolution(for: jpgPath)
            }
        }
    }

    // MARK: - Crop

    func enterCropMode() {
        isCropping = true
        cropRect = editParameters.cropRect ?? .full
    }

    func applyCrop() {
        editParameters.cropRect = cropRect.isApproximatelyFull ? nil : cropRect
        isCropping = false
    }

    func cancelCrop() {
        cropRect = editParameters.cropRect ?? .full
        isCropping = false
    }

    // MARK: - Export

    func exportRAWToJPG(replaceExisting: Bool) {
        guard let photo = selectedDetailPhoto, let rawPath = photo.rawPath else { return }

        let rawURL = URL(fileURLWithPath: rawPath)
        let params = editParameters

        let outputURL: URL
        if replaceExisting, let jpgPath = photo.jpgPath {
            outputURL = URL(fileURLWithPath: jpgPath)
        } else {
            let dir = rawURL.deletingLastPathComponent()
            let stem = rawURL.deletingPathExtension().lastPathComponent
            outputURL = dir.appendingPathComponent("\(stem)-raw-edit.jpg")
        }

        Task {
            let success = await ImageEditingService.shared.exportRAWToJPEG(
                rawURL: rawURL, parameters: params, outputURL: outputURL
            )
            if success {
                // Update the photo's jpgPath if a new file was created
                if !replaceExisting || photo.jpgPath == nil {
                    photo.jpgPath = outputURL.path
                }
                try? modelContext?.save()
            }
        }
    }

    func exportJPGPermanent() {
        guard let photo = selectedDetailPhoto, let jpgPath = photo.jpgPath else { return }

        let url = URL(fileURLWithPath: jpgPath)
        let params = editParameters

        Task {
            let success = await ImageEditingService.shared.exportStandardToJPEG(
                sourceURL: url, parameters: params, outputURL: url
            )
            if success {
                // Clear saved edit parameters since they're baked in
                photo.jpgEditParametersData = nil
                editParameters = EditParameters()
                try? modelContext?.save()
                editedPreviewImage = nil
                fullResEditImage = nil
            }
        }
    }

    // MARK: - Presets

    func loadPresets() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<EditPreset>(sortBy: [SortDescriptor(\.name)])
        editPresets = (try? context.fetch(descriptor)) ?? []
    }

    func savePreset() {
        guard let context = modelContext else { return }
        let name = presetNameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let preset = EditPreset(name: name, parameters: editParameters)
        context.insert(preset)
        try? context.save()
        presetNameInput = ""
        loadPresets()
    }

    func deletePreset(_ preset: EditPreset) {
        modelContext?.delete(preset)
        try? modelContext?.save()
        loadPresets()
    }

    func applyPreset(_ preset: EditPreset) {
        editParameters = preset.parameters
        updateEditPreview()
    }

    func applyPresetToSelection(_ preset: EditPreset) {
        let params = preset.parameters

        for photo in selectedPhotosList {
            if photo.jpgPath != nil {
                photo.jpgEditParameters = params
            }
            if let rawPath = photo.rawPath {
                metadata.writeEditParameters(params, forRAWAt: rawPath)
                photo.hasRawEdits = true
            }
        }

        try? modelContext?.save()
    }
}
