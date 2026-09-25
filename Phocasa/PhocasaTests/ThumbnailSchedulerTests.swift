import XCTest
@testable import Phocasa

/// Thread-safe recorder shared between test bodies and scheduler work closures.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [Int] = []
    private var inFlight = 0
    private var _peak = 0

    var started: [Int] { lock.withLock { _started } }
    var peak: Int { lock.withLock { _peak } }

    func begin(_ key: Int) {
        lock.withLock {
            _started.append(key)
            inFlight += 1
            _peak = max(_peak, inFlight)
        }
    }

    func end() {
        lock.withLock { inFlight -= 1 }
    }
}

final class ThumbnailSchedulerTests: XCTestCase {

    /// Polls `condition` until it holds, failing the test after `timeout`.
    private func waitFor(
        _ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Concurrency bound

    func testNeverExceedsMaxConcurrent() async {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 3)
        let recorder = Recorder()

        let results = await withTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for key in 0..<20 {
                group.addTask {
                    await scheduler.value(for: key) {
                        recorder.begin(key)
                        usleep(5_000)
                        recorder.end()
                        return key * 10
                    }
                }
            }
            var values: [Int] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values
        }

        XCTAssertLessThanOrEqual(recorder.peak, 3)
        XCTAssertEqual(results.sorted(), (0..<20).map { $0 * 10 })
        XCTAssertEqual(recorder.started.count, 20)
    }

    // MARK: - Ordering

    func testRunsNewestRequestFirst() async throws {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 1)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)

        let blocker = Task {
            await scheduler.value(for: 0) {
                recorder.begin(0)
                gate.wait()
                recorder.end()
                return 0
            }
        }
        try await waitFor("key 0 to start") { recorder.started == [0] }

        // Enqueue 1…5 strictly in order: each must be pending before the next is requested.
        var tasks: [Task<Int?, Never>] = []
        for key in 1...5 {
            tasks.append(Task {
                await scheduler.value(for: key) {
                    recorder.begin(key)
                    recorder.end()
                    return key
                }
            })
            try await waitFor("key \(key) to be pending") { scheduler.pendingKeyCount == key }
        }

        gate.signal()
        _ = await blocker.value
        for task in tasks { _ = await task.value }

        XCTAssertEqual(recorder.started, [0, 5, 4, 3, 2, 1])
    }

    func testRerequestingAPendingKeyMovesItToTheFront() async throws {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 1)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)

        let blocker = Task {
            await scheduler.value(for: 0) { recorder.begin(0); gate.wait(); recorder.end(); return 0 }
        }
        try await waitFor("key 0 to start") { recorder.started == [0] }

        var tasks: [Task<Int?, Never>] = []
        for key in [1, 2, 3] {
            tasks.append(Task { await scheduler.value(for: key) { recorder.begin(key); recorder.end(); return key } })
            try await waitFor("key \(key) to be pending") { scheduler.pendingKeyCount == key }
        }
        // Key 1 scrolls back into view: it is now the newest request.
        tasks.append(Task { await scheduler.value(for: 1) { recorder.begin(1); recorder.end(); return 1 } })
        try await waitFor("second waiter on key 1") { scheduler.waiterCount(for: 1) == 2 }
        XCTAssertEqual(scheduler.pendingKeyCount, 3, "a re-request must not duplicate the pending key")

        gate.signal()
        _ = await blocker.value
        for task in tasks { _ = await task.value }

        XCTAssertEqual(recorder.started, [0, 1, 3, 2])
    }

    // MARK: - Cancellation

    func testCancelledBeforeStartNeverRuns() async throws {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 1)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)

        let blocker = Task {
            await scheduler.value(for: 0) { recorder.begin(0); gate.wait(); recorder.end(); return 0 }
        }
        try await waitFor("key 0 to start") { recorder.started == [0] }

        let cancelled = Task {
            await scheduler.value(for: 7) { recorder.begin(7); recorder.end(); return 7 }
        }
        try await waitFor("key 7 to be pending") { scheduler.pendingKeyCount == 1 }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(scheduler.pendingKeyCount, 0, "a key with no waiters left is dropped from the stack")

        gate.signal()
        _ = await blocker.value
        // A later request proves the scheduler pumped after the blocker finished.
        let later = await scheduler.value(for: 8) { recorder.begin(8); recorder.end(); return 8 }

        XCTAssertEqual(later, 8)
        XCTAssertEqual(recorder.started, [0, 8], "cancelled key 7 must never run")
    }

    func testAlreadyCancelledCallerGetsNilAndWorkNeverRuns() async {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 1)
        let recorder = Recorder()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await scheduler.value(for: 3) { recorder.begin(3); recorder.end(); return 3 }
        }
        let result = await task.value

        XCTAssertNil(result)
        let later = await scheduler.value(for: 4) { recorder.begin(4); recorder.end(); return 4 }
        XCTAssertEqual(later, 4)
        XCTAssertEqual(recorder.started, [4])
        XCTAssertEqual(scheduler.pendingKeyCount, 0)
    }

    func testCancellingAfterStartResumesTheCallerAndFreesTheSlotWhenWorkEnds() async throws {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 1)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)

        let task = Task {
            await scheduler.value(for: 1) { recorder.begin(1); gate.wait(); recorder.end(); return 1 }
        }
        try await waitFor("key 1 to start") { recorder.started == [1] }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "a cancelled caller is resumed without waiting for running work")

        gate.signal()
        let later = await scheduler.value(for: 2) { recorder.begin(2); recorder.end(); return 2 }
        XCTAssertEqual(later, 2)
        XCTAssertEqual(recorder.started, [1, 2])
    }

    // MARK: - De-duplication

    func testSameKeySharesOneExecution() async throws {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 2)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)

        let first = Task {
            await scheduler.value(for: 1) { recorder.begin(1); gate.wait(); recorder.end(); return 42 }
        }
        try await waitFor("key 1 to start") { recorder.started == [1] }
        let second = Task {
            await scheduler.value(for: 1) { recorder.begin(1); recorder.end(); return -1 }
        }
        try await waitFor("second waiter") { scheduler.waiterCount(for: 1) == 2 }

        gate.signal()
        let a = await first.value
        let b = await second.value

        XCTAssertEqual(a, 42)
        XCTAssertEqual(b, 42)
        XCTAssertEqual(recorder.started, [1], "the work must run once")
    }

    func testSameKeySharesOneExecutionWhilePending() async throws {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 1)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)

        let blocker = Task {
            await scheduler.value(for: 0) { recorder.begin(0); gate.wait(); recorder.end(); return 0 }
        }
        try await waitFor("key 0 to start") { recorder.started == [0] }
        let callers = (0..<3).map { _ in
            Task { await scheduler.value(for: 5) { recorder.begin(5); recorder.end(); return 5 } }
        }
        try await waitFor("three waiters on key 5") { scheduler.waiterCount(for: 5) == 3 }

        gate.signal()
        _ = await blocker.value
        for caller in callers {
            let value = await caller.value
            XCTAssertEqual(value, 5)
        }
        XCTAssertEqual(recorder.started, [0, 5])
    }

    func testCancellingOneWaiterDoesNotCancelTheOther() async throws {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 1)
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)

        let blocker = Task {
            await scheduler.value(for: 0) { recorder.begin(0); gate.wait(); recorder.end(); return 0 }
        }
        try await waitFor("key 0 to start") { recorder.started == [0] }

        let kept = Task { await scheduler.value(for: 1) { recorder.begin(1); recorder.end(); return 11 } }
        let dropped = Task { await scheduler.value(for: 1) { recorder.begin(1); recorder.end(); return 11 } }
        try await waitFor("two waiters on key 1") { scheduler.waiterCount(for: 1) == 2 }

        dropped.cancel()
        let droppedResult = await dropped.value
        XCTAssertNil(droppedResult)
        XCTAssertEqual(scheduler.waiterCount(for: 1), 1)

        gate.signal()
        _ = await blocker.value
        let keptResult = await kept.value

        XCTAssertEqual(keptResult, 11)
        XCTAssertEqual(recorder.started, [0, 1])
    }

    func testNilResultIsDeliveredToEveryWaiter() async {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: 2)
        async let a = scheduler.value(for: 9) { nil }
        async let b = scheduler.value(for: 9) { nil }
        let results = await [a, b]
        XCTAssertEqual(results, [nil, nil])
    }
}

