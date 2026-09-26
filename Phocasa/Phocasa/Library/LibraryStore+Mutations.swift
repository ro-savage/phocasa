import SwiftData
import Foundation

// Changes to photos: each saves the store, writes the photo's file metadata back in the background where it changed,
// and patches the in-memory library instead of reloading it. None of them touches the selection; the view model
// does that for the flows that act on it.
extension LibraryStore {
    // MARK: - Rating

    func setRating(_ rating: Int, for photo: PhotoAsset) {
        photo.rating = rating
        try? modelContext?.save()

        writeMetadataInBackground([metadataWriteItem(for: photo)])
        applyFactChanges([photo])
        refreshVisiblePhotos()
    }

    /// Rates `photos` (in grid order, as `SelectionModel.selectedPhotosList` gives them) in one save.
    func setRating(_ rating: Int, for photos: [PhotoAsset]) {
        guard let context = modelContext else { return }
        for photo in photos {
            photo.rating = rating
        }
        try? context.save()

        writeMetadataInBackground(photos.map { metadataWriteItem(for: $0) })
        applyFactChanges(photos)
        refreshVisiblePhotos()
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

    /// Adds the tag to each of `photos` that doesn't have it yet, in one save.
    func addTag(name: String, category: String, to photos: [PhotoAsset]) {
        guard let context = modelContext else { return }
        let tag = findOrCreateTag(name: name, category: category, in: context)

        var changed: [PhotoAsset] = []
        for photo in photos {
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

    /// Removes the tag from every one of `photos`, in one save.
    func removeTag(_ tag: Tag, from photos: [PhotoAsset]) {
        guard let context = modelContext else { return }
        for photo in photos {
            photo.tags.removeAll { $0.id == tag.id }
        }
        try? context.save()
        writeMetadataInBackground(photos.map { metadataWriteItem(for: $0) })
        applyFactChanges(photos)
        refreshVisiblePhotos()
        sortTagCategories()
    }

    // MARK: - Bin

    /// Moves photos to the bin. Returns their ids.
    @discardableResult
    func moveToBin(_ photosToMove: [PhotoAsset]) -> [UUID] {
        var ids: [UUID] = []
        for photo in photosToMove {
            photo.isInBin = true
            ids.append(photo.id)
        }
        try? modelContext?.save()
        relocate(photosToMove, ids: ids, toBin: true)
        return ids
    }

    /// Takes photos out of the bin. Returns their ids.
    @discardableResult
    func restoreFromBin(_ photosToRestore: [PhotoAsset]) -> [UUID] {
        var ids: [UUID] = []
        for photo in photosToRestore {
            photo.isInBin = false
            ids.append(photo.id)
        }
        try? modelContext?.save()
        relocate(photosToRestore, ids: ids, toBin: false)
        return ids
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
            applied.append((photo, change))
        }
        try? modelContext?.save()
        fileTypeDeleteDidFinish(binned: applied.filter { $0.change == .toBin }.map(\.photo),
                                changed: applied.filter { $0.change != .toBin }.map(\.photo))
        if !problems.isEmpty {
            deleteProblem = DeleteProblem(photoCount: problems.count, attemptedCount: changes.count,
                                          fileType: deleteRAW ? "RAW" : "JPG", problems: problems)
        }
    }

    /// Moves the photos' files (and RAW sidecars) to the Trash, then deletes from the store the photos whose files
    /// went (or were gone already). A photo with a file that couldn't be moved stays in the bin, less the files that
    /// did go; a sidecar left behind doesn't keep its photo.
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
        for photo in deleted {
            context.delete(photo)
        }
        try? context.save()
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
        photo.rating = source.rating
        photo.captureDate = source.captureDate
        context.insert(photo)
        photo.tags = source.tags
        try? context.save()
        updateLibrary(adding: [photo], facts: makeFacts(for: [photo]), removing: [])
        return photo
    }

    // MARK: - Background Metadata Write-back

    /// The photo's rating and keywords, for its file. A JPG+RAW pair writes both: the JPG and the RAW's
    /// sidecar (user decision, task 23).
    func metadataWriteItem(for photo: PhotoAsset) -> MetadataWriteItem {
        // Each path is read once (model property reads aren't free on the main thread); this is `displayPath`
        // and `hasRawPair` spelled out.
        let jpgPath = photo.jpgPath
        let rawPath = photo.rawPath
        return MetadataWriteItem(path: jpgPath ?? rawPath ?? "", rating: photo.rating,
                                 keywords: photo.tags.map(\.fullName),
                                 pairedRAWPath: jpgPath == nil ? nil : rawPath)
    }

    /// Hands the writes to the serial `MetadataWriter`, which writes them off the main thread,
    /// in call order, keeping only the latest per file (a pair's JPG and sidecar count as two files).
    /// Returns immediately.
    private func writeMetadataInBackground(_ items: [MetadataWriteItem]) {
        guard !items.isEmpty else { return }
        MetadataWriter.shared.enqueue(items)
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
