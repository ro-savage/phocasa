import Foundation

// Pure, in-memory filtering, search and sidebar counting over plain-value snapshots of photos.
//
// Reading a property of a SwiftData model costs about 0.8 µs, so filtering 10k models on every
// click cost hundreds of milliseconds (spec §A1–§A2). `PhotoFacts` copies out the few values that
// filtering, search and counting need, once per photo, and everything here works on those copies.

/// The group a sidebar filter belongs to. Filters in the same group are ORed; groups are ANDed.
enum FilterCategory: Hashable, Sendable {
    /// `.all` and `.bin`: they choose the view, and never exclude photos.
    case special
    case rating
    case fileType
    case tag
}

enum SidebarFilter: Hashable, Sendable {
    case all
    case unrated
    case rated(Int)
    case tag(UUID)
    case tagCategory(String)
    case bin
    case jpgOnly
    case rawOnly

    var category: FilterCategory {
        switch self {
        case .all, .bin: return .special
        case .unrated, .rated: return .rating
        case .jpgOnly, .rawOnly: return .fileType
        case .tag, .tagCategory: return .tag
        }
    }

    /// Whether this single filter accepts the photo. Special filters accept everything.
    func matches(_ facts: PhotoFacts) -> Bool {
        switch self {
        case .all, .bin: return true
        case .unrated: return facts.rating == 0
        case .rated(let stars): return facts.rating == stars
        case .jpgOnly: return facts.hasJPG
        case .rawOnly: return facts.hasRAW
        case .tag(let tagID): return facts.tagIDs.contains(tagID)
        case .tagCategory(let category): return facts.tagCategories.contains(category)
        }
    }
}

// MARK: - Facts

/// Plain-value snapshot of what filtering, search and counting read.
struct PhotoFacts: Equatable, Sendable {
    let id: UUID
    var rating: Int
    var hasJPG: Bool
    var hasRAW: Bool
    var tagIDs: Set<UUID>
    /// Non-empty categories of the photo's tags.
    var tagCategories: Set<String>
    /// Lowercased file name, tag names and tag categories, joined with "\n".
    var searchKey: String

    init(id: UUID, rating: Int, hasJPG: Bool, hasRAW: Bool,
         tagIDs: Set<UUID>, tagCategories: Set<String>, searchKey: String) {
        self.id = id
        self.rating = rating
        self.hasJPG = hasJPG
        self.hasRAW = hasRAW
        self.tagIDs = tagIDs
        self.tagCategories = tagCategories
        self.searchKey = searchKey
    }

    @MainActor init(_ photo: PhotoAsset) {
        var tags = TagFactsCache()
        self.init(photo, tags: &tags)
    }

    /// Builds facts reading each tag model at most once across calls that share `tags`.
    @MainActor init(_ photo: PhotoAsset, tags: inout TagFactsCache) {
        self.init(photo, rating: photo.rating, tags: photo.tags, tagFacts: &tags)
    }

    /// Facts of `photo` with the given rating and tags (its row's may not hold them yet: `LibraryStore.facts(of:)`).
    @MainActor init(_ photo: PhotoAsset, rating: Int, tags: [Tag], tagFacts: inout TagFactsCache) {
        var tagIDs = Set<UUID>()
        var tagCategories = Set<String>()
        var searchKey = photo.fileName.lowercased()
        for tag in tags {
            let facts = tagFacts.facts(for: tag)
            tagIDs.insert(facts.id)
            if !facts.category.isEmpty { tagCategories.insert(facts.category) }
            searchKey += facts.searchKeySuffix
        }
        self.init(
            id: photo.id,
            rating: rating,
            hasJPG: photo.jpgPath != nil,
            hasRAW: photo.rawPath != nil,
            tagIDs: tagIDs,
            tagCategories: tagCategories,
            searchKey: searchKey
        )
    }

    /// These facts with `tag` added (not already there), without reading any model.
    mutating func add(_ tag: TagFacts) {
        guard tagIDs.insert(tag.id).inserted else { return }
        if !tag.category.isEmpty { tagCategories.insert(tag.category) }
        searchKey += tag.searchKeySuffix
    }

    /// These facts with `tag` taken out, without reading any model. `tagsByID` must hold every one of the photo's
    /// tags: the search key is the lowercased file name followed by each tag's suffix, so the file name is what's left
    /// once every suffix's length is taken off. Returns false (the facts unchanged) when a tag is missing from it.
    mutating func remove(_ tag: TagFacts, tagsByID: [UUID: TagFacts]) -> Bool {
        guard tagIDs.contains(tag.id) else { return true }
        var suffixBytes = 0
        for id in tagIDs {
            guard let facts = tagsByID[id] else { return false }
            suffixBytes += facts.searchKeySuffix.utf8.count
        }
        let nameBytes = searchKey.utf8.count - suffixBytes
        guard nameBytes >= 0 else { return false }
        tagIDs.remove(tag.id)
        var key = String(decoding: searchKey.utf8.prefix(nameBytes), as: UTF8.self)
        var categories = Set<String>()
        for id in tagIDs {
            guard let facts = tagsByID[id] else { continue }
            key += facts.searchKeySuffix
            if !facts.category.isEmpty { categories.insert(facts.category) }
        }
        searchKey = key
        tagCategories = categories
        return true
    }
}

