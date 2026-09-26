import SwiftData
import Foundation

/// A library folder's "Remove from Library…" waiting for its confirmation.
struct FolderRemoval: Identifiable {
    let folder: PhotoLibrary
    /// The folder's name and path, read when it was asked for.
    let name: String
    let path: String
    /// How many photos (in the library, the bin, or missing) leave with it; nil if the store couldn't say.
    let photoCount: Int?

    var id: ObjectIdentifier { ObjectIdentifier(folder) }

    var title: String { "Remove “\(name)” from the library?" }

    var message: String {
        let photos = photoCount.map { $0 == 1 ? "Its photo leaves" : "Its \($0.formatted()) photos leave" }
            ?? "Its photos leave"
        return "\(photos) Phocasa’s library. No file is moved, changed or deleted: ratings and keywords written to the "
            + "files stay there, but Phocasa forgets what only it keeps: JPG edits, and which photos were in the bin. "
            + "Open the folder again to add it back.\n\(path)"
    }

    /// Whether `photo`'s files are in the folder.
    func contains(_ photo: PhotoAsset) -> Bool {
        LibraryStore.isPath(photo.folderPath, inOrAt: path)
    }
}

// The library folders: each folder the owner opened is a `PhotoLibrary` row, and a rescan scans each
// (`LibraryStore+Scan`). Here: the list, where each folder is now, and removing one.
extension LibraryStore {
    // MARK: - The List

    /// Puts `folders` in the list, sorted by path, and forgets what was known about folders no longer in it.
    func setLibraryFolders(_ folders: [PhotoLibrary]) {
        let sorted = folders.sorted { $0.rootFolderPath.localizedStandardCompare($1.rootFolderPath) == .orderedAscending }
        libraryFolders = sorted
        let ids = Set(sorted.map(\.id))
        folderIssues = folderIssues.filter { ids.contains($0.key) }
    }

    func libraryFolder(withID id: UUID) -> PhotoLibrary? {
        libraryFolders.first { $0.id == id }
    }

    /// Takes a folder out of the list (before its row is deleted), with its waiting scan and what was known about it.
    func forgetLibraryFolder(_ folder: PhotoLibrary) {
        let id = folder.id
        libraryFolders.removeAll { $0 === folder }
        folderIssues[id] = nil
        scanning.queued.removeAll { $0 == id }
        scanning.requestedURLs[id] = nil
    }

    /// The first library folder that wasn't there at its last scan, in list order.
    func firstFolderIssue() -> ScanIssue? {
        libraryFolders.lazy.compactMap { self.folderIssues[$0.id] }.first
    }

    // MARK: - Where a Folder Is

    /// Where a library folder's scan finds it, and `movedFrom`, its recorded path, when that's not where it is:
    /// - where Open Folder found it (`handleFolderSelected(url:)`);
    /// - else its recorded path, while that's a folder (even when its bookmark points elsewhere: a drive of the same
    ///   name, a backup say, may be mounted there, and it's what the rows point at);
    /// - else where its bookmark finds it now (renamed or moved on its drive, or the drive mounted under another name),
    ///   unless that's in a Trash;
    /// - else its recorded path, which the scan then says isn't there.
    func location(of folder: PhotoLibrary) -> (url: URL, movedFrom: String?) {
        let recorded = folder.rootFolderPath
        if let requested = scanning.requestedURLs[folder.id] {
            return (requested, requested.path == recorded ? nil : recorded)
        }
        let recordedURL = URL(fileURLWithPath: recorded, isDirectory: true)
        guard !Self.isDirectory(recorded), let bookmark = folder.bookmarkData,
              let found = Self.resolvedBookmark(bookmark) else { return (recordedURL, nil) }
        let path = Self.canonicalPath(of: found)
        guard path != recorded, Self.isDirectory(path), !Self.isInTrash(path) else { return (recordedURL, nil) }
        return (URL(fileURLWithPath: path, isDirectory: true), recorded)
    }

    /// Whether a folder opened at `path` is where `folder`, which isn't at its recorded path now, has gone: its
    /// bookmark finds it there, or `path` is its recorded path on its drive mounted under another name.
    func isMovedLibraryFolder(_ folder: PhotoLibrary, nowAt path: String) -> Bool {
        let recorded = folder.rootFolderPath
        guard !Self.isDirectory(recorded) else { return false }
        if volumes.isSameFolderOnRenamedVolume(path, as: recorded) { return true }
        guard let bookmark = folder.bookmarkData, let found = Self.resolvedBookmark(bookmark) else { return false }
        return Self.canonicalPath(of: found) == path
    }

    /// A scan found `folder` at `url`, not its recorded path: the folder is recorded there, with a new bookmark. If
    /// that's inside another library folder (or is one), the other covers it and it stops being one; library folders
    /// inside it become part of it.
    func libraryFolderDidMove(_ folder: PhotoLibrary, to url: URL) {
        let path = url.path
        folder.rootFolderPath = path
        if let bookmark = Self.bookmark(of: url) { folder.bookmarkData = bookmark }
        let others = libraryFolders.filter { $0 !== folder }
        if others.contains(where: { Self.isPath(path, inOrAt: $0.rootFolderPath) }) {
            forgetLibraryFolder(folder)
            modelContext?.delete(folder)
            return
        }
        for inner in others where Self.isPath(inner.rootFolderPath, inOrAt: path) {
            forgetLibraryFolder(inner)
            modelContext?.delete(inner)
        }
        setLibraryFolders(libraryFolders)
    }

