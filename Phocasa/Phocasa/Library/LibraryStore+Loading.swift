import SwiftData
import Foundation

extension LibraryStore {
    /// State only the loading code uses, stored in `loading`.
    struct LoadingState {
        /// Set by `refreshAvailability()`, so the next `loadExistingData()` checks every photo's files. Launch and
        /// scans don't need it: each scan works out the missing set itself, off the main thread.
        var needsAvailabilityCheck = false
        /// Bumped by every full load (`loadExistingData()`, or a background load being applied). Work that started
        /// before a load and changes the in-memory library afterwards (a background load, a scan adding its new photos)
        /// checks it: the newer load already has what it would add.
        var generation = 0
        /// Launch loads a store with more photos than this in the background (`loadInBackground()`). A smaller one
        /// loads at once, in about a frame at most (~33 µs a photo).
        var backgroundLoadThreshold = 500
        /// Rows the background load fetches per main-actor turn: about 12 ms each (measured, 10k library).
        var pageSize = 500
        /// What the last background load did. For tests and benchmarks.
        var lastBackgroundLoad: BackgroundLoadReport?
        /// Test hook: called right after a background load has been applied, before the launch rescan starts.
        var backgroundLoadDidApply: (() -> Void)?
    }

    /// What a background load did. For tests and benchmarks.
    struct BackgroundLoadReport {
        /// Time spent on the main actor, over all its turns.
        var mainActorTime: Duration = .zero
        /// The longest main-actor turn: how long the load held the main actor at once.
        var longestTurn: Duration = .zero
        var turns = 0
        /// False when a full load ran meanwhile, so this one was dropped.
        var applied = false
    }

    // MARK: - Launch

    /// Launch: shows the library as stored, then rescans it. It trusts the last scan, so there is no `stat` pass
    /// here: the rescan finds which photos' files are missing, off the main thread (spec §B1).
    ///
    /// A library of more than `loading.backgroundLoadThreshold` photos loads without blocking the main actor
    /// (`loadInBackground()`), as the first job of the scan queue: the launch rescan queues behind it, `isScanning` is
    /// true meanwhile, and `waitForScans()` waits for both. Until the load is applied the library is empty; it then
    /// appears whole, in one main-actor turn.
    func open(_ context: ModelContext) {
        modelContext = context
        let photoCount = (try? context.fetchCount(FetchDescriptor<PhotoAsset>())) ?? 0
        guard photoCount > loading.backgroundLoadThreshold, scanning.task == nil else {
            loadExistingData()
            rescanCurrentLibrary()
            return
        }
        currentLibrary = (try? context.fetch(FetchDescriptor<PhotoLibrary>()))?.first // so a rescan can queue now
        startScanQueue(loadingFirstUnlessLoadedAfter: loading.generation)
        rescanCurrentLibrary() // queued behind the load
        readAheadForLaunchRescan()
    }

    // MARK: - Data Loading

