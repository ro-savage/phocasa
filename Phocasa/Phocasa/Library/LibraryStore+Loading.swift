import SwiftData
import Foundation

extension LibraryStore {
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

        let tags = (try? context.fetch(FetchDescriptor<Tag>(sortBy: Self.tagSortOrder))) ?? []
        tagFacts = TagFactsCache(tags: tags)

        let fetchedPhotos = sort.fetch(where: #Predicate { !$0.isDeleted }, in: context)

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
        needsAvailabilityCheck = false
    }

    func refreshAvailability() {
        needsAvailabilityCheck = true
        loadExistingData()
    }
}
