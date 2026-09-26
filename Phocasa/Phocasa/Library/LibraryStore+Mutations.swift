import SwiftData
import Foundation

// Changes to photos. Each patches the in-memory library at once (the facts, the counts, the grid) instead of reloading
// it, and queues the rows' new values (`LibraryStore+RowWrites`: written in the same turn for a few photos, in chunks
// sized by time for many), whose writes send the photos' rating and keywords to their files. None of them touches the
// selection; the view model does that for the flows that act on it.
extension LibraryStore {
    // MARK: - Rating

    func setRating(_ rating: Int, for photo: PhotoAsset) {
        setRating(rating, for: [photo])
    }

    /// Rates `photos` (in grid order, as `SelectionModel.selectedPhotosList` gives them). Every photo's files get the
    /// rating, even those that had it already.
    func setRating(_ rating: Int, for photos: [PhotoAsset]) {
        setRatings(photos.map { ($0, rating) })
    }

    /// Gives each photo its rating. The facts change in memory without reading the models.
    func setRatings(_ ratings: [(photo: PhotoAsset, rating: Int)]) {
        guard modelContext != nil, !ratings.isEmpty else { return }
        let positions = positions(of: ratings.map(\.photo.id))
        var located: [(facts: PhotoFacts, position: ListPosition)] = []
        located.reserveCapacity(ratings.count)
        for i in ratings.indices {
            guard let position = positions[i] else { continue }
            var facts = facts(at: position)
            facts.rating = ratings[i].rating
            located.append((facts, position))
        }
        enqueueRowChanges(ratings.map { ($0.photo, RowChange(rating: $0.rating, writesMetadata: true)) })
        applyFacts(located)
        refreshVisiblePhotos()
        writeQueuedRows(changedNow: ratings.map(\.photo))
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
        addTag(name: name, category: category, to: [photo])
    }

    /// Adds the tag to each of `photos` that doesn't have it yet.
    func addTag(name: String, category: String, to photos: [PhotoAsset]) {
        guard let context = modelContext else { return }
        let tag = findOrCreateTag(name: name, category: category, in: context)
        refreshTagLists(newTag: tag)
        // A new tag that no photo got (they all had it) isn't left unsaved; otherwise its photos' save writes it.
        if setTag(tag, on: photos, to: true) == 0 && context.hasChanges { try? context.save() }
    }

    func removeTag(_ tag: Tag, from photo: PhotoAsset) {
        removeTag(tag, from: [photo])
    }

    /// Removes the tag from every one of `photos` that has it.
    func removeTag(_ tag: Tag, from photos: [PhotoAsset]) {
        guard modelContext != nil else { return }
        setTag(tag, on: photos, to: false)
    }

    /// Gives `tag` to (`has`), or takes it from, each of `photos` that has it the other way. The facts change in memory
    /// without reading the models (the counts, the grid and the search keys with them), and each changed photo's row
    /// gains or loses the link. Only the photos that changed have their files written. Returns how many changed.
    @discardableResult
    private func setTag(_ tag: Tag, on photos: [PhotoAsset], to has: Bool) -> Int {
        guard !photos.isEmpty else { return 0 }
        let tagFact = tagFacts.facts(for: tag)
        let ids = photos.map(\.id)
        let positions = positions(of: ids)
        var tagsByID: [UUID: TagFacts]?
        var changed: [(photo: PhotoAsset, id: UUID)] = []
        var located: [(facts: PhotoFacts, position: ListPosition)] = []
        var rebuild: [PhotoAsset] = []
        for i in photos.indices {
            guard let position = positions[i] else {
                // Not loaded (not a photo on screen): its model and queued changes say whether it has the tag.
                if tags(of: photos[i]).contains(where: { $0 === tag }) != has { changed.append((photos[i], ids[i])) }
                continue
            }
            var facts = facts(at: position)
            guard facts.tagIDs.contains(tagFact.id) != has else { continue }
            changed.append((photos[i], ids[i]))
            if has {
                facts.add(tagFact)
            } else {
                if tagsByID == nil { tagsByID = tagFactsByID(including: tag) }
                guard facts.remove(tagFact, tagsByID: tagsByID ?? [:]) else {
                    rebuild.append(photos[i]) // a tag the lists don't know: its facts are read again below
                    continue
                }
            }
            located.append((facts, position))
        }
        let change = has ? RowChange(addedTags: [tag], writesMetadata: true)
            : RowChange(removedTags: [tag], writesMetadata: true)
        enqueueRowChanges(changed.map { ($0.photo, change) })
        applyFacts(located)
        applyFactChanges(rebuild)
        refreshVisiblePhotos()
        sortTagCategories()
        writeQueuedRows(changedNow: changed.map(\.photo))
        return changed.count
    }

