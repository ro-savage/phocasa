import Foundation
import SwiftData

/// The one definition of photo order. The library, the bin and the grid are all kept in this order, and nothing else
/// sorts photos.
///
/// Photos are ordered by capture date (EXIF `DateTimeOriginal`, `PhotoAsset.captureDate`), falling back to the file's
/// creation date for photos without one, newest first by default (user decision, wave 2 #6). A photo with neither
/// sorts as the oldest. Ties (burst shots share a capture second) are broken by the creation date. Every path that
/// orders photos goes through here:
/// - fetching from the store: `fetch(where:in:)`;
/// - the key, for a model (`key(of:)`, `sortKey(of:)`) or plain values (`key(captureDate:creationDate:)`), and
///   `precedes(_:_:)`;
/// - where one photo goes in a sorted list: `insertionIndex(for:in:)`;
/// - merging many photos into a sorted list: `merge(_:into:_:)`;
/// - putting a list back in order after capture dates changed: `ranks(of:)` and `reorder(_:_:ranks:)`;
/// - switching direction: `toggle()` and `reorderAfterToggle(_:)`.
struct LibrarySort: Equatable, Sendable {
    /// Newest first (the default), or oldest first.
    var newestFirst = true

    // MARK: - The key

    /// A photo's place in the order.
    struct Key: Comparable, Sendable {
        /// The capture date, or else the file creation date; `.distantPast` (the oldest) without either.
        var date: Date
        /// Breaks ties between equal dates (burst shots share a capture second): the file creation date, or
        /// `.distantPast`.
        var creationDate: Date

        static func < (a: Key, b: Key) -> Bool {
            a.date != b.date ? a.date < b.date : a.creationDate < b.creationDate
        }
    }

    static func key(captureDate: Date?, creationDate: Date?) -> Key {
        Key(date: captureDate ?? creationDate ?? .distantPast, creationDate: creationDate ?? .distantPast)
    }

    /// The sort date of a photo without a capture date.
    static func key(creationDate: Date?) -> Date {
        key(captureDate: nil, creationDate: creationDate).date
    }

    /// The sort date of a stored photo (`Key.date`: one or two model reads).
    static func key(of photo: PhotoAsset) -> Date {
        photo.captureDate ?? key(creationDate: photo.creationDate)
    }

    /// The full key of a stored photo (two model reads).
    static func sortKey(of photo: PhotoAsset) -> Key {
        key(captureDate: photo.captureDate, creationDate: photo.creationDate)
    }

    /// Whether a photo with sort date `a` comes before one with sort date `b`. Photos with equal dates don't.
    func precedes(_ a: Date, _ b: Date) -> Bool {
        newestFirst ? a > b : a < b
    }

    /// Whether a photo with key `a` comes before one with key `b`. Photos with equal keys don't.
    func precedes(_ a: Key, _ b: Key) -> Bool {
        newestFirst ? a > b : a < b
    }

    // MARK: - Fetching

