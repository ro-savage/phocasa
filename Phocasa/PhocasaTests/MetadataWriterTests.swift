import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import Phocasa

/// A `MetadataWriting` that records calls instead of touching files. A write can be held on a
/// semaphore, and each write can take a fixed time, so tests can see queueing and concurrency.
final class RecordingMetadataService: MetadataWriting, @unchecked Sendable {
    enum Call: Equatable {
        case metadata(path: String, rating: Int, keywords: [String])
        case editParameters(path: String, exposure: Double)
        case clearEdits(path: String)

        var path: String {
            switch self {
            case .metadata(let path, _, _), .editParameters(let path, _), .clearEdits(let path): path
            }
        }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var finished = 0
    private var active = 0
    private var peak = 0
    private var gate: DispatchSemaphore?
    private let started = DispatchSemaphore(value: 0)
    private let writeDuration: TimeInterval

    init(writeDuration: TimeInterval = 0) {
        self.writeDuration = writeDuration
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Calls in the order they started.
    var calls: [Call] { locked { recorded } }
    var finishedCount: Int { locked { finished } }
    var peakConcurrency: Int { locked { peak } }

    /// The next write blocks until the returned semaphore is signalled.
    func holdNextWrite() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        locked { gate = semaphore }
        return semaphore
    }

    /// Waits, off the main thread, until one more write has started.
    func waitForWriteToStart(timeout: TimeInterval = 5) async -> Bool {
        let started = self.started
        return await Task.detached { Self.wait(for: started, timeout: timeout) }.value
    }

    private static func wait(for semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func writeMetadata(rating: Int, keywords: [String], toImageAt path: String) {
        record(.metadata(path: path, rating: rating, keywords: keywords))
    }

    func writeEditParameters(_ params: EditParameters, forRAWAt path: String) {
        record(.editParameters(path: path, exposure: params.exposure))
    }

    func clearEditParameters(forRAWAt path: String) {
        record(.clearEdits(path: path))
    }

    private func record(_ call: Call) {
        let hold: DispatchSemaphore? = locked {
            recorded.append(call)
            active += 1
            peak = max(peak, active)
            defer { gate = nil }
            return gate
        }
        started.signal()
        hold?.wait()
        if writeDuration > 0 { Thread.sleep(forTimeInterval: writeDuration) }
        locked {
            active -= 1
            finished += 1
        }
    }
}

@MainActor
final class MetadataWriterTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("phocasa-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        await MetadataWriter.shared.flush()
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
    }

    // MARK: - Helpers

    private func item(_ path: String, _ rating: Int, _ keywords: [String] = []) -> MetadataWriteItem {
        MetadataWriteItem(path: path, rating: rating, keywords: keywords)
    }

    /// Holds the writer busy with a write to `blocker.jpg`, so later enqueues pile up behind it.
    private func startBlockedWrite(_ writer: MetadataWriter, _ fake: RecordingMetadataService) async -> DispatchSemaphore {
        let gate = fake.holdNextWrite()
        writer.enqueue([item("blocker.jpg", 0)])
        let started = await fake.waitForWriteToStart()
        XCTAssertTrue(started, "the blocker write never started")
        return gate
    }

    private func makeJPEG(_ name: String, size: Int = 1024) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<16 {
            ctx.setFillColor(CGColor(red: CGFloat(i) / 16, green: 0.5, blue: CGFloat(15 - i) / 16, alpha: 1))
            ctx.fill(CGRect(x: i * size / 16, y: 0, width: size / 16, height: size))
        }
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeViewModel(with photos: [PhotoAsset]) throws -> (PhotoLibraryViewModel, ModelContainer) {
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        for photo in photos { context.insert(photo) }
        try context.save()
        let vm = PhotoLibraryViewModel()
        vm.setModelContext(context)
        return (vm, container)
    }

    // MARK: - Queueing (fake service)

    func testCoalescesToLatestPerPath() async throws {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)
        let gate = fake.holdNextWrite()
        writer.enqueue([item("a.jpg", 1)])
        let started = await fake.waitForWriteToStart()
        XCTAssertTrue(started)