    /// Every tag's facts by id (and `tag`'s, if the lists don't have it yet), for taking a tag out of photos' facts.
    private func tagFactsByID(including tag: Tag) -> [UUID: TagFacts] {
        var byID: [UUID: TagFacts] = [:]
        for known in allTags + [tag] {
            let facts = tagFacts.facts(for: known)
            byID[facts.id] = facts
        }
        return byID
    }

    // MARK: - Bin

    /// Moves photos to the bin. Returns their ids.
    @discardableResult
    func moveToBin(_ photosToMove: [PhotoAsset]) -> [UUID] {
        setInBin(photosToMove, true)
    }

    /// Takes photos out of the bin. Returns their ids.
    @discardableResult
    func restoreFromBin(_ photosToRestore: [PhotoAsset]) -> [UUID] {
        setInBin(photosToRestore, false)
    }

    private func setInBin(_ photos: [PhotoAsset], _ inBin: Bool) -> [UUID] {
        let ids = photos.map(\.id)
        enqueueRowChanges(photos.map { ($0, RowChange(isInBin: inBin)) })
        relocate(photos, ids: ids, toBin: inBin)
        writeQueuedRows(changedNow: photos)
        return ids
    }

    // MARK: - Saved Edits

    /// Gives each photo its saved edits (presets, "Revert All Edits"): the rows through the write queue,
    /// and for a photo with a RAW its sidecar's edit parameters (`rawParameters`; nil clears them) through
    /// `RAWEditStore`, whose reads see them at once.
    func setSavedEdits(_ changes: [(photo: PhotoAsset, edits: SavedEdits, rawParameters: EditParameters?)]) {
        guard modelContext != nil, !changes.isEmpty else { return }
        for change in changes {
            if let rawPath = change.photo.rawPath {
                RAWEditStore.shared.save(change.rawParameters, forRAWAt: rawPath)
            }
        }
        queueRowChanges(changes.map { ($0.photo, RowChange(edits: $0.edits)) })
    }

    // MARK: - Deleting Files
    // The files are moved to the Trash on `fileTrasher`, off the main actor (spec §G5); the store changes once they
    // are there, and only for the files that went (or were gone already): a file that couldn't be moved (locked,
    // read-only, a share without a Trash) or whose drive isn't connected keeps its photo as it was, and
    // `deleteProblem` says how many and why. A photo whose delete is still running can't be deleted again meanwhile.

