import XCTest
@testable import Phocasa

/// Which library and thumbnail cache a launch uses (`LibraryLocation.resolve`). `resolve` is pure, so the folders
/// given here are never touched; `StoreLocationTests` checks the development library on disk, in a temp folder.
final class LibraryLocationTests: XCTestCase {

    private let appSupport = URL(fileURLWithPath: "/private/tmp/phocasa-test-app-support", isDirectory: true)
    private let caches = URL(fileURLWithPath: "/private/tmp/phocasa-test-caches", isDirectory: true)
    private var developmentFolder: URL { appSupport.appendingPathComponent("Phocasa-Development", isDirectory: true) }
    private let override = "/private/tmp/phocasa-thumbs-test"

    private func resolve(_ environment: [String: String], debug: Bool = true) -> LibraryLocation {
        LibraryLocation.resolve(environment: environment, isDebugBuild: debug, applicationSupport: appSupport,
                                caches: caches)
    }

    private var userLibrary: LibraryLocation {
        LibraryLocation(store: .user(applicationSupport: appSupport),
                        thumbnailCacheDirectory: ThumbnailDiskCache.defaultDirectory(in: caches))
    }

    // MARK: - Development library

    func testTheDevelopmentFlagInADebugBuildOpensTheDevelopmentLibrary() {
        let location = resolve(["PHOCASA_DEVELOPMENT_LIBRARY": "1"])

        XCTAssertEqual(location.store, .development(developmentFolder.appendingPathComponent("Phocasa.store")))
        XCTAssertEqual(location.thumbnailCacheDirectory?.standardizedFileURL.path,
                       developmentFolder.appendingPathComponent("Thumbnails/v1").standardizedFileURL.path,
                       "its thumbnails live in the development folder too")
    }

    func testTheDevelopmentCacheIsNeverInTheCachesFolder() throws {
        let cache = try XCTUnwrap(resolve(["PHOCASA_DEVELOPMENT_LIBRARY": "1"]).thumbnailCacheDirectory)
        let path = cache.standardizedFileURL.path

        XCTAssertFalse(path.hasPrefix(caches.standardizedFileURL.path + "/"), path)
        XCTAssertFalse(path.contains("com.phocasa.app"), path)
        XCTAssertNotEqual(cache, ThumbnailDiskCache.defaultDirectory(in: caches))
    }

    func testTheCacheOverrideAppliesToTheDevelopmentLibrary() {
        let location = resolve(["PHOCASA_DEVELOPMENT_LIBRARY": "1", "PHOCASA_THUMBNAIL_CACHE_DIR": override])

        XCTAssertEqual(location.thumbnailCacheDirectory?.path, override)
        XCTAssertEqual(location.store, .development(developmentFolder.appendingPathComponent("Phocasa.store")),
                       "the override moves only the cache")
    }

    func testAReleaseBuildIgnoresTheDevelopmentFlag() {
        XCTAssertEqual(resolve(["PHOCASA_DEVELOPMENT_LIBRARY": "1"], debug: false), userLibrary)
        XCTAssertEqual(
            resolve(["PHOCASA_DEVELOPMENT_LIBRARY": "1", "PHOCASA_THUMBNAIL_CACHE_DIR": override], debug: false),
            userLibrary
        )
    }

    /// How the user runs the app: a Debug launch without the flag opens the real library, as before.
    func testADebugLaunchWithoutTheFlagOpensTheUsersLibrary() {
        XCTAssertEqual(resolve([:]), userLibrary)
        XCTAssertEqual(resolve(["PHOCASA_DEVELOPMENT_LIBRARY": "0"]), userLibrary)
        XCTAssertEqual(resolve(["PHOCASA_DEVELOPMENT_LIBRARY": ""]), userLibrary)
        XCTAssertEqual(resolve(["PHOCASA_DEVELOPMENT_LIBRARY": "true"]), userLibrary, "only 1 turns it on")
    }

    // MARK: - Test host

    func testTheTestHostStaysInMemory() {
        let inMemory = LibraryLocation(store: .inMemory, thumbnailCacheDirectory: nil)
        XCTAssertEqual(resolve(["XCTestConfigurationFilePath": "/x"]), inMemory)
        XCTAssertEqual(resolve(["XCTestConfigurationFilePath": "/dev/null/in-memory"]), inMemory)
        XCTAssertEqual(resolve(["XCTestConfigurationFilePath": "/x"], debug: false), inMemory)
    }

    /// The Test action shares the Run action's environment (the scheme's `shouldUseLaunchSchemeArgsEnv`), so a flag
    /// set for Run would reach the unit-test host. The test host stays in memory regardless.
    func testTheTestHostWinsOverTheDevelopmentFlag() {
        XCTAssertEqual(resolve(["XCTestConfigurationFilePath": "/x", "PHOCASA_DEVELOPMENT_LIBRARY": "1"]),
                       LibraryLocation(store: .inMemory, thumbnailCacheDirectory: nil))
        XCTAssertEqual(
            resolve(["XCTestConfigurationFilePath": "/x", "PHOCASA_DEVELOPMENT_LIBRARY": "1",
                     "PHOCASA_THUMBNAIL_CACHE_DIR": override]),
            LibraryLocation(store: .inMemory,
                            thumbnailCacheDirectory: URL(fileURLWithPath: override, isDirectory: true))
        )
    }

    func testThisTestRunUsesAnInMemoryStore() {
        XCTAssertEqual(LibraryLocation.current.store, .inMemory)
        XCTAssertEqual(LibraryLocation.current.thumbnailCacheDirectory, ImageLoader.shared.diskCache?.directory,
                       "the store and the cache come from the same decision")
    }

    /// `resolve`'s Debug flag defaults to the build's: this test target builds Debug.
    func testTheDebugFlagDefaultsToTheBuildConfiguration() {
        XCTAssertTrue(LibraryLocation.isDebugBuild)
        XCTAssertEqual(
            LibraryLocation.resolve(environment: ["PHOCASA_DEVELOPMENT_LIBRARY": "1"], applicationSupport: appSupport,
                                    caches: caches).store,
            .development(developmentFolder.appendingPathComponent("Phocasa.store"))
        )
    }
}
