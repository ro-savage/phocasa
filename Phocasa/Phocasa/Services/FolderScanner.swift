import Foundation
import os
import UniformTypeIdentifiers

struct DiscoveredPhoto: Sendable {
    let fileName: String
    let jpgPath: String?
    let rawPath: String?
    let folderPath: String
    let fileSize: Int64
    let creationDate: Date?
    /// `"\(folderPath)/\(fileName)"`: the identity a scan matches stored photos by.
    let key: String
    /// The file's rating and keywords. Filled only for photos whose key the library doesn't know yet
    /// (see `FolderScanner.scan(folderURL:knownKeys:)`); nil otherwise.
    var metadata: MetadataService.PhotoMetadata?

    init(fileName: String, jpgPath: String?, rawPath: String?, folderPath: String, fileSize: Int64,
         creationDate: Date?, metadata: MetadataService.PhotoMetadata? = nil) {
        self.fileName = fileName
        self.jpgPath = jpgPath
        self.rawPath = rawPath
        self.folderPath = folderPath
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.key = Self.key(folderPath: folderPath, fileName: fileName)
        self.metadata = metadata
    }

    /// The matching key for a photo stored with this folder path and file name (stem).
    static func key(folderPath: String, fileName: String) -> String {
        "\(folderPath)/\(fileName)"
    }
}

