import Foundation
import os

/// Saved edit parameters of RAW files, which live in the RAW's `.xmp` sidecar.
///
/// - Writes go through `MetadataWriter`: serial, off the main thread, and in order with the rating and keyword
///   writes to the same sidecar, so neither can overwrite the other (spec §F3, §G5).
/// - Until the writer has written a saved value, reads return it from memory. So a read right after a save (the
///   detail view re-rendering the saved edit, or a new session on the same photo) never sees the old sidecar.
final class RAWEditStore: Sendable {
    static let shared = RAWEditStore()

    private struct Pending: Sendable {
        /// `nil` means the edits were cleared.
        let parameters: EditParameters?
        let version: Int
    }

    private struct State: Sendable {
        var nextVersion = 0
        var pending: [String: Pending] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Queues `parameters` for the sidecar of the RAW at `path`; `nil` clears them. Returns immediately.
    func save(_ parameters: EditParameters?, forRAWAt path: String) {
        let version = state.withLock { state in
            state.nextVersion += 1
            state.pending[path] = Pending(parameters: parameters, version: state.nextVersion)
            return state.nextVersion
        }
        MetadataWriter.shared.enqueueEditParameters(parameters, forRAWAt: path)
        // `flush()` sees every earlier enqueue, so once it returns the sidecar holds this value (or a newer one,
        // whose own entry has a newer version and stays).
        Task.detached(priority: .utility) { [state] in
            await MetadataWriter.shared.flush()
            state.withLock { state in
                if state.pending[path]?.version == version { state.pending[path] = nil }
            }
        }
    }

    /// The saved parameters: a value still waiting for the writer, otherwise the sidecar's. Synchronous: it may
    /// read the (small) sidecar file.
    func parameters(forRAWAt path: String) -> EditParameters? {
        if let pending = state.withLock({ $0.pending[path] }) { return pending.parameters }
        return MetadataService.shared.readEditParameters(forRAWAt: path)
    }

    /// `parameters(forRAWAt:)` with the sidecar read done on a background queue.
    func load(forRAWAt path: String) async -> EditParameters? {
        if let pending = state.withLock({ $0.pending[path] }) { return pending.parameters }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: parameters(forRAWAt: path))
            }
        }
    }
}