    /// The photos matching `predicate`, fetched from `context` in this order. Safe on any context, on its own thread.
    ///
    /// SwiftData can't sort by `captureDate ?? creationDate`, so the store sorts by capture date, then creation date.
    /// That gives two runs, each in order: the photos with a capture date, and those without, which SQLite puts first
    /// ascending and last descending, sorted by creation date. `interleavingRuns(_:)` merges them in memory. When
    /// either run is empty (every photo has a capture date, or none has one yet) that costs about 14 model reads at 10k.
    func fetch(where predicate: Predicate<PhotoAsset>, in context: ModelContext) -> [PhotoAsset] {
        let order: SortOrder = newestFirst ? .reverse : .forward
        let descriptor = FetchDescriptor<PhotoAsset>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.captureDate, order: order), SortDescriptor(\.creationDate, order: order)]
        )
        return interleavingRuns((try? context.fetch(descriptor)) ?? [])
    }

    /// Merges the store's two runs (see `fetch(where:in:)`) into one list in this order.
    func interleavingRuns(_ photos: [PhotoAsset]) -> [PhotoAsset] {
        // Newest first, the dated run comes first; oldest first, the undated one. Binary search for where it ends.
        var low = 0
        var high = photos.count
        while low < high {
            let mid = (low + high) / 2
            if (photos[mid].captureDate != nil) == newestFirst { low = mid + 1 } else { high = mid }
        }
        guard low > 0, low < photos.count else { return photos }
        let first = photos[..<low]
        let second = photos[low...]
        if min(first.count, second.count) * Self.log2(photos.count) < photos.count {
            return mergeByInsertion(first, second)
        }
        return newestFirst ? mergeLinearly(dated: first, undated: second) : mergeLinearly(dated: second, undated: first)
    }

    /// A small run merged into a large one by binary search: O(k log n) model reads. On equal keys, `first` comes
    /// first.
    private func mergeByInsertion(_ first: ArraySlice<PhotoAsset>, _ second: ArraySlice<PhotoAsset>) -> [PhotoAsset] {
        let smallIsFirst = first.count <= second.count
        let small = smallIsFirst ? first : second
        let large = smallIsFirst ? second : first
        var merged: [PhotoAsset] = []
        merged.reserveCapacity(first.count + second.count)
        var next = large.startIndex
        for photo in small {
            let key = Self.sortKey(of: photo)
            // The first photo of `large` (from `next`) that this one goes before.
            var low = next
            var high = large.endIndex
            while low < high {
                let mid = (low + high) / 2
                let other = Self.sortKey(of: large[mid])
                let goesBefore = smallIsFirst ? !precedes(other, key) : precedes(key, other)
                if goesBefore { high = mid } else { low = mid + 1 }
            }
            merged.append(contentsOf: large[next..<low])
            merged.append(photo)
            next = low
        }
        merged.append(contentsOf: large[next...])
        return merged
    }

    /// Two large runs merged in one pass: one model read per photo, plus the creation dates of photos whose dates tie.
    /// On equal keys, dated photos come first.
    private func mergeLinearly(dated: ArraySlice<PhotoAsset>, undated: ArraySlice<PhotoAsset>) -> [PhotoAsset] {
        let datedDates = dated.map { $0.captureDate ?? .distantPast }
        let undatedDates = undated.map { Self.key(creationDate: $0.creationDate) }
        var merged: [PhotoAsset] = []
        merged.reserveCapacity(dated.count + undated.count)
        var i = 0
        var j = 0
        while i < datedDates.count && j < undatedDates.count {
            let datedFirst: Bool
            if datedDates[i] != undatedDates[j] {
                datedFirst = precedes(datedDates[i], undatedDates[j])
            } else {
                // An undated photo's key is its creation date twice.
                let datedKey = Key(date: datedDates[i], creationDate: Self.key(creationDate: dated[dated.startIndex + i].creationDate))
                datedFirst = !precedes(Key(date: undatedDates[j], creationDate: undatedDates[j]), datedKey)
            }
            if datedFirst {
                merged.append(dated[dated.startIndex + i])
                i += 1
            } else {
                merged.append(undated[undated.startIndex + j])
                j += 1
            }
        }
        merged.append(contentsOf: dated[(dated.startIndex + i)...])
        merged.append(contentsOf: undated[(undated.startIndex + j)...])
        return merged
    }

    private static func log2(_ n: Int) -> Int {
        n > 1 ? Int.bitWidth - (n - 1).leadingZeroBitCount : 1
    }

    // MARK: - Sorted lists

    /// Where `photo` goes in `photos` (in this order): after every photo that doesn't come after it. A binary search,
    /// so it reads O(log n) keys.
    func insertionIndex(for photo: PhotoAsset, in photos: [PhotoAsset]) -> Int {
        insertionIndex(forKey: Self.sortKey(of: photo), in: photos)
    }

    private func insertionIndex(forKey key: Key, in photos: [PhotoAsset]) -> Int {
        var low = 0
        var high = photos.count
        while low < high {
            let mid = (low + high) / 2
            if precedes(key, Self.sortKey(of: photos[mid])) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Merges `incoming` into `photos` (in this order) in one pass, keeping each photo's facts next to it. Each
    /// incoming photo goes where `insertionIndex(for:in:)` puts it; incoming photos at the same place keep this order,
    /// then their order in `incoming`.
    func merge(
        _ incoming: [(photo: PhotoAsset, facts: PhotoFacts)],
        into photos: [PhotoAsset], _ facts: [PhotoFacts]
    ) -> ([PhotoAsset], [PhotoFacts]) {
        guard !incoming.isEmpty else { return (photos, facts) }
        let keys = incoming.map { Self.sortKey(of: $0.photo) }
        let positions = keys.map { insertionIndex(forKey: $0, in: photos) }
        let order = incoming.indices.sorted { a, b in
            if positions[a] != positions[b] { return positions[a] < positions[b] }
            if keys[a] != keys[b] { return precedes(keys[a], keys[b]) }
            return a < b
        }

        var mergedPhotos: [PhotoAsset] = []
        var mergedFacts: [PhotoFacts] = []
        mergedPhotos.reserveCapacity(photos.count + incoming.count)
        mergedFacts.reserveCapacity(facts.count + incoming.count)
        var next = 0
        for item in order {
            while next < positions[item] {
                mergedPhotos.append(photos[next])
                mergedFacts.append(facts[next])
                next += 1
            }
            mergedPhotos.append(incoming[item].photo)
            mergedFacts.append(incoming[item].facts)
        }
        mergedPhotos.append(contentsOf: photos[next...])
        mergedFacts.append(contentsOf: facts[next...])
        return (mergedPhotos, mergedFacts)
    }

    // MARK: - Direction

    /// Switches between newest and oldest first. Lists kept in the old order are put in the new one with
    /// `reorderAfterToggle(_:)`.
    mutating func toggle() {
        newestFirst.toggle()
    }

    /// Puts a list that was in this order before `toggle()` into the new order. The key doesn't change, so that is a
    /// reversal; photos with equal keys may swap places (a reload puts them back in the store's order).
    static func reorderAfterToggle<Element>(_ list: inout [Element]) {
        list.reverse()
    }
}