        // The first write for a.jpg is in progress; these queue up behind it.
        for rating in [2, 3, 4, 5] { writer.enqueue([item("a.jpg", rating)]) }
        gate.signal()
        await writer.flush()

        let calls = fake.calls.filter { $0.path == "a.jpg" }
        XCTAssertLessThanOrEqual(calls.count, 2, "\(calls)")
        XCTAssertEqual(calls.first, .metadata(path: "a.jpg", rating: 1, keywords: []))
        XCTAssertEqual(calls.last, .metadata(path: "a.jpg", rating: 5, keywords: []))
    }

    func testPreservesOrderAcrossPaths() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)
        let gate = await startBlockedWrite(writer, fake)

        writer.enqueue([item("a.jpg", 1)])
        writer.enqueue([item("b.jpg", 1)])
        writer.enqueue([item("a.jpg", 2)])
        gate.signal()
        await writer.flush()

        // a's newer payload replaced the older one in place, so a still goes first.
        XCTAssertEqual(fake.calls, [
            .metadata(path: "blocker.jpg", rating: 0, keywords: []),
            .metadata(path: "a.jpg", rating: 2, keywords: []),
            .metadata(path: "b.jpg", rating: 1, keywords: []),
        ])
    }

    func testLaterItemInOneBatchReplacesEarlierOne() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)

        writer.enqueue([item("a.jpg", 1, ["x"]), item("b.jpg", 2), item("a.jpg", 3, ["y"])])
        await writer.flush()

        XCTAssertEqual(fake.calls, [
            .metadata(path: "a.jpg", rating: 3, keywords: ["y"]),
            .metadata(path: "b.jpg", rating: 2, keywords: []),
        ])
    }

    func testWritesAreSerial() async {
        let fake = RecordingMetadataService(writeDuration: 0.002)
        let writer = MetadataWriter(writer: fake)

        // Enqueue from many threads at once.
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    writer.enqueue((0..<5).map { MetadataWriteItem(path: "p\(t)-\($0).jpg", rating: t % 6, keywords: []) })
                }
                group.addTask {
                    writer.enqueueEditParameters(EditParameters(exposure: Double(t)), forRAWAt: "r\(t).cr3")
                }
            }
        }
        await writer.flush()

        XCTAssertEqual(fake.peakConcurrency, 1)
        XCTAssertEqual(fake.calls.count, 48)
        XCTAssertEqual(Set(fake.calls.map(\.path)).count, 48)
        XCTAssertEqual(fake.finishedCount, 48)
    }

    func testCallsFromOneThreadAreAppliedInCallOrder() async {
        let fake = RecordingMetadataService(writeDuration: 0.001)
        let writer = MetadataWriter(writer: fake)

        for i in 0..<50 { writer.enqueue([item("p\(i).jpg", i % 6)]) }
        await writer.flush()

        XCTAssertEqual(fake.calls.map(\.path), (0..<50).map { "p\($0).jpg" })
    }

    func testEditParametersAndRatingForSameSidecarAreSerialised() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)
        let gate = await startBlockedWrite(writer, fake)

        writer.enqueue([item("x.cr3", 3, ["k"])])
        writer.enqueueEditParameters(EditParameters(exposure: 1.5), forRAWAt: "x.cr3")
        gate.signal()
        await writer.flush()

        XCTAssertEqual(fake.calls.filter { $0.path == "x.cr3" }, [
            .metadata(path: "x.cr3", rating: 3, keywords: ["k"]),
            .editParameters(path: "x.cr3", exposure: 1.5),
        ])
        XCTAssertEqual(fake.peakConcurrency, 1)
    }

    func testEditParametersThenRatingForSameSidecarKeepOrder() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)
        let gate = await startBlockedWrite(writer, fake)

        writer.enqueueEditParameters(EditParameters(exposure: -1), forRAWAt: "x.cr3")
        writer.enqueue([item("x.cr3", 2)])
        writer.enqueueEditParameters(EditParameters(exposure: -2), forRAWAt: "x.cr3")
        gate.signal()
        await writer.flush()

        XCTAssertEqual(fake.calls.filter { $0.path == "x.cr3" }, [
            .editParameters(path: "x.cr3", exposure: -2),
            .metadata(path: "x.cr3", rating: 2, keywords: []),
        ])
    }

    func testNilEditParametersClearThem() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)

        writer.enqueueEditParameters(nil, forRAWAt: "x.cr3")
        await writer.flush()

        XCTAssertEqual(fake.calls, [.clearEdits(path: "x.cr3")])
    }

    func testLatestEditParametersWin() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)
        let gate = await startBlockedWrite(writer, fake)

        writer.enqueueEditParameters(EditParameters(exposure: 1), forRAWAt: "x.cr3")
        writer.enqueueEditParameters(EditParameters(exposure: 2), forRAWAt: "x.cr3")
        writer.enqueueEditParameters(nil, forRAWAt: "x.cr3")
        gate.signal()
        await writer.flush()

        XCTAssertEqual(fake.calls.filter { $0.path == "x.cr3" }, [.clearEdits(path: "x.cr3")])
    }

    func testFlushWaitsForPendingWrites() async {
        let fake = RecordingMetadataService(writeDuration: 0.02)
        let writer = MetadataWriter(writer: fake)

        writer.enqueue((0..<5).map { item("f\($0).jpg", 1) })
        await writer.flush()

        XCTAssertEqual(fake.finishedCount, 5)
    }

    func testFlushWaitsForWriteInProgress() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)
        let gate = await startBlockedWrite(writer, fake)

        let flushed = Task { await writer.flush() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.finishedCount, 0, "the held write hasn't finished yet")
        gate.signal()
        await flushed.value

        XCTAssertEqual(fake.finishedCount, 1)
    }

    func testFlushWhenIdleReturns() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)

        await writer.flush()
        writer.enqueue([item("a.jpg", 1)])
        await writer.flush()
        await writer.flush()

        XCTAssertEqual(fake.finishedCount, 1)
    }

    func testEmptyPathsAreSkipped() async {
        let fake = RecordingMetadataService()
        let writer = MetadataWriter(writer: fake)

        writer.enqueue([item("", 3)])
        writer.enqueueEditParameters(EditParameters(exposure: 1), forRAWAt: "")
        await writer.flush()

        XCTAssertEqual(fake.calls, [])
    }

    // MARK: - Real files (MetadataService)

    func testRealWritesEndWithLatestRating() async throws {
        let jpg = try makeJPEG("rapid.jpg")
        let writer = MetadataWriter()

        let ratings = Array(repeating: [1, 2, 3, 4, 5], count: 3).flatMap { $0 } + [2]
        for rating in ratings { writer.enqueue([item(jpg.path, rating)]) }
        await writer.flush()

        XCTAssertEqual(MetadataService.shared.readMetadata(from: jpg.path).rating, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["rapid.jpg"])
    }

    func testRealRatingAndEditsOnRAWOnlySidecarBothSurvive() async throws {
        let raw = dir.appendingPathComponent("IMG_9.CR3")
        try Data("fake raw bytes".utf8).write(to: raw)
        let writer = MetadataWriter()

        writer.enqueue([item(raw.path, 3, ["x"])])
        writer.enqueueEditParameters(EditParameters(exposure: 1.5), forRAWAt: raw.path)
        writer.enqueue([item(raw.path, 4, ["x", "y"])])
        await writer.flush()

        let service = MetadataService.shared
        XCTAssertEqual(service.readEditParameters(forRAWAt: raw.path)?.exposure, 1.5)
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 4)
        XCTAssertEqual(service.readMetadata(from: raw.path).keywords, ["x", "y"])

        writer.enqueueEditParameters(nil, forRAWAt: raw.path)
        await writer.flush()

        XCTAssertNil(service.readEditParameters(forRAWAt: raw.path))
        XCTAssertEqual(service.readMetadata(from: raw.path).rating, 4)
    }

}