    /// Deletes one file type of each photo (with the RAW or JPG filter active): a pair loses that file, moved to the
    /// Trash; a photo with only one file, or both filters active, goes to the bin instead. A pair whose file can't be
    /// moved keeps it.
    ///
    /// A RAW goes with its `.xmp` sidecar (its rating, keywords and edits, and what other apps wrote about it), except
    /// when the pair's JPG keeps its own rating and keywords there (`phocasa:OverridesEmbedded`, for a JPG that can't
    /// take them): then the sidecar stays with the JPG.
    ///
    /// The rows change in chunks sized by time (`writeInChunks`), then the in-memory library once.
    func deleteFileType(of photosToRemove: [PhotoAsset], raw deleteRAW: Bool, jpg deleteJPG: Bool) async {
        enum Change { case toBin, dropRAW, dropJPG }
        var changes: [(photo: PhotoAsset, change: Change)] = []
        var files: [URL] = []
        var sidecars: [(sidecar: URL, jpg: URL, raw: URL)] = []
        for photo in photosToRemove where photosBeingDeleted.insert(photo.id).inserted {
            if deleteRAW && deleteJPG {
                // Both file type filters active — normal soft delete
                changes.append((photo, .toBin))
            } else if deleteRAW && photo.hasRawPair, let rawPath = photo.rawPath, let jpgPath = photo.jpgPath {
                let raw = URL(fileURLWithPath: rawPath)
                files.append(raw)
                sidecars.append((raw.xmpSidecarURL, URL(fileURLWithPath: jpgPath), raw))
                changes.append((photo, .dropRAW))
            } else if deleteJPG && photo.hasRawPair {
                files += Self.files(of: photo, jpg: true, raw: false)
                changes.append((photo, .dropJPG))
            } else {
                // Non-paired photo: normal soft delete
                changes.append((photo, .toBin))
            }
        }
        guard !changes.isEmpty else { return }

        let outcomes = Self.outcomesByPath(files, await moveToTrash(files))
        // A RAW's sidecar (its rating, keywords and edits) goes only once the RAW has, and not while the JPG's own
        // values live in it. Off the main actor: it reads each sidecar there is.
        let goneRAWs = sidecars.filter { outcomes[$0.raw.path]?.fileIsGone == true }
        if !goneRAWs.isEmpty {
            let sidecarFiles = await Task.detached(priority: .userInitiated) {
                goneRAWs.filter { !MetadataService.shared.sidecarOverridesEmbedded($0.jpg) }.map(\.sidecar)
            }.value
            _ = await moveToTrash(sidecarFiles)
        }

        var applied: [(photo: PhotoAsset, change: Change)] = []
        var problems: [(path: String, outcome: TrashOutcome)] = []
        for (photo, change) in changes {
            photosBeingDeleted.remove(photo.id)
            let path = change == .dropRAW ? photo.rawPath : change == .dropJPG ? photo.jpgPath : nil
            if let path, let outcome = outcomes[path], !outcome.fileIsGone {
                problems.append((path, outcome)) // the file is still there: the pair keeps it
                continue
            }
            applied.append((photo, change))
        }
        // Their queued changes first, so none of them is written over these afterwards.
        writePendingRows(of: applied.map(\.photo))
        if let context = modelContext {
            await writeInChunks(applied, in: context) { chunk in
                for (photo, change) in chunk where photo.modelContext != nil {
                    switch change {
                    case .toBin:
                        photo.isInBin = true
                    case .dropRAW:
                        photo.rawPath = nil
                        photo.hasRawEdits = false
                    case .dropJPG:
                        photo.jpgPath = nil
                        photo.jpgEditParametersData = nil
                    }
                }
            }
        }
        fileTypeDeleteDidFinish(binned: applied.filter { $0.change == .toBin }.map(\.photo),
                                changed: applied.filter { $0.change != .toBin }.map(\.photo))
        if !problems.isEmpty {
            deleteProblem = DeleteProblem(photoCount: problems.count, attemptedCount: changes.count,
                                          fileType: deleteRAW ? "RAW" : "JPG", problems: problems)
        }
    }

    /// Moves the photos' files (and RAW sidecars) to the Trash, then deletes from the store the photos whose files
    /// went (or were gone already). A photo with a file that couldn't be moved stays in the bin, less the files that
    /// did go; a sidecar left behind doesn't keep its photo. The library changes in memory at once; the rows go through
    /// the write queue (a few now, many in chunks), each untagged on its tags' side first.
    func deletePermanently(_ photosToDelete: [PhotoAsset]) async {
        guard let context = modelContext else { return }
        let photos = photosToDelete.filter { photosBeingDeleted.insert($0.id).inserted }
        guard !photos.isEmpty else { return }

        let files = photos.flatMap { Self.files(of: $0, jpg: true, raw: true) }
        let outcomes = Self.outcomesByPath(files, await moveToTrash(files))
        // A RAW's sidecar (its rating, keywords and edits) goes only once the RAW has: a RAW that couldn't be moved
        // keeps it.
        _ = await moveToTrash(photos.compactMap(\.rawPath).filter { outcomes[$0]?.fileIsGone == true }
            .map { URL(fileURLWithPath: $0).xmpSidecarURL })

        var deleted: [PhotoAsset] = []
        var kept: [PhotoAsset] = []
        var problems: [(path: String, outcome: TrashOutcome)] = []
        for photo in photos {
            photosBeingDeleted.remove(photo.id)
            let jpg = photo.jpgPath.map { ($0, outcomes[$0] ?? .alreadyGone) }
            let raw = photo.rawPath.map { ($0, outcomes[$0] ?? .alreadyGone) }
            let stuck = [jpg, raw].compactMap { $0 }.filter { !$0.1.fileIsGone }
            if stuck.isEmpty {
                deleted.append(photo)
                continue
            }
            problems += stuck.map { (path: $0.0, outcome: $0.1) }
            // It stays in the bin, pointing only at the files still there.
            if jpg?.1.fileIsGone == true { photo.jpgPath = nil }
            if raw?.1.fileIsGone == true { photo.rawPath = nil }
            kept.append(photo)
        }

        updateLibrary(adding: [], facts: [], removing: Set(deleted.map(\.id))) // in memory, before the models go
        if !kept.isEmpty { try? context.save() }
        queueRowChanges(deleted.map { ($0, RowChange(deletes: true)) })
        if !kept.isEmpty {
            photosDidChange(kept)
            deleteProblem = DeleteProblem(photoCount: kept.count, attemptedCount: photos.count, fileType: nil,
                                          problems: problems)
        }
    }

