import Foundation
import SwiftData
import os

extension PhotoAsset {
    /// Stores what a metadata read found about the photo's capture date. Scans call it when they insert a photo
    /// (`found.metadata` is nil when no read was attempted, and then nothing is recorded).
    func setCaptureDate(from metadata: MetadataService.PhotoMetadata?) {
        guard let metadata else { return }
        captureDate = metadata.captureDate
        captureDateChecked = metadata.captureDateChecked
    }
}

// MARK: - The backfill

/// Capture dates for rows stored before Phocasa read them, after launch (`LibraryStore.backfillCaptureDates()`).
///
/// 1. Off the main actor: find the rows with no capture date whose file hasn't been read (`captureDateChecked`), and
///    read their files, concurrently, at utility priority.
/// 2. Off the main actor: plan the new order of every row (`LibrarySort.ranks(of:)`), from plain values.
/// 3. On the main context, because a background context must never change a row the main context holds
///    (CLAUDE.md): write the dates in chunks sized to take about 8 ms each, saving each one and letting the run loop
///    run between them.
/// 4. On the main actor, once: put the library and the bin in the new order in memory (`LibrarySort.reorder`), with
///    no model reads and no reload.
///
/// A file that can't be read (missing, empty, not an image) isn't marked, so it is tried again on the next launch;
/// one read as an image without a capture date is marked, so it isn't.
enum CaptureDateBackfill {
    /// What one run did. For tests and benchmarks.
    struct Report: Sendable {
        /// Rows with no capture date whose file hadn't been read.
        var candidates = 0
        /// Rows given a capture date.
        var datesWritten = 0
        /// Files read as images that have no capture date (marked, so they aren't read again).
        var undated = 0
        /// Files that couldn't be read (tried again next time).
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

    /// A row whose capture date hasn't been read.
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
            var descriptor = FetchDescriptor<PhotoAsset>(
                predicate: #Predicate { $0.captureDate == nil && !$0.captureDateChecked && $0.fileSize > 0 })
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

    /// Main-actor time each write chunk aims at; chunks grow or shrink to stay near it. A frame is about 16 ms.
    private static let captureDateChunkTarget: Duration = .milliseconds(8)

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

    /// Reads the capture dates of stored photos that have none and whose files haven't been read, writes them on the
    /// main context in short chunks, then puts the library and the bin in the new order once, in memory (see
    /// `CaptureDateBackfill`). Photos added or moved meanwhile keep their changes: each chunk looks its rows up by id,
    /// and the re-order merges in photos the plan didn't know. Until it ends, the lists keep the old order.
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
        var found: [(id: UUID, read: CaptureDate.Read)] = []
        var newDates: [UUID: Date] = [:]
        for (candidate, read) in zip(candidates, reads) {
            switch read {
            case .date(let date):
                newDates[candidate.id] = date
                found.append((candidate.id, read))
            case .noDate:
                report.undated += 1
                found.append((candidate.id, read))
            case .unreadable:
                report.unreadable += 1
            }
        }
        guard !found.isEmpty else { return finishCaptureDateBackfill(report, start) }

        var ranks: [UUID: Int]?
        if !newDates.isEmpty {
            phase = clock.now
            ranks = await CaptureDateBackfill.ranks(in: container, newDates: newDates)
            report.planTime = clock.now - phase
        }

        var chunkRows = min(64, captureDates.maxChunkRows)
        var next = 0
        while next < found.count, let context = modelContext {
            let chunkStart = clock.now
            let end = min(next + chunkRows, found.count)
            report.datesWritten += applyCaptureDates(found[next..<end], in: context)
            let elapsed = clock.now - chunkStart
            report.chunkMainActorTimes.append(elapsed)
            captureDates.didApplyChunk?(report.chunkMainActorTimes.count - 1)
            next = end
            if elapsed < Self.captureDateChunkTarget / 2 {
                chunkRows = min(chunkRows * 2, captureDates.maxChunkRows)
            } else if elapsed > Self.captureDateChunkTarget {
                chunkRows = max(chunkRows / 2, 1)
            }
            // A short sleep, not a yield: the run loop gets to handle events and draw between chunks.
            if next < found.count { try? await Task.sleep(for: .milliseconds(1)) }
        }

        if let ranks, report.datesWritten > 0 {
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

    /// Writes one chunk's results into its rows (looked up by id: rows deleted since are skipped) and saves. A capture
    /// date already there is kept. Returns how many dates it wrote.
    private func applyCaptureDates(_ chunk: ArraySlice<(id: UUID, read: CaptureDate.Read)>,
                                   in context: ModelContext) -> Int {
        let ids = chunk.map(\.id)
        let rows = (try? context.fetch(FetchDescriptor<PhotoAsset>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let reads = Dictionary(chunk.map { ($0.id, $0.read) }, uniquingKeysWith: { first, _ in first })
        var written = 0
        for row in rows {
            guard let read = reads[row.id] else { continue }
            if case .date(let date) = read, row.captureDate == nil {
                row.captureDate = date
                written += 1
            }
            if !row.captureDateChecked { row.captureDateChecked = true }
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
