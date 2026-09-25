import Foundation

/// Bounded, newest-first, cancellable work scheduler with in-flight de-duplication.
///
/// - At most `maxConcurrent` work items run at once, on `DispatchQueue.global(qos:)`.
/// - Pending work is a LIFO stack: when a slot frees up, the most recently requested key runs next, so cells that
///   just scrolled into view are served before the ones that scrolled past.
/// - Callers asking for a key that is already pending or running share that one execution. Re-requesting a pending
///   key moves it to the top of the stack.
/// - A cancelled caller is resumed with `nil` straight away. A key whose callers have all been cancelled before its
///   work started is dropped, and its work never runs. Work that has already started runs to completion (its
///   closure can still store the result, for example in a cache), but nobody waits for it.
///
/// All state is protected by one lock. Work closures and continuation resumes run outside it.
final class ThumbnailScheduler<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    typealias Work = @Sendable () -> Value?

    /// Mutable state is only touched while holding the scheduler's lock.
    private final class Entry: @unchecked Sendable {
        let work: Work
        var waiters: [UInt64: CheckedContinuation<Value?, Never>] = [:]
        var started = false

        init(work: @escaping Work) {
            self.work = work
        }
    }

    let maxConcurrent: Int
    private let queue: DispatchQueue

    private let lock = NSLock()
    /// Keys waiting to start, oldest first. The pump takes from the end.
    private var pending: [Key] = []
    private var entries: [Key: Entry] = [:]
    private var running = 0
    private var nextToken: UInt64 = 0

    init(maxConcurrent: Int, qos: DispatchQoS.QoSClass = .userInitiated) {
        precondition(maxConcurrent > 0, "maxConcurrent must be at least 1")
        self.maxConcurrent = maxConcurrent
        self.queue = DispatchQueue.global(qos: qos)
    }

    /// Runs `work` for `key` at most once at a time. Callers with the same key share one execution.
    /// If every caller waiting on a key is cancelled before its work starts, the work never runs and callers get nil.
    func value(for key: Key, work: @escaping Work) async -> Value? {
        let token: UInt64 = lock.withLock {
            nextToken &+= 1
            return nextToken
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(key: key, token: token, continuation: continuation, work: work)
            }
        } onCancel: {
            cancel(key: key, token: token)
        }
    }

    // MARK: - Diagnostics (used by tests)

    /// The number of keys waiting to start.
    var pendingKeyCount: Int {
        lock.withLock { pending.count }
    }

    /// The number of callers waiting on `key`, whether its work is pending or running.
    func waiterCount(for key: Key) -> Int {
        lock.withLock { entries[key]?.waiters.count ?? 0 }
    }

    // MARK: - Private

    /// Runs synchronously inside `withCheckedContinuation`, so `Task.isCancelled` is the caller's task.
    /// Cancellation sets that flag before it runs `cancel(key:token:)`, and both take the lock, so either the flag
    /// is seen here or the handler finds the registered waiter.
    private func enqueue(
        key: Key, token: UInt64,
        continuation: CheckedContinuation<Value?, Never>,
        work: @escaping Work
    ) {
        let toStart: [(Key, Entry)]? = lock.withLock {
            if Task.isCancelled {
                return nil
            }
            if let entry = entries[key] {
                entry.waiters[token] = continuation
                if !entry.started, let index = pending.lastIndex(of: key), index != pending.count - 1 {
                    // The newest request wins: move the key to the top of the stack.
                    pending.remove(at: index)
                    pending.append(key)
                }
                return []
            }
            let entry = Entry(work: work)
            entry.waiters[token] = continuation
            entries[key] = entry
            pending.append(key)
            return takeRunnableLocked()
        }
        guard let toStart else {
            continuation.resume(returning: nil)
            return
        }
        toStart.forEach(start)
    }

    private func cancel(key: Key, token: UInt64) {
        let continuation: CheckedContinuation<Value?, Never>? = lock.withLock {
            // Absent: not registered yet (enqueue will see Task.isCancelled) or already resumed.
            guard let entry = entries[key], let continuation = entry.waiters.removeValue(forKey: token) else {
                return nil
            }
            if entry.waiters.isEmpty && !entry.started {
                entries[key] = nil
                // Cancelled cells are usually the oldest requests, near the bottom of the stack.
                if let index = pending.firstIndex(of: key) {
                    pending.remove(at: index)
                }
            }
            return continuation
        }
        continuation?.resume(returning: nil)
    }

    private func takeRunnableLocked() -> [(Key, Entry)] {
        var toStart: [(Key, Entry)] = []
        while running < maxConcurrent, let key = pending.popLast() {
            guard let entry = entries[key], !entry.started else { continue }
            entry.started = true
            running += 1
            toStart.append((key, entry))
        }
        return toStart
    }

    private func start(_ key: Key, _ entry: Entry) {
        queue.async { [self] in
            let value = autoreleasepool { entry.work() }
            let (waiters, next): ([CheckedContinuation<Value?, Never>], [(Key, Entry)]) = lock.withLock {
                let waiters = Array(entry.waiters.values)
                entry.waiters.removeAll()
                if entries[key] === entry {
                    entries[key] = nil
                }
                running -= 1
                return (waiters, takeRunnableLocked())
            }
            for waiter in waiters {
                waiter.resume(returning: value)
            }
            next.forEach(start)
        }
    }
}
