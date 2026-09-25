import Foundation
import SwiftData
import os

/// The in-memory library as plain values, read off the main actor through background contexts: what the launch of a
/// big library needs so the main actor never runs the ordered fetch or builds the facts (spec §B1).
///
/// The main actor still has to hold every photo as a model of its own context (the grid reads them). It fetches them
/// itself, a page at a time, while this is read; `LibraryStore.loadInBackground()` then puts them in this order.
///
/// The contexts only read, so they follow the background-context rule in CLAUDE.md.
struct LibrarySnapshot: Sendable {
    /// One list (the library or the bin), in `sort` order.
    struct List: Sendable {
        var ids: [PersistentIdentifier] = []
        /// `ids[i]`'s facts, as `PhotoFacts(_:tags:)` builds them.
        var facts: [PhotoFacts] = []
    }

    /// The order the lists are in.
    var sort: LibrarySort
    var library = List()
    var bin = List()
    /// `PhotoQuery().facetCounts(over:)` of the library's facts.
    var libraryCounts = FacetCounts()
    /// Every row as the launch rescan compares it with the disk (what `StoredPhoto.fetchAll(in:)` reads).
    var storedRows: [StoredPhoto] = []

    /// Rows are read in this many unordered parts, alongside the ordered fetch. Measured at 10k: 2 parts read the
    /// snapshot in ~230 ms against ~375 ms for one context doing it all (3 parts gain nothing more).
    private static let parallelParts = 2

    /// `read(from:sort:)` on a global queue.
    static func readInBackground(from container: ModelContainer, sort: LibrarySort) async -> LibrarySnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: read(from: container, sort: sort))
            }
        }
    }

    /// What a part reads for one row.
    private struct Row {
        var facts: PhotoFacts
        var key: String
        var jpgPath: String?
        var rawPath: String?
        var fileSize: Int64
    }

    /// Reads the snapshot through new contexts on `container`, which only read. Don't call it on the main thread.
    /// The order (one ordered fetch per list, through `sort`) and the rows (`parallelParts` unordered ranges, which
    /// give the facts and the stored rows) are read in parallel, then put together.
    static func read(from container: ModelContainer, sort: LibrarySort) -> LibrarySnapshot {
        let rowCount = (try? ModelContext(container).fetchCount(FetchDescriptor<PhotoAsset>())) ?? 0
        let parts = max(1, parallelParts)
        let partSize = max(1, (rowCount + parts - 1) / parts)
        let order = OSAllocatedUnfairLock<(library: [PersistentIdentifier], bin: [PersistentIdentifier])>(
            initialState: ([], []))
        let rows = OSAllocatedUnfairLock(initialState: [PersistentIdentifier: Row](minimumCapacity: rowCount))
        DispatchQueue.concurrentPerform(iterations: parts + 1) { part in
            let context = ModelContext(container)
            if part == 0 {
                // Bin membership comes from the predicates, never the property (see `StoredPhoto.fetchAllNow`).
                let library = sort.fetch(where: #Predicate { !$0.isDeleted }, in: context).map(\.persistentModelID)
                let bin = sort.fetch(where: #Predicate { $0.isDeleted }, in: context).map(\.persistentModelID)
                order.withLock { $0 = (library, bin) }
            } else {
                var range = FetchDescriptor<PhotoAsset>()
                range.fetchOffset = (part - 1) * partSize
                range.fetchLimit = partSize
                var tagFacts: [PersistentIdentifier: SnapshotTagFacts] = [:]
                let read = ((try? context.fetch(range)) ?? []).map { photo in
                    (photo.persistentModelID, readRow(of: photo, tagFacts: &tagFacts))
                }
                rows.withLock { rows in
                    for (id, row) in read { rows[id] = row }
                }
            }
        }

        let (libraryOrder, binOrder) = order.withLock { $0 }
        var byID = rows.withLock { $0 }
        var snapshot = LibrarySnapshot(sort: sort)
        snapshot.storedRows.reserveCapacity(libraryOrder.count + binOrder.count)
        var missed: ModelContext? // for a row the ranges didn't cover (added while they were read)
        var tagFacts: [PersistentIdentifier: SnapshotTagFacts] = [:]
        for inBin in [false, true] {
            var list = List()
            for id in inBin ? binOrder : libraryOrder {
                var found = byID.removeValue(forKey: id)
                if found == nil {
                    missed = missed ?? ModelContext(container)
                    found = (missed?.model(for: id) as? PhotoAsset).map { readRow(of: $0, tagFacts: &tagFacts) }
                }
                guard let row = found else { continue }
                list.ids.append(id)
                list.facts.append(row.facts)
                snapshot.storedRows.append(StoredPhoto(id: row.facts.id, key: row.key, jpgPath: row.jpgPath,
                                                       rawPath: row.rawPath, fileSize: row.fileSize, isInBin: inBin))
            }
            if inBin { snapshot.bin = list } else { snapshot.library = list }
        }
        snapshot.libraryCounts = PhotoQuery().facetCounts(over: snapshot.library.facts)
        return snapshot
    }

    private static func readRow(of photo: PhotoAsset, tagFacts: inout [PersistentIdentifier: SnapshotTagFacts]) -> Row {
        let fileName = photo.fileName
        let jpgPath = photo.jpgPath
        let rawPath = photo.rawPath
        return Row(facts: facts(id: photo.id, fileName: fileName, rating: photo.rating, jpgPath: jpgPath,
                                rawPath: rawPath, tags: photo.tags, tagFacts: &tagFacts),
                   key: DiscoveredPhoto.key(folderPath: photo.folderPath, fileName: fileName),
                   jpgPath: jpgPath, rawPath: rawPath, fileSize: photo.fileSize)
    }

    /// `PhotoFacts(_:tags:)`, off the main actor: the same fields, built the same way
    /// (`ScanTests.testSnapshotReadsWhatAFullLoadBuilds` compares the two).
    private static func facts(id: UUID, fileName: String, rating: Int, jpgPath: String?, rawPath: String?, tags: [Tag],
                              tagFacts: inout [PersistentIdentifier: SnapshotTagFacts]) -> PhotoFacts {
        var tagIDs = Set<UUID>()
        var tagCategories = Set<String>()
        var searchKey = fileName.lowercased()
        for tag in tags {
            let facts: SnapshotTagFacts
            if let known = tagFacts[tag.persistentModelID] {
                facts = known
            } else {
                facts = SnapshotTagFacts(tag)
                tagFacts[tag.persistentModelID] = facts
            }
            tagIDs.insert(facts.id)
            if !facts.category.isEmpty { tagCategories.insert(facts.category) }
            searchKey += facts.searchKeySuffix
        }
        return PhotoFacts(id: id, rating: rating, hasJPG: jpgPath != nil, hasRAW: rawPath != nil,
                          tagIDs: tagIDs, tagCategories: tagCategories, searchKey: searchKey)
    }
}

/// `TagFacts`, off the main actor.
private struct SnapshotTagFacts {
    let id: UUID
    let category: String
    let searchKeySuffix: String

    init(_ tag: Tag) {
        let name = tag.name
        let category = tag.category
        id = tag.id
        self.category = category
        searchKeySuffix = category.isEmpty
            ? "\n" + name.lowercased()
            : "\n" + name.lowercased() + "\n" + category.lowercased()
    }
}