final class FolderScanner: Sendable {
    static let standardExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif"
    ]

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2",
        "pef", "srw", "3fr", "iiq", "rwl", "raw", "mrw", "dcr"
    ]

    static let allExtensions: Set<String> = standardExtensions.union(rawExtensions)

    /// Folders, by extension, that are another app's library. Their photos are that app's copies: a rating would be
    /// written into them and a delete would trash them out of the library. Each is a package (skipped by
    /// `.skipsPackageDescendants`) only on a Mac with that app installed, so they're also skipped by name here.
    static let skippedFolderExtensions: Set<String> = [
        "photoslibrary", // Apple Photos: originals/ and resources/derivatives/ (JPEG renders of every photo)
        "photolibrary",  // iPhoto: Masters/, Previews/, Thumbnails/
        "aplibrary",     // Aperture: Masters/, Previews/, Thumbnails/
        "lrdata",        // Lightroom Classic "… Previews.lrdata" and "… Smart Previews.lrdata" (DNGs, read as RAWs)
        "lrcat-data",    // Lightroom Classic's catalog data folder
        "lrlibrary",     // Lightroom's (cloud) desktop library, which keeps the originals it syncs
        "cocatalog",     // Capture One catalog: managed originals, previews and thumbnails
    ]

    /// Folders, by lowercased name, that aren't the owner's photos: thumbnail caches, recycle bins, snapshots and
    /// backups (copies of every photo, which would all be imported a second time).
    static let skippedFolderNames: Set<String> = [
        "photo booth library",        // Photo Booth's library (a package without an extension)
        "@eadir",                     // Synology: a thumbnail folder per photo, in every folder
        "#recycle",                   // Synology recycle bin
        "#snapshot",                  // Synology snapshots of the share
        "@recycle",                   // QNAP recycle bin
        "@recently-snapshot",         // QNAP snapshots of the share
        "$recycle.bin",               // Windows recycle bin, on drives used with a PC
        "system volume information",  // Windows system folder
        "backups.backupdb",           // Time Machine backups on an HFS+ drive: copies of whole disks
    ]
    // Dot folders (`.Trashes`, `.Trash`, `.Spotlight-V100`, a QNAP `.@__thumb`, Android's `.thumbnails`) are hidden, so
    // `.skipsHiddenFiles` skips them already.

    /// Whether the scan skips a folder with this name (see `skippedFolderExtensions`, `skippedFolderNames`).
    static func skipsFolder(named name: String) -> Bool {
        let lowercased = name.lowercased()
        return skippedFolderNames.contains(lowercased)
            || skippedFolderExtensions.contains((lowercased as NSString).pathExtension)
    }

    /// Whether `path` is inside a folder the scan skips, below `root` (the folder the owner chose, which is scanned
    /// whatever its name). Only the names are looked at, not the disk.
    static func isInsideSkippedFolder(_ path: String, below root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let folders = path.dropFirst(prefix.count).split(separator: "/").dropLast()
        return folders.contains { skipsFolder(named: String($0)) }
    }

    /// Files per unit of work when reading metadata concurrently.
    private static let metadataChunkSize = 64

    /// Finds the photos under `folderURL` (JPG+RAW with the same stem are one photo), off the main thread.
    /// Reads no metadata. The order is unspecified: the view model sorts on fetch.
    ///
    /// Hidden files and folders, the insides of packages, and the folders `skipsFolder(named:)` names are skipped;
    /// `folderURL` itself is scanned whatever it is.
    func scan(folderURL: URL) async -> [DiscoveredPhoto] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = self.scanSync(folderURL: folderURL)
                continuation.resume(returning: results)
            }
        }
    }

    /// Enumerates the folder and reads metadata for new files, concurrently and off the main thread.
    /// Photos whose `key` is in `knownKeys` keep `metadata == nil`.
    func scan(folderURL: URL, knownKeys: Set<String>) async -> [DiscoveredPhoto] {
        let discovered = await scan(folderURL: folderURL)
        return await readMetadata(for: discovered, skipping: knownKeys)
    }

    /// Fills `metadata` for every photo whose key isn't in `knownKeys`, reading the JPG if there is one and
    /// the RAW otherwise. Runs off the main thread, about 64 files per work item across all cores.
    /// `progress(done, total)` is called from worker threads after each work item.
    func readMetadata(
        for photos: [DiscoveredPhoto],
        skipping knownKeys: Set<String> = [],
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> [DiscoveredPhoto] {
        let targets = photos.indices.filter { !knownKeys.contains(photos[$0].key) }
        guard !targets.isEmpty else { return photos }
        let paths = targets.map { photos[$0].jpgPath ?? photos[$0].rawPath ?? "" }
        let metadata = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.readMetadataConcurrently(paths: paths, progress: progress))
            }
        }
        var result = photos
        for (position, index) in targets.enumerated() {
            result[index].metadata = metadata[position]
        }
        return result
    }

    private struct MetadataChunks: Sendable {
        var parts: [[MetadataService.PhotoMetadata?]]
        var done = 0
    }

    private static func readMetadataConcurrently(
        paths: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) -> [MetadataService.PhotoMetadata?] {
        let chunkSize = metadataChunkSize
        let chunkCount = (paths.count + chunkSize - 1) / chunkSize
        // Each work item reads its own range and hands it in once, so the lock is taken once per 64 files.
        let chunks = OSAllocatedUnfairLock(initialState: MetadataChunks(parts: Array(repeating: [], count: chunkCount)))
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let range = (chunk * chunkSize)..<min(paths.count, (chunk + 1) * chunkSize)
            let part: [MetadataService.PhotoMetadata?] = range.map { i in
                paths[i].isEmpty ? nil : MetadataService.shared.readMetadata(from: paths[i])
            }
            let finished = chunks.withLock { state in
                state.parts[chunk] = part
                state.done += range.count
                return state.done
            }
            progress?(finished, paths.count)
        }
        return chunks.withLock { $0.parts }.flatMap { $0 }
    }

    private func scanSync(folderURL: URL) -> [DiscoveredPhoto] {
        var filesByFolder: [String: [String: [(url: URL, isRaw: Bool, fileSize: Int64, creationDate: Date?)]]] = [:]

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.allExtensions.contains(ext) else {
                // Only a name test: `skipDescendants()` on a file does nothing.
                if Self.skipsFolder(named: fileURL.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]),
                  resourceValues.isRegularFile == true else { continue }

            let stem = fileURL.deletingPathExtension().lastPathComponent
            let folder = fileURL.deletingLastPathComponent().path
            let isRaw = Self.rawExtensions.contains(ext)
            let fileSize = Int64(resourceValues.fileSize ?? 0)

            filesByFolder[folder, default: [:]][stem, default: []].append(
                (url: fileURL, isRaw: isRaw, fileSize: fileSize, creationDate: resourceValues.creationDate)
            )
        }

        var results: [DiscoveredPhoto] = []

        for (folder, stems) in filesByFolder {
            for (stem, files) in stems {
                var jpgPath: String?
                var rawPath: String?
                var totalSize: Int64 = 0
                var creationDate: Date?

                for file in files {
                    totalSize += file.fileSize

                    if creationDate == nil {
                        creationDate = file.creationDate
                    }

                    if file.isRaw {
                        rawPath = file.url.path
                    } else {
                        if jpgPath == nil {
                            jpgPath = file.url.path
                        }
                    }
                }

                results.append(DiscoveredPhoto(
                    fileName: stem,
                    jpgPath: jpgPath,
                    rawPath: rawPath,
                    folderPath: folder,
                    fileSize: totalSize,
                    creationDate: creationDate
                ))
            }
        }

        return results
    }
}
