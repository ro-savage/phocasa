import Foundation

// Moving photos between the library and the bin in memory, as a reload would place them: each list stays in `sort`
// order (`LibrarySort` finds where a photo goes), and the grid and the counts are patched rather than rebuilt when
// few photos move.
extension LibraryStore {
    /// Moves photos between the library and the bin in memory. A restored photo whose file was missing at the last
    /// availability check stays hidden.
    func relocate(_ moving: [PhotoAsset], ids: [UUID], toBin: Bool) {
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
        let index = sort.insertionIndex(for: photo, in: inBin ? binPhotos : allPhotos)
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
            (binPhotos, binFacts) = sort.merge(incoming, into: binPhotos, binFacts)
            binVersion += 1
        } else {
            (allPhotos, allFacts) = sort.merge(incoming, into: allPhotos, allFacts)
            libraryVersion += 1
        }
        libraryCounts = PhotoQuery().facetCounts(over: allFacts)
        filteredCounts = nil
    }

    // MARK: - Photos Joining or Leaving the Library

    /// Scans: `adding` photos that aren't in memory yet join the library (new rows, or photos whose files are back),
    /// each where a reload would put it; `facts[i]` are `adding[i]`'s. Photos with ids in `removing` leave the library
    /// and the bin (their files went missing). Few photos patch the lists, the grid and the counts; many are merged
    /// and recounted. O(k log n) for k photos in the patch case, one pass in the merge case: no fetch, no reload.
    func updateLibrary(adding photos: [PhotoAsset], facts: [PhotoFacts], removing ids: Set<UUID>) {
        precondition(photos.count == facts.count)
        if ids.count <= Self.patchLimit {
            let found = ids.compactMap { position(of: $0, useIndex: ids.count > 2) }
            // From the end of each list first, so the positions found stay valid.
            for position in found.sorted(by: { $0.index > $1.index }) {
                _ = removeFromList(at: position)
            }
        } else {
            var removed: [UUID: PhotoFacts] = [:]
            if let kept = removing(ids, from: allPhotos, allFacts, capturingInto: &removed) {
                (allPhotos, allFacts) = kept
                libraryVersion += 1
            }
            if let kept = removing(ids, from: binPhotos, binFacts, capturingInto: &removed) {
                (binPhotos, binFacts) = kept
                binVersion += 1
            }
        }
        if photos.count <= Self.patchLimit {
            for (photo, photoFacts) in zip(photos, facts) {
                insertIntoList(photo, facts: photoFacts, inBin: false)
            }
        } else {
            (allPhotos, allFacts) = sort.merge(zip(photos, facts).map { (photo: $0, facts: $1) }, into: allPhotos, allFacts)
            libraryVersion += 1
        }
        if ids.count > Self.patchLimit || photos.count > Self.patchLimit {
            libraryCounts = PhotoQuery().facetCounts(over: allFacts)
            filteredCounts = nil
        }
        refreshVisiblePhotos()
        sortTagCategories()
    }

    /// A file-type delete is done (`deleteFileType`): `binned` photos went to the bin, and each of `changed` lost its
    /// JPG or its RAW, which changes its facts (and so perhaps whether a filtered grid shows it). No reload.
    func fileTypeDeleteDidFinish(binned: [PhotoAsset], changed: [PhotoAsset]) {
        applyFactChanges(changed)
        relocate(binned, ids: binned.map(\.id), toBin: true)
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
}