    /// Each file's outcome by path (`outcomes[i]` is `files[i]`'s).
    private static func outcomesByPath(_ files: [URL], _ outcomes: [TrashOutcome]) -> [String: TrashOutcome] {
        Dictionary(zip(files.map(\.path), outcomes), uniquingKeysWith: { first, _ in first })
    }

    /// The files a delete moves to the Trash: the photo's JPG (`jpg`) and/or its RAW (`raw`). Every delete uses this
    /// one list; the RAW's `.xmp` sidecar follows only once the RAW has gone (its rating and edits live there).
    static func files(of photo: PhotoAsset, jpg: Bool, raw: Bool) -> [URL] {
        var urls: [URL] = []
        if jpg, let jpgPath = photo.jpgPath {
            urls.append(URL(fileURLWithPath: jpgPath))
        }
        if raw, let rawPath = photo.rawPath {
            let rawURL = URL(fileURLWithPath: rawPath)
            urls.append(rawURL)
        }
        return urls
    }

    /// Batches of more than this many files show their progress in the status bar.
    static let trashProgressMinimum = 20
    /// Files trashed per trip to `fileTrasher`, so the progress can update in between.
    private static let trashChunkSize = 10

    /// Moves each of `files` that exists to the Trash, a few at a time, keeping `trashProgress` current. Returns what
    /// happened to each (`outcomes[i]` is `files[i]`'s).
    private func moveToTrash(_ files: [URL]) async -> [TrashOutcome] {
        guard !files.isEmpty else { return [] }
        trashPending.total += files.count
        publishTrashProgress()
        var outcomes: [TrashOutcome] = []
        outcomes.reserveCapacity(files.count)
        var start = 0
        while start < files.count {
            let end = min(start + Self.trashChunkSize, files.count)
            let chunk = Array(files[start..<end])
            outcomes += await fileTrasher.trash(chunk)
            trashPending.done += chunk.count
            publishTrashProgress()
            start = end
        }
        if trashPending.done == trashPending.total {
            trashPending = TrashProgress(done: 0, total: 0) // every running delete has trashed its files
            publishTrashProgress()
        }
        return outcomes
    }

    private func publishTrashProgress() {
        let shown = trashPending.total > Self.trashProgressMinimum ? trashPending : nil
        if trashProgress != shown { trashProgress = shown }
    }

    // MARK: - Exports

    /// A new JPG exported from `source` (`EditSession.exportToNewFile()`) joins the library as a photo of its own, as a
    /// scan would insert it (its folder, file name and path, so the next scan knows it rather than adding it again),
    /// with `source`'s rating, tags and capture date: the export carries the original's metadata, so it sorts beside
    /// it. `source` doesn't change. Patched in memory, no reload.
    @discardableResult
    func addExportedPhoto(at url: URL, copying source: PhotoAsset) -> PhotoAsset? {
        guard let context = modelContext else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        let photo = PhotoAsset(fileName: url.deletingPathExtension().lastPathComponent, jpgPath: url.path,
                               folderPath: url.deletingLastPathComponent().path, creationDate: values?.creationDate,
                               fileSize: Int64(values?.fileSize ?? 0))
        photo.rating = rating(of: source)
        photo.captureDate = source.captureDate
        context.insert(photo)
        photo.tags = tags(of: source)
        try? context.save()
        updateLibrary(adding: [photo], facts: makeFacts(for: [photo]), removing: [])
        return photo
    }