/// The values of one tag that photo facts need.
struct TagFacts: Equatable, Sendable {
    let id: UUID
    let category: String
    /// "\n" + lowercased name, plus "\n" + lowercased category when it isn't empty.
    let searchKeySuffix: String

    @MainActor init(_ tag: Tag) {
        let name = tag.name
        let category = tag.category
        id = tag.id
        self.category = category
        searchKeySuffix = category.isEmpty
            ? "\n" + name.lowercased()
            : "\n" + name.lowercased() + "\n" + category.lowercased()
    }
}

/// Caches `TagFacts` by object identity, so building facts for thousands of photos reads each tag
/// model once instead of once per photo. Entries retain their tag, so an identifier can't be reused.
@MainActor struct TagFactsCache {
    private var entries: [ObjectIdentifier: (tag: Tag, facts: TagFacts)] = [:]

    init(tags: [Tag] = []) {
        entries.reserveCapacity(tags.count)
        for tag in tags { entries[ObjectIdentifier(tag)] = (tag, TagFacts(tag)) }
    }

    mutating func facts(for tag: Tag) -> TagFacts {
        let key = ObjectIdentifier(tag)
        if let entry = entries[key] { return entry.facts }
        let facts = TagFacts(tag)
        entries[key] = (tag, facts)
        return facts
    }
}

// MARK: - Counts

struct FacetCounts: Equatable, Sendable {
    var ratings: [Int: Int] = [:]
    var tags: [UUID: Int] = [:]
    var categories: [String: Int] = [:]
    var jpg = 0
    var raw = 0
}

// MARK: - Query

struct PhotoQuery: Equatable, Sendable {
    var filters: Set<SidebarFilter> = []
    var searchText: String = ""

    /// True when nothing can exclude a photo: no rating, file-type or tag filter, and no search.
    var matchesEverything: Bool {
        searchText.isEmpty && filters.allSatisfy { $0.category == .special }
    }

    /// Filters AND search.
    func matches(_ facts: PhotoFacts) -> Bool {
        matchesFilters(facts) && matchesSearch(facts)
    }

    /// OR within a filter category, AND across categories. `ignoring` drops one category, which is
    /// how faceted counts are defined.
    func matchesFilters(_ facts: PhotoFacts, ignoring: FilterCategory? = nil) -> Bool {
        let groups = FilterGroups(filters)
        return (ignoring == .rating || groups.matchesRating(facts))
            && (ignoring == .fileType || groups.matchesFileType(facts))
            && (ignoring == .tag || groups.matchesTag(facts))
    }

    /// Case-insensitive `contains` over the file name, tag names and tag categories.
    func matchesSearch(_ facts: PhotoFacts) -> Bool {
        SearchNeedle(searchText).matches(facts)
    }

    /// Indices of the facts that match filters and search, in their original order.
    func matchingIndices(in facts: [PhotoFacts]) -> [Int] {
        let groups = FilterGroups(filters)
        let needle = SearchNeedle(searchText)
        var result: [Int] = []
        result.reserveCapacity(facts.count)
        for i in facts.indices where groups.matchesAll(facts[i]) && needle.matches(facts[i]) {
            result.append(i)
        }
        return result
    }

    /// Sidebar badge counts, in one pass. Search is ignored. With filters, each facet counts the
    /// photos that match every filter outside its own category: rating counts ignore rating filters,
    /// tag and category counts ignore tag filters, JPG/RAW counts ignore file-type filters.
    /// A category counts at most once per photo.
    func facetCounts(over facts: [PhotoFacts]) -> FacetCounts {
        let groups = FilterGroups(filters)
        var counts = FacetCounts()
        for i in facts.indices {
            groups.tally(facts[i], into: &counts, adding: true)
        }
        return counts
    }

    /// Updates counts from `facetCounts(over:)` (for this query) in O(1) when one photo changes:
    /// pass the facts it had (`old`, nil if it's new to the counted photos) and has now (`new`, nil
    /// if it left them). Entries that drop to zero are removed, as a full count wouldn't have them.
    func updateFacetCounts(_ counts: inout FacetCounts, replacing old: PhotoFacts?, with new: PhotoFacts?) {
        let groups = FilterGroups(filters)
        if let old { groups.tally(old, into: &counts, adding: false) }
        if let new { groups.tally(new, into: &counts, adding: true) }
    }
}

