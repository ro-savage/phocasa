import SwiftData
import Foundation

extension LibraryStore {
    /// State only the loading code uses, stored in `loading`.
    struct LoadingState {
        /// Set by `refreshAvailability()`, so the next `loadExistingData()` checks every photo's files. Launch and
        /// scans don't need it: each scan works out the missing set itself, off the main thread.
        var needsAvailabilityCheck = false
        /// Bumped by every `loadExistingData()`. Work that started before a load and patches the in-memory library
        /// afterwards (a scan adding its new photos) checks it: the load already has what it would add.
        var generation = 0
    }

    // MARK: - Launch

    /// Launch: shows the library as stored, then rescans it. It trusts the last scan, so there is no `stat` pass
    /// here: the rescan finds which photos' files are missing, off the main thread (spec §B1).
    func open(_ context: ModelContext) {
        modelContext = context
        loadExistingData()
        rescanCurrentLibrary()
    }

    // MARK: - Data Loading

    /// The one place (besides scans) that reads photos and tags from the store. Everything else works
    /// on the in-memory state this builds.
    func loadExistingData() {
        guard let context = modelContext else { return }
        loading.generation += 1

        let tags = (try? context.fetch(FetchDescriptor<Tag>(sortBy: Self.tagSortOrder))) ?? []
        tagFacts = TagFactsCache(tags: tags)

        let fetchedPhotos = sort.fetch(where: #Predicate { !$0.isDeleted }, in: context)

        if loading.needsAvailabilityCheck {
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

        binPhotos = sort.fetch(where: #Predicate { $0.isDeleted }, in: context)
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
