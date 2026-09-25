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
            photo.isDeleted = true
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
            photo.isDeleted = false
            ids.append(photo.id)
        }
        try? modelContext?.save()
        relocate(photosToRestore, ids: ids, toBin: false)
        return ids
    }

    // MARK: - Deleting Files

    /// Deletes one file type of each photo (with the RAW or JPG filter active): a pair loses that file, moved to the
    /// Trash; a photo with only one file, or both filters active, goes to the bin instead.
    func deleteFileType(of photosToRemove: [PhotoAsset], raw deleteRAW: Bool, jpg deleteJPG: Bool) {
        for photo in photosToRemove {
            if deleteRAW && deleteJPG {
                // Both file type filters active — normal soft delete
                photo.isDeleted = true
            } else if deleteRAW && photo.hasRawPair {
                Self.moveToTrash(Self.files(of: photo, jpg: false, raw: true))
                photo.rawPath = nil
                photo.hasRawEdits = false
            } else if deleteJPG && photo.hasRawPair {
                Self.moveToTrash(Self.files(of: photo, jpg: true, raw: false))
                photo.jpgPath = nil
                photo.jpgEditParametersData = nil
            } else {
                // Non-paired photo: normal soft delete
                photo.isDeleted = true
            }
        }
        try? modelContext?.save()
        loadExistingData()
    }

    /// Moves the photos' files (and RAW sidecars) to the Trash and deletes the photos from the store.
    func deletePermanently(_ photosToDelete: [PhotoAsset]) {
        guard let context = modelContext else { return }

        for photo in photosToDelete {
            Self.moveToTrash(Self.files(of: photo, jpg: true, raw: true))
            context.delete(photo)
        }

        try? context.save()
        loadExistingData()
    }

    /// The files a delete moves to the Trash: the photo's JPG (`jpg`) and/or its RAW (`raw`) together with the RAW's
    /// XMP sidecar. Every delete uses this one list.
    static func files(of photo: PhotoAsset, jpg: Bool, raw: Bool) -> [URL] {
        var urls: [URL] = []
        if jpg, let jpgPath = photo.jpgPath {
            urls.append(URL(fileURLWithPath: jpgPath))
        }
        if raw, let rawPath = photo.rawPath {
            let rawURL = URL(fileURLWithPath: rawPath)
            urls.append(rawURL)
            urls.append(rawURL.xmpSidecarURL)
        }
        return urls
    }

    /// Moves each of `urls` that exists to the Trash, in order. Failures are ignored, as before.
    private static func moveToTrash(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // MARK: - Background Metadata Write-back

    /// The photo's rating and keywords, for its file. A JPG+RAW pair writes both: the JPG and the RAW's
    /// sidecar (user decision, task 23).
    private func metadataWriteItem(for photo: PhotoAsset) -> MetadataWriteItem {
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
