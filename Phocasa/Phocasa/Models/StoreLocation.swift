import Foundation
import CoreData

/// Where the library's SwiftData store lives: `Application Support/Phocasa/Phocasa.store`.
///
/// Builds before this one kept it at SwiftData's default location, `Application Support/default.store`, which the app
/// shares with any other non-sandboxed app that keeps the default. `prepare(in:)` moves such a store into the Phocasa
/// folder once, before the container opens it: the SQLite file with its `-wal` and `-shm` files and its
/// external-data folder (`.default_SUPPORT`, which SwiftData names after the store file), renamed to match.
enum StoreLocation {
    static let folderName = "Phocasa"
    static let storeFileName = "Phocasa.store"
    static let legacyStoreFileName = "default.store"

    /// The store to open under `applicationSupport`, after moving a legacy store into the Phocasa folder.
    ///
    /// - A store in the Phocasa folder is used as it is; a `default.store` beside it is left alone.
    /// - A `default.store` that holds Phocasa's models moves there. The store file moves last, so a launch that
    ///   stopped part way finishes the move next time.
    /// - A `default.store` of another app's models stays where it is, and Phocasa starts its own store.
    /// - A `default.store` whose metadata can't be read, or that fails to move, is opened where it is, as before.
    static func prepare(in applicationSupport: URL, fileManager: FileManager = .default) -> URL {
        let folder = applicationSupport.appendingPathComponent(folderName, isDirectory: true)
        let store = folder.appendingPathComponent(storeFileName)
        let legacy = applicationSupport.appendingPathComponent(legacyStoreFileName)

        if fileManager.fileExists(atPath: store.path) { return store }

        if fileManager.fileExists(atPath: legacy.path) {
            switch holdsPhocasaModels(legacy) {
            case nil:
                return legacy
            case true?:
                do {
                    try move(legacy, to: store, fileManager: fileManager)
                    return store
                } catch {
                    return legacy
                }
            case false?:
                break
            }
        }

        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return store
    }

    /// Whether the store at `url` was written with Phocasa's models (its metadata names a `PhotoAsset` entity); nil
    /// when its metadata can't be read. Reads only the metadata: SwiftData has no API for that, so this is Core Data's.
    private static func holdsPhocasaModels(_ url: URL) -> Bool? {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        else { return nil }
        let entities = metadata[NSStoreModelVersionHashesKey] as? [String: Any] ?? [:]
        return entities["PhotoAsset"] != nil
    }

    /// The files of the store at `url`, whether or not they exist: its `-wal` and `-shm` files and its external-data
    /// folder (`.<name>_SUPPORT`), then the store file itself, last. The legacy move and `StoreBackup` both use it.
    static func files(of url: URL) -> [URL] {
        func sibling(_ suffix: String) -> URL {
            url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + suffix)
        }
        let supportFolder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)_SUPPORT", isDirectory: true)
        return [sibling("-wal"), sibling("-shm"), supportFolder, url]
    }

    /// The store's files at `url`, paired with their names for a store at `destination`: the companions first, the
    /// store file itself last.
    private static func files(of url: URL, at destination: URL) -> [(from: URL, to: URL)] {
        zip(files(of: url), files(of: destination)).map { (from: $0, to: $1) }
    }

    /// Moves the store at `url` to `destination`. A companion already at the destination without its source there
    /// is one an interrupted move left; one with its source there too is replaced. On failure, what this call moved
    /// goes back, and the error is rethrown.
    private static func move(_ url: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var moved: [(from: URL, to: URL)] = []
        do {
            for file in files(of: url, at: destination) where fileManager.fileExists(atPath: file.from.path) {
                if fileManager.fileExists(atPath: file.to.path) {
                    try fileManager.removeItem(at: file.to)
                }
                try fileManager.moveItem(at: file.from, to: file.to)
                moved.append(file)
            }
        } catch {
            for file in moved.reversed() {
                try? fileManager.moveItem(at: file.to, to: file.from)
            }
            throw error
        }
    }
}
