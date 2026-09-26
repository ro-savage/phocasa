import XCTest
import SwiftData
@testable import Phocasa

/// The store's rolling backups (`StoreBackup`): at launch, before the container opens, the store's files are copied
/// into `Backups/<yyyy-MM-dd-HHmmss>/` in the library's folder, at most once a day, keeping the newest few. Each test
/// uses a temp folder as the library's folder. The copies are checked byte for byte on stand-in files (a backup copies
/// files whatever they hold, and a real store's SQLite files change whenever SQLite checkpoints); one test opens the
/// backup of a real store.
final class StoreBackupTests: XCTestCase {

    private var folder: URL!
    private var store: URL { folder.appendingPathComponent("Phocasa.store") }
    private var backups: URL { folder.appendingPathComponent("Backups", isDirectory: true) }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhocasaTests-StoreBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: - Helpers

    /// A moment in the current calendar, as a launch sees it.
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0,
                      _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                                   second: second))!
    }

    /// Stand-ins for a store's files, by path relative to the library's folder.
    private let storeFiles: [String: Data] = [
        "Phocasa.store": Data("the store".utf8),
        "Phocasa.store-wal": Data("its write-ahead log".utf8),
        "Phocasa.store-shm": Data("its shared memory".utf8),
        ".Phocasa_SUPPORT/_EXTERNAL_DATA/6E1F": Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7) }),
    ]

    private func writeStoreFiles() throws {
        for (path, data) in storeFiles {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    /// Every file under `dir` with its bytes, by path relative to it; `excluding` top-level names.
    private func snapshot(_ dir: URL, excluding: Set<String> = []) throws -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return files }
        let base = dir.standardizedFileURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            if let top = path.split(separator: "/").first, excluding.contains(String(top)) { continue }
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            files[path] = try Data(contentsOf: url)
        }
        return files
    }

    /// The live store's files: everything in the folder but the backups.
    private func liveFiles() throws -> [String: Data] { try snapshot(folder, excluding: ["Backups"]) }

    private func backupNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: backups.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
    }

    // MARK: - Copying

    func testABackupCopiesTheStoreAndItsCompanionsByteForByte() throws {
        try writeStoreFiles()

        let outcome = StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26, 9, 30, 5))

        let backup = backups.appendingPathComponent("2026-09-26-093005", isDirectory: true)
        XCTAssertEqual(outcome, .created(backup))
        XCTAssertEqual(try snapshot(backup), storeFiles, "the store, its -wal and -shm and its external data")
        XCTAssertEqual(try liveFiles(), storeFiles, "the live store is as it was")
        XCTAssertEqual(try backupNames(), ["2026-09-26-093005"])
    }

    func testAStoreWithoutCompanionsIsCopiedAlone() throws {
        try Data("just the store".utf8).write(to: store)

        let outcome = StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26))

        guard case .created(let backup) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try snapshot(backup), ["Phocasa.store": Data("just the store".utf8)])
    }

    func testThereIsNoBackupBeforeThereIsAStore() throws {
        XCTAssertEqual(StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26)), .skipped(.noStore))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path), "no Backups folder is made")
    }

    func testAtMostOneBackupADay() throws {
        try writeStoreFiles()

        XCTAssertEqual(StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26, 9, 0, 0)),
                       .created(backups.appendingPathComponent("2026-09-26-090000", isDirectory: true)))
        XCTAssertEqual(StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26, 23, 59, 59)),
                       .skipped(.alreadyBackedUpToday))
        XCTAssertEqual(StoreBackup.backUp(store, into: backups, now: date(2026, 9, 27, 0, 0, 1)),
                       .created(backups.appendingPathComponent("2026-09-27-000001", isDirectory: true)))

        XCTAssertEqual(try backupNames(), ["2026-09-26-090000", "2026-09-27-000001"])
    }

    // MARK: - Pruning

    func testPruningKeepsTheNewestBackupsAndNothingElseIsTouched() throws {
        try writeStoreFiles()
        for day in 1...7 {
            _ = StoreBackup.backUp(store, into: backups, now: date(2026, 9, day, 8))
        }
        try FileManager.default.createDirectory(at: backups.appendingPathComponent("Kept by hand"),
                                                withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: backups.appendingPathComponent("README.txt"))

        StoreBackup.prune(backups, keeping: 5)

        XCTAssertEqual(try backupNames(), ["2026-09-03-080000", "2026-09-04-080000", "2026-09-05-080000",
                                           "2026-09-06-080000", "2026-09-07-080000", "Kept by hand", "README.txt"])
        XCTAssertEqual(StoreBackup.backups(in: backups).map(\.lastPathComponent),
                       ["2026-09-07-080000", "2026-09-06-080000", "2026-09-05-080000", "2026-09-04-080000",
                        "2026-09-03-080000"], "newest first")
        XCTAssertEqual(try liveFiles(), storeFiles)
    }

    func testTheAppKeepsFiveBackups() {
        XCTAssertEqual(StoreBackup.keptBackups, 5)
    }

    // MARK: - Failures

    /// A copy that fails part way leaves no backup (neither a partial one nor one that counts as today's) and never
    /// touches the live store.
    func testAFailedCopyLeavesTheStoreAloneAndNoBackup() throws {
        try writeStoreFiles()
        let failing = FailingFileManager(failWhenCopyingTo: "Phocasa.store-shm")

        let outcome = StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26, 9), fileManager: failing)

        guard case .failed = outcome else { return XCTFail("expected the copy to fail, got \(outcome)") }
        XCTAssertTrue(failing.copied.contains("Phocasa.store-wal"), "precondition: it failed part way")
        XCTAssertEqual(try liveFiles(), storeFiles, "the live store is as it was")
        XCTAssertEqual(try backupNames(), [], "no backup, and no partial copy, is left")
        XCTAssertEqual(StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26, 10)),
                       .created(backups.appendingPathComponent("2026-09-26-100000", isDirectory: true)),
                       "a failed backup doesn't count as the day's")
    }

    func testABackupsFolderThatCantBeMadeFailsWithoutTouchingTheStore() throws {
        try writeStoreFiles()
        try Data("in the way".utf8).write(to: backups)

        let outcome = StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26))

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try Data(contentsOf: backups), Data("in the way".utf8))
        XCTAssertEqual(try snapshot(folder, excluding: ["Backups"]), storeFiles)
    }

    /// A launch that stopped part way through a copy (a crash, a power cut) left a partial copy under a hidden name:
    /// it isn't a backup, doesn't count as the day's, and goes at the next backup.
    func testALeftoverPartialCopyIsNeitherCountedNorKept() throws {
        try writeStoreFiles()
        let partial = backups.appendingPathComponent(".2026-09-26-080000.partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: partial.appendingPathComponent("Phocasa.store"))
        XCTAssertEqual(StoreBackup.backups(in: backups), [])

        let outcome = StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26, 9))

        XCTAssertEqual(outcome, .created(backups.appendingPathComponent("2026-09-26-090000", isDirectory: true)))
        XCTAssertEqual(try backupNames(), ["2026-09-26-090000"])
    }

    // MARK: - A real store

    /// Restoring a backup is copying its files back in place of the store's: here, the backup's own store opens with
    /// every photo, the binned one binned, the rated one's externally stored edit data included.
    func testTheBackupOfARealStoreOpensWithEveryValue() throws {
        let blob = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let schema = Schema([Phocasa.PhotoAsset.self, Phocasa.Tag.self, Phocasa.PhotoLibrary.self,
                             Phocasa.EditPreset.self])
        do {
            let container = try ModelContainer(for: schema,
                                               configurations: ModelConfiguration(schema: schema, url: store))
            let context = ModelContext(container)
            let binned = Phocasa.PhotoAsset(fileName: "binned", folderPath: "/p")
            binned.isInBin = true
            let rated = Phocasa.PhotoAsset(fileName: "rated", folderPath: "/p")
            rated.rating = 4
            rated.jpgEditParametersData = blob
            context.insert(binned)
            context.insert(rated)
            try context.save()
        }   // quit

        guard case .created(let backup) = StoreBackup.backUp(store, into: backups, now: date(2026, 9, 26)) else {
            return XCTFail("no backup")
        }

        let copy = backup.appendingPathComponent("Phocasa.store")
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: copy))
        let photos = try ModelContext(container).fetch(FetchDescriptor<Phocasa.PhotoAsset>())
        XCTAssertEqual(photos.map(\.fileName).sorted(), ["binned", "rated"])
        XCTAssertEqual(photos.first { $0.fileName == "binned" }?.isInBin, true)
        XCTAssertEqual(photos.first { $0.fileName == "rated" }?.rating, 4)
        XCTAssertEqual(photos.first { $0.fileName == "rated" }?.jpgEditParametersData, blob)
    }
}

/// A file manager whose copy to a file named `failWhenCopyingTo` fails, like a full disk; records what it copied.
private final class FailingFileManager: FileManager, @unchecked Sendable {
    private let failingName: String
    private(set) var copied: [String] = []

    init(failWhenCopyingTo name: String) {
        failingName = name
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == failingName {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: srcURL, to: dstURL)
        copied.append(dstURL.lastPathComponent)
    }
}
