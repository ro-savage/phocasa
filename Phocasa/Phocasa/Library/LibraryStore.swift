import SwiftUI
import SwiftData

/// The photo library in memory: the model context, every photo in the library and in the bin with the plain-value
/// facts that filtering, search and counting read, the sidebar counts and tag lists, and what the grid shows
/// (`photos`).
///
/// The store is read by `loadExistingData()` and by scans, nowhere else. Everything else works on this in-memory state
/// and never re-fetches (spec §A1): mutations patch it in place, and `photosDidChange(_:)` takes changes made to the
/// models from outside. The type is split by concern:
/// - this file: the state, the grid (`photos`, `index(of:)`) and how it is kept current;
/// - `LibraryStore+Loading`: launch (`open(_:)`), `loadExistingData()`, file availability;
/// - `LibraryStore+Scan`: folder opening and scans;
/// - `LibraryStore+Mutations`: rating, tags, bin, deletes, metadata write-back;
/// - `LibraryStore+ListEditing`: moving photos between the library and the bin in memory;
/// - `LibraryStore+Filtering`: filters, search, the sort toggle, the tag lists;
/// - `LibrarySort`: photo order.
///
/// Stored properties that the extension files write are `internal`; only `LibraryStore` and its extensions write
/// them. State that only one extension file uses lives in a struct declared in that file (`LoadingState`,
/// `ScanState`), so that file's owner can change it without touching this one.
@Observable @MainActor
final class LibraryStore {
    /// The photos the grid shows. Only this file writes it: it keeps `index(of:)` and the grid bookkeeping in step,
    /// so an outside assignment would silently desync them.
    private(set) var photos: [PhotoAsset] = []
    /// The library (every photo not in the bin whose files were found), in `sort` order.
    var allPhotos: [PhotoAsset] = []
    var searchText: String = ""
    var activeFilters: Set<SidebarFilter> = []
    var viewingBin: Bool = false
    /// The order of every list. Set it directly only before `loadExistingData()`; `toggleSortOrder()` reorders in
    /// memory.
    var sort = LibrarySort()
    var sortNewestFirst: Bool { sort.newestFirst }
    var allTags: [Tag] = []
    var tagCategories: [String] = []
    /// Tags of each non-empty category, sorted by name (the order of `allTags`).
    var tagsByCategory: [String: [Tag]] = [:]
    /// Tags without a category, in `allTags` order.
    var uncategorizedTags: [Tag] = []
    var currentLibrary: PhotoLibrary?
    var isScanning: Bool = false
    var scanProgress: String = ""
    /// Files being moved to the Trash by deletes still running, when there are more than
    /// `trashProgressMinimum` (the status bar shows it).
    var trashProgress: TrashProgress?
    /// The last delete that left photos as they were because files couldn't be moved to the Trash, for the alert; nil
    /// once dismissed.
    var deleteProblem: DeleteProblem?
    /// Why the last full load (`loadExistingData()` or the launch's background load) couldn't read the store; nil once
    /// one has. The library shown is the one before it (empty at launch), and the grid says the library couldn't be
    /// read rather than that there are no photos.
    var libraryReadFailure: String?
    /// Why the last scan stopped or didn't run (the store couldn't be read or saved, or the library's folder isn't
    /// there); nil after a scan that went through.
    var scanIssue: ScanIssue?

    /// The problem the status bar shows once no scan is running, if any.
    var statusMessage: String? {
        libraryReadFailure ?? scanIssue?.statusText
    }

    // Sidebar counts, for the active filters (published by `publishCounts()`).
    private(set) var ratingCounts: [Int: Int] = [:]
    private(set) var categoryCounts: [String: Int] = [:]
    private(set) var jpgCount: Int = 0
    private(set) var rawCount: Int = 0
    private(set) var tagCounts: [UUID: Int] = [:]
    private(set) var binCount: Int = 0

    var modelContext: ModelContext?

    // MARK: - In-Memory Library State
    // `loadExistingData()` fetches once. Filtering, search, sort, counts and mutations then work on
    // this state. Each facts array lines up index-for-index with its photo array, so hot paths read
    // plain values and never model properties (each model read costs ~0.8 µs; spec §A1).

    @ObservationIgnored var allFacts: [PhotoFacts] = []
    /// Photos in the bin, in the same order as `allPhotos`.
    @ObservationIgnored var binPhotos: [PhotoAsset] = []
    @ObservationIgnored var binFacts: [PhotoFacts] = []
    /// Bumped whenever `allPhotos` / `binPhotos` gain, lose or reorder photos.
    @ObservationIgnored var libraryVersion = 0
    @ObservationIgnored var binVersion = 0
    /// How `photos` was derived.
    @ObservationIgnored var grid = GridState()
    /// Positions in `photos` by id. Rebuilt on first use after `photos` changes.
    @ObservationIgnored private var photoIndexCache: [UUID: Int]?
    /// Sidebar counts over the whole library with no filters. Every mutation keeps them current.
    @ObservationIgnored var libraryCounts = FacetCounts()
    /// Faceted counts for the active filters, kept current the same way until the filters change.
    @ObservationIgnored var filteredCounts: (filters: Set<SidebarFilter>, counts: FacetCounts)?
    @ObservationIgnored var tagFacts = TagFactsCache()
    /// Lowercased names for `searchSuggestions`, in `tagCategories` / `allTags` order.
    var categorySearchKeys: [(category: String, key: String)] = []
    var tagNameSearchKeys: [(name: String, key: String)] = []

