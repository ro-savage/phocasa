import Foundation
import SwiftData
import os

/// What a launch opened: the library's container, or why it has none (`LibraryProblem`, which the window shows in
/// place of the library). `open` runs the steps before the store opens, in this order:
///
/// 1. **Lock** the library's folder (`LibraryLock`). If another process holds it, nothing else happens: no legacy
///    move, no backup, no open. The in-memory test host takes no lock.
/// 2. **Prepare** the store (`LibraryLocation.prepareStore`: the user's library may move a legacy `default.store` into
///    its folder first).
/// 3. **Back up** the store (`StoreBackup`), with no process holding its files open. Only the library's own
///    `Phocasa.store`, never a `default.store` still opened where it is (it may be another app's).
/// 4. **Open** it (`openContainer`). A store that doesn't open (damaged, or a migration that can't be inferred) is
///    reported, never deleted, moved or overwritten. SwiftData renames and removes nothing when a store fails to
///    open; SQLite may rewrite its `-shm`, which holds no data, and isn't given a file that plainly isn't a database
///    (`LibraryLaunchTests`). Only a launch that opened the store prunes the backups.
struct LibraryLaunch {
    enum Outcome {
        case opened(ModelContainer)
        case unavailable(LibraryProblem)
    }

    let outcome: Outcome
    /// The library's lock, held while this launch exists: the app keeps its launch for its whole life. Nil for the
    /// in-memory store, and when another process holds the lock.
    let lock: LibraryLock?
    /// What the backup did; nil when none was tried (in memory, locked out, or a store that isn't the library's own).
    let backup: StoreBackup.Outcome?

    /// The app's models.
    static var schema: Schema { Schema([PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self]) }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.phocasa.app", category: "Launch")

    /// Locks, prepares, backs up and opens the library at `location` (see the type's comment). `now` names the
    /// backup.
    static func open(_ location: LibraryLocation, fileManager: FileManager = .default, now: Date = Date()) -> LibraryLaunch {
        guard let folder = location.libraryFolder else { return openInMemory() }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let lock: LibraryLock
        switch LibraryLock.acquire(in: folder) {
        case .acquired(let acquired):
            lock = acquired
        case .held(let holder):
            return LibraryLaunch(outcome: .unavailable(LibraryProblem(reason: .alreadyOpen(holder), folder: folder,
                                                                      store: nil, backups: [])),
                                 lock: nil, backup: nil)
        case .failed(let reason):
            return LibraryLaunch(outcome: .unavailable(LibraryProblem(reason: .lockFailed(reason), folder: folder,
                                                                      store: nil, backups: [])),
                                 lock: nil, backup: nil)
        }

        guard let store = location.prepareStore(fileManager: fileManager) else { return openInMemory() }

        let backups = folder.appendingPathComponent(StoreBackup.folderName, isDirectory: true)
        let isLibrarysOwnStore = store.standardizedFileURL
            == folder.appendingPathComponent(StoreLocation.storeFileName).standardizedFileURL
        let backup = isLibrarysOwnStore ? StoreBackup.backUp(store, into: backups, now: now, fileManager: fileManager)
            : nil
        if case .failed(let reason)? = backup {
            log.error("The store's backup failed, the launch goes on: \(reason, privacy: .public)")
        }

        do {
            let container = try openContainer(at: store)
            if isLibrarysOwnStore { StoreBackup.prune(backups, fileManager: fileManager) }
            return LibraryLaunch(outcome: .opened(container), lock: lock, backup: backup)
        } catch {
            log.error("The store at \(store.path, privacy: .public) didn't open: \(String(describing: error), privacy: .public)")
            let problem = LibraryProblem(reason: .cannotOpen(describe(error)), folder: folder, store: store,
                                         backups: StoreBackup.backups(in: backups, fileManager: fileManager))
            return LibraryLaunch(outcome: .unavailable(problem), lock: lock, backup: backup)
        }
    }

    /// Opens the store at `url` with the app's models, migrating it in place (SwiftData's lightweight migration) if
    /// it's older. Throws when it can't be opened.
    ///
    /// SQLite rewrites a store's `-shm` when it opens it, even to find the store isn't a database, so a file that
    /// plainly isn't one (`mayBeDatabase`) is refused before SQLite sees it: its files stay byte for byte as they
    /// were. (The `-shm` holds no data, only an index SQLite rebuilds from the `-wal`; a store damaged further in
    /// still reaches SQLite, which fails without changing anything else.)
    static func openContainer(at url: URL) throws -> ModelContainer {
        guard mayBeDatabase(url) else { throw StoreOpenError.notADatabase }
        let schema = schema
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
    }

    /// False for a file that can't be an SQLite database: it exists, isn't empty, and doesn't start with SQLite's
    /// header. A missing or empty file is SQLite's to create; one that can't be read is SQLite's to report.
    static func mayBeDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), !header.isEmpty else { return true }
        return header == Data("SQLite format 3\u{0}".utf8)
    }

    enum StoreOpenError: LocalizedError {
        case notADatabase

        var errorDescription: String? {
            switch self {
            case .notADatabase: "Its store file isn't a database: it's damaged."
            }
        }
    }

    /// A throwaway in-memory store (the XCTest host). It can only fail if the models themselves are broken, which no
    /// launch could get past.
    private static func openInMemory() -> LibraryLaunch {
        let schema = schema
        do {
            let container = try ModelContainer(for: schema,
                                               configurations: ModelConfiguration(schema: schema,
                                                                                  isStoredInMemoryOnly: true))
            return LibraryLaunch(outcome: .opened(container), lock: nil, backup: nil)
        } catch {
            fatalError("Failed to create an in-memory ModelContainer: \(error)")
        }
    }

    /// The error as a person can read it. SwiftData says only that it couldn't load the store
    /// (`SwiftDataError.loadIssueModelContainer`, with no underlying error), so that gets the likely causes, and its
    /// own description in brackets for a bug report.
    private static func describe(_ error: Error) -> String {
        if let error = error as? StoreOpenError { return error.localizedDescription }
        return "SwiftData couldn't load its store: it may be damaged, or written by a version of Phocasa this one "
            + "can't read. (\(error.localizedDescription))"
    }
}

/// Why a launch didn't open the library, for the window that says so (`LibraryUnavailableView`).
struct LibraryProblem: Equatable {
    enum Reason: Equatable {
        /// Another process holds the library's lock; nil when the lock file doesn't say which.
        case alreadyOpen(LibraryLock.Holder?)
        /// The lock couldn't be taken (the reason), so the store wasn't opened.
        case lockFailed(String)
        /// The store didn't open (the reason).
        case cannotOpen(String)
    }

    let reason: Reason
    /// The library's folder: the one Show in Finder opens.
    let folder: URL
    /// The store the launch tried to open; nil when it stopped before choosing one.
    let store: URL?
    /// The store's backups, newest first.
    let backups: [URL]
}