    /// Whether `path` is `folder` or inside it.
    nonisolated static func isPath(_ path: String, inOrAt folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The folder's path as the scanner reports the paths of the files in it (symbolic links resolved, so
    /// `/private/var/…`), or as given when it can't be read.
    nonisolated static func canonicalPath(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? url.standardizedFileURL.path
    }

    /// A bookmark of the folder, which finds it again once it's renamed or moved on its drive, or its drive is mounted
    /// under another name.
    nonisolated static func bookmark(of url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where a bookmark finds its folder now, without mounting a drive or share, or asking.
    nonisolated static func resolvedBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        _ = url.startAccessingSecurityScopedResource() // Phocasa isn't sandboxed: its access doesn't depend on this
        return url
    }

    nonisolated static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether `path` is in a Trash (`~/.Trash`, or a drive's `.Trashes`): a folder moved there was thrown away, and
    /// its bookmark follows it.
    nonisolated static func isInTrash(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    // MARK: - Removing a Folder

    /// Whether "Remove from Library…" can run now: never while a scan (or another removal) runs, nor while a delete is
    /// moving files to the Trash.
    var canRemoveLibraryFolders: Bool {
        !isScanning && photosBeingDeleted.isEmpty
    }

    /// How many stored photos (in the library, the bin, or missing) leave with the folder (`photoIDs(leavingWith:)`);
    /// nil if the store couldn't say.
    func photoCount(inFolder folder: PhotoLibrary) async -> Int? {
        try? await photoIDs(leavingWith: folder).count
    }

    /// The stored photos (in the library, the bin, or missing) whose files are in the folder, and in no other library
    /// folder (a store could hold two rows for one folder, or one inside another: those photos stay with the other),
    /// read off the main actor. The main context's unsaved changes aren't in it: save first.
    private func photoIDs(leavingWith folder: PhotoLibrary) async throws -> [UUID] {
        guard let container = modelContext?.container else { throw StoreReadError() }
        let root = folder.rootFolderPath
        let others = libraryFolders.filter { $0 !== folder }.map(\.rootFolderPath)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try ModelContext(container).fetch(Self.photos(inFolder: root))
                        .filter { photo in !others.contains { Self.isPath(photo.folderPath, inOrAt: $0) } }
                        .map(\.id)
                })
            }
        }
    }

    /// "Remove from Library…", confirmed: the folder's photos (in the library, the bin, or missing) leave the store and
    /// memory, then the folder does. Files are never touched. It runs on the scan queue, so no scan runs meanwhile, and
    /// scans asked for meanwhile wait; it isn't started while one runs (`canRemoveLibraryFolders`). Returns the removed
    /// photos' ids, once they're gone; nil when it can't start.
    @discardableResult
    func removeLibraryFolder(_ folder: PhotoLibrary) -> Task<[UUID], Never>? {
        guard canRemoveLibraryFolders, modelContext != nil, libraryFolders.contains(where: { $0 === folder }) else {
            return nil
        }
        let removal = Task { @MainActor in await self.performRemoval(of: folder) }
        let name = (folder.rootFolderPath as NSString).lastPathComponent
        startScanQueue(progress: "Removing “\(name)” from the library...") { _ = await removal.value }
        return removal
    }

    /// Rows deleted per main-actor turn: a main-context save costs about 7 ms, plus about 0.13 ms a row.
    private static let removalChunkSize = 256

    private func performRemoval(of folder: PhotoLibrary) async -> [UUID] {
        guard let context = modelContext else { return [] }
        let root = folder.rootFolderPath
        let name = (root as NSString).lastPathComponent
        // The rows are read through another context, which can't see unsaved changes (a photo just added, say).
        do {
            if context.hasChanges { try context.save() }
        } catch {
            return removalDidStop(.storeUnreadable(error.localizedDescription))
        }
        let ids: [UUID]
        do {
            ids = try await photoIDs(leavingWith: folder)
        } catch {
            return removalDidStop(.storeUnreadable(error.localizedDescription))
        }

        // Out of memory first, before the models go (as a permanent delete does), then out of the store, a chunk a turn.
        let removing = Set(ids)
        updateLibrary(adding: [], facts: [], removing: removing)
        missingPhotoIDs.subtract(removing)
        var start = 0
        var saveError: (any Error)?
        while start < ids.count {
            if start > 0 { await Task.yield() }
            let chunk = Array(ids[start..<min(start + Self.removalChunkSize, ids.count)])
            let rows = (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { chunk.contains($0.id) })))
                ?? []
            for row in rows { context.delete(row) }
            do { try context.save() } catch { saveError = saveError ?? error }
            start += chunk.count
        }
        // The folder last: if the removal is cut short, it's still listed, and removing it again finishes it.
        forgetLibraryFolder(folder)
        context.delete(folder)
        do { try context.save() } catch { saveError = saveError ?? error }

        if scanIssue?.unavailableFolder == root { scanIssue = nil }
        if let saveError {
            // The deletions wait in the context; the next save writes them.
            scanIssue = .storeUnsaved(saveError.localizedDescription)
        }
        scanIssue = scanIssue ?? firstFolderIssue()
        scanProgress = "Removed “\(name)” from the library"
        return ids
    }

    private func removalDidStop(_ issue: ScanIssue) -> [UUID] {
        scanIssue = issue
        scanProgress = issue.statusText
        return []
    }

    /// The stored photos whose files are in the folder at `root` (their folder is it, or inside it): the rows a scan of
    /// it checks (`StoredPhoto.isInside`).
    private nonisolated static func photos(inFolder root: String) -> FetchDescriptor<PhotoAsset> {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.folderPath == root || $0.folderPath.starts(with: prefix) })
    }
}