    let scanner = FolderScanner()
    /// Photos whose files were missing at the last scan (or availability check). Tracking the missing set
    /// (rather than the available set) means photos inserted or restored since the last check
    /// stay visible instead of silently disappearing.
    var missingPhotoIDs: Set<UUID> = []
    /// The loading code's own state (`LoadingState`, declared in `LibraryStore+Loading`).
    @ObservationIgnored var loading = LoadingState()
    /// The scan code's own state (`ScanState`, declared in `LibraryStore+Scan`).
    @ObservationIgnored var scanning = ScanState()
    /// The capture-date backfill's state (`CaptureDateState`, declared in `CaptureDateBackfill`).
    @ObservationIgnored var captureDates = CaptureDateState()
    /// What the last scan did. For tests and benchmarks.
    @ObservationIgnored var lastScanReport: ScanReport?
    /// Test hook: called at the end of a scan, after it has applied its changes to existing rows and inserted
    /// its new ones, just before it sets `lastScanDate` and saves.
    @ObservationIgnored var scanWillSave: ((ModelContext) -> Void)?
    /// Where deletes move files to the Trash, off the main actor. Tests put in one that never touches the real Trash.
    @ObservationIgnored var fileTrasher = FileTrasher.shared
    /// Every file of the deletes still running, and how many are in the Trash already.
    @ObservationIgnored var trashPending = TrashProgress(done: 0, total: 0)
    /// Photos with a delete still running. Another delete of them does nothing (it would delete them twice).
    @ObservationIgnored var photosBeingDeleted: Set<UUID> = []

    struct TrashProgress: Equatable {
        var done: Int
        var total: Int
    }

    /// What `photos` shows, so that a refresh that changes nothing costs nothing and small mutations
    /// can patch `photos` in place instead of re-filtering the whole library.
    struct GridState {
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
    struct ListPosition {
        var inBin: Bool
        var index: Int
    }

    /// Mutations touching more photos than this re-filter the grid instead of patching it.
    static let patchLimit = 8

    // MARK: - The Grid

    /// Position of the photo in `photos`, in O(1) (the index is rebuilt on first use after a change).
    func index(of id: UUID) -> Int? {
        access(keyPath: \.photos) // the result changes whenever `photos` does
        return photoIndex()[id]
    }

    /// The ids of `photos`, in grid order, without reading the models.
    var shownIDs: [UUID] {
        access(keyPath: \.photos)
        return grid.ids
    }

    private func photoIndex() -> [UUID: Int] {
        if let photoIndexCache { return photoIndexCache }
        var index = [UUID: Int](minimumCapacity: grid.ids.count)
        for (position, id) in grid.ids.enumerated() { index[id] = position }
        photoIndexCache = index
        return index
    }

    var currentQuery: PhotoQuery {
        PhotoQuery(filters: activeFilters, searchText: searchText)
    }

    func listVersion(inBin: Bool) -> Int {
        inBin ? binVersion : libraryVersion
    }

    /// Whether `photos` is up to date with the current contents of that list (so it can be patched).
    func gridShowsCurrent(inBin: Bool) -> Bool {
        grid.showsBin == inBin && grid.sourceVersion == listVersion(inBin: inBin)
    }

    /// Brings `photos` and the sidebar counts up to date with the filters, the search text and the
    /// shown list (library or bin). Re-filters only when one of those changed since `photos` was
    /// built or patched. Reads no model properties.
    func refreshVisiblePhotos() {
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
    func countLibraryChange(from old: PhotoFacts?, to new: PhotoFacts?) {
        PhotoQuery().updateFacetCounts(&libraryCounts, replacing: old, with: new)
        if let filters = filteredCounts?.filters {
            PhotoQuery(filters: filters).updateFacetCounts(&filteredCounts!.counts, replacing: old, with: new)
        }
    }

    /// Finds a loaded photo: O(1) through the grid when it is shown, a scan of the facts otherwise.
    func position(of id: UUID, useIndex: Bool) -> ListPosition? {
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

    /// The ids of the photo's tags, from the in-memory facts: no model reads when the photo is in the grid.
    func tagIDs(of photo: PhotoAsset) -> Set<UUID> {
        if let position = position(of: photo.id, useIndex: true) {
            return (position.inBin ? binFacts : allFacts)[position.index].tagIDs
        }
        return Set(photo.tags.map(\.id))
    }

    /// A linear scan that reads only the `id` field of each element (no struct copies).
    private static func firstIndex(of id: UUID, in facts: [PhotoFacts]) -> Int? {
        facts.withUnsafeBufferPointer { buffer in
            for i in buffer.indices where buffer[i].id == id { return i }
            return nil
        }
    }

    /// For code that changes a photo's rating, tags, file paths or file name directly rather than
    /// through this store's methods (for example, an export that gives a RAW-only photo a JPG):
    /// updates the in-memory library, the grid and the counts to match the models.
    func photosDidChange(_ changed: [PhotoAsset]) {
        applyFactChanges(changed)
        refreshVisiblePhotos()
        sortTagCategories()
    }

    /// Re-reads the facts of photos whose rating or tags changed (a few model reads each), and
    /// applies them to the counts and the grid.
    func applyFactChanges(_ changed: [PhotoAsset]) {
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
    func gridDidRemove(atSource sourceIndex: Int) {
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
    func gridDidInsert(_ photo: PhotoAsset, facts: PhotoFacts, atSource sourceIndex: Int) {
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
}
