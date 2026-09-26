import Foundation

/// Rolling backups of the library's store, in `Backups/` in the library's folder
/// (`Application Support/Phocasa/Backups/<yyyy-MM-dd-HHmmss>/`, or the development library's own).
///
/// The store is the only copy of what isn't in the photo files: JPG edit parameters, the bin, presets, the library's
/// folder. `LibraryLaunch` backs it up at launch, once it holds the library's lock and after `StoreLocation`'s legacy
/// move, before the container opens: no process has the SQLite files open, so the store, its `-wal` and `-shm` and its
/// external-data folder copied together are consistent. `FileManager.copyItem` clones on APFS, so a backup costs
/// almost nothing until the live store changes.
///
/// At most one backup a day (by the calendar day of its name). Only a launch that then opened the store prunes, to
/// the newest `keptBackups`: a store that fails to open is backed up but prunes nothing, so launches that fail day
/// after day never push the good backups out.
///
/// Restoring one: quit Phocasa, then copy the backup's files over the library's (`Phocasa.store`, `-wal`, `-shm` and
/// `.Phocasa_SUPPORT`, removing a live `-wal`/`-shm` the backup doesn't have).
enum StoreBackup {
    static let folderName = "Backups"
    /// Five launch days: long enough to notice a problem (a bad bulk change, a damaged store) before the last good
    /// copy goes, while the Backups folder stays a few times the store's size at most (on APFS, clones share what
    /// hasn't changed).
    static let keptBackups = 5

    enum Skip: Equatable {
        case noStore
        case alreadyBackedUpToday
    }

    enum Outcome: Equatable {
        case created(URL)
        case skipped(Skip)
        /// The copy failed (the reason); nothing of it was left behind, and the store wasn't touched.
        case failed(String)
    }

    /// Copies the store at `store` and its companions into a new backup in `folder`, named for `now`, unless there's
    /// no store yet or a backup from `now`'s day already exists. The copy goes to a hidden `.<name>.partial` folder
    /// first and gets its name only once whole, so a launch that stops part way leaves no backup that looks complete;
    /// a failed copy is removed. It only ever reads the store's files.
    static func backUp(_ store: URL, into folder: URL, now: Date = Date(), calendar: Calendar = .current,
                       fileManager: FileManager = .default) -> Outcome {
        guard fileManager.fileExists(atPath: store.path) else { return .skipped(.noStore) }
        let name = name(for: now, calendar: calendar)
        let day = name.prefix(10)
        if backups(in: folder, fileManager: fileManager).contains(where: { $0.lastPathComponent.hasPrefix(day) }) {
            return .skipped(.alreadyBackedUpToday)
        }
        let partial = folder.appendingPathComponent(".\(name).partial", isDirectory: true)
        let backup = folder.appendingPathComponent(name, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            removePartialCopies(in: folder, fileManager: fileManager)
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
            for file in StoreLocation.files(of: store) where fileManager.fileExists(atPath: file.path) {
                try fileManager.copyItem(at: file, to: partial.appendingPathComponent(file.lastPathComponent))
            }
            try fileManager.moveItem(at: partial, to: backup)
            return .created(backup)
        } catch {
            try? fileManager.removeItem(at: partial)
            return .failed(error.localizedDescription)
        }
    }

    /// Removes all but the newest `keeping` backups in `folder`. Only folders named like a backup are touched.
    static func prune(_ folder: URL, keeping: Int = keptBackups, fileManager: FileManager = .default) {
        for backup in backups(in: folder, fileManager: fileManager).dropFirst(max(0, keeping)) {
            try? fileManager.removeItem(at: backup)
        }
    }

    /// The backups in `folder`, newest first: the folders named `yyyy-MM-dd-HHmmss`.
    static func backups(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isBackupName).sorted(by: >)
            .map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    /// A backup's name: `now` in `calendar`, `yyyy-MM-dd-HHmmss`, which sorts by time.
    static func name(for now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        return String(format: "%04d-%02d-%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
                      c.minute ?? 0, c.second ?? 0)
    }

    private static func isBackupName(_ name: String) -> Bool {
        let characters = Array(name)
        guard characters.count == 17 else { return false }
        return characters.indices.allSatisfy { i in
            [4, 7, 10].contains(i) ? characters[i] == "-" : characters[i].isASCII && characters[i].isNumber
        }
    }

    /// Removes the partial copies a launch that stopped part way left.
    private static func removePartialCopies(in folder: URL, fileManager: FileManager) {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
