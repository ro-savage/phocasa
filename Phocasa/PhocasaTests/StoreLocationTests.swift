import XCTest
import SwiftData
@testable import Phocasa

/// Another app's model: a non-sandboxed app that keeps SwiftData's default location shares `default.store` in
/// Application Support with Phocasa's old builds.
@Model
final class ForeignNote {
    var text: String
    init(text: String) { self.text = text }
}

/// The library's store lives in `Application Support/Phocasa/Phocasa.store`; the first launch moves a store left at
/// SwiftData's default location (`Application Support/default.store`, where builds before this change kept it) into
/// that folder. The development library (`LibraryLocation`, `PHOCASA_DEVELOPMENT_LIBRARY=1`) keeps its own store in
/// `Application Support/Phocasa-Development/` and leaves both alone. Each test uses its own temp folder in place of
/// Application Support.
@MainActor
final class StoreLocationTests: XCTestCase {

    private var appSupport: URL!
    private var legacyURL: URL { appSupport.appendingPathComponent("default.store") }
    private var phocasaFolder: URL { appSupport.appendingPathComponent("Phocasa", isDirectory: true) }
    private var newURL: URL { phocasaFolder.appendingPathComponent("Phocasa.store") }

    /// Large enough that SwiftData keeps it outside the SQLite file (`.<store>_SUPPORT/_EXTERNAL_DATA`).
    private let externalBlob = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUp() async throws {
        appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaTests-StoreLocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dir = appSupport!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Stores

    private static let currentSchema = Schema([Phocasa.PhotoAsset.self, Phocasa.Tag.self, Phocasa.PhotoLibrary.self,
                                               Phocasa.EditPreset.self])

    /// The app's current models at `url`, opened the way `PhocasaApp` opens the real store.
    private func openCurrent(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: Self.currentSchema,
                           configurations: ModelConfiguration(schema: Self.currentSchema, url: url))
    }

    /// Writes a store of `schema` at `url`.
    private func write(at url: URL, schema: Schema, _ fill: (ModelContext) throws -> Void) throws {
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        try fill(context)
        try context.save()
    }

    /// A store in the format libraries had before task 31, as a user's `default.store` is: a binned photo and a
    /// rated photo whose edit data is stored externally.
    private func writeV1Store(at url: URL) throws {
        try write(at: url, schema: Schema(versionedSchema: PhocasaSchemaV1.self)) { context in
            let binned = PhocasaSchemaV1.PhotoAsset(fileName: "binned", jpgPath: "/p/binned.jpg", folderPath: "/p")
            binned.isDeleted = true
            let rated = PhocasaSchemaV1.PhotoAsset(fileName: "rated", jpgPath: "/p/rated.jpg", folderPath: "/p")
            rated.rating = 4
            rated.jpgEditParametersData = externalBlob
            context.insert(binned)
            context.insert(rated)
        }
    }

    /// A current-format store holding one photo named `fileName`.
    private func writeCurrentStore(at url: URL, fileName: String) throws {
        try write(at: url, schema: Self.currentSchema) { context in
            context.insert(Phocasa.PhotoAsset(fileName: fileName, folderPath: "/p"))
        }
    }

