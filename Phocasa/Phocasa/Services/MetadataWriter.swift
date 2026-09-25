import Foundation
import os

/// One photo's rating and keyword write-back. `path` is the photo's file: a JPG (or another standard image),
/// which gets the values embedded, or a RAW file, whose `.xmp` sidecar gets them.
struct MetadataWriteItem: Sendable, Equatable {
    let path: String
    let rating: Int
    let keywords: [String]
    /// For a JPG+RAW pair, the RAW file (`path` is then the JPG). Its `.xmp` sidecar gets the same rating and
    /// keywords, so the two files never disagree.
    let pairedRAWPath: String?

    init(path: String, rating: Int, keywords: [String], pairedRAWPath: String? = nil) {
        self.path = path
        self.rating = rating
        self.keywords = keywords
        self.pairedRAWPath = pairedRAWPath
    }

    /// The files this item writes, in order: `path`, then the paired RAW (through its sidecar).
    var paths: [String] {
        guard let raw = pairedRAWPath, !raw.isEmpty, raw != path else { return [path] }
        return [path, raw]
    }
}

/// The file operations `MetadataWriter` performs. `MetadataService` is the real one; tests inject a fake.
protocol MetadataWriting: Sendable {
    func writeMetadata(rating: Int, keywords: [String], toImageAt path: String)
    func writeEditParameters(_ params: EditParameters, forRAWAt path: String)
    func clearEditParameters(forRAWAt path: String)
}

extension MetadataService: MetadataWriting {}

/// Serialises every metadata write. Only the latest pending write per path is kept.
///
/// - `enqueue` and `enqueueEditParameters` are synchronous and never block: they add to an inbox
///   and return. Writes are applied in the order those calls were made, and `flush()` sees
///   every call that happened before it, from any thread.
/// - Writes run one at a time on this actor's own serial queue (utility QoS), never on the
///   cooperative thread pool and never two at once, so writes to one file can't interleave.
/// - Pending paths are written in the order they were first enqueued. Enqueueing a path that is
///   still waiting replaces its payload in place. A path's rating/keyword write and its RAW
///   edit-parameter write are kept side by side (they share the sidecar) and run in the order
///   they were enqueued.
/// - The drain loop takes in new enqueues before every write, so a newer payload replaces one
///   that hasn't been written yet.
actor MetadataWriter {
    static let shared = MetadataWriter()

    private let queue = DispatchSerialQueue(label: "com.phocasa.metadata-writer", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let service: any MetadataWriting

    private enum Operation: Sendable {
        case metadata(rating: Int, keywords: [String])
        case setEditParameters(EditParameters)
        case clearEditParameters

        /// Operations of the same kind supersede each other; the two kinds don't.
        var touchesEditParameters: Bool {
            if case .metadata = self { return false }
            return true
        }
    }

    private struct Submission: Sendable {
        let path: String
        let operation: Operation
    }

    /// Enqueued but not yet taken in by the actor. Filled from any thread.
    private struct Inbox: Sendable {
        var submissions: [Submission] = []
        var wakeUpScheduled = false
    }

    /// What is still to be written for one path: at most one operation of each kind, in enqueue order.
    private struct PendingPath {
        private(set) var operations: [Operation] = []

        mutating func put(_ operation: Operation) {
            if let i = operations.firstIndex(where: { $0.touchesEditParameters == operation.touchesEditParameters }) {
                operations[i] = operation
            } else {
                operations.append(operation)
            }
        }

        mutating func popFirst() -> Operation? {
            operations.isEmpty ? nil : operations.removeFirst()
        }
    }

    private nonisolated let inbox = OSAllocatedUnfairLock(initialState: Inbox())
    private var pending: [String: PendingPath] = [:]
    /// The paths in `pending`, oldest first.
    private var order: [String] = []
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(service: MetadataService = .shared) {
        self.service = service
    }

    /// For tests: writes through any `MetadataWriting`.
    init(writer: any MetadataWriting) {
        self.service = writer
    }

    // MARK: - API

    /// Queues rating and keyword writes. Returns immediately.
    ///
    /// An item for a JPG+RAW pair becomes two writes, the JPG and then the RAW's sidecar. Each is a path of
    /// its own here, so both are coalesced and ordered like any other write, and the sidecar write stays
    /// serialised with that RAW's edit-parameter writes.
    nonisolated func enqueue(_ items: [MetadataWriteItem]) {
        submit(items.flatMap { item in
            item.paths.map { Submission(path: $0, operation: .metadata(rating: item.rating, keywords: item.keywords)) }
        })
    }

    /// RAW edit parameters go through the same queue, so they can't race rating/keyword writes to the same sidecar.
    /// `nil` clears them. Returns immediately.
    nonisolated func enqueueEditParameters(_ params: EditParameters?, forRAWAt path: String) {
        submit([Submission(path: path, operation: params.map(Operation.setEditParameters) ?? .clearEditParameters)])
    }

    /// Waits until everything enqueued so far has been written. For tests and app termination.
    /// (It returns once the writer is idle, so it also waits for anything enqueued meanwhile.)
    func flush() async {
        takeInInbox()
        guard isDraining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Inbox

    private nonisolated func submit(_ submissions: [Submission]) {
        let submissions = submissions.filter { !$0.path.isEmpty }
        guard !submissions.isEmpty else { return }
        let needsWakeUp = inbox.withLock { inbox in
            inbox.submissions.append(contentsOf: submissions)
            defer { inbox.wakeUpScheduled = true }
            return !inbox.wakeUpScheduled
        }
        if needsWakeUp {
            Task(priority: .utility) { await self.takeInInbox() }
        }
    }

    /// Moves the inbox into `pending` and starts draining if there is work.
    private func takeInInbox() {
        let submissions = inbox.withLock { inbox in
            defer {
                inbox.submissions.removeAll()
                inbox.wakeUpScheduled = false
            }
            return inbox.submissions
        }
        for submission in submissions {
            put(submission.operation, for: submission.path)
        }
        startDrainingIfNeeded()
    }

    // MARK: - Queue

    private func put(_ operation: Operation, for path: String) {
        if pending[path] == nil { order.append(path) }
        pending[path, default: PendingPath()].put(operation)
    }

    private func nextOperation() -> Submission? {
        guard let path = order.first, var entry = pending[path], let operation = entry.popFirst() else { return nil }
        if entry.operations.isEmpty {
            pending[path] = nil
            order.removeFirst()
        } else {
            pending[path] = entry
        }
        return Submission(path: path, operation: operation)
    }

    private func startDrainingIfNeeded() {
        guard !isDraining, !order.isEmpty else { return }
        isDraining = true
        Task(priority: .utility) { self.drain() }
    }

    private func drain() {
        while true {
            takeInInbox()   // newer payloads replace older ones that are still waiting
            guard let next = nextOperation() else { break }
            perform(next.operation, at: next.path)
        }
        isDraining = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Synchronous file I/O, on this actor's serial queue.
    private func perform(_ operation: Operation, at path: String) {
        switch operation {
        case .metadata(let rating, let keywords):
            service.writeMetadata(rating: rating, keywords: keywords, toImageAt: path)
        case .setEditParameters(let params):
            service.writeEditParameters(params, forRAWAt: path)
        case .clearEditParameters:
            service.clearEditParameters(forRAWAt: path)
        }
    }
}
