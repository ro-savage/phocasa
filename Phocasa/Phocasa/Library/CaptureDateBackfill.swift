import Foundation
import SwiftData
import os

/// Capture dates for rows stored before Phocasa read them, after launch (`LibraryStore.backfillCaptureDates()`).
///
/// 1. Off the main actor: find the rows with no capture date, and read their files, concurrently, at utility priority.
/// 2. Off the main actor: plan the new order of every row (`LibrarySort.ranks(of:)`), from plain values.
/// 3. On the main context, because a background context must never change a row the main context holds
///    (CLAUDE.md): write the dates in chunks of about 12 ms each, saving each one and leaving the run loop as long again
///    between them.
/// 4. On the main actor, once: put the library and the bin in the new order in memory (`LibrarySort.reorder`), with
///    no model reads and no reload.
///
/// Files without a capture date (or that can't be read: missing, empty, not an image) are read again on each launch,
/// in the background, and nothing is written for them. A "checked" attribute would avoid the re-reads, but every
/// attribute costs every fetch and save: a second one measured +4% on the library's fetch-bound benchmarks.
enum CaptureDateBackfill {
    /// What one run did. For tests and benchmarks.
    struct Report: Sendable {
        /// Rows with no capture date (and a non-empty file).
        var candidates = 0
        /// Rows given a capture date.
        var datesWritten = 0
        /// Files read as images that have no capture date.
        var undated = 0
        /// Files that couldn't be read.
        var unreadable = 0
        /// Whether the library was put in the new order.
        var reordered = false
        /// Main-actor time of each write chunk.
        var chunkMainActorTimes: [Duration] = []
        /// Main-actor time of the re-order at the end.
        var reorderMainActorTime: Duration = .zero
        /// Off the main actor: finding the rows, reading their files, planning the order.
        var findTime: Duration = .zero
        var readTime: Duration = .zero
        var planTime: Duration = .zero
        /// From start to finish.
        var wallTime: Duration = .zero
    }

    /// A row without a capture date.
    struct Candidate: Sendable {
        let id: UUID
        let jpgPath: String?
        let rawPath: String?
    }

    /// Files read per unit of concurrent work.
    private static let readChunkSize = 64

    /// The rows to read, through a new context on `container`, off the main thread. It only reads. Rows whose files
    /// were empty at the last scan are left out: they can't hold a date (a scan that sees them grow updates
    /// `fileSize`, and the next backfill reads them).
    static func candidates(in container: ModelContainer) async -> [Candidate] {
        await offMain {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<PhotoAsset>(predicate: #Predicate { $0.captureDate == nil && $0.fileSize > 0 })
            descriptor.propertiesToFetch = [\.id, \.jpgPath, \.rawPath]
            let rows = (try? context.fetch(descriptor)) ?? []
            return rows.map { Candidate(id: $0.id, jpgPath: $0.jpgPath, rawPath: $0.rawPath) }
        }
    }

    /// Each candidate's capture date, in order, read across all cores off the main thread. A pair reads its JPG (as
    /// scans do), or its RAW when the JPG can't be read.
    static func read(_ candidates: [Candidate]) async -> [CaptureDate.Read] {
        await offMain {
            let chunkCount = (candidates.count + readChunkSize - 1) / readChunkSize
            let parts = OSAllocatedUnfairLock(initialState: [[CaptureDate.Read]](repeating: [], count: chunkCount))
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let range = (chunk * readChunkSize)..<min(candidates.count, (chunk + 1) * readChunkSize)
                let part = range.map { read(candidates[$0]) }
                parts.withLock { $0[chunk] = part }
            }
            return parts.withLock { $0 }.flatMap { $0 }
        }
    }

    private static func read(_ candidate: Candidate) -> CaptureDate.Read {
        var result = CaptureDate.Read.unreadable
        if let jpg = candidate.jpgPath { result = CaptureDate.read(from: jpg) }
        if result == .unreadable, let raw = candidate.rawPath { result = CaptureDate.read(from: raw) }
        return result
    }

    /// Every row's place in the order once `newDates` are written (`LibrarySort.ranks(of:)`), from a snapshot read
    /// through a new context on `container`, off the main thread.
    static func ranks(in container: ModelContainer, newDates: [UUID: Date]) async -> [UUID: Int] {
        await offMain {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<PhotoAsset>()
            descriptor.propertiesToFetch = [\.id, \.captureDate, \.creationDate]
            let rows = (try? context.fetch(descriptor)) ?? []
            let keys = rows.map { row in
                let id = row.id
                return (id: id, key: LibrarySort.key(captureDate: newDates[id] ?? row.captureDate,
                                                     creationDate: row.creationDate))
            }
            return LibrarySort.ranks(of: keys)
        }
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}

extension LibraryStore {
    /// State of the capture-date backfill, stored in `captureDates`.
    struct CaptureDateState {
        /// The backfill started after launch, while it runs.
        var task: Task<Void, Never>?
        /// What the last backfill did. For tests and benchmarks.
        var lastReport: CaptureDateBackfill.Report?
        /// The most rows one write chunk may take (tests make it small).
        var maxChunkRows = 1024
        /// How long after the launch scans the backfill waits before it starts, so it doesn't compete with the launch's
        /// thumbnail decodes. It doesn't start if the library is released meanwhile. Tests shorten it.
        var startDelay: Duration = .seconds(2)
        /// Test hook: called on the main actor after each write chunk is saved, with its index.
        var didApplyChunk: ((Int) -> Void)?
    }