// MARK: - Benchmark (opt-in)

/// Fast-scroll simulation with CPU-bound synthetic "decodes". Skipped unless PHOCASA_BENCH=1:
///   TEST_RUNNER_PHOCASA_BENCH=1 xcodebuild ... test -only-testing:PhocasaTests/ThumbnailSchedulerBenchmarks
final class ThumbnailSchedulerBenchmarks: XCTestCase {

    private static let requestCount = 200
    private static let spacing: Duration = .microseconds(2500)
    private static let decodeCPUNanos: UInt64 = 80_000_000
    /// A grid cell further than this behind the newest request has scrolled away and is cancelled.
    private static let cancelDistance = 40

    /// Burns `nanos` of this thread's CPU time, so oversubscription stretches wall time like a real decode.
    private static func burnCPU(_ nanos: UInt64) {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var x: UInt64 = 1
        while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < nanos {
            for _ in 0..<1_000 { x = x &* 6364136223846793005 &+ 1442695040888963407 }
        }
        if x == 0 { print("") }
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Returns (last 20 done after the final request, everything done after the final request), in ms.
    @MainActor
    private func runScheduler(maxConcurrent: Int) async throws -> (Double, Double) {
        let scheduler = ThumbnailScheduler<Int, Int>(maxConcurrent: maxConcurrent)
        let clock = ContinuousClock()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<Self.requestCount {
            tasks.append(Task {
                _ = await scheduler.value(for: i) {
                    Self.burnCPU(Self.decodeCPUNanos)
                    return i
                }
            })
            if i >= Self.cancelDistance { tasks[i - Self.cancelDistance].cancel() }
            try await Task.sleep(for: Self.spacing)
        }
        let last = clock.now
        for task in tasks.suffix(20) { await task.value }
        let last20 = Self.ms(clock.now - last)
        for task in tasks { await task.value }
        return (last20, Self.ms(clock.now - last))
    }

    /// The pre-task-11 pattern: one block per request on an unbounded concurrent queue, no cancellation.
    @MainActor
    private func runUnboundedFIFO() async throws -> (Double, Double) {
        let queue = DispatchQueue(label: "bench.fifo", qos: .userInitiated, attributes: .concurrent)
        let clock = ContinuousClock()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<Self.requestCount {
            tasks.append(Task {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.async {
                        Self.burnCPU(Self.decodeCPUNanos)
                        continuation.resume()
                    }
                }
            })
            if i >= Self.cancelDistance { tasks[i - Self.cancelDistance].cancel() }
            try await Task.sleep(for: Self.spacing)
        }
        let last = clock.now
        for task in tasks.suffix(20) { await task.value }
        let last20 = Self.ms(clock.now - last)
        for task in tasks { await task.value }
        return (last20, Self.ms(clock.now - last))
    }

    @MainActor
    func testFastScrollLast20() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHOCASA_BENCH"] == "1",
                          "Set PHOCASA_BENCH=1 to run benchmarks")
        let workers = ProcessInfo.processInfo.activeProcessorCount
        var lifo: [(Double, Double)] = [], fifo: [(Double, Double)] = []
        for _ in 0..<3 {
            lifo.append(try await runScheduler(maxConcurrent: workers))
            fifo.append(try await runUnboundedFIFO())
        }
        let label = "BENCH|thumbScheduler|200 x 80ms CPU, 2.5ms apart, cancel >\(Self.cancelDistance) behind"
        print("\(label)|ThumbnailScheduler(maxConcurrent: \(workers)) last20_ms=\(String(format: "%.1f", Self.median(lifo.map(\.0))))|all_ms=\(String(format: "%.1f", Self.median(lifo.map(\.1))))|runs=3")
        print("\(label)|unbounded FIFO GCD (old) last20_ms=\(String(format: "%.1f", Self.median(fifo.map(\.0))))|all_ms=\(String(format: "%.1f", Self.median(fifo.map(\.1))))|runs=3")
        XCTAssertLessThanOrEqual(Self.median(lifo.map(\.0)), 300, "last 20 should be done within 300 ms")
    }
}
