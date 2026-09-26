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
    /// `PhotoAsset.isInBin`: the photo is in the bin.
    let isInBin: Bool
    /// `PhotoAsset.captureDate` and `creationDate`, which tell a moved photo from a lookalike
    /// (`ScanPlan.relinkMovedPhotos(fileExists:)`).
    var captureDate: Date? = nil
    var creationDate: Date? = nil

    /// Whether the photo's files are in `folder` or below it (by its key, so without a look at the disk).
    func isInside(_ folder: String) -> Bool {
        key.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

/// A read of the store that gave no usable answer without throwing: `fetchCount` of a store it can't read answers
/// `NSNotFound`.
struct StoreReadError: LocalizedError {
    var errorDescription: String? { "The library’s database couldn’t be read." }
}

extension StoredPhoto {
    /// Every photo row in the store (binned ones and ones whose files are missing included), read through a
    /// new context on `container`, off the main thread. It only reads: all writes go through the view
    /// model's context. That context's unsaved changes aren't visible here, so save it first.
    ///
    /// Throws if the store can't be read: a scan's diff against no rows would find every photo new and insert the
    /// whole library again.
    static func fetchAll(in container: ModelContainer) async throws -> [StoredPhoto] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try fetchAllNow(in: container) })
            }
        }
    }

    /// Synchronous `fetchAll(in:)`, for the calling thread. Don't call it on the main thread.
    static func fetchAllNow(in container: ModelContainer) throws -> [StoredPhoto] {
        let context = ModelContext(container)
        let binned = try context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.isInBin }))
        let binnedIDs = Set(binned.map(\.id))
        let photos = try context.fetch(FetchDescriptor<PhotoAsset>())
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
                isInBin: binnedIDs.contains(id),
                captureDate: photo.captureDate,
                creationDate: photo.creationDate
            ))
        }
        return rows
    }
}

/// What a scan of one library folder changes in the library: the difference between the stored rows and what the scan
/// found on disk.
struct ScanPlan: Sendable {
    /// New values for a stored row.
    struct Update: Sendable, Equatable {
        let id: UUID
        let jpgPath: String?
        let rawPath: String?
        let fileSize: Int64
    }

    /// A stored photo found under another path: moved or renamed with its folder, or on a drive mounted under another
    /// name. The row takes the files found (its paths, folder, name and size) and keeps everything else: its rating,
    /// tags, edits, bin state and dates.
    struct Relink: Sendable, Equatable {
        let id: UUID
        let fileName: String
        let folderPath: String
        let jpgPath: String?
        let rawPath: String?
        let fileSize: Int64

        init(id: UUID, to found: DiscoveredPhoto) {
            self.id = id
            fileName = found.fileName
            folderPath = found.folderPath
            jpgPath = found.jpgPath
            rawPath = found.rawPath
            fileSize = found.fileSize
        }
    }

    /// Stored rows (in the library or the bin) whose paths or size differ from what the scan found. Every row with a
    /// found key is compared, so duplicate rows for one file (left by older versions) are all kept up to date. A row in
    /// the bin stays there: a scan never takes a photo out of the bin (user decision, wave 2 #1).
    var updates: [Update] = []
    /// Stored rows found at new paths: by their path inside a library folder that moved (`init`), then by their files
    /// (`relinkMovedPhotos(fileExists:)`). A row in the bin stays there.
    var relinks: [Relink] = []
    /// Found photos with no stored row, in discovery order, less the ones relinked. Their metadata hasn't been read yet.
    var newPhotos: [DiscoveredPhoto] = []
    /// Library photos (not in the bin) this scan checks that it didn't find and none of whose files exist. What the
    /// scan found is available. A photo it didn't find whose file still exists (for example under a folder that isn't
    /// a library folder any more) stays visible, as with a full availability check, unless it's inside a folder below
    /// the root that the scan skips (`FolderScanner.isInsideSkippedFolder`): earlier versions imported photos from
    /// inside other apps' libraries, and the library stops showing those.
    var missingIDs: Set<UUID> = []
    /// Library photos in `previouslyMissing` that aren't missing any more (found, their file is back, or relinked):
    /// the library shows them again.
    var foundAgainIDs: Set<UUID> = []
    /// How many photos the scan found.
    var discoveredCount = 0