    /// Main-actor time each write chunk aims at: chunks grow below 11 ms and shrink above 15 ms, so none takes much
    /// more than a frame (about 16 ms). With 10k photos loaded, a main-context save costs about 7 ms however few rows
    /// it writes (`setRating` pays it too), plus about 0.15 ms per row with its fetch, so chunks settle at about
    /// 25–40 rows there, and at more in smaller libraries.
    private static let captureDateChunkGrowBelow: Duration = .milliseconds(11)
    private static let captureDateChunkShrinkAbove: Duration = .milliseconds(15)

    /// After launch (`PhotoLibraryViewModel.setModelContext`): once the launch rescan, and any scan queued behind it,
    /// is done, and `captureDates.startDelay` later, fills in the capture dates of photos stored without one
    /// (`backfillCaptureDates()`).
    func backfillCaptureDatesAfterScans() {
        guard captureDates.task == nil else { return }
        let delay = captureDates.startDelay
        captureDates.task = Task { [weak self] in
            await self?.waitForScans()
            try? await Task.sleep(for: delay)
            guard let self else { return } // the window closed
            await self.waitForScans()
            await self.backfillCaptureDates()
            self.captureDates.task = nil
        }
    }

    /// Reads the capture dates of stored photos that have none, writes the ones found on the main context in short
    /// chunks, then puts the library and the bin in the new order once, in memory (see `CaptureDateBackfill`). Photos
    /// added or moved meanwhile keep their changes: each chunk looks its rows up by id, and the re-order merges in
    /// photos the plan didn't know. Until it ends, the lists keep the old order.
    @discardableResult
    func backfillCaptureDates() async -> CaptureDateBackfill.Report {
        let clock = ContinuousClock()
        let start = clock.now
        var report = CaptureDateBackfill.Report()
        guard let container = modelContext?.container else { return finishCaptureDateBackfill(report, start) }

        var phase = clock.now
        let candidates = await CaptureDateBackfill.candidates(in: container)
        report.findTime = clock.now - phase
        report.candidates = candidates.count
        guard !candidates.isEmpty else { return finishCaptureDateBackfill(report, start) }

        phase = clock.now
        let reads = await CaptureDateBackfill.read(candidates)
        report.readTime = clock.now - phase
        var found: [(id: UUID, date: Date)] = []
        for (candidate, read) in zip(candidates, reads) {
            switch read {
            case .date(let date): found.append((candidate.id, date))
            case .noDate: report.undated += 1
            case .unreadable: report.unreadable += 1
            }
        }
        guard !found.isEmpty else { return finishCaptureDateBackfill(report, start) }

        phase = clock.now
        let newDates = Dictionary(found.map { ($0.id, $0.date) }, uniquingKeysWith: { first, _ in first })
        let ranks = await CaptureDateBackfill.ranks(in: container, newDates: newDates)
        report.planTime = clock.now - phase

        var chunkRows = min(32, captureDates.maxChunkRows)
        var next = 0
        while next < found.count, let context = modelContext {
            let chunkStart = clock.now
            let end = min(next + chunkRows, found.count)
            report.datesWritten += applyCaptureDates(found[next..<end], in: context)
            let elapsed = clock.now - chunkStart
            report.chunkMainActorTimes.append(elapsed)
            captureDates.didApplyChunk?(report.chunkMainActorTimes.count - 1)
            next = end
            if elapsed < Self.captureDateChunkGrowBelow {
                chunkRows = min(max(chunkRows * 5 / 4, chunkRows + 1), captureDates.maxChunkRows)
            } else if elapsed > Self.captureDateChunkShrinkAbove {
                chunkRows = max(chunkRows * 3 / 4, 1)
            }
            // Sleep as long as the chunk took (not a yield): the run loop gets at least half the main actor to handle
            // events and draw while the backfill writes.
            if next < found.count { try? await Task.sleep(for: max(elapsed, .milliseconds(2))) }
        }

        if report.datesWritten > 0 {
            phase = clock.now
            (allPhotos, allFacts) = sort.reorder(allPhotos, allFacts, ranks: ranks)
            (binPhotos, binFacts) = sort.reorder(binPhotos, binFacts, ranks: ranks)
            libraryVersion += 1
            binVersion += 1
            refreshVisiblePhotos()
            report.reorderMainActorTime = clock.now - phase
            report.reordered = true
        }
        return finishCaptureDateBackfill(report, start)
    }

    /// Writes one chunk's dates into its rows (looked up by id: rows deleted since are skipped; the fetch also keeps a
    /// binned row's flag from being written back, spec §H5) and saves. A capture date already there is kept. Returns
    /// how many dates it wrote.
    private func applyCaptureDates(_ chunk: ArraySlice<(id: UUID, date: Date)>, in context: ModelContext) -> Int {
        let ids = chunk.map(\.id)
        let rows = (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let dates = Dictionary(chunk.map { ($0.id, $0.date) }, uniquingKeysWith: { first, _ in first })
        var written = 0
        for row in rows where row.captureDate == nil {
            guard let date = dates[row.id] else { continue }
            row.captureDate = date
            written += 1
        }
        if context.hasChanges { try? context.save() }
        return written
    }

    private func finishCaptureDateBackfill(_ report: CaptureDateBackfill.Report,
                                           _ start: ContinuousClock.Instant) -> CaptureDateBackfill.Report {
        var report = report
        report.wallTime = ContinuousClock.now - start
        captureDates.lastReport = report
        return report
    }
}
