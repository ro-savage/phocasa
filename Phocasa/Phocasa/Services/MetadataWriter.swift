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

}

/// The file operations `MetadataWriter` performs. `MetadataService` is the real one; tests inject a fake.
protocol MetadataWriting: Sendable {
    func writeMetadata(rating: Int, keywords: [String], toImageAt path: String)
    func writeEditParameters(_ params: EditParameters, forRAWAt path: String)
    func clearEditParameters(forRAWAt path: String)
}

extension MetadataService: MetadataWriting {}

/// Told about each rating and keyword write into an image file itself (a JPG or another standard image, not a RAW
/// sidecar). Those rewrite only the file's metadata, and its pixels stay identical. `ImageLoader` uses it to keep the
/// photo's disk-cached thumbnails, whose key includes the file's size.
protocol MetadataRewriteObserver: Sendable {
    /// Performs `rewrite`, the write, synchronously, so the observer can look at the file before and after.
    func rewritingMetadata(ofImageAt path: String, _ rewrite: () -> Void)
}

/// One write `MetadataWriter` makes to one file: its rating and keywords, or a RAW's edit parameters (set or cleared).
enum MetadataWriteOperation: Codable, Equatable, Sendable {
    case metadata(rating: Int, keywords: [String])
    case setEditParameters(EditParameters)
    case clearEditParameters

