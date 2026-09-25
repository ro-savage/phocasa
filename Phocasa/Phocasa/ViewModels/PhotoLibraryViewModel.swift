import SwiftUI
import SwiftData

@Observable @MainActor
final class PhotoLibraryViewModel {
    /// The photos the grid shows. Only the in-memory library code below writes it: it keeps `index(of:)` and the
    /// grid bookkeeping in step, so an outside assignment would silently desync them.
    private(set) var photos: [PhotoAsset] = []
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
    /// Tags of each non-empty category, sorted by name (the order of `allTags`).
    private(set) var tagsByCategory: [String: [Tag]] = [:]
    /// Tags without a category, in `allTags` order.
    private(set) var uncategorizedTags: [Tag] = []

    // MARK: - In-Memory Library State
    // `loadExistingData()` fetches once. Filtering, search, sort, counts and mutations then work on
    // this state. Each facts array lines up index-for-index with its photo array, so hot paths read
    // plain values and never model properties (each model read costs ~0.8 µs; spec §A1).

    @ObservationIgnored private var allFacts: [PhotoFacts] = []
    /// Photos in the bin, in the same creation-date order as `allPhotos`.
    @ObservationIgnored private var binPhotos: [PhotoAsset] = []
    @ObservationIgnored private var binFacts: [PhotoFacts] = []
    /// Bumped whenever `allPhotos` / `binPhotos` gain, lose or reorder photos.
    @ObservationIgnored private var libraryVersion = 0
    @ObservationIgnored private var binVersion = 0
    /// How `photos` was derived.
    @ObservationIgnored private var grid = GridState()
    /// Positions in `photos` by id. Rebuilt on first use after `photos` changes.
    @ObservationIgnored private var photoIndexCache: [UUID: Int]?
    /// Sidebar counts over the whole library with no filters. Every mutation keeps them current.
    @ObservationIgnored private var libraryCounts = FacetCounts()
    /// Faceted counts for the active filters, kept current the same way until the filters change.
    @ObservationIgnored private var filteredCounts: (filters: Set<SidebarFilter>, counts: FacetCounts)?
    @ObservationIgnored private var tagFacts = TagFactsCache()
    /// Lowercased names for `searchSuggestions`, in `tagCategories` / `allTags` order.
    private var categorySearchKeys: [(category: String, key: String)] = []
    private var tagNameSearchKeys: [(name: String, key: String)] = []

    /// What `photos` shows, so that a refresh that changes nothing costs nothing and small mutations
    /// can patch `photos` in place instead of re-filtering the whole library.
    private struct GridState {
        var query = PhotoQuery()
        var showsBin = false
        /// `libraryVersion` / `binVersion` of the shown list when `photos` was last brought up to date.
        var sourceVersion = -1
        /// `photos[i].id`, without reading the models.
        var ids: [UUID] = []
        /// The position in the shown list of each photo in `photos`; nil when `photos` is the whole list.
        var sourceIndices: [Int]?
    }

    /// A photo's place in the library (`allPhotos`) or the bin (`binPhotos`).
    private struct ListPosition {
        var inBin: Bool
        var index: Int
    }

    /// Mutations touching more photos than this re-filter the grid instead of patching it.
    private static let patchLimit = 8

    // MARK: - Image Editing State
    /// The edit in progress: its photo, parameters, renders, comparison and crop state. Exists only while editing.
    private(set) var editSession: EditSession?
    var isEditing: Bool { editSession != nil }
    /// What the last editing session saved, so the detail view shows the saved edit at once rather than the
    /// unedited photo. Cleared when the detail photo changes or the detail view closes.
    private(set) var savedEditHandoff: SavedEditHandoff?
    /// Bumped when an export rewrites a photo's file, so the detail view decodes it again.
    private(set) var editedFilesVersion = 0
    var editPresets: [EditPreset] = []
    var presetNameInput: String = ""

    var selectedPhotosList: [PhotoAsset] {
        selectedPhotos.compactMap { index(of: $0) }.sorted().map { photos[$0] }
    }

    func isPartOfMultiSelection(_ photo: PhotoAsset) -> Bool {
        selectedPhotos.count > 1 && selectedPhotos.contains(photo.id)
    }

