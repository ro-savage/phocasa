import Foundation
import SwiftData

/// A stored photo row as plain values, so a scan can compare the store with the disk off the main actor.
struct StoredPhoto: Sendable, Equatable {
    let id: UUID
    /// `DiscoveredPhoto.key(folderPath:fileName:)` of the row.
    let key: String
    let jpgPath: String?
    let rawPath: String?
    let fileSize: Int64
    /// `PhotoAsset.isDeleted`: the photo is in the bin.
    let isInBin: Bool
}

extension StoredPhoto {
    /// Every photo row in the store (binned ones and ones whose files are missing included), read through a
    /// new context on `container`, off the main thread. It only reads: all writes go through the view
    /// model's context. That context's unsaved changes aren't visible here, so save it first.
    static func fetchAll(in container: ModelContainer) async -> [StoredPhoto] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: fetchAllNow(in: container))
            }
        }
    }

    /// Synchronous `fetchAll(in:)`, for the calling thread. Don't call it on the main thread.
    static func fetchAllNow(in container: ModelContainer) -> [StoredPhoto] {
        let context = ModelContext(container)
        // Bin membership comes from a predicate the store evaluates. Reading `isDeleted` through a model can
        // disagree with the store (it collides with Core Data's own `isDeleted`; results/10.md, deviation 12).
        let binned = (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isDeleted }))) ?? []
        let binnedIDs = Set(binned.map(\.id))
        let photos = (try? context.fetch(FetchDescriptor<PhotoAsset>())) ?? []
        var rows: [StoredPhoto] = []
        rows.reserveCapacity(photos.count)
        for photo in photos {
            let id = photo.id
            rows.append(StoredPhoto(
                id: id,
                key: DiscoveredPhoto.key(folderPath: photo.folderPath, fileName: photo.fileName),
                jpgPath: photo.jpgPath,
                rawPath: photo.rawPath,
                fileSize: photo.fileSize,
                isInBin: binnedIDs.contains(id)
            ))
        }
        return rows
    }
}

/// What a scan changes in the library: the difference between the stored rows and what the scan found on disk.
struct ScanPlan: Sendable {
    /// New values for a stored row.
    struct Update: Sendable, Equatable {
        let id: UUID
        let jpgPath: String?
        let rawPath: String?
        let fileSize: Int64
        /// The row is in the bin and its files were found, so the scan puts it back in the library
        /// (the scan's existing behaviour).
        let restoresFromBin: Bool
    }

    /// Stored rows whose paths, size or bin state differ from what the scan found. Every row with a found key
    /// is compared, so duplicate rows for one file (left by older versions) are all kept up to date.
    var updates: [Update] = []
    /// Found photos with no stored row, in discovery order. Their metadata hasn't been read yet.
    var newPhotos: [DiscoveredPhoto] = []
    /// Library photos (not in the bin) that the scan didn't find and none of whose files exist. What the scan
    /// found is available. A photo it didn't find whose file still exists (for example under an earlier library
    /// root) stays visible, as with a full availability check.
    var missingIDs: Set<UUID> = []
    /// How many photos the scan found.
    var discoveredCount = 0

    /// `fileExists` is called only for rows the scan didn't find; after an unchanged rescan, never.
    init(stored: [StoredPhoto], discovered: [DiscoveredPhoto],
         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        discoveredCount = discovered.count
        let foundByKey = Dictionary(discovered.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var knownKeys = Set<String>(minimumCapacity: stored.count)
        for row in stored {
            if let found = foundByKey[row.key] {
                knownKeys.insert(row.key)
                if row.jpgPath != found.jpgPath || row.rawPath != found.rawPath
                    || row.fileSize != found.fileSize || row.isInBin {
                    updates.append(Update(id: row.id, jpgPath: found.jpgPath, rawPath: found.rawPath,
                                          fileSize: found.fileSize, restoresFromBin: row.isInBin))
                }
            } else if !row.isInBin {
                let jpgExists = row.jpgPath.map(fileExists) ?? false
                let rawExists = row.rawPath.map(fileExists) ?? false
                if !jpgExists && !rawExists { missingIDs.insert(row.id) }
            }
        }
        newPhotos = discovered.filter { !knownKeys.contains($0.key) }
    }

    /// Computes the plan off the main thread.
    static func make(stored: [StoredPhoto], discovered: [DiscoveredPhoto]) async -> ScanPlan {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ScanPlan(stored: stored, discovered: discovered))
            }
        }
    }

    /// Whether a background context may insert this new photo: only if its file has no keywords. Such a photo
    /// has no relationships, so inserting it touches no row that the view model's context has loaded.
    ///
    /// A photo with keywords links to tags, and the view model's context may hold those tags with their
    /// `photos` inverse already loaded. That copy doesn't see links saved by another context, and the next
    /// save of the tag in the view model's context would write it back and drop them. So those photos are
    /// inserted in the view model's context.
    static func canInsertInBackground(_ photo: DiscoveredPhoto) -> Bool {
        photo.metadata?.keywords.isEmpty ?? true
    }

    /// Photos inserted per background save.
    private static let backgroundSaveChunkSize = 500

    /// Inserts the new photos that pass `canInsertInBackground` (and skips the others) through a new context on
    /// `container`, off the main thread, saving every few hundred rows. Returns how many rows were saved.
    static func insertInBackground(_ photos: [DiscoveredPhoto], into container: ModelContainer) async -> Int {
        let photos = photos.filter(canInsertInBackground)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ModelContext(container)
                var saved = 0
                var start = 0
                while start < photos.count {
                    let end = min(start + backgroundSaveChunkSize, photos.count)
                    for found in photos[start..<end] {
                        let asset = PhotoAsset(
                            fileName: found.fileName,
                            jpgPath: found.jpgPath,
                            rawPath: found.rawPath,
                            folderPath: found.folderPath,
                            creationDate: found.creationDate,
                            fileSize: found.fileSize
                        )
                        asset.rating = found.metadata?.rating ?? 0
                        context.insert(asset)
                    }
                    do {
                        try context.save()
                        saved += end - start
                    } catch {
                        context.rollback() // leave these for the next scan, which will find them new again
                    }
                    start = end
                }
                continuation.resume(returning: saved)
            }
        }
    }
}
