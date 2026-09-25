import AppKit
import os

/// Quitting waits for the metadata writes still queued (ratings, keywords, RAW edit parameters) to reach the files,
/// for at most `quitFlushTimeout`.
///
/// SwiftUI has no hook for app termination on macOS (`scenePhase` doesn't report it), so this is an app delegate,
/// installed with `@NSApplicationDelegateAdaptor`: `applicationShouldTerminate` answers `.terminateLater` and replies
/// once the flush is done or the timeout has passed. A known AppKit exception (see CLAUDE.md).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let quitFlushTimeout: Duration = .seconds(5)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.replyAfterFlushing(timeout: Self.quitFlushTimeout) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Waits for the pending writes (`flushPendingWrites`), then calls `reply` on the main actor.
    static func replyAfterFlushing(
        timeout: Duration,
        flush: @escaping @Sendable () async -> Void = { await MetadataWriter.shared.flush() },
        reply: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            await flushPendingWrites(timeout: timeout, flush: flush)
            reply()
        }
    }

    /// Waits until `flush` returns or `timeout` passes, whichever comes first, and returns whether the flush finished.
    /// A flush that is still running when the timeout passes carries on; it isn't cancelled. (The writer drains at
    /// utility QoS, and waiting on it doesn't raise that, hence the timeout.)
    @discardableResult
    static func flushPendingWrites(
        timeout: Duration,
        flush: @escaping @Sendable () async -> Void = { await MetadataWriter.shared.flush() }
    ) async -> Bool {
        let answered = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            @Sendable func answer(_ finished: Bool) {
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: finished) }
            }
            Task {
                await flush()
                answer(true)
            }
            Task {
                try? await Task.sleep(for: timeout)
                answer(false)
            }
        }
    }
}