    /// The stored rows, for `relinkMovedPhotos(fileExists:)`.
    private var stored: [StoredPhoto] = []
    /// Keys of the stored rows the scan found.
    private var foundKeys: Set<String> = []
    private var relinkedIDs: Set<UUID> = []
    /// Whether each row looked at has no file left (`filesAreGone(_:_:)`), so no file is asked about twice.
    private var gone: [UUID: Bool] = [:]
    private var previouslyMissing: Set<UUID> = []

    /// - `previouslyMissing`: the missing set the library shows now (`LibraryStore.missingPhotoIDs`).
    /// - `root`: the library folder scanned. `movedFrom`: where it was, when it has moved since it was recorded
    ///   (renamed, or its drive mounted under another name); a new photo is then the row at the same path inside the
    ///   old folder, when that row's files are gone.
    /// - `otherRoots`: the other library folders. Their rows are their own scans' to check: this one doesn't look at
    ///   their files, and they stay missing or not as they were. Rows under no library folder are checked by every scan.
    ///
    /// `fileExists` is called only for rows this scan checks that it didn't find, and for rows a relink looks at; after
    /// an unchanged rescan, never.
    init(stored: [StoredPhoto], discovered: [DiscoveredPhoto], previouslyMissing: Set<UUID> = [], root: String? = nil,
         movedFrom: String? = nil, otherRoots: [String] = [],
         fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        discoveredCount = discovered.count
        self.stored = stored
        self.previouslyMissing = previouslyMissing
        let foundByKey = Dictionary(discovered.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        foundKeys.reserveCapacity(stored.count)
        /// Whether this scan checks the row's files: rows under the folder scanned (where it is or was), and rows under
        /// no other library folder.
        func isChecked(_ row: StoredPhoto) -> Bool {
            guard let root else { return true }
            if row.isInside(root) || movedFrom.map(row.isInside) == true { return true }
            return !otherRoots.contains(where: row.isInside)
        }
        for row in stored {
            var checked = true
            if let found = foundByKey[row.key] {
                foundKeys.insert(row.key)
                if row.jpgPath != found.jpgPath || row.rawPath != found.rawPath || row.fileSize != found.fileSize {
                    updates.append(Update(id: row.id, jpgPath: found.jpgPath, rawPath: found.rawPath,
                                          fileSize: found.fileSize))
                }
            } else if row.isInBin || !isChecked(row) {
                checked = false
            } else if let root, let path = row.jpgPath ?? row.rawPath,
                      FolderScanner.isInsideSkippedFolder(path, below: root) {
                missingIDs.insert(row.id)
            } else if filesAreGone(row, fileExists) {
                missingIDs.insert(row.id)
            }
            if checked && !row.isInBin && previouslyMissing.contains(row.id) && !missingIDs.contains(row.id) {
                foundAgainIDs.insert(row.id)
            }
        }
        newPhotos = discovered.filter { !foundKeys.contains($0.key) }
        if let root, let movedFrom, movedFrom != root, !newPhotos.isEmpty {
            relinkByPath(from: movedFrom, to: root, fileExists)
        }
    }

    /// Computes the plan off the main thread.
    static func make(stored: [StoredPhoto], discovered: [DiscoveredPhoto], previouslyMissing: Set<UUID> = [],
                     root: String? = nil, movedFrom: String? = nil, otherRoots: [String] = []) async -> ScanPlan {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ScanPlan(stored: stored, discovered: discovered,
                                                        previouslyMissing: previouslyMissing, root: root,
                                                        movedFrom: movedFrom, otherRoots: otherRoots))
            }
        }
    }

    /// The library's missing set after this scan, from the one it shows now: what this scan found missing is, what it
    /// found (or relinked) isn't, and rows it didn't check stay as they were.
    func missingSet(after shown: Set<UUID>) -> Set<UUID> {
        shown.subtracting(foundAgainIDs).union(missingIDs)
    }

    // MARK: - Moved Photos

    /// The library folder moved (`oldRoot` → `root`): each new photo is the row at the same path inside the old folder,
    /// if that row's files are gone. The strongest match, so it needs nothing else, and it tells apart lookalikes the
    /// match by files can't. Duplicate rows of one file (left by older versions) are relinked together, as `updates`
    /// keeps them all up to date.
    private mutating func relinkByPath(from oldRoot: String, to root: String, _ fileExists: (String) -> Bool) {
        let oldPrefix = oldRoot.hasSuffix("/") ? oldRoot : oldRoot + "/"
        let newPrefix = root.hasSuffix("/") ? root : root + "/"
        var rowsByKey: [String: [Int]] = [:]
        for index in stored.indices where !foundKeys.contains(stored[index].key) && stored[index].isInside(oldRoot) {
            rowsByKey[stored[index].key, default: []].append(index)
        }
        guard !rowsByKey.isEmpty else { return }
        var relinkedKeys = Set<String>()
        for photo in newPhotos where photo.key.hasPrefix(newPrefix) {
            guard let rows = rowsByKey[oldPrefix + photo.key.dropFirst(newPrefix.count)] else { continue }
            for index in rows where filesAreGone(stored[index], fileExists) {
                relink(stored[index], to: photo)
                relinkedKeys.insert(photo.key)
            }
        }
        newPhotos.removeAll { relinkedKeys.contains($0.key) }
    }

    /// Once the new photos' metadata has been read: a new photo is a stored row the scan didn't find, whose files are
    /// gone, when both have the same files by name (the same stem, and a JPG and a RAW with the same names, or not)
    /// and the same capture date. A row stored without a capture date needs the same size and file creation date
    /// instead. (The size isn't asked otherwise: a rating written into a file changes its size, and the row keeps the
    /// old one until a scan sees the file where it was.)
    ///
    /// Only a one-to-one match relinks. When two missing rows could be the new photo, or the row two new photos (a
    /// photo moved and copied, lookalikes both moved), nothing is guessed: the photos are added as new ones and the rows
    /// stay missing, as before. Rows are looked for wherever they are: under this folder, another library folder or
    /// none, in the bin or not.
    mutating func relinkMovedPhotos(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        guard !newPhotos.isEmpty else { return }
        var photosByNames: [FileNames: [Int]] = [:]
        for index in newPhotos.indices {
            photosByNames[FileNames(newPhotos[index]), default: []].append(index)
        }
        var rowsByNames: [FileNames: [Int]] = [:]
        for index in stored.indices where !foundKeys.contains(stored[index].key) {
            let names = FileNames(stored[index])
            if photosByNames[names] != nil { rowsByNames[names, default: []].append(index) }
        }
        guard !rowsByNames.isEmpty else { return }

        var relinkedPhotos = Set<Int>()
        for (names, photoIndices) in photosByNames {
            guard let rowIndices = rowsByNames[names] else { continue }
            for photoIndex in photoIndices {
                let photo = newPhotos[photoIndex]
                var match: Int?
                var matches = 0
                for rowIndex in rowIndices where Self.canBe(stored[rowIndex], photo)
                    && !relinkedIDs.contains(stored[rowIndex].id) && filesAreGone(stored[rowIndex], fileExists) {
                    matches += 1
                    match = rowIndex
                }
                guard matches == 1, let rowIndex = match,
                      photoIndices.filter({ Self.canBe(stored[rowIndex], newPhotos[$0]) }).count == 1 else { continue }
                relink(stored[rowIndex], to: photo)
                relinkedPhotos.insert(photoIndex)
            }
        }
        guard !relinkedPhotos.isEmpty else { return }
        newPhotos = newPhotos.indices.filter { !relinkedPhotos.contains($0) }.map { newPhotos[$0] }
    }

    /// `relinkMovedPhotos(fileExists:)` off the main thread.
    func relinkingMovedPhotos() async -> ScanPlan {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var plan = self
                plan.relinkMovedPhotos()
                continuation.resume(returning: plan)
            }
        }
    }

    /// Whether `photo` can be the stored `row`, moved, given that their files have the same names: the same capture
    /// date, or for a row stored without one, the same size and file creation date.
    private static func canBe(_ row: StoredPhoto, _ photo: DiscoveredPhoto) -> Bool {
        if let taken = row.captureDate { return photo.metadata?.captureDate == taken }
        guard let created = row.creationDate else { return false }
        return photo.creationDate == created && photo.fileSize == row.fileSize
    }

    /// A photo's files by name: its JPG's and its RAW's.
    private struct FileNames: Hashable {
        let jpg: String?
        let raw: String?

        init(_ row: StoredPhoto) {
            jpg = row.jpgPath.map(Self.name)
            raw = row.rawPath.map(Self.name)
        }

        init(_ photo: DiscoveredPhoto) {
            jpg = photo.jpgPath.map(Self.name)
            raw = photo.rawPath.map(Self.name)
        }

        private static func name(_ path: String) -> String {
            (path as NSString).lastPathComponent
        }
    }

    private mutating func relink(_ row: StoredPhoto, to photo: DiscoveredPhoto) {
        relinks.append(Relink(id: row.id, to: photo))
        relinkedIDs.insert(row.id)
        missingIDs.remove(row.id)
        if !row.isInBin && previouslyMissing.contains(row.id) { foundAgainIDs.insert(row.id) }
    }

    /// Whether none of the row's files exists. Each row's files are asked about once.
    private mutating func filesAreGone(_ row: StoredPhoto, _ fileExists: (String) -> Bool) -> Bool {
        if let known = gone[row.id] { return known }
        let isGone = !(row.jpgPath.map(fileExists) ?? false) && !(row.rawPath.map(fileExists) ?? false)
        gone[row.id] = isGone
        return isGone
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

    /// The row a scan inserts for a new photo (without its tags): its files, and the rating and capture date read
    /// from them. A RAW whose `.xmp` sidecar holds a saved Phocasa edit is marked edited (`hasRawEdits`), so the
    /// detail view shows the edit.
    static func newRow(for found: DiscoveredPhoto) -> PhotoAsset {
        let asset = PhotoAsset(
            fileName: found.fileName,
            jpgPath: found.jpgPath,
            rawPath: found.rawPath,
            folderPath: found.folderPath,
            creationDate: found.creationDate,
            fileSize: found.fileSize
        )
        asset.rating = found.metadata?.rating ?? 0
        asset.captureDate = found.metadata?.captureDate
        if found.rawPath != nil && found.metadata?.editParameters != nil { asset.hasRawEdits = true }
        return asset
    }

    /// Photos inserted per background save.
    private static let backgroundSaveChunkSize = 500

    /// Inserts the new photos that pass `canInsertInBackground` (and skips the others) through a new context on
    /// `container`, off the main thread, saving every few hundred rows. Returns the ids of the rows saved.
    static func insertInBackground(_ photos: [DiscoveredPhoto], into container: ModelContainer) async -> [UUID] {
        let photos = photos.filter(canInsertInBackground)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ModelContext(container)
                var saved: [UUID] = []
                var start = 0
                while start < photos.count {
                    let end = min(start + backgroundSaveChunkSize, photos.count)
                    var chunk: [UUID] = []
                    for found in photos[start..<end] {
                        let asset = newRow(for: found)
                        context.insert(asset)
                        chunk.append(asset.id)
                    }
                    do {
                        try context.save()
                        saved += chunk
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
