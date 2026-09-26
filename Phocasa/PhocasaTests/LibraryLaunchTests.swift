import XCTest
import SwiftData
@testable import Phocasa

/// Phocasa's models with a change no migration can infer (a photo's name stored as a number): a store written with
/// them can't be opened by the live models.
enum IncompatibleSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(99, 0, 0)
    static var models: [any PersistentModel.Type] { [PhotoAsset.self] }

    @Model
    final class PhotoAsset {
        var fileName: Int
        init(fileName: Int) { self.fileName = fileName }
    }
}

/// A launch's steps before the window shows the library (`LibraryLaunch.open`): take the library's lock, move a
/// legacy store (`StoreLocation`), back the store up (`StoreBackup`), open it. A second launch on a locked library
/// opens nothing; a store that doesn't open is left exactly as it was and the launch says so instead of crashing.
/// Each test uses its own temp folder in place of Application Support.
@MainActor
final class LibraryLaunchTests: XCTestCase {

    private var appSupport: URL!
    private var phocasaFolder: URL { appSupport.appendingPathComponent("Phocasa", isDirectory: true) }
    private var storeURL: URL { phocasaFolder.appendingPathComponent("Phocasa.store") }
    private var legacyURL: URL { appSupport.appendingPathComponent("default.store") }
    private var backups: URL { phocasaFolder.appendingPathComponent("Backups", isDirectory: true) }
    private var developmentFolder: URL { appSupport.appendingPathComponent("Phocasa-Development", isDirectory: true) }

    override func setUp() async throws {
        appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaTests-LibraryLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dir = appSupport!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Helpers

    private var userLibrary: LibraryLocation {
        LibraryLocation(store: .user(applicationSupport: appSupport), thumbnailCacheDirectory: nil)
    }

    private var developmentLibrary: LibraryLocation {
        LibraryLocation.resolve(environment: ["PHOCASA_DEVELOPMENT_LIBRARY": "1"], isDebugBuild: true,
                                applicationSupport: appSupport,
                                caches: appSupport.appendingPathComponent("Caches", isDirectory: true))
    }

    private func day(_ day: Int, hour: Int = 9) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    private static let schema = Schema([Phocasa.PhotoAsset.self, Phocasa.Tag.self, Phocasa.PhotoLibrary.self,
                                        Phocasa.EditPreset.self])

    /// A store of the app's models at `url` holding photos named `names`; its container is released on return.
    private func writeStore(at url: URL, names: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let container = try ModelContainer(for: Self.schema,
                                           configurations: ModelConfiguration(schema: Self.schema, url: url))
        let context = ModelContext(container)
        for name in names { context.insert(Phocasa.PhotoAsset(fileName: name, folderPath: "/p")) }
        try context.save()
    }

    private func photoNames(at url: URL) throws -> [String] {
        let container = try ModelContainer(for: Self.schema,
                                           configurations: ModelConfiguration(schema: Self.schema, url: url))
        return try ModelContext(container).fetch(FetchDescriptor<Phocasa.PhotoAsset>()).map(\.fileName).sorted()
    }

    private func photoNames(in launch: LibraryLaunch) throws -> [String] {
        guard case .opened(let container) = launch.outcome else { throw Unexpected(launch) }
        return try ModelContext(container).fetch(FetchDescriptor<Phocasa.PhotoAsset>()).map(\.fileName).sorted()
    }

    private func problem(of launch: LibraryLaunch) throws -> LibraryProblem {
        guard case .unavailable(let problem) = launch.outcome else { throw Unexpected(launch) }
        return problem
    }

    private struct Unexpected: Error, CustomStringConvertible {
        let description: String
        init(_ launch: LibraryLaunch) { description = "unexpected launch: \(launch.outcome)" }
    }

    /// Every file under `dir` with its bytes, by path relative to it.
    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return files }
        let base = dir.standardizedFileURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            files[String(url.standardizedFileURL.path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return files
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: - The lock

    func testAFreshInstallOpensAnEmptyLibraryAndHoldsItsLock() throws {
        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        XCTAssertEqual(try photoNames(in: launch), [])
        XCTAssertNotNil(launch.lock)
        XCTAssertEqual(launch.lock?.url.standardizedFileURL,
                       phocasaFolder.appendingPathComponent("Phocasa.lock").standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path), "no store yet, so no backup")
    }

    /// A Debug build run from Xcode beside the installed app: the second launch finds the library locked and opens,
    /// moves and backs up nothing.
    func testASecondLaunchOnTheSameLibraryOpensNothing() throws {
        try writeStore(at: storeURL, names: ["a"])
        let first = LibraryLaunch.open(userLibrary, now: day(26))
        XCTAssertEqual(try photoNames(in: first), ["a"])
        let backupsAfterFirst = names(in: backups)

        let second = LibraryLaunch.open(userLibrary, now: day(27))

        let problem = try problem(of: second)
        XCTAssertEqual(problem.reason, .alreadyOpen(.current), "it says who has the library open")
        XCTAssertNil(second.lock)
        XCTAssertEqual(names(in: backups), backupsAfterFirst, "no backup: the other process may be writing")
        withExtendedLifetime(first) {}
    }

    /// The lock comes before the legacy move, so two launches can't both move a `default.store`.
    func testALaunchLockedOutLeavesALegacyStoreWhereItIs() throws {
        try writeStore(at: legacyURL, names: ["legacy"])
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        guard case .acquired(let other) = LibraryLock.acquire(in: phocasaFolder) else { return XCTFail("no lock") }
        defer { other.release() }

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        XCTAssertEqual(try problem(of: launch).reason, .alreadyOpen(.current))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path), "not moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testTheLibraryOpensAgainOnceTheFirstLaunchIsGone() throws {
        var first: LibraryLaunch? = LibraryLaunch.open(userLibrary, now: day(26))
        XCTAssertNotNil(first?.lock)
        first = nil   // the process quits

        let second = LibraryLaunch.open(userLibrary, now: day(26))
        XCTAssertEqual(try photoNames(in: second), [])
    }

