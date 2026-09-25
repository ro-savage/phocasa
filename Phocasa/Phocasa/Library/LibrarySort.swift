import Foundation
import SwiftData

/// The one definition of photo order. The library, the bin and the grid are all kept in this order, and nothing else
/// sorts photos.
///
/// Photos are ordered by a key, today the file's creation date (a photo without one sorts as the oldest), newest
/// first by default. Every path that orders photos goes through here:
/// - fetching from the store: `fetch(where:in:)`;
/// - the key, for a model (`key(of:)`) or a plain value (`key(creationDate:)`), and `precedes(_:_:)`;
/// - where one photo goes in a sorted list: `insertionIndex(for:in:)`;
/// - merging many photos into a sorted list: `merge(_:into:_:)`;
/// - switching direction: `toggle()` and `reorderAfterToggle(_:)`.
struct LibrarySort: Equatable, Sendable {
    /// Newest first (the default), or oldest first.
    var newestFirst = true

    // MARK: - The key

    /// The sort key of a photo with this creation date. A photo without one sorts as the oldest, which is also where
    /// the store's sort puts a nil date in either direction.
    static func key(creationDate: Date?) -> Date {
        creationDate ?? .distantPast
    }

    /// The sort key of a stored photo (one model read).
    static func key(of photo: PhotoAsset) -> Date {
        key(creationDate: photo.creationDate)
    }

    /// Whether a photo with key `a` comes before one with key `b`. Photos with equal keys don't.
    func precedes(_ a: Date, _ b: Date) -> Bool {
        newestFirst ? a > b : a < b
    }

    // MARK: - Fetching

    /// The photos matching `predicate`, fetched from `context` in this order. The store sorts by the key: SQLite puts
    /// a nil date first ascending and last descending, which is where `key(creationDate:)` puts it.
    func fetch(where predicate: Predicate<PhotoAsset>, in context: ModelContext) -> [PhotoAsset] {
        let descriptor = FetchDescriptor<PhotoAsset>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.creationDate, order: newestFirst ? .reverse : .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Sorted lists

    /// Where `photo` goes in `photos` (in this order): after every photo that doesn't come after it. A binary search,
    /// so it reads O(log n) keys.
    func insertionIndex(for photo: PhotoAsset, in photos: [PhotoAsset]) -> Int {
        let key = Self.key(of: photo)
        var low = 0
        var high = photos.count
        while low < high {
            let mid = (low + high) / 2
            if precedes(key, Self.key(of: photos[mid])) { high = mid } else { low = mid + 1 }
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
        let keys = incoming.map { Self.key(of: $0.photo) }
        let positions = incoming.map { insertionIndex(for: $0.photo, in: photos) }
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