    /// The one place (besides scans and the launch's background load) that reads photos and tags from the store.
    /// Everything else works on the in-memory state this builds.
    func loadExistingData() {
        guard let context = modelContext else { return }

        let tags = fetchTags(in: context)
        tagFacts = TagFactsCache(tags: tags)

        let fetchedPhotos = sort.fetch(where: #Predicate { !$0.isDeleted }, in: context)

        if loading.needsAvailabilityCheck {
            checkFileAvailability(for: fetchedPhotos)
        }

        showLibrary(fetchedPhotos, facts: makeFacts(for: fetchedPhotos))

        binPhotos = sort.fetch(where: #Predicate { $0.isDeleted }, in: context)
        binFacts = makeFacts(for: binPhotos)

        finishLoad(tags: tags, in: context)
    }

    /// `loadExistingData()` for a big library at launch, without blocking the main actor (spec §B1).
    /// - A background context reads the order, the facts, the counts and the stored rows (`LibrarySnapshot`).
    /// - Meanwhile the main actor fetches every row as a model of its own context, `loading.pageSize` rows per turn:
    ///   the grid needs the models, and that fetch (about 23 µs a row) can't leave the main actor. Then the tags, and
    ///   the models in the snapshot's order, a turn at a time. No turn takes much longer than one page (~12 ms).
    /// - Last, in one turn, the library is shown whole.
    ///
    /// Dropped if a full load has run since `generation` (the value of `loading.generation` when the launch asked for
    /// this load): that load is newer.
    func loadInBackground(unlessLoadedAfter generation: Int) async {
        guard let context = modelContext else { return }
        let clock = ContinuousClock()
        var report = BackgroundLoadReport()
        var turnStart = clock.now
        func endTurn() {
            let turn = clock.now - turnStart
            report.mainActorTime += turn
            report.longestTurn = max(report.longestTurn, turn)
            report.turns += 1
        }
        func nextTurn() async -> Bool {
            endTurn()
            await Task.yield()
            turnStart = clock.now
            return loading.generation == generation && modelContext === context
        }

        scanProgress = "Loading library..."
        let container = context.container
        let sort = self.sort
        let snapshotRead = Task.detached(priority: .userInitiated) {
            LibrarySnapshot.read(from: container, sort: sort)
        }
        defer { loading.lastBackgroundLoad = report }

        // Every row as a model of this context, in no particular order (the snapshot has the order). Holding them
        // keeps them registered, so the models the snapshot names are these, already filled in.
        var rows: [PhotoAsset] = []
        let pageSize = loading.pageSize
        var loaded = true
        while loaded {
            var page = FetchDescriptor<PhotoAsset>()
            page.fetchOffset = rows.count
            page.fetchLimit = pageSize
            page.includePendingChanges = false
            let fetched = (try? context.fetch(page)) ?? []
            rows += fetched
            loaded = await nextTurn()
            if fetched.count < pageSize { break }
        }
        var tags: [Tag] = []
        if loaded {
            tags = fetchTags(in: context) // ~9 ms, so a turn of its own
            loaded = await nextTurn()
        }
        // Waited for even when a full load ran meanwhile (and has everything), so no read outlives the load.
        let snapshot = await snapshotRead.value
        guard loaded && loading.generation == generation && modelContext === context else { return }
        turnStart = clock.now

        // The models in the snapshot's order, with their facts.
        var library: (photos: [PhotoAsset], facts: [PhotoFacts]) = ([], [])
        var bin: (photos: [PhotoAsset], facts: [PhotoFacts]) = ([], [])
        for inBin in [false, true] {
            let list = inBin ? snapshot.bin : snapshot.library
            var start = 0
            while start < list.ids.count {
                let end = min(start + Self.modelLookupsPerTurn, list.ids.count)
                for i in start..<end {
                    guard let photo = context.model(for: list.ids[i]) as? PhotoAsset else { continue }
                    if inBin {
                        bin.photos.append(photo)
                        bin.facts.append(list.facts[i])
                    } else {
                        library.photos.append(photo)
                        library.facts.append(list.facts[i])
                    }
                }
                start = end
                guard await nextTurn() else { return }
            }
        }

        // One turn: the library appears whole.
        if sort != snapshot.sort { // toggled while loading
            LibrarySort.reorderAfterToggle(&library.photos)
            LibrarySort.reorderAfterToggle(&library.facts)
            LibrarySort.reorderAfterToggle(&bin.photos)
            LibrarySort.reorderAfterToggle(&bin.facts)
        }
        tagFacts = TagFactsCache(tags: tags)
        showLibrary(library.photos, facts: library.facts)
        binPhotos = bin.photos
        binFacts = bin.facts
        let complete = missingPhotoIDs.isEmpty && library.facts.count == snapshot.library.facts.count
        finishLoad(tags: tags, counts: complete ? snapshot.libraryCounts : nil, in: context)
        scanning.readAhead?.rows = (snapshot.storedRows, loading.generation)
        report.applied = true
        endTurn()
        withExtendedLifetime(rows) {}
        loading.lastBackgroundLoad = report
        loading.backgroundLoadDidApply?()
    }

    /// `context.model(for:)` lookups per main-actor turn in `loadInBackground`: about 1 µs each for a registered row.
    private static let modelLookupsPerTurn = 5_000

    private func fetchTags(in context: ModelContext) -> [Tag] {
        (try? context.fetch(FetchDescriptor<Tag>(sortBy: Self.tagSortOrder))) ?? []
    }

    /// The library photos a load found, less those whose files were missing at the last scan.
    private func showLibrary(_ photos: [PhotoAsset], facts: [PhotoFacts]) {
        if missingPhotoIDs.isEmpty {
            allPhotos = photos
            allFacts = facts
        } else {
            let available = facts.indices.filter { !missingPhotoIDs.contains(facts[$0].id) }
            allPhotos = available.map { photos[$0] }
            allFacts = available.map { facts[$0] }
        }
    }

    /// The end of every full load, once the library and the bin are in place: counts (`counts`, when the caller has
    /// them for `allFacts` already), tag lists, the grid.
    private func finishLoad(tags: [Tag], counts: FacetCounts? = nil, in context: ModelContext) {
        loading.generation += 1
        libraryVersion += 1
        binVersion += 1
        libraryCounts = counts ?? PhotoQuery().facetCounts(over: allFacts)
        filteredCounts = nil
        setTagLists(tags)
        refreshVisiblePhotos()
        sortTagCategories()

        let libDescriptor = FetchDescriptor<PhotoLibrary>()
        currentLibrary = (try? context.fetch(libDescriptor))?.first
    }

    func makeFacts(for photos: [PhotoAsset]) -> [PhotoFacts] {
        var facts: [PhotoFacts] = []
        facts.reserveCapacity(photos.count)
        for photo in photos {
            facts.append(PhotoFacts(photo, tags: &tagFacts))
        }
        return facts
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
        loading.needsAvailabilityCheck = false
    }

    func refreshAvailability() {
        loading.needsAvailabilityCheck = true
        loadExistingData()
    }
}
