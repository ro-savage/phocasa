import Foundation

/// Where a launch keeps its library and its thumbnail disk cache. `current` decides both from one environment read,
/// so `PhocasaApp`'s store and `ImageLoader.shared`'s cache can't disagree.
///
/// - **A normal launch** opens the user's library, `Application Support/Phocasa/Phocasa.store` (`StoreLocation`, which
///   moves a store left at SwiftData's default location there first), and caches thumbnails in
///   `Caches/<bundle id>/Thumbnails/v1`.
/// - **The XCTest host** (`XCTestConfigurationFilePath` set) uses a throwaway in-memory store, so test runs never open,
///   migrate or rescan the user's library, and no disk cache unless `PHOCASA_THUMBNAIL_CACHE_DIR` names a folder.
struct LibraryLocation: Equatable, Sendable {
    enum Store: Equatable, Sendable {
        /// A throwaway in-memory store.
        case inMemory
        /// The user's library in this Application Support folder; `StoreLocation.prepare(in:)` picks the file.
        case user(applicationSupport: URL)
    }

    let store: Store
    /// Where `ImageLoader.shared` keeps its thumbnails; nil for no disk cache.
    let thumbnailCacheDirectory: URL?

    static let testConfigurationKey = "XCTestConfigurationFilePath"
    static let thumbnailCacheDirectoryKey = "PHOCASA_THUMBNAIL_CACHE_DIR"

    /// This launch's location, decided once.
    static let current = resolve(environment: ProcessInfo.processInfo.environment,
                                 applicationSupport: .applicationSupportDirectory,
                                 caches: ThumbnailDiskCache.userCachesDirectory)

    /// The location for a launch with `environment`, given the Application Support and Caches folders. Pure: it
    /// touches no file.
    static func resolve(environment: [String: String], applicationSupport: URL, caches: URL) -> LibraryLocation {
        if environment[testConfigurationKey] != nil {
            return LibraryLocation(store: .inMemory, thumbnailCacheDirectory: configuredCacheDirectory(environment))
        }
        return LibraryLocation(store: .user(applicationSupport: applicationSupport),
                               thumbnailCacheDirectory: ThumbnailDiskCache.defaultDirectory(in: caches))
    }

    /// The store file to open, or nil for an in-memory store. For the user's library this is
    /// `StoreLocation.prepare(in:)`, which may move a legacy store first.
    func prepareStore(fileManager: FileManager = .default) -> URL? {
        switch store {
        case .inMemory:
            return nil
        case .user(let applicationSupport):
            return StoreLocation.prepare(in: applicationSupport, fileManager: fileManager)
        }
    }

    private static func configuredCacheDirectory(_ environment: [String: String]) -> URL? {
        guard let configured = environment[thumbnailCacheDirectoryKey], !configured.isEmpty else { return nil }
        return URL(fileURLWithPath: configured, isDirectory: true)
    }
}