    // MARK: - Backups

    func testALaunchBacksUpTheStoreBeforeOpeningIt() throws {
        try writeStore(at: storeURL, names: ["a", "b"])

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        XCTAssertEqual(try photoNames(in: launch), ["a", "b"])
        guard case .created(let backup)? = launch.backup else { return XCTFail("\(String(describing: launch.backup))") }
        XCTAssertEqual(backup.deletingLastPathComponent().standardizedFileURL, backups.standardizedFileURL)
        XCTAssertEqual(try photoNames(at: backup.appendingPathComponent("Phocasa.store")), ["a", "b"])
    }

    /// The owner's first launch of this build moves their `default.store` into the Phocasa folder; the backup is of
    /// the moved store.
    func testTheBackupComesAfterTheLegacyMove() throws {
        try writeStore(at: legacyURL, names: ["legacy"])

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        XCTAssertEqual(try photoNames(in: launch), ["legacy"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path), "moved")
        guard case .created(let backup)? = launch.backup else { return XCTFail("\(String(describing: launch.backup))") }
        XCTAssertEqual(try photoNames(at: backup.appendingPathComponent("Phocasa.store")), ["legacy"])
    }

    func testAnotherAppsDefaultStoreIsNeverBackedUpOrTouched() throws {
        let foreign = Schema([ForeignNote.self])
        do {
            let container = try ModelContainer(for: foreign, configurations: ModelConfiguration(schema: foreign,
                                                                                                url: legacyURL))
            let context = ModelContext(container)
            context.insert(ForeignNote(text: "not a photo"))
            try context.save()
        }
        let otherFiles = names(in: appSupport)

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        XCTAssertEqual(try photoNames(in: launch), [], "Phocasa starts its own library")
        XCTAssertEqual(names(in: appSupport).filter { $0 != "Phocasa" }, otherFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path), "nothing of the other app's is copied")
    }

    /// A `default.store` whose metadata can't be read may be another app's: it's opened where it is, as before, but
    /// never backed up. This one is garbage, so it doesn't open either, and stays as it was.
    func testAnUnreadableLegacyStoreIsNotBackedUpAndLeftAsItWas() throws {
        try Data("not a database".utf8).write(to: legacyURL)

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        let problem = try problem(of: launch)
        guard case .cannotOpen = problem.reason else { return XCTFail("\(problem.reason)") }
        XCTAssertEqual(problem.store?.standardizedFileURL, legacyURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: legacyURL), Data("not a database".utf8))
        XCTAssertEqual(names(in: appSupport), ["Phocasa", "default.store"], "nothing renamed or added beside it")
        XCTAssertNil(launch.backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }

    func testTheDevelopmentLibraryLocksAndBacksUpOnlyItsOwnFolder() throws {
        try writeStore(at: storeURL, names: ["real"])
        try writeStore(at: developmentFolder.appendingPathComponent("Phocasa.store"), names: ["development"])
        let realLibrary = names(in: phocasaFolder)

        let launch = LibraryLaunch.open(developmentLibrary, now: day(26))

        XCTAssertEqual(try photoNames(in: launch), ["development"])
        XCTAssertEqual(launch.lock?.url.deletingLastPathComponent().standardizedFileURL,
                       developmentFolder.standardizedFileURL)
        guard case .created(let backup)? = launch.backup else { return XCTFail("\(String(describing: launch.backup))") }
        XCTAssertEqual(backup.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       developmentFolder.standardizedFileURL)
        XCTAssertEqual(names(in: phocasaFolder), realLibrary, "no lock, no backup in the real library's folder")
    }

    func testTheInMemoryLibraryTakesNoLockAndWritesNothing() throws {
        let launch = LibraryLaunch.open(LibraryLocation(store: .inMemory, thumbnailCacheDirectory: nil), now: day(26))

        XCTAssertEqual(try photoNames(in: launch), [])
        XCTAssertNil(launch.lock)
        XCTAssertNil(launch.backup)
        XCTAssertEqual(names(in: appSupport), [])
    }

    // MARK: - A store that doesn't open

    /// A damaged store used to crash every launch (`fatalError`). Now the launch reports it, and neither SwiftData
    /// nor Phocasa renames, removes or rewrites any of its files.
    func testADamagedStoreFailsToOpenAndIsLeftAsItWas() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        let damaged: [String: Data] = [
            "Phocasa.store": Data("not a database".utf8),
            "Phocasa.store-wal": Data("not a log".utf8),
            "Phocasa.store-shm": Data("not shared memory".utf8),
        ]
        for (name, data) in damaged { try data.write(to: phocasaFolder.appendingPathComponent(name)) }

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        let problem = try problem(of: launch)
        guard case .cannotOpen(let reason) = problem.reason else { return XCTFail("\(problem.reason)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(problem.store?.standardizedFileURL, storeURL.standardizedFileURL)
        XCTAssertEqual(try snapshot(phocasaFolder).filter { !$0.key.contains("/") && $0.key.hasPrefix("Phocasa.store") },
                       damaged, "every file byte for byte")
        XCTAssertEqual(names(in: phocasaFolder), ["Backups", "Phocasa.lock", "Phocasa.store", "Phocasa.store-shm",
                                                  "Phocasa.store-wal"], "nothing renamed, removed or added")
        XCTAssertEqual(problem.backups.count, 1, "the copy taken before the open is kept")
    }

    /// What SwiftData itself does with a store that isn't a database, given it straight (no `mayBeDatabase` check):
    /// Core Data "attempts recovery", but renames and removes nothing, and leaves the store and its `-wal` byte for
    /// byte. SQLite does rewrite the `-shm` (its index of the `-wal`, which holds no data of its own), which is why
    /// `openContainer` doesn't hand it such a file.
    func testSwiftDataRenamesAndRemovesNothingWhenAStoreDoesntOpen() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        let damaged: [String: Data] = [
            "Phocasa.store": Data("not a database".utf8),
            "Phocasa.store-wal": Data("not a log".utf8),
            "Phocasa.store-shm": Data("not shared memory".utf8),
        ]
        for (name, data) in damaged { try data.write(to: phocasaFolder.appendingPathComponent(name)) }

        let schema = LibraryLaunch.schema
        XCTAssertThrowsError(try ModelContainer(for: schema,
                                                configurations: ModelConfiguration(schema: schema, url: storeURL)))

        XCTAssertEqual(names(in: phocasaFolder), ["Phocasa.store", "Phocasa.store-shm", "Phocasa.store-wal"])
        let after = try snapshot(phocasaFolder)
        XCTAssertEqual(after["Phocasa.store"], damaged["Phocasa.store"])
        XCTAssertEqual(after["Phocasa.store-wal"], damaged["Phocasa.store-wal"])
    }

    /// A store with SQLite's header but damage further in reaches SQLite, which fails without renaming, removing or
    /// rewriting the store.
    func testAStoreDamagedPastItsHeaderFailsToOpenAndIsLeftAsItWas() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        var damaged = Data("SQLite format 3\u{0}".utf8)
        damaged.append(Data((0..<8176).map { UInt8(truncatingIfNeeded: $0 &* 13) }))
        try damaged.write(to: storeURL)
        XCTAssertTrue(LibraryLaunch.mayBeDatabase(storeURL), "precondition: it passes the header check")

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        guard case .cannotOpen = try problem(of: launch).reason else { return XCTFail("\(launch.outcome)") }
        XCTAssertEqual(try Data(contentsOf: storeURL), damaged)
        XCTAssertEqual(names(in: phocasaFolder).filter { !$0.hasPrefix("Phocasa.store-") },
                       ["Backups", "Phocasa.lock", "Phocasa.store"], "nothing renamed or removed")
    }

    func testOnlyAFileThatPlainlyIsntADatabaseIsRefusedBeforeSQLiteSeesIt() throws {
        let file = appSupport.appendingPathComponent("probe.store")
        XCTAssertTrue(LibraryLaunch.mayBeDatabase(file), "missing: SQLite creates it")
        try Data().write(to: file)
        XCTAssertTrue(LibraryLaunch.mayBeDatabase(file), "empty: SQLite's to fill")
        try Data("SQLite format 3\u{0}rest".utf8).write(to: file)
        XCTAssertTrue(LibraryLaunch.mayBeDatabase(file))
        try Data("SQLite format 2\u{0}rest".utf8).write(to: file)
        XCTAssertFalse(LibraryLaunch.mayBeDatabase(file))
        try Data("SQLite".utf8).write(to: file)
        XCTAssertFalse(LibraryLaunch.mayBeDatabase(file), "truncated inside the header")
    }

    /// A store no migration can bring to the live models (here, one a future build might write) fails to open, and
    /// is left as it was: it still opens with its own models.
    func testAStoreThatCantBeMigratedFailsToOpenAndIsLeftAsItWas() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        let incompatible = Schema(versionedSchema: IncompatibleSchema.self)
        do {
            let container = try ModelContainer(for: incompatible,
                                               configurations: ModelConfiguration(schema: incompatible, url: storeURL))
            let context = ModelContext(container)
            context.insert(IncompatibleSchema.PhotoAsset(fileName: 42))
            try context.save()
        }
        let before = names(in: phocasaFolder)

        let launch = LibraryLaunch.open(userLibrary, now: day(26))

        guard case .cannotOpen = try problem(of: launch).reason else { return XCTFail("\(launch.outcome)") }
        XCTAssertEqual(names(in: phocasaFolder).filter { $0 != "Backups" && $0 != "Phocasa.lock" }, before,
                       "nothing renamed, removed or added")
        let container = try ModelContainer(for: incompatible,
                                           configurations: ModelConfiguration(schema: incompatible, url: storeURL))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<IncompatibleSchema.PhotoAsset>())
            .map(\.fileName), [42], "the store holds what it held")
    }

    /// Launches that fail day after day keep every backup: only a launch that opened the store prunes.
    func testOnlyALaunchThatOpenedTheStorePrunesBackups() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        for old in 1...5 {
            let backup = backups.appendingPathComponent(StoreBackup.name(for: day(old)), isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try Data("good".utf8).write(to: backup.appendingPathComponent("Phocasa.store"))
        }
        try Data("not a database".utf8).write(to: storeURL)

        var failed: LibraryLaunch? = LibraryLaunch.open(userLibrary, now: day(20))
        XCTAssertEqual(try failed.map(problem(of:))?.backups.count, 6, "five good backups and today's")
        failed = nil

        try FileManager.default.removeItem(at: storeURL)
        try writeStore(at: storeURL, names: ["repaired"])
        let opened = LibraryLaunch.open(userLibrary, now: day(21))

        XCTAssertEqual(try photoNames(in: opened), ["repaired"])
        XCTAssertEqual(StoreBackup.backups(in: backups).map(\.lastPathComponent),
                       [day(21), day(20), day(5), day(4), day(3)].map { StoreBackup.name(for: $0) })
    }

    // MARK: - What the window says

    func testTheProblemSaysWhereTheLibraryAndItsBackupsAreAndThatNothingChanged() throws {
        try FileManager.default.createDirectory(at: phocasaFolder, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: storeURL)

        let problem = try problem(of: LibraryLaunch.open(userLibrary, now: day(26)))

        let text = problem.details.joined(separator: "\n")
        XCTAssertEqual(problem.title, "Phocasa can't open its library")
        XCTAssertTrue(text.contains(storeURL.path), text)
        XCTAssertTrue(text.contains(backups.path), text)
        XCTAssertTrue(text.contains("Nothing was changed"), text)
        XCTAssertTrue(text.contains(StoreBackup.name(for: day(26))), "names the newest backup: \(text)")
    }

    func testTheProblemSaysWhichOtherPhocasaHasTheLibraryOpen() throws {
        let problem = LibraryProblem(reason: .alreadyOpen(.init(processID: 4242, appPath: "/Applications/Phocasa.app")),
                                     folder: phocasaFolder, store: nil, backups: [])

        let text = problem.details.joined(separator: "\n")
        XCTAssertEqual(problem.title, "Phocasa is already open with this library")
        XCTAssertTrue(text.contains("/Applications/Phocasa.app"), text)
        XCTAssertTrue(text.contains("4242"), text)
        XCTAssertTrue(text.contains(phocasaFolder.path), text)
    }
}
