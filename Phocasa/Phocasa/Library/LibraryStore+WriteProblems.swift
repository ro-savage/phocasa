import Foundation

/// The status bar's Retry for metadata writes that didn't reach their files (`MetadataWriteProblem`): the photos those
/// files belong to, and their current values written again.
extension LibraryStore {
    /// The photos in the library or the bin with a file (JPG or RAW) at one of `paths`, by path. One pass over the
    /// photos, two model reads each, for an explicit Retry.
    func photos(withFilesAt paths: Set<String>) -> [String: PhotoAsset] {
        guard !paths.isEmpty else { return [:] }
        var found: [String: PhotoAsset] = [:]
        for list in [allPhotos, binPhotos] {
            for photo in list {
                for path in [photo.jpgPath, photo.rawPath].compactMap({ $0 }) where paths.contains(path) {
                    found[path] = photo
                }
                if found.count == paths.count { return found }
            }
        }
        return found
    }

    /// Writes the photos' current rating and keywords to their files again, as a rating change would (a pair: the JPG
    /// and the RAW's sidecar). Returns immediately. A change of theirs still in the write queue is written first, so
    /// the files get the values the library shows.
    func rewriteMetadata(of photos: [PhotoAsset]) {
        writePendingRows(of: photos)
        var seen = Set<UUID>()
        let items = photos.filter { seen.insert($0.id).inserted }.map(metadataWriteItem(for:))
        guard !items.isEmpty else { return }
        MetadataWriter.shared.enqueue(items)
    }
}