    /// Operations of the same kind supersede each other; the two kinds don't.
    var touchesEditParameters: Bool {
        if case .metadata = self { return false }
        return true
    }
}

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
/// - Rating and keyword writes into an image file itself run inside `rewriteObserver`, if there
///   is one. `shared` reports to `ImageLoader.shared`, which keeps the thumbnails it cached on disk.
/// - What isn't written yet is kept in `journal` (`MetadataWriteJournal`), if there is one, and a new writer starts
///   with what its journal holds, ahead of anything enqueued: `resumeJournaledWrites()` at launch writes it.
/// - A write for a file on a volume that isn't mounted (`VolumeCheck`) isn't made and isn't dropped: it waits, in the
///   journal, until `retryWaitingWrites()` or the next launch, unless a newer write for that file replaces it.
/// - `progress` hears how many writes are left, a few times a second at most and at 0.
actor MetadataWriter {
    static let shared = MetadataWriter(
        service: .shared, rewriteObserver: ImageLoader.shared,
        journal: LibraryLocation.current.metadataWriteJournalURL.map { MetadataWriteJournal(url: $0) },
        progress: MetadataWriteProgress.post)

    private let queue = DispatchSerialQueue(label: "com.phocasa.metadata-writer", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let service: any MetadataWriting

    private typealias Operation = MetadataWriteOperation

    private struct Submission: Sendable {
        let path: String
        let operation: Operation

        var entry: MetadataWriteJournal.Entry { .init(path: path, operation: operation) }
    }

    /// Enqueued but not yet taken in by the actor. Filled from any thread.
    private struct Inbox: Sendable {
        var submissions: [Submission] = []
        var wakeUpScheduled = false
    }

    /// What is still to be written for one path: at most one operation of each kind, in enqueue order.
    private struct PendingPath {
        private(set) var operations: [Operation] = []

        /// Returns whether it added an operation (rather than replacing one of the same kind).
        @discardableResult
        mutating func put(_ operation: Operation) -> Bool {
            if let i = operations.firstIndex(where: { $0.touchesEditParameters == operation.touchesEditParameters }) {
                operations[i] = operation
                return false
            }
            operations.append(operation)
            return true
        }

        /// Drops the operation of `operation`'s kind, if there is one.
        mutating func removeKind(of operation: Operation) {
            operations.removeAll { $0.touchesEditParameters == operation.touchesEditParameters }
        }

        mutating func popFirst() -> Operation? {
            operations.isEmpty ? nil : operations.removeFirst()
        }
    }

    private nonisolated let inbox: OSAllocatedUnfairLock<Inbox>
    private var pending: [String: PendingPath] = [:]
    /// The paths in `pending`, oldest first.
    private var order: [String] = []
    /// How many operations `pending` holds.
    private var pendingCount = 0
    /// Writes for files on volumes that aren't mounted, by path, and those paths in the order they were put aside.
    private var waiting: [String: PendingPath] = [:]
    private var waitingOrder: [String] = []
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Wraps each rating and keyword write into an image file itself (not RAW sidecar writes, not edit parameters).
    nonisolated let rewriteObserver: (any MetadataRewriteObserver)?
    private nonisolated let journal: MetadataWriteJournal?
    private let volumes: VolumeCheck
    private let progress: (@Sendable (Int) -> Void)?

    private let clock = ContinuousClock()
    /// When the journal was last saved, and whether the file holds anything.
    private var journalSavedAt: ContinuousClock.Instant?
    private var journalIsEmpty = true
    private var progressReportedAt: ContinuousClock.Instant?
    private var reportedCount = 0

    /// How often the journal is saved while writes are made, so a crash replays little that was written already.
    static let journalInterval: Duration = .seconds(1)
    /// How often `progress` hears the count at most.
    static let progressInterval: Duration = .milliseconds(250)

    init(service: MetadataService = .shared, rewriteObserver: (any MetadataRewriteObserver)? = nil,
         journal: MetadataWriteJournal? = nil, volumes: VolumeCheck = VolumeCheck(),
         progress: (@Sendable (Int) -> Void)? = nil) {
        self.init(writer: service, rewriteObserver: rewriteObserver, journal: journal, volumes: volumes,
                  progress: progress)
    }

    /// For tests: writes through any `MetadataWriting`. The journal's entries are the first writes to make.
    init(writer: any MetadataWriting, rewriteObserver: (any MetadataRewriteObserver)? = nil,
         journal: MetadataWriteJournal? = nil, volumes: VolumeCheck = VolumeCheck(),
         progress: (@Sendable (Int) -> Void)? = nil) {
        self.service = writer
        self.rewriteObserver = rewriteObserver
        self.journal = journal
        self.volumes = volumes
        self.progress = progress
        let replayed = journal?.load().map { Submission(path: $0.path, operation: $0.operation) } ?? []
        inbox = OSAllocatedUnfairLock(initialState: Inbox(submissions: replayed))
        journalIsEmpty = journal == nil // a file there may hold lines it couldn't read: the first save replaces it
    }

    // MARK: - API

    /// Queues rating and keyword writes. Returns immediately.
    ///
    /// An item for a JPG+RAW pair becomes two writes, the JPG and then the RAW's sidecar. Each is a path of
    /// its own here, so both are coalesced and ordered like any other write, and the sidecar write stays
    /// serialised with that RAW's edit-parameter writes.
    nonisolated func enqueue(_ items: [MetadataWriteItem]) {
        var submissions: [Submission] = []
        submissions.reserveCapacity(items.count)
        for item in items {
            let operation = Operation.metadata(rating: item.rating, keywords: item.keywords)
            submissions.append(Submission(path: item.path, operation: operation))
            if let raw = item.pairedRAWPath, !raw.isEmpty, raw != item.path {
                submissions.append(Submission(path: raw, operation: operation))
            }
        }
        submit(submissions)
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

    /// Runs `body` on the writer's queue, between two writes, so no metadata write can interleave with it. Exports
    /// replace a photo's file through this: a rating write in progress on the same file would otherwise swap the old
    /// pixels back in. (A write enqueued meanwhile runs afterwards, on the new file.)
    func runExclusively<T: Sendable>(_ body: @Sendable () -> T) -> T {
        body()
    }

    /// Starts writing what the journal held at launch (the writes a quit, crash or force quit left), ahead of anything
    /// enqueued since. Returns immediately. The app calls it once it has launched.
    nonisolated func resumeJournaledWrites() {
        let needsWakeUp = inbox.withLock { inbox in
            guard !inbox.submissions.isEmpty, !inbox.wakeUpScheduled else { return false }
            inbox.wakeUpScheduled = true
            return true
        }
        if needsWakeUp {
            Task(priority: .utility) { await self.takeInInbox() }
        }
    }

    /// Tries again the writes waiting for a volume that wasn't mounted (after a scan found the library's folder, say).
    /// Returns immediately.
    nonisolated func retryWaitingWrites() {
        Task(priority: .utility) { await self.requeueWaitingWrites() }
    }

    /// Adds to the journal what was enqueued but not taken in yet (the writer is busy with a write), so it's written at
    /// the next launch. For quitting, when the wait for the queue gives up; from any thread, without waiting for the
    /// writer.
    nonisolated func journalBeforeQuit() {
        guard let journal else { return }
        let submissions = inbox.withLock { $0.submissions }
        journal.saveAdding(submissions.map(\.entry))
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
        if !submissions.isEmpty {
            saveJournal() // before any of them is written
            reportProgress(now: true)
        }
        startDrainingIfNeeded()
    }

    // MARK: - Queue

    private func put(_ operation: Operation, for path: String) {
        if var aside = waiting[path] { // a newer write replaces one waiting for its volume
            aside.removeKind(of: operation)
            if aside.operations.isEmpty {
                waiting[path] = nil
                waitingOrder.removeAll { $0 == path }
            } else {
                waiting[path] = aside
            }
        }
        if pending[path] == nil { order.append(path) }
        if pending[path, default: PendingPath()].put(operation) { pendingCount += 1 }
    }

    private func nextOperation() -> Submission? {
        guard let path = order.first, var entry = pending[path], let operation = entry.popFirst() else { return nil }
        pendingCount -= 1
        if entry.operations.isEmpty {
            pending[path] = nil
            order.removeFirst()
        } else {
            pending[path] = entry
        }
        return Submission(path: path, operation: operation)
    }

    /// Puts a write for a file on a volume that isn't mounted aside, in the journal.
    private func setAside(_ submission: Submission) {
        if waiting[submission.path] == nil { waitingOrder.append(submission.path) }
        waiting[submission.path, default: PendingPath()].put(submission.operation)
    }

    private func requeueWaitingWrites() {
        guard !waitingOrder.isEmpty else { return }
        let paths = waitingOrder
        let aside = waiting
        waiting = [:]
        waitingOrder = []
        for path in paths {
            for operation in aside[path]?.operations ?? [] { put(operation, for: path) }
        }
        startDrainingIfNeeded()
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
            if !volumes.isVolumeAvailable(for: next.path) {
                setAside(next)
            } else {
                perform(next.operation, at: next.path)
            }
            if let savedAt = journalSavedAt, clock.now - savedAt >= Self.journalInterval { saveJournal() }
            reportProgress()
        }
        isDraining = false
        saveJournal() // nothing left, or only writes waiting for their volume
        reportProgress(now: true)
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Journal and progress

    /// Saves what's still to write: the queue, the writes waiting for their volume, and what's in the inbox.
    private func saveJournal() {
        guard let journal else { return }
        var entries: [MetadataWriteJournal.Entry] = []
        entries.reserveCapacity(pendingCount)
        for (paths, operations) in [(order, pending), (waitingOrder, waiting)] {
            for path in paths {
                for operation in operations[path]?.operations ?? [] {
                    entries.append(.init(path: path, operation: operation))
                }
            }
        }
        entries += inbox.withLock { $0.submissions }.map(\.entry)
        journalSavedAt = clock.now
        guard !(entries.isEmpty && journalIsEmpty) else { return }
        journal.save(entries)
        journalIsEmpty = entries.isEmpty
    }

    /// Tells `progress` how many writes are left: at most every `progressInterval`, unless `now`.
    private func reportProgress(now: Bool = false) {
        guard let progress, pendingCount != reportedCount else { return }
        let time = clock.now
        if !now, let reportedAt = progressReportedAt, time - reportedAt < Self.progressInterval { return }
        progressReportedAt = time
        reportedCount = pendingCount
        progress(pendingCount)
    }

    /// Synchronous file I/O, on this actor's serial queue.
    private func perform(_ operation: Operation, at path: String) {
        switch operation {
        case .metadata(let rating, let keywords):
            let service = self.service
            let write = { service.writeMetadata(rating: rating, keywords: keywords, toImageAt: path) }
            // A RAW's rating goes to its .xmp sidecar (see MetadataService.writeMetadata): the RAW itself is untouched.
            if let rewriteObserver,
               !FolderScanner.rawExtensions.contains((path as NSString).pathExtension.lowercased()) {
                rewriteObserver.rewritingMetadata(ofImageAt: path, write)
            } else {
                write()
            }
        case .setEditParameters(let params):
            service.writeEditParameters(params, forRAWAt: path)
        case .clearEditParameters:
            service.clearEditParameters(forRAWAt: path)
        }
    }
}
