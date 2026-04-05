import SwiftUI
import SwiftData

enum SidebarFilter: Hashable {
    case all
    case unrated
    case rated(Int)
    case tag(UUID)
    case tagCategory(String)
    case bin
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
    var currentFilter: SidebarFilter = .all
    var allTags: [Tag] = []
    var tagCategories: [String] = []
    var showDeleteConfirmation: Bool = false
    var showPermanentDeleteConfirmation: Bool = false
    var photosToDelete: [PhotoAsset] = []
    var currentLibrary: PhotoLibrary?
    var showFolderPicker: Bool = false
    var binCount: Int = 0
    var viewingBin: Bool = false

    private let scanner = FolderScanner()
    private let metadata = MetadataService.shared
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadExistingData()
    }

    // MARK: - Data Loading

    func loadExistingData() {
        guard let context = modelContext else { return }

        let photoDescriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { !$0.isDeleted },
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        allPhotos = (try? context.fetch(photoDescriptor)) ?? []

        let binDescriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { $0.isDeleted },
            sortBy: [SortDescriptor(\.creationDate, order: .reverse)]
        )
        let binPhotos = (try? context.fetch(binDescriptor)) ?? []
        binCount = binPhotos.count

        if viewingBin {
            photos = binPhotos
        } else {
            photos = allPhotos
        }

        let tagDescriptor = FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.category), SortDescriptor(\.name)])
        allTags = (try? context.fetch(tagDescriptor)) ?? []
        tagCategories = Array(Set(allTags.map(\.category))).sorted()

        let libDescriptor = FetchDescriptor<PhotoLibrary>()
        currentLibrary = (try? context.fetch(libDescriptor))?.first
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

            // Get existing photo file names for deduplication
            let existingDescriptor = FetchDescriptor<PhotoAsset>()
            let existing = (try? context.fetch(existingDescriptor)) ?? []
            let existingByKey = Dictionary(
                uniqueKeysWithValues: existing.map { ("\($0.folderPath)/\($0.fileName)", $0) }
            )

            var newCount = 0
            for photo in discovered {
                let key = "\(photo.folderPath)/\(photo.fileName)"
                if let existingPhoto = existingByKey[key] {
                    // Update paths if changed
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

                    // Read existing metadata from file
                    let filePath = photo.jpgPath ?? photo.rawPath ?? ""
                    if !filePath.isEmpty {
                        let meta = metadata.readMetadata(from: filePath)
                        asset.rating = meta.rating

                        // Import tags from keywords
                        for keyword in meta.keywords {
                            let parts = keyword.split(separator: ":", maxSplits: 1)
                            let category: String
                            let name: String
                            if parts.count == 2 {
                                category = String(parts[0])
                                name = String(parts[1])
                            } else {
                                category = "general"
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
            loadExistingData()
            isScanning = false
        }
    }

    // MARK: - Rating

    func setRating(_ rating: Int, for photo: PhotoAsset) {
        photo.rating = rating
        try? modelContext?.save()

        // Write back to file
        let keywords = photo.tags.map(\.fullName)
        metadata.writeMetadata(rating: rating, keywords: keywords, toImageAt: photo.displayPath)
    }

    func setRatingForSelection(_ rating: Int) {
        guard let context = modelContext else { return }
        for id in selectedPhotos {
            if let photo = photos.first(where: { $0.id == id }) {
                photo.rating = rating
                let keywords = photo.tags.map(\.fullName)
                metadata.writeMetadata(rating: rating, keywords: keywords, toImageAt: photo.displayPath)
            }
        }
        try? context.save()
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

    func deleteSelected() {
        let toDelete = photos.filter { selectedPhotos.contains($0.id) }
        guard !toDelete.isEmpty else { return }

        if viewingBin {
            // In bin: ask for permanent delete confirmation
            photosToDelete = toDelete
            showPermanentDeleteConfirmation = true
        } else {
            // Normal view: move to bin (soft delete)
            moveToBin(toDelete)
        }
    }

    func deletePhoto(_ photo: PhotoAsset) {
        if viewingBin {
            photosToDelete = [photo]
            showPermanentDeleteConfirmation = true
        } else {
            moveToBin([photo])
        }
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
        let toRestore = photos.filter { selectedPhotos.contains($0.id) }
        restoreFromBin(toRestore)
    }

    func confirmPermanentDelete() {
        guard let context = modelContext else { return }

        for photo in photosToDelete {
            if let jpgPath = photo.jpgPath {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: jpgPath), resultingItemURL: nil)
            }
            if let rawPath = photo.rawPath {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: rawPath), resultingItemURL: nil)
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

            // Write back
            let keywords = photo.tags.map(\.fullName)
            metadata.writeMetadata(rating: photo.rating, keywords: keywords, toImageAt: photo.displayPath)
        }
        loadExistingData()
    }

    func addTagToSelection(name: String, category: String) {
        guard let context = modelContext else { return }
        let tag = findOrCreateTag(name: name, category: category, in: context)

        for id in selectedPhotos {
            if let photo = photos.first(where: { $0.id == id }) {
                if !photo.tags.contains(where: { $0.id == tag.id }) {
                    photo.tags.append(tag)
                    let keywords = photo.tags.map(\.fullName)
                    metadata.writeMetadata(rating: photo.rating, keywords: keywords, toImageAt: photo.displayPath)
                }
            }
        }
        try? context.save()
        loadExistingData()
    }

    func removeTag(_ tag: Tag, from photo: PhotoAsset) {
        photo.tags.removeAll { $0.id == tag.id }
        try? modelContext?.save()

        let keywords = photo.tags.map(\.fullName)
        metadata.writeMetadata(rating: photo.rating, keywords: keywords, toImageAt: photo.displayPath)
        loadExistingData()
    }

    // MARK: - Filtering

    func applyFilter(_ filter: SidebarFilter) {
        currentFilter = filter
        viewingBin = (filter == .bin)
        loadExistingData()

        switch filter {
        case .all, .bin:
            break // loadExistingData already set photos correctly
        case .unrated:
            photos = allPhotos.filter { $0.rating == 0 }
        case .rated(let stars):
            photos = allPhotos.filter { $0.rating == stars }
        case .tag(let tagId):
            photos = allPhotos.filter { photo in
                photo.tags.contains { $0.id == tagId }
            }
        case .tagCategory(let category):
            photos = allPhotos.filter { photo in
                photo.tags.contains { $0.category == category }
            }
        }
        applySearch()
    }

    func applySearch() {
        guard !searchText.isEmpty else {
            if currentFilter == .all {
                photos = allPhotos
            }
            return
        }

        let query = searchText.lowercased()
        photos = photos.filter { photo in
            photo.fileName.lowercased().contains(query) ||
            photo.tags.contains { $0.name.lowercased().contains(query) || $0.category.lowercased().contains(query) }
        }
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
            selectedDetailPhoto = photos[newIndex]
        }
    }

    func closeDetail() {
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
            // Nothing selected — start at first photo
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
            // Shift+Arrow: extend selection range
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
}