    private let scanner = FolderScanner()
    private let metadata = MetadataService.shared
    private var modelContext: ModelContext?
    /// Photos whose files were missing at the last availability check. Tracking the missing set
    /// (rather than the available set) means photos inserted or restored since the last check
    /// stay visible instead of silently disappearing.
    private var missingPhotoIDs: Set<UUID> = []
    private var needsAvailabilityCheck = true

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadExistingData()
        loadPresets()
        rescanCurrentLibrary()
    }

    // MARK: - File Availability

    private func checkFileAvailability(for photos: [PhotoAsset]) {
        var missing = Set<UUID>()
        let fm = FileManager.default
        for photo in photos {
            let jpgExists = photo.jpgPath.map { fm.fileExists(atPath: $0) } ?? false
            let rawExists = photo.rawPath.map { fm.fileExists(atPath: $0) } ?? false
            if !jpgExists && !rawExists {
                missing.insert(photo.id)
            }
        }
        missingPhotoIDs = missing
        needsAvailabilityCheck = false
    }

    func refreshAvailability() {
        needsAvailabilityCheck = true
        loadExistingData()
    }

    // MARK: - Data Loading

    /// The one place (besides scans) that reads photos and tags from the store. Everything else works
    /// on the in-memory state this builds.
    func loadExistingData() {
        guard let context = modelContext else { return }

        let tags = (try? context.fetch(FetchDescriptor<Tag>(sortBy: Self.tagSortOrder))) ?? []
        tagFacts = TagFactsCache(tags: tags)

        let sortOrder: SortOrder = sortNewestFirst ? .reverse : .forward
        let photoDescriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { !$0.isDeleted },
            sortBy: [SortDescriptor(\.creationDate, order: sortOrder)]
        )
        let fetchedPhotos = (try? context.fetch(photoDescriptor)) ?? []

        if needsAvailabilityCheck {
            checkFileAvailability(for: fetchedPhotos)
        }

        let fetchedFacts = makeFacts(for: fetchedPhotos)
        if missingPhotoIDs.isEmpty {
            allPhotos = fetchedPhotos
            allFacts = fetchedFacts
        } else {
            let available = fetchedFacts.indices.filter { !missingPhotoIDs.contains(fetchedFacts[$0].id) }
            allPhotos = available.map { fetchedPhotos[$0] }
            allFacts = available.map { fetchedFacts[$0] }
        }

        let binDescriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { $0.isDeleted },
            sortBy: [SortDescriptor(\.creationDate, order: sortOrder)]
        )
        binPhotos = (try? context.fetch(binDescriptor)) ?? []
        binFacts = makeFacts(for: binPhotos)

        libraryVersion += 1
        binVersion += 1
        libraryCounts = PhotoQuery().facetCounts(over: allFacts)
        filteredCounts = nil
        setTagLists(tags)
        refreshVisiblePhotos()
        sortTagCategories()

        let libDescriptor = FetchDescriptor<PhotoLibrary>()
        currentLibrary = (try? context.fetch(libDescriptor))?.first
    }

    /// `allTags` order: by category, then name (the same descriptors sort the fetch and in-memory inserts).
    private static var tagSortOrder: [SortDescriptor<Tag>] {
        [SortDescriptor(\.category), SortDescriptor(\.name)]
    }

    private func makeFacts(for photos: [PhotoAsset]) -> [PhotoFacts] {
        var facts: [PhotoFacts] = []
        facts.reserveCapacity(photos.count)
        for photo in photos {
            facts.append(PhotoFacts(photo, tags: &tagFacts))
        }
        return facts
    }

    // MARK: - In-Memory Library

    /// Position of the photo in `photos`, in O(1) (the index is rebuilt on first use after a change).
    func index(of id: UUID) -> Int? {
        access(keyPath: \.photos) // the result changes whenever `photos` does
        return photoIndex()[id]
    }

    private func photoIndex() -> [UUID: Int] {
        if let photoIndexCache { return photoIndexCache }
        var index = [UUID: Int](minimumCapacity: grid.ids.count)
        for (position, id) in grid.ids.enumerated() { index[id] = position }
        photoIndexCache = index
        return index
    }

    private var currentQuery: PhotoQuery {
        PhotoQuery(filters: activeFilters, searchText: searchText)
    }

    private func listVersion(inBin: Bool) -> Int {
        inBin ? binVersion : libraryVersion
    }

    /// Whether `photos` is up to date with the current contents of that list (so it can be patched).
    private func gridShowsCurrent(inBin: Bool) -> Bool {
        grid.showsBin == inBin && grid.sourceVersion == listVersion(inBin: inBin)
    }

    /// Brings `photos` and the sidebar counts up to date with the filters, the search text and the
    /// shown list (library or bin). Re-filters only when one of those changed since `photos` was
    /// built or patched. Reads no model properties.
    private func refreshVisiblePhotos() {
        let query = currentQuery
        if grid.query != query || !gridShowsCurrent(inBin: viewingBin) {
            rebuildGrid(query: query)
        }
        publishCounts()
    }

    private func rebuildGrid(query: PhotoQuery) {
        let listPhotos = viewingBin ? binPhotos : allPhotos
        let listFacts = viewingBin ? binFacts : allFacts
        var state = GridState(query: query, showsBin: viewingBin, sourceVersion: listVersion(inBin: viewingBin))
        if query.matchesEverything {
            state.ids = listFacts.map(\.id)
            photos = listPhotos
        } else {
            let matching = query.matchingIndices(in: listFacts)
            state.ids = matching.map { listFacts[$0].id }
            state.sourceIndices = matching
            photos = matching.map { listPhotos[$0] }
        }
        grid = state
        photoIndexCache = nil
    }

    /// Publishes the counts for the active filters. Counts cover the library (never the bin) and
    /// ignore search, so search keystrokes and the bin view reuse them.
    private func publishCounts() {
        let counts: FacetCounts
        if activeFilters.allSatisfy({ $0.category == .special }) {
            filteredCounts = nil
            counts = libraryCounts
        } else if let cached = filteredCounts, cached.filters == activeFilters {
            counts = cached.counts
        } else {
            counts = PhotoQuery(filters: activeFilters).facetCounts(over: allFacts)
            filteredCounts = (activeFilters, counts)
        }
        // Assign only on change, so the sidebar isn't invalidated for nothing.
        if ratingCounts != counts.ratings { ratingCounts = counts.ratings }
        if tagCounts != counts.tags { tagCounts = counts.tags }
        if categoryCounts != counts.categories { categoryCounts = counts.categories }
        if jpgCount != counts.jpg { jpgCount = counts.jpg }
        if rawCount != counts.raw { rawCount = counts.raw }
        if binCount != binPhotos.count { binCount = binPhotos.count }
    }

    /// Keeps the counts current when a library photo changes, joins (`old == nil`) or leaves
    /// (`new == nil`) the library.
    private func countLibraryChange(from old: PhotoFacts?, to new: PhotoFacts?) {
        PhotoQuery().updateFacetCounts(&libraryCounts, replacing: old, with: new)
        if let filters = filteredCounts?.filters {
            PhotoQuery(filters: filters).updateFacetCounts(&filteredCounts!.counts, replacing: old, with: new)
        }
    }

    /// Finds a loaded photo: O(1) through the grid when it is shown, a scan of the facts otherwise.
    private func position(of id: UUID, useIndex: Bool) -> ListPosition? {
        if gridShowsCurrent(inBin: grid.showsBin) {
            let shownAt = useIndex || photoIndexCache != nil ? photoIndex()[id] : grid.ids.firstIndex(of: id)
            if let shownAt {
                return ListPosition(inBin: grid.showsBin, index: grid.sourceIndices?[shownAt] ?? shownAt)
            }
        }
        // Scan the smaller list first: that's usually the bin.
        let binFirst = binFacts.count <= allFacts.count
        for inBin in [binFirst, !binFirst] {
            if let index = Self.firstIndex(of: id, in: inBin ? binFacts : allFacts) {
                return ListPosition(inBin: inBin, index: index)
            }
        }
        return nil
    }

    /// A linear scan that reads only the `id` field of each element (no struct copies).
    private static func firstIndex(of id: UUID, in facts: [PhotoFacts]) -> Int? {
        facts.withUnsafeBufferPointer { buffer in
            for i in buffer.indices where buffer[i].id == id { return i }
            return nil
        }
    }

    /// For code that changes a photo's rating, tags, file paths or file name directly rather than
    /// through this view model's methods (for example, an export that gives a RAW-only photo a JPG):
    /// updates the in-memory library, the grid and the counts to match the models.
    func photosDidChange(_ changed: [PhotoAsset]) {
        applyFactChanges(changed)
        refreshVisiblePhotos()
        sortTagCategories()
    }

    /// Re-reads the facts of photos whose rating or tags changed (a few model reads each), and
    /// applies them to the counts and the grid.
    private func applyFactChanges(_ changed: [PhotoAsset]) {
        guard !changed.isEmpty else { return }
        // Locate everything first: patching the grid below invalidates the index.
        var located: [(facts: PhotoFacts, position: ListPosition)] = []
        for photo in changed {
            let new = PhotoFacts(photo, tags: &tagFacts)
            if let position = position(of: new.id, useIndex: changed.count > 2) {
                located.append((new, position))
            }
        }
        let patching = located.count <= Self.patchLimit
        let recount = located.count > 1_000 // cheaper than that many incremental updates
        for (new, position) in located {
            let old: PhotoFacts
            if position.inBin {
                old = binFacts[position.index]
                binFacts[position.index] = new
            } else {
                old = allFacts[position.index]
                allFacts[position.index] = new
                if !recount { countLibraryChange(from: old, to: new) }
            }
            // Only a filtered grid can gain or lose photos when facts change.
            guard patching, gridShowsCurrent(inBin: position.inBin), grid.sourceIndices != nil else { continue }
            let matches = grid.query.matches(new)
            if grid.query.matches(old) != matches {
                gridDidChangeMembership(atSource: position.index, now: matches)
            }
        }
        if recount {
            libraryCounts = PhotoQuery().facetCounts(over: allFacts)
            filteredCounts = nil
        }
        if !patching && grid.sourceIndices != nil { grid.sourceVersion = -1 } // re-filter in refreshVisiblePhotos
    }

    // MARK: - Grid Patching
    // Small mutations update `photos` in place. A filtered grid maps each shown photo to its position
    // in the shown list (`grid.sourceIndices`, ascending), so a binary search finds where it goes.

    private func firstShown(atOrAfter sourceIndex: Int, in indices: [Int]) -> Int {
        var low = 0
        var high = indices.count
        while low < high {
            let mid = (low + high) / 2
            if indices[mid] < sourceIndex { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A photo in the shown list started or stopped matching the grid's query.
    private func gridDidChangeMembership(atSource sourceIndex: Int, now matches: Bool) {
        guard var indices = grid.sourceIndices else { return }
        let shownAt = firstShown(atOrAfter: sourceIndex, in: indices)
        let isShown = shownAt < indices.count && indices[shownAt] == sourceIndex
        guard isShown != matches else {
            grid.sourceVersion = -1 // shouldn't happen; re-filter rather than patch the wrong row
            return
        }
        grid.sourceIndices = nil // keep `indices` uniquely referenced while editing it
        if matches {
            let photo = grid.showsBin ? binPhotos[sourceIndex] : allPhotos[sourceIndex]
            let id = grid.showsBin ? binFacts[sourceIndex].id : allFacts[sourceIndex].id
            photos.insert(photo, at: shownAt)
            grid.ids.insert(id, at: shownAt)
            indices.insert(sourceIndex, at: shownAt)
        } else {
            photos.remove(at: shownAt)
            grid.ids.remove(at: shownAt)
            indices.remove(at: shownAt)
        }
        grid.sourceIndices = indices
        photoIndexCache = nil
    }

    /// The shown list lost the photo at `sourceIndex`.
    private func gridDidRemove(atSource sourceIndex: Int) {
        guard var indices = grid.sourceIndices else {
            photos.remove(at: sourceIndex)
            grid.ids.remove(at: sourceIndex)
            photoIndexCache = nil
            return
        }
        grid.sourceIndices = nil
        let shownAt = firstShown(atOrAfter: sourceIndex, in: indices)
        if shownAt < indices.count && indices[shownAt] == sourceIndex {
            photos.remove(at: shownAt)
            grid.ids.remove(at: shownAt)
            indices.remove(at: shownAt)
            photoIndexCache = nil
        }
        for i in shownAt..<indices.count { indices[i] -= 1 }
        grid.sourceIndices = indices
    }

    /// The shown list gained `photo` at `sourceIndex`.
    private func gridDidInsert(_ photo: PhotoAsset, facts: PhotoFacts, atSource sourceIndex: Int) {
        guard var indices = grid.sourceIndices else {
            photos.insert(photo, at: sourceIndex)
            grid.ids.insert(facts.id, at: sourceIndex)
            photoIndexCache = nil
            return
        }
        grid.sourceIndices = nil
        let shownAt = firstShown(atOrAfter: sourceIndex, in: indices)
        for i in shownAt..<indices.count { indices[i] += 1 }
        if grid.query.matches(facts) {
            photos.insert(photo, at: shownAt)
            grid.ids.insert(facts.id, at: shownAt)
            indices.insert(sourceIndex, at: shownAt)
            photoIndexCache = nil
        }
        grid.sourceIndices = indices
    }

    // MARK: - Tag Lists

    /// Rebuilds everything derived from the tag list. `tags` must be sorted by `tagSortOrder`.
    /// `tagCategories` keeps its order until the next `sortTagCategories()`.
    private func setTagLists(_ tags: [Tag]) {
        var byCategory: [String: [Tag]] = [:]
        var uncategorized: [Tag] = []
        var nameKeys: [(name: String, key: String)] = []
        nameKeys.reserveCapacity(tags.count)
        for tag in tags {
            let name = tag.name
            let category = tag.category
            if category.isEmpty {
                uncategorized.append(tag)
            } else {
                byCategory[category, default: []].append(tag)
            }
            nameKeys.append((name, name.lowercased()))
        }
        allTags = tags
        tagsByCategory = byCategory
        uncategorizedTags = uncategorized
        tagNameSearchKeys = nameKeys
    }

    /// Orders `tagCategories` by how many library photos have a tag in each (descending), then by
    /// name. Called after loads and after changes to tags or to which photos are in the library.
    private func sortTagCategories() {
        let counts = libraryCounts.categories
        let sorted = tagsByCategory.keys.sorted { a, b in
            let countA = counts[a, default: 0]
            let countB = counts[b, default: 0]
            if countA != countB { return countA > countB }
            return a < b
        }
        if sorted != tagCategories { tagCategories = sorted }
        categorySearchKeys = sorted.map { ($0, $0.lowercased()) }
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
        applyFactChanges([photo])
        refreshVisiblePhotos()
    }

    func setRatingForSelection(_ rating: Int) {
        guard let context = modelContext else { return }
        let selection = selectedPhotosList
        for photo in selection {
            photo.rating = rating
        }
        try? context.save()

        writeMetadataInBackground(selection.map { metadataWriteItem(for: $0) })
        applyFactChanges(selection)
        refreshVisiblePhotos()
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
        selectedPhotos = Set(grid.ids)
    }

    func clearSelection() {
        selectedPhotos.removeAll()
        lastSelectedId = nil
    }

    func rangeSelect(to photo: PhotoAsset) {
        guard let lastId = lastSelectedId,
              let lastIndex = index(of: lastId),
              let currentIndex = index(of: photo.id) else {
            selectedPhotos.insert(photo.id)
            lastSelectedId = photo.id
            return
        }

        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        selectedPhotos.formUnion(grid.ids[range])
        lastSelectedId = photo.id
    }

    /// The photo Space/Return should open: the last-clicked photo if it is still selected and in the
    /// grid, otherwise the selected photo that comes first in the grid.
    var primarySelectedPhoto: PhotoAsset? {
        if let id = lastSelectedId, selectedPhotos.contains(id), let position = index(of: id) {
            return photos[position]
        }
        return selectedPhotos.compactMap { index(of: $0) }.min().map { photos[$0] }
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
        var ids: [UUID] = []
        for photo in photosToMove {
            photo.isDeleted = true
            ids.append(photo.id)
        }
        selectedPhotos.subtract(ids)
        try? modelContext?.save()
        relocate(photosToMove, ids: ids, toBin: true)
    }

    func restoreFromBin(_ photosToRestore: [PhotoAsset]) {
        var ids: [UUID] = []
        for photo in photosToRestore {
            photo.isDeleted = false
            ids.append(photo.id)
        }
        selectedPhotos.subtract(ids)
        try? modelContext?.save()
        relocate(photosToRestore, ids: ids, toBin: false)
    }

    /// Moves photos between the library and the bin in memory, as a reload would place them: each
    /// list stays in creation-date order, and a restored photo whose file was missing at the last
    /// availability check stays hidden.
    private func relocate(_ moving: [PhotoAsset], ids: [UUID], toBin: Bool) {
        var seen = Set<UUID>()
        let unique = zip(moving, ids).filter { seen.insert($0.1).inserted }.map { (photo: $0.0, id: $0.1) }
        if unique.count <= Self.patchLimit {
            relocateInPlace(unique, toBin: toBin)
        } else {
            relocateByMerging(unique, toBin: toBin)
        }
        refreshVisiblePhotos()
        sortTagCategories()
    }

    /// A few photos: O(log n) per photo to find its place, plus array inserts and removals; the grid
    /// and the counts are patched rather than recomputed.
    private func relocateInPlace(_ moving: [(photo: PhotoAsset, id: UUID)], toBin: Bool) {
        let found = moving.map { (photo: $0.photo, id: $0.id, position: position(of: $0.id, useIndex: moving.count > 2)) }
        // Remove from the end of each list first, so the positions found stay valid.
        var removed: [UUID: PhotoFacts] = [:]
        for item in found.sorted(by: { ($0.position?.index ?? -1) > ($1.position?.index ?? -1) }) {
            guard let position = item.position else { continue }
            removed[item.id] = removeFromList(at: position)
        }
        for item in found {
            if !toBin && missingPhotoIDs.contains(item.id) { continue }
            let facts = removed[item.id] ?? PhotoFacts(item.photo, tags: &tagFacts)
            insertIntoList(item.photo, facts: facts, inBin: toBin)
        }
    }

    private func removeFromList(at position: ListPosition) -> PhotoFacts {
        let patchGrid = gridShowsCurrent(inBin: position.inBin)
        let facts: PhotoFacts
        if position.inBin {
            binPhotos.remove(at: position.index)
            facts = binFacts.remove(at: position.index)
            binVersion += 1
        } else {
            allPhotos.remove(at: position.index)
            facts = allFacts.remove(at: position.index)
            libraryVersion += 1
            countLibraryChange(from: facts, to: nil)
        }
        if patchGrid {
            gridDidRemove(atSource: position.index)
            grid.sourceVersion = listVersion(inBin: position.inBin)
        }
        return facts
    }

    private func insertIntoList(_ photo: PhotoAsset, facts: PhotoFacts, inBin: Bool) {
        let patchGrid = gridShowsCurrent(inBin: inBin)
        let index = insertionIndex(for: photo.creationDate, in: inBin ? binPhotos : allPhotos)
        if inBin {
            binPhotos.insert(photo, at: index)
            binFacts.insert(facts, at: index)
            binVersion += 1
        } else {
            allPhotos.insert(photo, at: index)
            allFacts.insert(facts, at: index)
            libraryVersion += 1
            countLibraryChange(from: nil, to: facts)
        }
        if patchGrid {
            gridDidInsert(photo, facts: facts, atSource: index)
            grid.sourceVersion = listVersion(inBin: inBin)
        }
    }

    /// Where a photo goes in a list sorted by creation date the way the fetch sorts (newest first when
    /// `sortNewestFirst`; nil dates count as oldest): after every photo that doesn't sort after it.
    /// A binary search, so it reads O(log n) creation dates.
    private func insertionIndex(for date: Date?, in photos: [PhotoAsset]) -> Int {
        let date = date ?? .distantPast
        let newestFirst = sortNewestFirst
        var low = 0
        var high = photos.count
        while low < high {
            let mid = (low + high) / 2
            let other = photos[mid].creationDate ?? .distantPast
            if newestFirst ? date > other : date < other { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Many photos: one filtering pass and one merge per list, then the grid and counts are rebuilt.
    private func relocateByMerging(_ moving: [(photo: PhotoAsset, id: UUID)], toBin: Bool) {
        let ids = Set(moving.map(\.id))
        var removed: [UUID: PhotoFacts] = [:]
        if let kept = removing(ids, from: allPhotos, allFacts, capturingInto: &removed) {
            (allPhotos, allFacts) = kept
            libraryVersion += 1
        }
        if let kept = removing(ids, from: binPhotos, binFacts, capturingInto: &removed) {
            (binPhotos, binFacts) = kept
            binVersion += 1
        }
        var incoming: [(photo: PhotoAsset, facts: PhotoFacts)] = []
        for item in moving {
            if !toBin && missingPhotoIDs.contains(item.id) { continue }
            incoming.append((item.photo, removed[item.id] ?? PhotoFacts(item.photo, tags: &tagFacts)))
        }
        if toBin {
            (binPhotos, binFacts) = inserting(incoming, into: binPhotos, binFacts)
            binVersion += 1
        } else {
            (allPhotos, allFacts) = inserting(incoming, into: allPhotos, allFacts)
            libraryVersion += 1
        }
        libraryCounts = PhotoQuery().facetCounts(over: allFacts)
        filteredCounts = nil
    }

    /// The photos and facts without `ids`, or nil when none of them is there.
    private func removing(
        _ ids: Set<UUID>, from photos: [PhotoAsset], _ facts: [PhotoFacts],
        capturingInto captured: inout [UUID: PhotoFacts]
    ) -> ([PhotoAsset], [PhotoFacts])? {
        guard !ids.isEmpty, facts.contains(where: { ids.contains($0.id) }) else { return nil }
        var keptPhotos: [PhotoAsset] = []
        var keptFacts: [PhotoFacts] = []
        keptPhotos.reserveCapacity(photos.count)
        keptFacts.reserveCapacity(facts.count)
        for i in facts.indices {
            if ids.contains(facts[i].id) {
                captured[facts[i].id] = facts[i]
            } else {
                keptPhotos.append(photos[i])
                keptFacts.append(facts[i])
            }
        }
        return (keptPhotos, keptFacts)
    }

    /// Merges photos into a creation-date-sorted list (see `insertionIndex(for:in:)`) in one pass.
    private func inserting(
        _ incoming: [(photo: PhotoAsset, facts: PhotoFacts)],
        into photos: [PhotoAsset], _ facts: [PhotoFacts]
    ) -> ([PhotoAsset], [PhotoFacts]) {
        guard !incoming.isEmpty else { return (photos, facts) }
        let newestFirst = sortNewestFirst
        let dates = incoming.map { $0.photo.creationDate ?? .distantPast }
        let positions = incoming.map { insertionIndex(for: $0.photo.creationDate, in: photos) }
        let order = incoming.indices.sorted { a, b in
            if positions[a] != positions[b] { return positions[a] < positions[b] }
            if dates[a] != dates[b] { return newestFirst ? dates[a] > dates[b] : dates[a] < dates[b] }
            return a < b
        }

        var mergedPhotos: [PhotoAsset] = []
        var mergedFacts: [PhotoFacts] = []
        mergedPhotos.reserveCapacity(photos.count + incoming.count)
        mergedFacts.reserveCapacity(facts.count + incoming.count)
        var next = 0
        for item in order {
            while next < positions[item] {
                mergedPhotos.append(photos[next])
                mergedFacts.append(facts[next])
                next += 1
            }
            mergedPhotos.append(incoming[item].photo)
            mergedFacts.append(incoming[item].facts)
        }
        mergedPhotos.append(contentsOf: photos[next...])
        mergedFacts.append(contentsOf: facts[next...])
        return (mergedPhotos, mergedFacts)
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
        guard modelContext != nil else { return }
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
        var changed: [PhotoAsset] = []
        if !photo.tags.contains(where: { $0.id == tag.id }) {
            photo.tags.append(tag)
            try? context.save()

            writeMetadataInBackground([metadataWriteItem(for: photo)])
            changed.append(photo)
        }
        refreshTagLists(newTag: tag)
        applyFactChanges(changed)
        refreshVisiblePhotos()
        sortTagCategories()
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
        applyFactChanges(changed)
        refreshVisiblePhotos()
        sortTagCategories()

        writeMetadataInBackground(changed.map { metadataWriteItem(for: $0) })
    }

    func removeTag(_ tag: Tag, from photo: PhotoAsset) {
        photo.tags.removeAll { $0.id == tag.id }
        try? modelContext?.save()

        writeMetadataInBackground([metadataWriteItem(for: photo)])
        applyFactChanges([photo])
        refreshVisiblePhotos()
        sortTagCategories()
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
                applyFactChanges(selected)
                refreshVisiblePhotos()
                sortTagCategories()
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

    /// Clears the photo's saved JPG and RAW edits. The sidecar write goes through `MetadataWriter`.
    func revertEditsForPhoto(_ photo: PhotoAsset) {
        photo.jpgEditParametersData = nil
        photo.hasRawEdits = false
        if let rawPath = photo.rawPath {
            RAWEditStore.shared.save(nil, forRAWAt: rawPath)
        }
        try? modelContext?.save()
    }

    /// Categories, then tag names, containing the search text (case-insensitive); at most 10.
    var searchSuggestions: [String] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        var seen = Set<String>()
        var results: [String] = []

        for entry in categorySearchKeys {
            if entry.key.contains(query) && seen.insert(entry.category).inserted {
                results.append(entry.category)
            }
        }

        for entry in tagNameSearchKeys {
            if entry.key.contains(query) && seen.insert(entry.name).inserted {
                results.append(entry.name)
            }
        }

        return Array(results.prefix(10))
    }

    // MARK: - Filtering

    func applyFilter(_ filter: SidebarFilter, isShiftHeld: Bool = false) {
        if filter == .all {
            activeFilters.removeAll()
            viewingBin = false
            refreshVisiblePhotos()
            return
        }

        if filter == .bin {
            activeFilters = [.bin]
            viewingBin = true
            refreshVisiblePhotos()
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
            let newCategory = filter.category
            activeFilters = activeFilters.filter { $0.category != newCategory }
            activeFilters.insert(filter)
        }

        refreshVisiblePhotos()
    }

    /// Re-applies the active filters and the search text to the in-memory library.
    func applyCurrentFilter() {
        refreshVisiblePhotos()
    }

    /// Re-applies the search text (together with the active filters) to the in-memory library.
    func applySearch() {
        refreshVisiblePhotos()
    }

    // MARK: - Sorting

    /// Reverses the in-memory lists (photos with equal creation dates may swap places). Counts don't
    /// change, so only the grid is rebuilt.
    func toggleSortOrder() {
        sortNewestFirst.toggle()
        allPhotos.reverse()
        allFacts.reverse()
        binPhotos.reverse()
        binFacts.reverse()
        libraryVersion += 1
        binVersion += 1
        refreshVisiblePhotos()
    }

    // MARK: - Navigation

    func openDetail(for photo: PhotoAsset) {
        selectedDetailPhoto = photo
        showingDetail = true
    }

    func navigateDetail(direction: Int) {
        guard let current = selectedDetailPhoto,
              let index = self.index(of: current.id) else { return }

        let newIndex = index + direction
        if newIndex >= 0 && newIndex < photos.count {
            // Save edits before navigating, then keep editing on the next photo (a session belongs to one photo).
            let editingRAW = editSession?.isRAW
            editSession?.end(save: true)
            editSession = nil
            savedEditHandoff = nil
            selectedDetailPhoto = photos[newIndex]
            if let editingRAW {
                continueEditing(photos[newIndex], isRAW: editingRAW)
            }
        }
    }

    func closeDetail() {
        if isEditing {
            stopEditing(save: true)
        }
        savedEditHandoff = nil
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
           let idx = index(of: lastId) {
            currentIndex = idx
        } else {
            let id = grid.ids[0]
            selectedPhotos = [id]
            lastSelectedId = id
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

        let targetID = grid.ids[targetIndex]

        if extendSelection {
            let rangeStart = min(currentIndex, targetIndex)
            let rangeEnd = max(currentIndex, targetIndex)
            selectedPhotos.formUnion(grid.ids[rangeStart...rangeEnd])
        } else {
            selectedPhotos = [targetID]
        }
        lastSelectedId = targetID
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

    /// Adds a tag that was just created (or found) to the in-memory tag lists, without a fetch.
    /// The caller re-sorts `tagCategories` with `sortTagCategories()` once the counts are current.
    private func refreshTagLists(newTag: Tag) {
        guard !allTags.contains(where: { $0.id == newTag.id }) else { return }
        var tags = allTags
        tags.append(newTag)
        tags.sort(using: Self.tagSortOrder)
        setTagLists(tags)
    }

    // MARK: - Background Metadata Write-back

    private func metadataWriteItem(for photo: PhotoAsset) -> MetadataWriteItem {
        MetadataWriteItem(path: photo.displayPath, rating: photo.rating, keywords: photo.tags.map(\.fullName))
    }

    /// Hands the writes to the serial `MetadataWriter`, which writes them off the main thread,
    /// in call order, keeping only the latest per file. Returns immediately.
    private func writeMetadataInBackground(_ items: [MetadataWriteItem]) {
        guard !items.isEmpty else { return }
        MetadataWriter.shared.enqueue(items)
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

    /// Saves the current session, if any, then starts editing `photo` in a new one.
    func startEditing(photo: PhotoAsset, isRAW: Bool) {
        if let current = editSession {
            if let handoff = current.end(save: true) { savedEditHandoff = handoff }
            editSession = nil
        }
        selectedDetailPhoto = photo
        let session = EditSession(photo: photo, isRAW: isRAW, modelContext: modelContext)
        editSession = session
        Task { await session.begin() }
    }

    /// Ends the session. With `save`, its edits are saved and the detail view shows them.
    func stopEditing(save: Bool = true) {
        guard let session = editSession else { return }
        let handoff = session.end(save: save)
        editSession = nil
        if let handoff { savedEditHandoff = handoff }
    }

    /// After navigating while editing: edit the new photo too, if it has a file of the kind being edited.
    private func continueEditing(_ photo: PhotoAsset, isRAW: Bool) {
        guard (isRAW ? photo.rawPath : photo.jpgPath) != nil else { return }
        startEditing(photo: photo, isRAW: isRAW)
    }

    // MARK: - Export

    /// Exports the session's RAW edit to a JPEG (see `EditSession.exportRAWToJPG`), then refreshes what depends
    /// on the file: the in-memory library facts when the photo got a new JPG, and cached decodes of the written file.
    func exportRAWToJPG(replaceExisting: Bool) {
        guard let session = editSession else { return }
        let photo = session.photo
        let jpgBefore = photo.jpgPath
        Task {
            guard await session.exportRAWToJPG(replaceExisting: replaceExisting) else { return }
            if photo.jpgPath != jpgBefore {
                photosDidChange([photo])
            }
            if let written = photo.jpgPath {
                fileWasRewritten(written)
            }
        }
    }

    /// Bakes the session's edits into the JPG file (see `EditSession.exportJPGPermanent`).
    func exportJPGPermanent() {
        guard let session = editSession, let jpgPath = session.photo.jpgPath else { return }
        Task {
            guard await session.exportJPGPermanent() else { return }
            fileWasRewritten(jpgPath)
        }
    }

    /// An export rewrote `path`: drop its cached thumbnails and have the detail view decode it again.
    private func fileWasRewritten(_ path: String) {
        ImageLoader.shared.invalidate(path: path)
        editedFilesVersion += 1
    }

    // MARK: - Presets

    func loadPresets() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<EditPreset>(sortBy: [SortDescriptor(\.name)])
        editPresets = (try? context.fetch(descriptor)) ?? []
    }

    /// Saves the session's current parameters (defaults when not editing) as a preset named `presetNameInput`.
    func savePreset() {
        guard let context = modelContext else { return }
        let name = presetNameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let preset = EditPreset(name: name, parameters: editSession?.parameters ?? EditParameters())
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
        editSession?.apply(preset)
    }

    /// Saves `preset` as the edits of every selected photo: JPG edits in the model, RAW edits in the sidecar
    /// (through `MetadataWriter`).
    func applyPresetToSelection(_ preset: EditPreset) {
        let params = preset.parameters

        for photo in selectedPhotosList {
            if photo.jpgPath != nil {
                photo.jpgEditParameters = params
            }
            if let rawPath = photo.rawPath {
                RAWEditStore.shared.save(params, forRAWAt: rawPath)
                photo.hasRawEdits = true
            }
        }

        try? modelContext?.save()
    }
}
