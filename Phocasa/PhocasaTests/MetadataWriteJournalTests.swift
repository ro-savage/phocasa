import XCTest
import os
@testable import Phocasa

/// What `MetadataWriter` hasn't written yet is kept in a journal file next to the store, so writes still queued at quit
/// (the wait gives up after 5 s), at a crash or a force quit are made at the next launch. Every test uses a temp
/// journal and a fake writer; none touches the real library's journal.
@MainActor
final class MetadataWriteJournalTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
    }

    private var journalURL: URL { dir.appendingPathComponent("PendingMetadataWrites.jsonl") }

    private func item(_ path: String, _ rating: Int, _ keywords: [String] = []) -> MetadataWriteItem {
        MetadataWriteItem(path: path, rating: rating, keywords: keywords)
    }

    private func edits(_ exposure: Double) -> EditParameters {
        var params = EditParameters()
        params.exposure = exposure
        return params
    }

    /// Waits until `condition` holds, for up to 5 s.
    private func eventually(_ condition: () -> Bool, _ message: String) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail(message) }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - The file

    func testJournalRoundTrip() {
        let entries: [MetadataWriteJournal.Entry] = [
            .init(path: "/p/a.jpg", operation: .metadata(rating: 3, keywords: ["people:Ann", "Été"])),
            .init(path: "/p/a.arw", operation: .setEditParameters(edits(1.5))),
            .init(path: "/p/b.arw", operation: .clearEditParameters),
        ]
        MetadataWriteJournal(url: journalURL).save(entries)

        XCTAssertEqual(MetadataWriteJournal(url: journalURL).load(), entries)

        MetadataWriteJournal(url: journalURL).save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "nothing left to write: no file")
        XCTAssertEqual(MetadataWriteJournal(url: journalURL).load(), [])
    }

    /// A journal cut short (a crash as it was written, a disk that filled) keeps every entry written whole; a file of
    /// garbage gives none, and neither traps.
    func testTruncatedOrDamagedJournalIsReadSafely() throws {
        let entries: [MetadataWriteJournal.Entry] = [
            .init(path: "/p/a.jpg", operation: .metadata(rating: 1, keywords: [])),
            .init(path: "/p/b.jpg", operation: .metadata(rating: 2, keywords: ["x"])),
            .init(path: "/p/c.jpg", operation: .metadata(rating: 3, keywords: [])),
        ]
        MetadataWriteJournal(url: journalURL).save(entries)
        let data = try Data(contentsOf: journalURL)
        try data.prefix(data.count - 12).write(to: journalURL)

        XCTAssertEqual(MetadataWriteJournal(url: journalURL).load(), Array(entries.prefix(2)))

        try Data([0xFF, 0x00, 0x7B, 0x22, 0x0A, 0x5B]).write(to: journalURL)
        XCTAssertEqual(MetadataWriteJournal(url: journalURL).load(), [])
    }

    /// The journal's place follows the store: next to the user's library, next to the development library, and none
    /// for the test host's in-memory store.
    func testJournalLivesNextToTheStore() {
        let support = URL(fileURLWithPath: "/tmp/phocasa-journal-location/Application Support", isDirectory: true)
        let caches = URL(fileURLWithPath: "/tmp/phocasa-journal-location/Caches", isDirectory: true)
        let user = LibraryLocation.resolve(environment: [:], isDebugBuild: false, applicationSupport: support,
                                           caches: caches)
        XCTAssertEqual(user.metadataWriteJournalURL?.path, support.path + "/Phocasa/PendingMetadataWrites.jsonl")
        let development = LibraryLocation.resolve(environment: [LibraryLocation.developmentFlag: "1"],
                                                  isDebugBuild: true, applicationSupport: support, caches: caches)
        XCTAssertEqual(development.metadataWriteJournalURL?.path,
                       support.path + "/Phocasa-Development/PendingMetadataWrites.jsonl")
        let testHost = LibraryLocation.resolve(environment: [LibraryLocation.testConfigurationKey: "x"],
                                               applicationSupport: support, caches: caches)
        XCTAssertNil(testHost.metadataWriteJournalURL)
        XCTAssertNil(LibraryLocation.current.metadataWriteJournalURL, "the test host keeps no journal")
    }

    // MARK: - The writer keeps it

    /// Everything enqueued is in the journal before it's written, and the journal is gone once all of it is.
    func testWriterJournalsWhatItHasNotWrittenYet() async throws {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake, journal: MetadataWriteJournal(url: journalURL))
        // A write held in progress, so the three below are taken in together once it's done.
        let blocker = fake.holdNextWrite()
        writer.enqueue([item("/p/blocker.jpg", 0)])
        let blockerStarted = await fake.waitForWriteToStart()
        XCTAssertTrue(blockerStarted)
        writer.enqueue([item("/p/a.jpg", 1), item("/p/b.jpg", 2)])
        writer.enqueueEditParameters(edits(0.5), forRAWAt: "/p/c.arw")
        let gate = fake.holdNextWrite()
        blocker.signal()
        let started = await fake.waitForWriteToStart()
        XCTAssertTrue(started)

        XCTAssertEqual(MetadataWriteJournal(url: journalURL).load().map(\.path), ["/p/a.jpg", "/p/b.jpg", "/p/c.arw"],
                       "the write in progress stays in the journal until it's done")

        gate.signal()
        await writer.flush()
        XCTAssertEqual(fake.calls.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    /// At the next launch the journal is written first, in the order it was queued.
    func testReplayWritesTheJournalInOrder() async {
        MetadataWriteJournal(url: journalURL).save([
            .init(path: "/p/b.jpg", operation: .metadata(rating: 4, keywords: ["k"])),
            .init(path: "/p/a.jpg", operation: .metadata(rating: 2, keywords: [])),
            .init(path: "/p/c.arw", operation: .setEditParameters(edits(-1))),
        ])
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake, journal: MetadataWriteJournal(url: journalURL))

        writer.resumeJournaledWrites()
        await eventually({ fake.calls.count == 3 }, "the journal wasn't replayed")
        await writer.flush()

        XCTAssertEqual(fake.calls, [
            .metadata(path: "/p/b.jpg", rating: 4, keywords: ["k"]),
            .metadata(path: "/p/a.jpg", rating: 2, keywords: []),
            .editParameters(path: "/p/c.arw", exposure: -1),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    /// A newer write for a replayed path replaces the replayed one, as any newer payload replaces a waiting one.
    func testNewerWriteSupersedesAReplayedOne() async {
        MetadataWriteJournal(url: journalURL).save([
            .init(path: "/p/a.jpg", operation: .metadata(rating: 2, keywords: [])),
            .init(path: "/p/b.jpg", operation: .metadata(rating: 1, keywords: [])),
        ])
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake, journal: MetadataWriteJournal(url: journalURL))

        writer.enqueue([item("/p/a.jpg", 5)])
        writer.resumeJournaledWrites()
        await writer.flush()

        XCTAssertEqual(fake.calls, [
            .metadata(path: "/p/a.jpg", rating: 5, keywords: []),
            .metadata(path: "/p/b.jpg", rating: 1, keywords: []),
        ])
    }

    /// Quit gave up waiting while a write was stuck: what was enqueued meanwhile (still in the inbox, as the writer is
    /// busy) goes into the journal too.
    func testJournalBeforeQuitKeepsWhatIsStillWaiting() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake, journal: MetadataWriteJournal(url: journalURL))
        let gate = fake.holdNextWrite()
        writer.enqueue([item("/p/stuck.jpg", 1)])
        let started = await fake.waitForWriteToStart()
        XCTAssertTrue(started)
        writer.enqueueEditParameters(edits(2), forRAWAt: "/p/edited.arw") // the edit a quit saves

        writer.journalBeforeQuit()

        XCTAssertEqual(MetadataWriteJournal(url: journalURL).load().map(\.path), ["/p/stuck.jpg", "/p/edited.arw"])
        gate.signal()
        await writer.flush()
    }

    /// A write for a file on a drive that isn't connected isn't lost: it waits in the journal (for the next launch),
    /// the queue doesn't wait for it, and it's written once the drive is back.
    func testWritesForADriveThatIsNotConnectedWaitForIt() async throws {
        let volumes = dir.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        let away = volumes.appendingPathComponent("Away/2024/a.jpg").path
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake, journal: MetadataWriteJournal(url: journalURL),
                                    volumes: VolumeCheck(volumesDirectory: volumes.path))

        writer.enqueue([item(away, 4), item("/p/here.jpg", 1)])
        await writer.flush()

        XCTAssertEqual(fake.calls, [.metadata(path: "/p/here.jpg", rating: 1, keywords: [])])
        XCTAssertEqual(MetadataWriteJournal(url: journalURL).load().map(\.path), [away])

        try FileManager.default.createDirectory(at: volumes.appendingPathComponent("Away/2024"),
                                                withIntermediateDirectories: true)
        writer.retryWaitingWrites()
        await eventually({ fake.calls.count == 2 }, "the waiting write wasn't retried")
        await writer.flush()

        XCTAssertEqual(fake.calls.last, .metadata(path: away, rating: 4, keywords: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    /// The status bar's count: writes still to make, down to 0 once they're made.
    func testWriterReportsHowManyWritesAreLeft() async {
        let counts = OSAllocatedUnfairLock(initialState: [Int]())
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake, progress: { count in counts.withLock { $0.append(count) } })
        let gate = fake.holdNextWrite()
        writer.enqueue((0..<30).map { item("/p/\($0).jpg", 1) })
        let started = await fake.waitForWriteToStart()
        XCTAssertTrue(started)
        await eventually({ counts.withLock { $0.contains(30) } }, "30 left was never reported")

        gate.signal()
        await writer.flush()

        XCTAssertEqual(counts.withLock { $0.last }, 0)
    }

    // MARK: - Quit

    /// When quit stops waiting, the rest of the queue is journalled before the app goes.
    func testQuitThatTimesOutJournalsTheRest() async {
        for hangs in [true, false] {
            let events = OSAllocatedUnfairLock(initialState: [String]())
            let replied = expectation(description: "reply")
            AppDelegate.replyAfterFlushing(timeout: .milliseconds(100), flush: {
                if hangs { try? await Task.sleep(for: .seconds(30)) }
            }, journal: {
                events.withLock { $0.append("journal") }
            }, reply: {
                events.withLock { $0.append("reply") }
                replied.fulfill()
            })
            await fulfillment(of: [replied], timeout: 5)
            XCTAssertEqual(events.withLock { $0 }, hangs ? ["journal", "reply"] : ["reply"], "hangs: \(hangs)")
        }
    }
}