    // MARK: - Background Metadata Write-back

    /// The photo's rating and keywords, for its file, as its row holds them. A JPG+RAW pair writes both: the JPG and
    /// the RAW's sidecar (user decision, task 23).
    func metadataWriteItem(for photo: PhotoAsset) -> MetadataWriteItem {
        // Each path is read once (model property reads aren't free on the main thread); this is `displayPath`
        // and `hasRawPair` spelled out.
        let jpgPath = photo.jpgPath
        let rawPath = photo.rawPath
        return MetadataWriteItem(path: jpgPath ?? rawPath ?? "", rating: photo.rating,
                                 keywords: photo.tags.map(\.fullName),
                                 pairedRAWPath: jpgPath == nil ? nil : rawPath)
    }

    // MARK: - Big Writes Outside the Queue

    /// Changes rows with `write`, over `items` in chunks sized by time, saving each chunk and leaving the run loop a
    /// pause between them: for big writes that are done before the in-memory library changes (file-type deletes,
    /// scans). A write of at most `rowWrites.immediateLimit` items is one chunk. Without `savingLast`, the last chunk
    /// is left for the caller's own save. Returns the time spent writing.
    @discardableResult
    func writeInChunks<Item>(_ items: [Item], in context: ModelContext, savingLast: Bool = true,
                             _ write: (ArraySlice<Item>) -> Void) async -> Duration {
        var sizer = rowWrites.sizer
        let clock = ContinuousClock()
        var spent: Duration = .zero
        var start = items.startIndex
        var rows = rowWrites.immediateLimit
        while start < items.endIndex {
            let chunkStart = clock.now
            let end = min(start + rows, items.endIndex)
            write(items[start..<end])
            if savingLast || end < items.endIndex { try? context.save() }
            let elapsed = clock.now - chunkStart
            spent += elapsed
            sizer.record(rows: end - start, took: elapsed)
            rows = sizer.rows
            start = end
            if start < items.endIndex { try? await Task.sleep(for: WriteChunkSizer.pause(after: elapsed)) }
        }
        return spent
    }
}

/// A delete that left photos as they were because some of their files couldn't be moved to the Trash: how many, and
/// why, for the alert (`LibraryStore.deleteProblem`).
struct DeleteProblem: Equatable {
    /// Photos the delete left in place, all or in part.
    let photoCount: Int
    /// Photos it was asked to delete.
    let attemptedCount: Int
    /// "RAW" or "JPG" for a file-type delete; nil for a permanent delete.
    let fileType: String?
    /// One line per reason: a drive that isn't connected, or a file and why it couldn't be moved.
    let reasons: [String]

    /// Reasons listed before "And N more."
    static let reasonLimit = 5

    init(photoCount: Int, attemptedCount: Int, fileType: String?, problems: [(path: String, outcome: TrashOutcome)]) {
        self.photoCount = photoCount
        self.attemptedCount = attemptedCount
        self.fileType = fileType
        var reasons: [String] = []
        var drives = Set<String>()
        for (path, outcome) in problems {
            switch outcome {
            case .volumeUnavailable(let name):
                if drives.insert(name).inserted { reasons.append("“\(name)” isn’t connected.") }
            case .failed(let reason):
                reasons.append("“\((path as NSString).lastPathComponent)”: \(reason)")
            case .trashed, .alreadyGone:
                break
            }
        }
        self.reasons = reasons
    }

    var title: String { "Some Files Weren’t Moved to the Trash" }

    var message: String {
        let summary: String
        if let fileType {
            let photos = photoCount == 1 ? "1 photo" : "\(photoCount) photos"
            summary = "The \(fileType) file\(photoCount == 1 ? "" : "s") of \(photos) couldn’t be moved to the Trash, "
                + "so \(photoCount == 1 ? "that photo keeps it" : "those photos keep them")."
        } else {
            summary = "\(photoCount) of \(attemptedCount) photos couldn’t be moved to the Trash, so "
                + (photoCount == 1 ? "it’s" : "they’re") + " still in the Bin."
        }
        var lines = Array(reasons.prefix(Self.reasonLimit))
        if reasons.count > Self.reasonLimit { lines.append("And \(reasons.count - Self.reasonLimit) more.") }
        return ([summary] + lines).joined(separator: "\n")
    }
}
