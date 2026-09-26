import Foundation
import os

/// What `MetadataWriter` hasn't written yet, in a small file next to the library's store, so writes still queued when
/// the app quits (quit waits 5 s at most), crashes or is force-quit are made at the next launch.
///
/// - The file is JSON Lines: one `Entry` per line, in the order the writes are to be made. Each carries the absolute
///   value to write (a rating and keywords, or edit parameters), so replaying one that was written already changes
///   nothing, and a newer write for the same file replaces a replayed one as any newer payload replaces a waiting one.
/// - It's replaced whole, atomically, so a crash as it's written leaves the one before; a file cut short another way
///   keeps every line written whole (`load()` skips the rest).
/// - `MetadataWriter` saves it whenever it takes in new writes (before it makes any of them), about once a second
///   while it drains, and when it's done (no file when nothing is left).
final class MetadataWriteJournal: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let operation: MetadataWriteOperation
    }

    let url: URL
    private let lock = NSLock()
    /// What the file holds (the last `save`), so `saveAdding(_:)` can add to it.
    private var saved: [Entry] = []

    init(url: URL) {
        self.url = url
    }

    /// The entries the file holds, in order; none if there's no file. Lines that can't be read are skipped.
    func load() -> [Entry] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            saved = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Entry.self, from: $0) }
            return saved
        }
    }

    /// Replaces the file with `entries`; removes it when there are none.
    func save(_ entries: [Entry]) {
        lock.withLock { write(entries) }
    }

    /// Adds `extra` to what the file holds.
    func saveAdding(_ extra: [Entry]) {
        lock.withLock { write(saved + extra) }
    }

    private func write(_ entries: [Entry]) {
        saved = entries
        let fm = FileManager.default
        guard !entries.isEmpty else {
            try? fm.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder() // compact output: never a newline inside an entry
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension LibraryLocation {
    static let metadataWriteJournalName = "PendingMetadataWrites.jsonl"

    /// Where `MetadataWriter.shared` keeps its journal: in the store's folder (`Application Support/Phocasa/` for the
    /// user's library, `Phocasa-Development/` for the development library); none for the in-memory test-host store.
    /// Pure: it touches no file.
    var metadataWriteJournalURL: URL? {
        switch store {
        case .inMemory:
            return nil
        case .user(let applicationSupport):
            return applicationSupport.appendingPathComponent(StoreLocation.folderName, isDirectory: true)
                .appendingPathComponent(Self.metadataWriteJournalName)
        case .development(let storeURL):
            return storeURL.deletingLastPathComponent().appendingPathComponent(Self.metadataWriteJournalName)
        }
    }
}

/// How many metadata writes `MetadataWriter.shared` has still to make, for the status bar ("Saving to files… 1,234
/// left"). Updated from the writer's queue a few times a second at most, and at 0.
@MainActor @Observable
final class MetadataWriteProgress {
    static let shared = MetadataWriteProgress()

    private(set) var pending = 0
    @ObservationIgnored private var applied = 0

    /// Orders the updates: each hops to the main actor on a task of its own.
    nonisolated private static let sequence = OSAllocatedUnfairLock(initialState: 0)

    /// The writer's report of `count` writes left; from any thread.
    nonisolated static func post(_ count: Int) {
        let number = sequence.withLock { value -> Int in
            value += 1
            return value
        }
        Task { @MainActor in shared.apply(count, number: number) }
    }

    private func apply(_ count: Int, number: Int) {
        guard number > applied else { return }
        applied = number
        if pending != count { pending = count }
    }
}
