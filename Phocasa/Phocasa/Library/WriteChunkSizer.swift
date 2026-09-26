import Foundation

/// How many rows the next chunk of a big main-context write takes, sized by time.
///
/// A chunk costs about `fixedCost + perRow × rows` (`ScaleChecks.testTagCostAtLibraryScale`, 150,000 photos):
/// - a main-context save costs about 1 µs for every photo the context holds, however few rows it writes (~140 ms with
///   150,000 loaded), and a change to a tag's links about 4 µs more for every photo the tag has (its whole relationship
///   is read and diffed: ~0.7 s for a tag on 150,000 photos);
/// - each row or link written costs 0.1–0.3 ms more.
///
/// The per-row part varies little, so it starts at 0.2 ms and is only corrected, slowly and within 0.1–0.5 ms, by
/// chunks whose rows made up half their time or more (a slow save or a WAL checkpoint in a chunk made mostly of fixed
/// cost can't make rows look expensive and shrink the chunks to nothing). The fixed part varies a hundredfold, so
/// each chunk measures it again (its time less its rows'). The next chunk aims at `target`: at least `shortestChunk`,
/// with at least `rowTime` (and a third of the chunk) for rows on top of the fixed part, and at most 200 ms unless the
/// fixed part alone makes that too short to get anywhere. Chunks at most double from one to the next. A library of
/// 150,000 photos gets rating chunks of about 210 ms of several hundred rows each; a small library gets short ones. (A
/// chunk sized to a frame, whatever the fixed part, shrinks to a row a save in a big library.)
struct WriteChunkSizer {
    /// Rows the next chunk takes.
    private(set) var rows: Int
    /// The most rows a chunk takes. Tests make it small.
    var maximumRows: Int {
        didSet { rows = min(rows, maximumRows) }
    }
    /// The part of a chunk's time that doesn't depend on its rows, as the last chunk measured it.
    private(set) var fixedCost: Duration?
    /// Time per row.
    private(set) var perRow: Duration = .microseconds(200)

    /// The first chunk of a batch, which measures the fixed part.
    static let firstRows = 32
    static let longestChunk: Duration = .milliseconds(200)
    static let perRowRange: ClosedRange<Duration> = .microseconds(100) ... .microseconds(500)
    /// The shortest chunk worth making, and the time for rows in every chunk on top of the fixed part. 40 ms each for
    /// what the user just did; background work (`CaptureDateBackfill`) asks for less, so a small library's chunks stay
    /// within a frame.
    let shortestChunk: Duration
    let rowTime: Duration
    /// The rows' share of a chunk whose fixed part is long, as a fraction of that part: a half for what the user just
    /// did (fewer, longer chunks: done sooner), less for a scan's inserts, which run while the owner browses.
    let rowShare: Double

    init(maximumRows: Int = 50_000, shortestChunk: Duration = .milliseconds(40), rowTime: Duration = .milliseconds(40),
         rowShare: Double = 0.5) {
        self.maximumRows = maximumRows
        self.shortestChunk = shortestChunk
        self.rowTime = rowTime
        self.rowShare = rowShare
        rows = max(1, min(Self.firstRows, maximumRows))
    }

    /// What a chunk aims to take, for the fixed part measured.
    var target: Duration {
        let fixed = fixedCost ?? .zero
        let wanted = max(shortestChunk, fixed + max(rowTime, fixed * rowShare))
        return min(wanted, max(Self.longestChunk, fixed * (1 + rowShare)))
    }

    /// Rows for a chunk of `target`, with the estimates so far (`fallback` before anything was timed).
    func steadyRows(fallback: Int) -> Int {
        guard let fixed = fixedCost else { return min(fallback, maximumRows) }
        let wanted = Int(((target - fixed) / perRow).rounded(.down))
        return max(1, min(wanted, maximumRows))
    }

    /// The next chunk starts small again: a new batch of work, whose fixed part the last one's says little about (a
    /// tag change's is many times a rating's).
    mutating func startBatch() {
        rows = max(1, min(Self.firstRows, maximumRows))
    }

    /// Takes in how long a chunk of `done` rows took, and sizes the next one.
    mutating func record(rows done: Int, took elapsed: Duration) {
        guard done > 0 else { return }
        if let fixed = fixedCost, perRow * done >= elapsed / 2 {
            let observed = max(elapsed - fixed, .zero) / done
            perRow = (perRow * 3 + min(max(observed, Self.perRowRange.lowerBound), Self.perRowRange.upperBound)) / 4
        }
        fixedCost = max(elapsed - perRow * done, .zero)
        rows = max(1, min(steadyRows(fallback: Self.firstRows), 2 * done))
    }

    /// How long the run loop gets between two chunks: half the chunk's time, so events and drawing get at least a
    /// third of the main thread while a big write runs, and at least a few milliseconds.
    static func pause(after elapsed: Duration) -> Duration {
        max(elapsed / 2, .milliseconds(8))
    }
}