/// The query's filters, grouped by category once, so that checking a photo is a few set lookups.
private struct FilterGroups {
    private var ratings: Set<Int> = []
    private var hasRatingFilter = false
    private var wantsJPG = false
    private var wantsRAW = false
    private var tagIDs: [UUID] = []
    private var tagCategories: [String] = []
    private var hasTagFilter = false

    init(_ filters: Set<SidebarFilter>) {
        for filter in filters {
            switch filter {
            case .all, .bin: break
            case .unrated: ratings.insert(0); hasRatingFilter = true
            case .rated(let stars): ratings.insert(stars); hasRatingFilter = true
            case .jpgOnly: wantsJPG = true
            case .rawOnly: wantsRAW = true
            case .tag(let id): tagIDs.append(id); hasTagFilter = true
            case .tagCategory(let category): tagCategories.append(category); hasTagFilter = true
            }
        }
    }

    func matchesAll(_ facts: PhotoFacts) -> Bool {
        matchesRating(facts) && matchesFileType(facts) && matchesTag(facts)
    }

    /// Adds (or removes) one photo's contribution to faceted counts: each facet counts the photos
    /// that match every filter group except its own.
    func tally(_ photo: PhotoFacts, into counts: inout FacetCounts, adding: Bool) {
        let rating = matchesRating(photo)
        let fileType = matchesFileType(photo)
        let tag = matchesTag(photo)
        let delta = adding ? 1 : -1
        if fileType && tag {
            Self.bump(&counts.ratings, photo.rating, by: delta)
        }
        if rating && fileType {
            for id in photo.tagIDs { Self.bump(&counts.tags, id, by: delta) }
            for category in photo.tagCategories { Self.bump(&counts.categories, category, by: delta) }
        }
        if rating && tag {
            if photo.hasJPG { counts.jpg += delta }
            if photo.hasRAW { counts.raw += delta }
        }
    }

    private static func bump<Key: Hashable>(_ counts: inout [Key: Int], _ key: Key, by delta: Int) {
        if delta > 0 {
            counts[key, default: 0] += delta
        } else if let count = counts[key] {
            counts[key] = count + delta > 0 ? count + delta : nil
        }
    }

    func matchesRating(_ facts: PhotoFacts) -> Bool {
        !hasRatingFilter || ratings.contains(facts.rating)
    }

    func matchesFileType(_ facts: PhotoFacts) -> Bool {
        guard wantsJPG || wantsRAW else { return true }
        return (wantsJPG && facts.hasJPG) || (wantsRAW && facts.hasRAW)
    }

    func matchesTag(_ facts: PhotoFacts) -> Bool {
        guard hasTagFilter else { return true }
        // The filter names one or two tags; hashed lookups beat iterating the photo's sets.
        for id in tagIDs where facts.tagIDs.contains(id) { return true }
        for category in tagCategories where facts.tagCategories.contains(category) { return true }
        return false
    }
}

/// Lowercased search text. Fields in a search key are separated by "\n", so a needle that contains
/// "\n" could only match across two fields: it never matches (the search field is single-line).
private struct SearchNeedle {
    private let text: String?
    private let impossible: Bool
    /// The needle's bytes when it is ASCII without "\r"; enables the byte-search fast path.
    private let asciiBytes: [UInt8]?

    init(_ searchText: String) {
        let text = searchText.isEmpty ? nil : searchText.lowercased()
        self.text = text
        impossible = text?.contains("\n") ?? false
        if let text, text.utf8.count == text.utf16.count, !text.utf8.contains(0x0D) {
            asciiBytes = Array(text.utf8)
        } else {
            asciiBytes = nil
        }
    }

    func matches(_ facts: PhotoFacts) -> Bool {
        guard let text else { return true }
        if impossible { return false }
        if let asciiBytes, let found = Self.asciiContains(facts.searchKey, asciiBytes) {
            return found
        }
        return facts.searchKey.contains(text)
    }

    /// Byte search, used only when both strings are ASCII without "\r". Then every byte is one
    /// `Character` and no two spellings are canonically equivalent, so the result is exactly what
    /// `String.contains` returns, several times faster. Returns nil when the key doesn't qualify.
    private static func asciiContains(_ key: String, _ needle: [UInt8]) -> Bool? {
        guard key.utf8.count == key.utf16.count else { return nil } // non-ASCII (utf16.count is O(1) for ASCII)
        return key.utf8.withContiguousStorageIfAvailable { hay -> Bool? in
            guard let base = hay.baseAddress else { return needle.isEmpty }
            if memchr(base, 0x0D, hay.count) != nil { return nil }
            return needle.withUnsafeBufferPointer { memmem(base, hay.count, $0.baseAddress, $0.count) != nil }
        } ?? nil
    }
}
