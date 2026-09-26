import XCTest
@testable import Phocasa

/// Collects what `MetadataWriter`'s posts say, from any thread.
private final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [MetadataWriteReport] = []

    func append(_ report: MetadataWriteReport) { lock.withLock { reports.append(report) } }
    var last: MetadataWriteReport? { lock.withLock { reports.last } }
    var count: Int { lock.withLock { reports.count } }
}

/// `MetadataWriter` keeps the writes that didn't reach their files, and those kept in a sidecar, for the status bar
/// (REL-4 #1): the latest per file and kind, bounded, cleared by a write that goes through, retried on request.
@MainActor
final class MetadataWriteProblemTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-problems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        await MetadataWriter.shared.flush()
        if let dir {
            let fm = FileManager.default
            for url in (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [] {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try? fm.removeItem(at: dir)
        }
        dir = nil
    }

    // MARK: - Helpers

    /// A path in the temp folder, so a skipped write is classified against a real, writable folder.
    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func item(_ path: String, _ rating: Int) -> MetadataWriteItem {
        MetadataWriteItem(path: path, rating: rating, keywords: [])
    }

    private func makeWriter(_ fake: RecordingMetadataService, log: ReportLog? = nil) -> MetadataWriter {
        guard let log else { return MetadataWriter(writer: fake) }
        let post: @Sendable (MetadataWriteReport) -> Void = { log.append($0) }
        return MetadataWriter(writer: fake, problems: post)
    }

    private func problem(_ path: String, _ issue: MetadataWriteProblem.Issue,
                         kind: MetadataWriteProblem.Kind = .ratingAndKeywords) -> MetadataWriteProblem {
        MetadataWriteProblem(path: path, operation: kind == .editParameters ? .setEditParameters(EditParameters())
                                                                            : .metadata(rating: 1, keywords: []),
                             issue: issue, date: Date())
    }

    // MARK: - Collecting

    func testAWriteThatFailsIsReportedAndOneThatGoesThroughClearsIt() async {
        let fake = RecordingMetadataService()
        let log = ReportLog()
        let writer = makeWriter(fake, log: log)
        let a = path("a.jpg")

        fake.setOutcome(.failed("The disk is full."), for: a)
        writer.enqueue([item(a, 3)])
        await writer.flush()

        let failures = await writer.report.failures.problems
        XCTAssertEqual(failures.map(\.path), [a])
        XCTAssertEqual(failures.first?.issue, .failed("The disk is full."))
        XCTAssertEqual(failures.first?.operation, .metadata(rating: 3, keywords: []))
        XCTAssertEqual(log.last?.failures.problems.map(\.path), [a], "the status bar heard it once the queue was done")

        fake.setOutcome(.writtenIntoFile, for: a)
        writer.enqueue([item(a, 4)])
        await writer.flush()

        let after = await writer.report
        XCTAssertTrue(after.failures.isEmpty)
        XCTAssertEqual(log.last, after)
    }

    func testOnlyTheLatestProblemPerFileIsKept() async {
        let fake = RecordingMetadataService()
        let writer = makeWriter(fake)
        let a = path("a.jpg")

        fake.setOutcome(.failed("first"), for: a)
        writer.enqueue([item(a, 1)])
        await writer.flush()
        fake.setOutcome(.failed("second"), for: a)
        writer.enqueue([item(a, 2)])
        await writer.flush()

        let failures = await writer.report.failures.problems
        XCTAssertEqual(failures.map(\.issue), [.failed("second")])
        XCTAssertEqual(failures.first?.operation, .metadata(rating: 2, keywords: []))
    }

    func testWritesKeptInASidecarAreListedApart() async {
        let fake = RecordingMetadataService()
        let writer = makeWriter(fake)
        let gif = path("a.gif")
        let ro = path("ro.jpg")
        fake.setOutcome(.keptInSidecar, for: gif)
        fake.setOutcome(.skippedReadOnly, for: ro)

        writer.enqueue([item(gif, 1), item(ro, 2)])
        await writer.flush()

        let report = await writer.report
        XCTAssertEqual(report.keptInSidecar.problems.map(\.path), [gif])
        XCTAssertEqual(report.failures.problems.map(\.path), [ro])
        XCTAssertEqual(report.failures.problems.first?.issue, .readOnly(.file))
        XCTAssertEqual(report.failedFileCount, 1)
        XCTAssertEqual(report.keptInSidecarFileCount, 1)

        // Once it goes into the file, it's no longer in a sidecar.
        fake.setOutcome(.writtenIntoFile, for: gif)
        writer.enqueue([item(gif, 3)])
        await writer.flush()
        let keptAfter = await writer.report.keptInSidecar
        XCTAssertTrue(keptAfter.isEmpty)
    }

    /// A RAW's rating write and its edit write share the sidecar, and each keeps its own problem.
    func testARAWsRatingAndEditProblemsAreKeptApart() async {
        let fake = RecordingMetadataService()
        let writer = makeWriter(fake)
        let raw = path("a.ARW")
        fake.setOutcome(.skippedUnparseableSidecar, for: raw)

        writer.enqueue([item(raw, 2)])
        writer.enqueueEditParameters(EditParameters(exposure: 1), forRAWAt: raw)
        await writer.flush()
        var report = await writer.report
        XCTAssertEqual(report.failures.problems.map(\.kind), [.ratingAndKeywords, .editParameters])
        XCTAssertEqual(report.failedFileCount, 1, "one file")

        // The edit goes through; the rating's problem stays.
        fake.setOutcome(.writtenToSidecar, for: raw)
        writer.enqueueEditParameters(EditParameters(exposure: 2), forRAWAt: raw)
        await writer.flush()
        report = await writer.report
        XCTAssertEqual(report.failures.problems.map(\.kind), [.ratingAndKeywords])
    }

    /// The outcome comes back through the thumbnail re-key hook, which wraps writes into image files.
    func testTheOutcomeOfAWriteInsideTheRewriteObserverIsKept() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake, rewriteObserver: RecordingRewriteObserver(service: fake))
        let a = path("a.jpg")
        fake.setOutcome(.skippedReadOnly, for: a)

        writer.enqueue([item(a, 1)])
        await writer.flush()

        let failures = await writer.report.failures.problems
        XCTAssertEqual(failures.map(\.issue), [.readOnly(.file)])
    }

    func testTheListIsBoundedAndDropsTheOldest() {
        var list = MetadataWriteProblemList()
        let total = MetadataWriteProblemList.limit + 10
        for i in 0..<total {
            let p = problem("/p/\(i).jpg", .failed("x"))
            XCTAssertTrue(list.set(p, for: p.key))
        }
        XCTAssertEqual(list.problems.count, MetadataWriteProblemList.limit)
        XCTAssertEqual(list.droppedCount, 10)
        XCTAssertEqual(list.problems.first?.path, "/p/10.jpg", "the oldest went first")
        XCTAssertFalse(list.contains(problem("/p/0.jpg", .failed("x")).key))

        // A newer problem for a listed file moves it to the end; a write that goes through clears it.
        let again = problem("/p/10.jpg", .failed("y"))
        list.set(again, for: again.key)
        XCTAssertEqual(list.problems.last, again)
        XCTAssertEqual(list.problems.count, MetadataWriteProblemList.limit)
        XCTAssertTrue(list.set(nil, for: again.key))
        XCTAssertFalse(list.set(nil, for: again.key), "nothing to clear")
        XCTAssertEqual(list.problems.count, MetadataWriteProblemList.limit - 1)
    }

    // MARK: - Retry, dismiss, clear

    func testRetryWritesTheEditThatFailedAgain() async {
        let fake = RecordingMetadataService()
        let writer = makeWriter(fake)
        let raw = path("a.ARW")
        fake.setOutcome(.skippedReadOnly, for: raw)
        writer.enqueueEditParameters(EditParameters(exposure: 2), forRAWAt: raw)
        await writer.flush()
        let failed = await writer.report.failures.problems
        XCTAssertEqual(failed.count, 1)

        fake.setOutcome(.writtenToSidecar, for: raw)
        await writer.retry(editsOf: failed)
        await writer.flush()

        XCTAssertEqual(fake.calls.last, .editParameters(path: raw, exposure: 2))
        let after = await writer.report.failures
        XCTAssertTrue(after.isEmpty)
    }

    /// An edit saved since the failure is waiting to be written: it wins, and the old one isn't written after it.
    func testRetryLeavesANewerEditAlone() async {
        let fake = RecordingMetadataService()
        let writer = makeWriter(fake)
        let raw = path("a.ARW")
        fake.setOutcome(.skippedReadOnly, for: raw)
        writer.enqueueEditParameters(EditParameters(exposure: 2), forRAWAt: raw)
        await writer.flush()
        let failed = await writer.report.failures.problems
        fake.setOutcome(.writtenToSidecar, for: raw)

        let gate = fake.holdNextWrite()
        writer.enqueue([item(path("blocker.jpg"), 0)])
        let started = await fake.waitForWriteToStart()
        XCTAssertTrue(started)
        writer.enqueueEditParameters(EditParameters(exposure: 3), forRAWAt: raw)
        let retry = Task { await writer.retry(editsOf: failed) }
        gate.signal()
        await retry.value
        await writer.flush()

        XCTAssertEqual(fake.calls.filter { $0.path == raw }.last, .editParameters(path: raw, exposure: 3))
        XCTAssertFalse(fake.calls.dropFirst(2).contains(.editParameters(path: raw, exposure: 2)))
    }

    func testRetryIgnoresRatingProblems() async {
        let fake = RecordingMetadataService()
        let writer = makeWriter(fake)
        await writer.retry(editsOf: [problem(path("a.jpg"), .failed("x"))])
        await writer.flush()
        XCTAssertEqual(fake.calls, [], "ratings are retried with the photo's current values, through enqueue")
    }

    func testDismissAndClear() async {
        let fake = RecordingMetadataService()
        let log = ReportLog()
        let writer = makeWriter(fake, log: log)
        let a = path("a.jpg"), b = path("b.jpg"), c = path("c.gif")
        fake.setOutcome(.failed("x"), for: a)
        fake.setOutcome(.failed("x"), for: b)
        fake.setOutcome(.keptInSidecar, for: c)
        writer.enqueue([item(a, 1), item(b, 1), item(c, 1)])
        await writer.flush()

        await writer.dismissProblems([MetadataWriteProblem.Key(path: a, kind: .ratingAndKeywords)])
        var report = await writer.report
        XCTAssertEqual(report.failures.problems.map(\.path), [b])
        XCTAssertEqual(log.last, report, "the status bar hears a dismissal at once")

        await writer.clearProblems()
        report = await writer.report
        XCTAssertEqual(report, MetadataWriteReport())
        XCTAssertEqual(log.last, report)
    }
}
