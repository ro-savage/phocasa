import Foundation

/// Moves files to the Trash off the main thread (spec §G5). `trashItem` can take tens of milliseconds a file, so a
/// big permanent delete used to freeze the app. An actor on its own serial queue: files are trashed one at a time, in
/// the order asked, never on the main actor.
actor FileTrasher {
    static let shared = FileTrasher()

    private let queue = DispatchSerialQueue(label: "com.phocasa.file-trasher", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Moves one file to the Trash. Tests pass their own, so they never touch the user's Trash.
    private let trashItem: @Sendable (URL) throws -> Void

    init(trashItem: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.trashItem = trashItem
    }

    /// Moves each of `urls` that exists to the Trash, in order. A file that can't be trashed is skipped, as before.
    func trash(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            try? trashItem(url)
        }
    }
}
