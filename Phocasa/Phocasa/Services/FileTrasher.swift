import Foundation

/// What happened to one file a delete asked to move to the Trash.
enum TrashOutcome: Sendable, Equatable {
    /// It's in the Trash.
    case trashed
    /// It wasn't there, and its volume is: it's gone already (deleted or moved outside Phocasa).
    case alreadyGone
    /// It isn't there because its volume isn't mounted (a drive unplugged, a share disconnected): it may well still be
    /// on that drive. `name` is the volume's.
    case volumeUnavailable(name: String)
    /// It's there, but couldn't be moved to the Trash (locked, read-only, no permission, a volume without a Trash).
    /// The reason is the error's description.
    case failed(String)

    /// Whether the file is no longer where the photo says it is: moved to the Trash or gone already.
    var fileIsGone: Bool {
        self == .trashed || self == .alreadyGone
    }
}

/// Moves files to the Trash off the main thread (spec §G5). `trashItem` can take tens of milliseconds a file, so a
/// big permanent delete used to freeze the app. An actor on its own serial queue: files are trashed one at a time, in
/// the order asked, never on the main actor.
actor FileTrasher {
    static let shared = FileTrasher()

    private let queue = DispatchSerialQueue(label: "com.phocasa.file-trasher", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Moves one file to the Trash. Tests pass their own, so they never touch the user's Trash.
    private let trashItem: @Sendable (URL) throws -> Void
    /// Tells a missing file that is gone from one on a volume that isn't mounted. Tests pass a temp "Volumes" folder.
    private let volumes: VolumeCheck

    init(trashItem: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }, volumes: VolumeCheck = VolumeCheck()) {
        self.trashItem = trashItem
        self.volumes = volumes
    }

    /// Moves each of `urls` that exists to the Trash, in order, and says what happened to each (`outcomes[i]` is
    /// `urls[i]`'s). A file that can't be moved stays where it is.
    func trash(_ urls: [URL]) -> [TrashOutcome] {
        let fm = FileManager.default
        return urls.map { url in
            guard fm.fileExists(atPath: url.path) else {
                if !volumes.isVolumeAvailable(for: url.path) {
                    return .volumeUnavailable(name: volumes.volumeName(of: url.path) ?? url.path)
                }
                return .alreadyGone
            }
            do {
                try trashItem(url)
                return .trashed
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }
}