    private func foreignNotes(at url: URL) throws -> [String] {
        let schema = Schema([ForeignNote.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        return try ModelContext(container).fetch(FetchDescriptor<ForeignNote>()).map(\.text)
    }

    private func photoNames(at url: URL) throws -> [String] {
        let container = try openCurrent(at: url)
        return try ModelContext(container).fetch(FetchDescriptor<Phocasa.PhotoAsset>()).map(\.fileName).sorted()
    }

    // MARK: - Files

    /// Every file under `dir`, by path relative to it, with its bytes: empty for a store's SQLite files. SQLite
    /// rewrites those when it checkpoints, which SwiftData does when it likes, even after its container is gone (and
    /// through a moved file's handle), so their contents are checked by opening the store. Directories are implied
    /// by their files.
    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return files }
        let base = dir.standardizedFileURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            let isSQLite = [".store", ".store-wal", ".store-shm"].contains { path.hasSuffix($0) }
            files[path] = isSQLite ? Data() : try Data(contentsOf: url)
        }
        return files
    }

    /// The paths whose contents differ between two snapshots, or that only one has.
    private func differences(_ a: [String: Data], _ b: [String: Data]) -> [String] {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    /// The legacy store's files under their names after the move.
    private func renamedToNewStore(_ legacy: [String: Data]) -> [String: Data] {
        var moved: [String: Data] = [:]
        for (path, data) in legacy {
            let renamed = path
                .replacingOccurrences(of: ".default_SUPPORT/", with: ".Phocasa_SUPPORT/")
                .replacingOccurrences(of: "default.store", with: "Phocasa.store")
            moved["Phocasa/" + renamed] = data
        }
        return moved
    }

    // MARK: - Tests

    func testAFreshInstallKeepsItsStoreInThePhocasaFolder() throws {
        let url = StoreLocation.prepare(in: appSupport)

        XCTAssertEqual(url.standardizedFileURL, newURL.standardizedFileURL)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: phocasaFolder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the Phocasa folder exists for SwiftData to create the store in")

        try writeCurrentStore(at: url, fileName: "first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    /// What the move relies on: SwiftData names a store's external-data folder after the store file.
    func testExternalDataLivesInAFolderNamedAfterTheStore() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        let container = try openCurrent(at: newURL)
        let context = ModelContext(container)
        let photo = Phocasa.PhotoAsset(fileName: "edited", folderPath: "/p")
        photo.jpgEditParametersData = externalBlob
        context.insert(photo)
        try context.save()

        let files = try snapshot(phocasaFolder).keys
        XCTAssertTrue(files.contains { $0.hasPrefix(".Phocasa_SUPPORT/_EXTERNAL_DATA/") }, "\(files.sorted())")
    }

    func testALegacyStoreMovesIntoThePhocasaFolderWithAllItsFiles() throws {
        try writeV1Store(at: legacyURL)
        let legacyFiles = try snapshot(appSupport)
        XCTAssertTrue(legacyFiles.keys.contains("default.store"))
        XCTAssertTrue(legacyFiles.keys.contains { $0.hasPrefix(".default_SUPPORT/_EXTERNAL_DATA/") },
                      "precondition: the legacy store keeps data outside its SQLite file")

        let url = StoreLocation.prepare(in: appSupport)

        XCTAssertEqual(url.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(differences(try snapshot(appSupport), renamedToNewStore(legacyFiles)), [],
                       "every file of the store moved, the external data byte for byte, and nothing is left behind")
    }

    func testAMovedLegacyStoreOpensWithEveryValueKept() throws {
        try writeV1Store(at: legacyURL)

        let url = StoreLocation.prepare(in: appSupport)

        XCTAssertEqual(url.standardizedFileURL, newURL.standardizedFileURL)
        let container = try openCurrent(at: url)
        let photos = try ModelContext(container).fetch(FetchDescriptor<Phocasa.PhotoAsset>())
        XCTAssertEqual(photos.map(\.fileName).sorted(), ["binned", "rated"])
        let binned = try XCTUnwrap(photos.first { $0.fileName == "binned" })
        let rated = try XCTUnwrap(photos.first { $0.fileName == "rated" })
        XCTAssertTrue(binned.isInBin)
        XCTAssertEqual(rated.rating, 4)
        XCTAssertEqual(rated.jpgEditParametersData, externalBlob, "the externally stored data came along")
    }

    func testAStoreInThePhocasaFolderWinsAndTheLegacyStoreIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        try writeCurrentStore(at: newURL, fileName: "current")
        try writeCurrentStore(at: legacyURL, fileName: "legacy")
        let before = try snapshot(appSupport)

        let url = StoreLocation.prepare(in: appSupport)

        XCTAssertEqual(url.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(differences(try snapshot(appSupport), before), [], "nothing moved")
        XCTAssertEqual(try photoNames(at: url), ["current"])
        XCTAssertEqual(try photoNames(at: legacyURL), ["legacy"])
    }

    func testAnotherAppsDefaultStoreIsLeftAlone() throws {
        try write(at: legacyURL, schema: Schema([ForeignNote.self])) { context in
            context.insert(ForeignNote(text: "not a photo"))
        }
        let before = try snapshot(appSupport)

        let url = StoreLocation.prepare(in: appSupport)

        XCTAssertEqual(url.standardizedFileURL, newURL.standardizedFileURL, "Phocasa starts its own store")
        XCTAssertEqual(differences(try snapshot(appSupport), before), [], "the other app's store stays where it is")
        XCTAssertEqual(try foreignNotes(at: legacyURL), ["not a photo"])
    }

    /// A `default.store` whose metadata can't be read isn't moved: the app opens it where it is, as before.
    func testAnUnreadableLegacyStoreIsOpenedWhereItIs() throws {
        try Data("not a database".utf8).write(to: legacyURL)
        let before = try snapshot(appSupport)

        let url = StoreLocation.prepare(in: appSupport)

        XCTAssertEqual(url.standardizedFileURL, legacyURL.standardizedFileURL)
        XCTAssertEqual(differences(try snapshot(appSupport), before), [])
    }

    /// The store file moves last. A launch that stopped after moving its companions finishes the move.
    func testAnInterruptedMoveIsFinishedOnTheNextLaunch() throws {
        try writeV1Store(at: legacyURL)
        let legacyFiles = try snapshot(appSupport)
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: appSupport.appendingPathComponent(".default_SUPPORT"),
                                         to: phocasaFolder.appendingPathComponent(".Phocasa_SUPPORT"))

        let url = StoreLocation.prepare(in: appSupport)

        XCTAssertEqual(url.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(differences(try snapshot(appSupport), renamedToNewStore(legacyFiles)), [])
        let container = try openCurrent(at: url)
        let rated = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Phocasa.PhotoAsset>())
            .first { $0.fileName == "rated" })
        XCTAssertEqual(rated.jpgEditParametersData, externalBlob)
    }

    // MARK: - Development library

    private var developmentFolder: URL { appSupport.appendingPathComponent("Phocasa-Development", isDirectory: true) }
    private var developmentURL: URL { developmentFolder.appendingPathComponent("Phocasa.store") }

    /// A Debug launch with `PHOCASA_DEVELOPMENT_LIBRARY=1`, with the temp folder as Application Support.
    private func developmentLocation() -> LibraryLocation {
        LibraryLocation.resolve(environment: ["PHOCASA_DEVELOPMENT_LIBRARY": "1"], isDebugBuild: true,
                                applicationSupport: appSupport,
                                caches: appSupport.appendingPathComponent("Caches", isDirectory: true))
    }

    private func isInDevelopmentFolder(_ path: String) -> Bool {
        let folder = developmentFolder.standardizedFileURL.path
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return path == folder || path.hasPrefix(folder + "/")
    }

    func testTheDevelopmentLibraryKeepsItsStoreInItsOwnFolder() throws {
        let url = try XCTUnwrap(developmentLocation().prepareStore())

        XCTAssertEqual(url.standardizedFileURL, developmentURL.standardizedFileURL)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: developmentFolder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the development folder exists for SwiftData to create the store in")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: appSupport.path), ["Phocasa-Development"],
                       "nothing else is made")

        try writeCurrentStore(at: url, fileName: "development")
        XCTAssertEqual(try photoNames(at: developmentURL), ["development"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: phocasaFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    /// A real library and a legacy store, both of Phocasa's models. The development library doesn't look at either:
    /// every file stays where it was, and each store still holds its own photos.
    func testTheDevelopmentLibraryLeavesTheRealAndLegacyStoresAlone() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        try writeCurrentStore(at: newURL, fileName: "real")
        try writeV1Store(at: legacyURL)
        let before = try snapshot(appSupport)
        XCTAssertTrue(before.keys.contains("Phocasa/Phocasa.store"))
        XCTAssertTrue(before.keys.contains("default.store"))
        XCTAssertTrue(before.keys.contains { $0.hasPrefix(".default_SUPPORT/_EXTERNAL_DATA/") })
        let files = RecordingFileManager()

        let url = try XCTUnwrap(developmentLocation().prepareStore(fileManager: files))
        try writeCurrentStore(at: url, fileName: "development")

        XCTAssertEqual(url.standardizedFileURL, developmentURL.standardizedFileURL)
        XCTAssertEqual(files.paths.filter { !isInDevelopmentFolder($0) }, [], "it looked at nothing outside its folder")
        let after = try snapshot(appSupport).filter { !$0.key.hasPrefix("Phocasa-Development/") }
        XCTAssertEqual(differences(after, before), [], "every file of both stores is still there, and nothing moved")
        // Opened only now, after the check (opening the V1 store migrates it).
        XCTAssertEqual(try photoNames(at: developmentURL), ["development"])
        XCTAssertEqual(try photoNames(at: newURL), ["real"])
        XCTAssertEqual(try photoNames(at: legacyURL), ["binned", "rated"])
    }

    /// With only a legacy store, a normal launch moves it into the Phocasa folder. The development library doesn't.
    func testTheDevelopmentLibraryRunsNoLegacyMove() throws {
        try writeV1Store(at: legacyURL)
        let before = try snapshot(appSupport)

        let url = try XCTUnwrap(developmentLocation().prepareStore())

        XCTAssertEqual(url.standardizedFileURL, developmentURL.standardizedFileURL)
        XCTAssertEqual(differences(try snapshot(appSupport), before), [], "the legacy store stays where it is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: phocasaFolder.path), "no Phocasa folder is made")
    }

    /// What the in-memory test host can't do: a library written in one launch is there in the next.
    func testTheDevelopmentLibrarySurvivesARelaunch() throws {
        do {
            let url = try XCTUnwrap(developmentLocation().prepareStore())
            let container = try openCurrent(at: url)
            let context = ModelContext(container)
            let binned = Phocasa.PhotoAsset(fileName: "binned", folderPath: "/p")
            binned.isInBin = true
            let rated = Phocasa.PhotoAsset(fileName: "rated", folderPath: "/p")
            rated.rating = 5
            context.insert(binned)
            context.insert(rated)
            try context.save()
        }   // quit: the container is released

        let url = try XCTUnwrap(developmentLocation().prepareStore())   // the next launch
        XCTAssertEqual(url.standardizedFileURL, developmentURL.standardizedFileURL)
        let container = try openCurrent(at: url)
        let photos = try ModelContext(container).fetch(FetchDescriptor<Phocasa.PhotoAsset>())
        XCTAssertEqual(photos.map(\.fileName).sorted(), ["binned", "rated"])
        XCTAssertEqual(photos.first { $0.fileName == "binned" }?.isInBin, true)
        XCTAssertEqual(photos.first { $0.fileName == "rated" }?.rating, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phocasaFolder.path))
    }
}

/// A file manager that records every path it's asked about or asked to change.
private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var paths: [String] { lock.withLock { recorded } }

    private func record(_ paths: String...) { lock.withLock { recorded += paths } }

    override func fileExists(atPath path: String) -> Bool {
        record(path)
        return super.fileExists(atPath: path)
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        record(path)
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        record(path)
        return try super.contentsOfDirectory(atPath: path)
    }

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        record(url.path)
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        record(srcURL.path, dstURL.path)
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at url: URL) throws {
        record(url.path)
        try super.removeItem(at: url)
    }
}
