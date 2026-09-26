import Foundation

/// How many rows the next chunk of a big main-context write takes, sized by time.
///
/// A chunk costs about `fixedCost + perRow × rows` (`ScaleChecks.testTagCostAtLibraryScale`, 150,000 photos):
/// - a main-context save costs about 1 µs for every photo the context holds, however few rows it writes (~140 ms with
///   150,000 loaded), and a change to a tag's links about 4 µs more for every photo the tag has (its whole relationship
///   is read and diffed: ~0.7 s for a tag on 150,000 photos);
/// - each row or link written costs 0.1–0.3 ms more.
///
/// The sizer measures the fixed part with a small probe chunk (at first, and again whenever a chunk's time strays from
/// what it predicted: a tag that grows as it is written), the per-row part from the chunk after a probe, and picks the
/// rows for a chunk of `target`: at least `shortestChunk`, with at least `rowTime` (and a third of the chunk) for rows
/// on top of the fixed part, and at most 200 ms unless the fixed part alone makes that too short to get anywhere. A
/// library of 150,000 photos gets rating chunks of about 210 ms of several hundred rows each; a small library gets
/// short ones. (A chunk sized to a frame, whatever the fixed part, shrinks to a row a save in a big library.)
struct WriteChunkSizer {
    /// Rows the next chunk takes.
    private(set) var rows: Int
    /// The most rows a chunk takes. Tests make it small.
    var maximumRows: Int {
        didSet { rows = min(rows, maximumRows) }
    }
    /// The part of a chunk's time that doesn't depend on its rows, once a chunk has been timed.
    private(set) var fixedCost: Duration?
    /// Time per row: a guess until a chunk after a probe has been timed.
    private(set) var perRow: Duration = .microseconds(150)
    /// Whether the next chunk is a probe (`probeRows` rows, to measure the fixed part).
    private var nextIsProbe = true
    private var lastProbe: (rows: Int, took: Duration)?

    static let probeRows = 8
    /// The fewest rows a chunk other than a probe takes, whatever the estimates say.
    static let minimumRows = 32
    static let longestChunk: Duration = .milliseconds(200)
    /// The shortest chunk worth making, and the time for rows in every chunk on top of the fixed part. 40 ms each for
    /// what the user just did; background work (`CaptureDateBackfill`) asks for less, so a small library's chunks stay
    /// within a frame.
    let shortestChunk: Duration
    let rowTime: Duration

    init(maximumRows: Int = 50_000, shortestChunk: Duration = .milliseconds(40), rowTime: Duration = .milliseconds(40)) {
        self.maximumRows = maximumRows
        self.shortestChunk = shortestChunk
        self.rowTime = rowTime
        rows = max(1, min(Self.probeRows, maximumRows))
    }

    /// What a chunk aims to take, for the fixed part measured.
    var target: Duration {
        let fixed = fixedCost ?? .zero
        let wanted = max(shortestChunk, fixed + max(rowTime, fixed / 2))
        return min(wanted, max(Self.longestChunk, fixed * 1.5))
    }

    /// Rows for a chunk of `target`, with the estimates so far (`fallback` before anything was timed).
    func steadyRows(fallback: Int) -> Int {
        guard let fixed = fixedCost else { return min(fallback, maximumRows) }
        let wanted = Int(((target - fixed) / perRow).rounded(.down))
        return max(1, min(max(wanted, Self.minimumRows), maximumRows))
    }

    /// Takes in how long a chunk of `done` rows took, and sizes the next one.
    mutating func record(rows done: Int, took elapsed: Duration) {
        guard done > 0 else { return }
        if nextIsProbe {
            nextIsProbe = false
            lastProbe = (done, elapsed)
            fixedCost = max(elapsed - perRow * done, .zero)
        } else if let probe = lastProbe {
            lastProbe = nil
            if done > probe.rows * 2 {
                let observed = max(elapsed - probe.took, .zero) / (done - probe.rows)
                perRow = min(max(observed, .microseconds(5)), .milliseconds(20))
                fixedCost = max(probe.took - perRow * probe.rows, .zero)
            }
        } else if let fixed = fixedCost {
            let predicted = fixed + perRow * done
            if elapsed > predicted * 1.3 || elapsed * 1.3 < predicted { nextIsProbe = true }
        }
        rows = nextIsProbe ? max(1, min(Self.probeRows, maximumRows)) : steadyRows(fallback: Self.minimumRows)
    }

    /// How long the run loop gets between two chunks: half the chunk's time, so events and drawing get at least a
    /// third of the main thread while a big write runs, and at least a few milliseconds.
    static func pause(after elapsed: Duration) -> Duration {
        max(elapsed / 2, .milliseconds(8))
    }
}
