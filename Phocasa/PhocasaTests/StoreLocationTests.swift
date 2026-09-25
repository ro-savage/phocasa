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
/// that folder. Each test uses its own temp folder in place of Application Support.
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
}
