import Foundation
import SwiftData

/// The in-memory library as plain values, read off the main actor through a background context: what the launch of a
/// big library needs so the main actor never runs the ordered fetch or builds the facts (spec §B1).
///
/// The main actor still has to hold every photo as a model of its own context (the grid reads them). It fetches them
/// itself, a page at a time, while this is read; `LibraryStore.loadInBackground()` then puts them in this order.
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

    /// Reads the snapshot through a new context on `container`. It only reads. Don't call it on the main thread.
    static func read(from container: ModelContainer, sort: LibrarySort) -> LibrarySnapshot {
        let context = ModelContext(container)
        var snapshot = LibrarySnapshot(sort: sort)
        var tagFacts: [PersistentIdentifier: SnapshotTagFacts] = [:]
        // Bin membership comes from the predicates, never the property (see `StoredPhoto.fetchAllNow`).
        let library = sort.fetch(where: #Predicate { !$0.isDeleted }, in: context)
        let bin = sort.fetch(where: #Predicate { $0.isDeleted }, in: context)
        snapshot.storedRows.reserveCapacity(library.count + bin.count)
        snapshot.library = list(of: library, inBin: false, tagFacts: &tagFacts, rows: &snapshot.storedRows)
        snapshot.bin = list(of: bin, inBin: true, tagFacts: &tagFacts, rows: &snapshot.storedRows)
        snapshot.libraryCounts = PhotoQuery().facetCounts(over: snapshot.library.facts)
        return snapshot
    }

    private static func list(of photos: [PhotoAsset], inBin: Bool,
                             tagFacts: inout [PersistentIdentifier: SnapshotTagFacts],
                             rows: inout [StoredPhoto]) -> List {
        var list = List()
        list.ids.reserveCapacity(photos.count)
        list.facts.reserveCapacity(photos.count)
        for photo in photos {
            let id = photo.id
            let fileName = photo.fileName
            let jpgPath = photo.jpgPath
            let rawPath = photo.rawPath
            list.ids.append(photo.persistentModelID)
            list.facts.append(facts(id: id, fileName: fileName, rating: photo.rating, jpgPath: jpgPath,
                                    rawPath: rawPath, tags: photo.tags, tagFacts: &tagFacts))
            rows.append(StoredPhoto(id: id, key: DiscoveredPhoto.key(folderPath: photo.folderPath, fileName: fileName),
                                    jpgPath: jpgPath, rawPath: rawPath, fileSize: photo.fileSize, isInBin: inBin))
        }
        return list
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
