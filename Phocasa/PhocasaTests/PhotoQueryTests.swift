import XCTest
@testable import Phocasa

/// Pure tests for `PhotoQuery` / `PhotoFacts` / `FacetCounts`: no SwiftData involved.
final class PhotoQueryTests: XCTestCase {

    // MARK: - Helpers

    private let people = UUID()
    private let places = UUID()
    private let loose = UUID()

    /// Builds facts the way `PhotoFacts(photo)` would: the search key is the lowercased file name,
    /// tag names and tag categories joined with "\n".
    private func facts(
        _ name: String,
        rating: Int = 0,
        jpg: Bool = true,
        raw: Bool = false,
        tags: [(id: UUID, name: String, category: String)] = []
    ) -> PhotoFacts {
        var fields = [name.lowercased()]
        for tag in tags {
            fields.append(tag.name.lowercased())
            if !tag.category.isEmpty { fields.append(tag.category.lowercased()) }
        }
        return PhotoFacts(
            id: UUID(),
            rating: rating,
            hasJPG: jpg,
            hasRAW: raw,
            tagIDs: Set(tags.map(\.id)),
            tagCategories: Set(tags.map(\.category).filter { !$0.isEmpty }),
            searchKey: fields.joined(separator: "\n")
        )
    }

    private func matching(_ query: PhotoQuery, _ all: [PhotoFacts]) -> [UUID] {
        all.filter { query.matches($0) }.map(\.id)
    }

    // MARK: - Filters

    func testEmptyQueryMatchesEverything() {
        let all = [facts("a", rating: 0), facts("b", rating: 5, jpg: false, raw: true)]
        XCTAssertEqual(matching(PhotoQuery(), all), all.map(\.id))
    }

    func testRatingFiltersAreORWithinCategory() {
        let three = facts("three", rating: 3)
        let four = facts("four", rating: 4)
        let five = facts("five", rating: 5)
        let query = PhotoQuery(filters: [.rated(3), .rated(5)])

        XCTAssertEqual(matching(query, [three, four, five]), [three.id, five.id])
    }

    func testUnratedMatchesZeroOnly() {
        let zero = facts("zero", rating: 0)
        let one = facts("one", rating: 1)
        XCTAssertEqual(matching(PhotoQuery(filters: [.unrated]), [zero, one]), [zero.id])
        XCTAssertEqual(matching(PhotoQuery(filters: [.unrated, .rated(1)]), [zero, one]), [zero.id, one.id])
    }

    func testDifferentCategoriesAreANDed() {
        let threeJPG = facts("a", rating: 3, jpg: true, raw: false)
        let threeRAW = facts("b", rating: 3, jpg: false, raw: true)
        let fourJPG = facts("c", rating: 4, jpg: true, raw: false)
        let query = PhotoQuery(filters: [.rated(3), .jpgOnly])

        XCTAssertEqual(matching(query, [threeJPG, threeRAW, fourJPG]), [threeJPG.id])
    }

    func testFileTypeFiltersAreORWithinCategory() {
        let jpg = facts("jpg", jpg: true, raw: false)
        let raw = facts("raw", jpg: false, raw: true)
        let pair = facts("pair", jpg: true, raw: true)

        XCTAssertEqual(matching(PhotoQuery(filters: [.jpgOnly]), [jpg, raw, pair]), [jpg.id, pair.id])
        XCTAssertEqual(matching(PhotoQuery(filters: [.rawOnly]), [jpg, raw, pair]), [raw.id, pair.id])
        XCTAssertEqual(matching(PhotoQuery(filters: [.jpgOnly, .rawOnly]), [jpg, raw, pair]), [jpg.id, raw.id, pair.id])
    }

    func testSpecialFiltersNeverExclude() {
        let all = [facts("a", rating: 0), facts("b", rating: 4, jpg: false, raw: true)]
        XCTAssertEqual(matching(PhotoQuery(filters: [.all]), all), all.map(\.id))
        XCTAssertEqual(matching(PhotoQuery(filters: [.bin]), all), all.map(\.id))
        // A special filter doesn't form a group that could exclude photos alongside real filters.
        XCTAssertEqual(matching(PhotoQuery(filters: [.bin, .rated(4)]), all), [all[1].id])
    }

    func testTagAndTagCategoryFilters() {
        let alice = facts("a", tags: [(people, "alice", "people")])
        let paris = facts("b", tags: [(places, "paris", "places")])
        let untagged = facts("c")
        let all = [alice, paris, untagged]

        XCTAssertEqual(matching(PhotoQuery(filters: [.tag(people)]), all), [alice.id])
        XCTAssertEqual(matching(PhotoQuery(filters: [.tagCategory("places")]), all), [paris.id])
        // Tag and tag-category filters share one category, so they are ORed.
        XCTAssertEqual(matching(PhotoQuery(filters: [.tag(people), .tagCategory("places")]), all),
                       [alice.id, paris.id])
    }

    func testFilterCategories() {
        XCTAssertEqual(SidebarFilter.all.category, .special)
        XCTAssertEqual(SidebarFilter.bin.category, .special)
        XCTAssertEqual(SidebarFilter.unrated.category, .rating)
        XCTAssertEqual(SidebarFilter.rated(2).category, .rating)
        XCTAssertEqual(SidebarFilter.jpgOnly.category, .fileType)
        XCTAssertEqual(SidebarFilter.rawOnly.category, .fileType)
        XCTAssertEqual(SidebarFilter.tag(UUID()).category, .tag)
        XCTAssertEqual(SidebarFilter.tagCategory("x").category, .tag)
    }

    func testMatchesFiltersIgnoringCategory() {
        let threeRAW = facts("a", rating: 3, jpg: false, raw: true)
        let query = PhotoQuery(filters: [.rated(4), .rawOnly])

        XCTAssertFalse(query.matchesFilters(threeRAW))
        XCTAssertTrue(query.matchesFilters(threeRAW, ignoring: .rating))
        XCTAssertFalse(query.matchesFilters(threeRAW, ignoring: .fileType))
    }

    // MARK: - Search

    func testSearchMatchesFileNameTagNameAndCategoryCaseInsensitively() {
        let byName = facts("Sunset_Beach")
        let byTag = facts("IMG_1", tags: [(people, "Alice", "Family")])
        let other = facts("IMG_2")
        let all = [byName, byTag, other]

        XCTAssertEqual(matching(PhotoQuery(searchText: "sunset"), all), [byName.id])
        XCTAssertEqual(matching(PhotoQuery(searchText: "SUNSET"), all), [byName.id])
        XCTAssertEqual(matching(PhotoQuery(searchText: "aLiCe"), all), [byTag.id])
        XCTAssertEqual(matching(PhotoQuery(searchText: "family"), all), [byTag.id])
        XCTAssertEqual(matching(PhotoQuery(searchText: "img_"), all), [byTag.id, other.id])
        XCTAssertEqual(matching(PhotoQuery(searchText: ""), all), all.map(\.id))
    }

    func testSearchDoesNotMatchAcrossFieldBoundaries() {
        let photo = facts("ab", tags: [(loose, "cd", "")])
        XCTAssertFalse(PhotoQuery(searchText: "bc").matchesSearch(photo))
        XCTAssertFalse(PhotoQuery(searchText: "b\nc").matchesSearch(photo))
        XCTAssertTrue(PhotoQuery(searchText: "ab").matchesSearch(photo))
        XCTAssertTrue(PhotoQuery(searchText: "cd").matchesSearch(photo))
    }

    func testSearchAndFiltersCombine() {
        let a = facts("sunset", rating: 3)
        let b = facts("sunset", rating: 4)
        let c = facts("forest", rating: 3)
        let query = PhotoQuery(filters: [.rated(3)], searchText: "sun")

        XCTAssertEqual(matching(query, [a, b, c]), [a.id])
    }

    // MARK: - Facet counts

    func testFacetCountsWithoutFiltersArePlainCounts() {
        let all = [
            facts("a", rating: 0, jpg: true, raw: false, tags: [(people, "alice", "people")]),
            facts("b", rating: 3, jpg: false, raw: true, tags: [(people, "alice", "people"), (places, "paris", "places")]),
            facts("c", rating: 3, jpg: true, raw: true, tags: [(loose, "misc", "")]),
        ]

        let counts = PhotoQuery().facetCounts(over: all)

        XCTAssertEqual(counts.ratings, [0: 1, 3: 2])
        XCTAssertEqual(counts.tags, [people: 2, places: 1, loose: 1])
        XCTAssertEqual(counts.categories, ["people": 2, "places": 1])
        XCTAssertEqual(counts.jpg, 2)
        XCTAssertEqual(counts.raw, 2)
    }

    func testFacetCountsOfEmptyLibraryAreEmpty() {
        XCTAssertEqual(PhotoQuery().facetCounts(over: []), FacetCounts())
        XCTAssertEqual(PhotoQuery(filters: [.rated(3)]).facetCounts(over: []), FacetCounts())
    }

    func testFacetCountsExcludeOwnCategory() {
        let all = [
            facts("a", rating: 3, jpg: true, raw: false, tags: [(people, "alice", "people")]),
            facts("b", rating: 3, jpg: false, raw: true, tags: [(places, "paris", "places")]),
            facts("c", rating: 5, jpg: true, raw: true, tags: [(people, "alice", "people")]),
            facts("d", rating: 0, jpg: true, raw: false),
        ]

        let counts = PhotoQuery(filters: [.rated(3)]).facetCounts(over: all)

        // Rating counts ignore the rating filter: they cover every photo.
        XCTAssertEqual(counts.ratings, [3: 2, 5: 1, 0: 1])
        // Tag, category and file-type counts only cover the 3-star photos.
        XCTAssertEqual(counts.tags, [people: 1, places: 1])
        XCTAssertEqual(counts.categories, ["people": 1, "places": 1])
        XCTAssertEqual(counts.jpg, 1)
        XCTAssertEqual(counts.raw, 1)
    }

    func testFacetCountsWithFiltersInEveryCategory() {
        let all = [
            facts("a", rating: 3, jpg: true, raw: false, tags: [(people, "alice", "people")]),
            facts("b", rating: 3, jpg: false, raw: true, tags: [(people, "alice", "people")]),
            facts("c", rating: 4, jpg: true, raw: false, tags: [(people, "alice", "people")]),
            facts("d", rating: 3, jpg: true, raw: false, tags: [(places, "paris", "places")]),
        ]

        let counts = PhotoQuery(filters: [.rated(3), .jpgOnly, .tag(people)]).facetCounts(over: all)

        // Ratings: photos that are JPG and tagged people → a, c.
        XCTAssertEqual(counts.ratings, [3: 1, 4: 1])
        // Tags and categories: photos that are 3-star and JPG → a, d.
        XCTAssertEqual(counts.tags, [people: 1, places: 1])
        XCTAssertEqual(counts.categories, ["people": 1, "places": 1])
        // File types: photos that are 3-star and tagged people → a, b.
        XCTAssertEqual(counts.jpg, 1)
        XCTAssertEqual(counts.raw, 1)
    }

    func testCategoryCountedOncePerPhoto() {
        let second = UUID()
        let photo = facts("a", tags: [(people, "alice", "people"), (second, "bob", "people")])

        let counts = PhotoQuery().facetCounts(over: [photo])

        XCTAssertEqual(counts.categories, ["people": 1])
        XCTAssertEqual(counts.tags, [people: 1, second: 1])
    }

    func testFacetCountsIgnoreSearch() {
        let all = [facts("sunset", rating: 3), facts("forest", rating: 4)]

        XCTAssertEqual(PhotoQuery(searchText: "sunset").facetCounts(over: all),
                       PhotoQuery().facetCounts(over: all))
        XCTAssertEqual(PhotoQuery(filters: [.jpgOnly], searchText: "zzz").facetCounts(over: all),
                       PhotoQuery(filters: [.jpgOnly]).facetCounts(over: all))
    }

    func testSpecialFiltersGivePlainCounts() {
        let all = [facts("a", rating: 3), facts("b", rating: 4, jpg: false, raw: true)]
        XCTAssertEqual(PhotoQuery(filters: [.bin]).facetCounts(over: all), PhotoQuery().facetCounts(over: all))
        XCTAssertEqual(PhotoQuery(filters: [.all]).facetCounts(over: all), PhotoQuery().facetCounts(over: all))
    }

    func testSearchWithNonASCIIKeysBehavesLikeStringContains() {
        // Keys that aren't plain ASCII take the `String.contains` path, with its canonical equivalence.
        let decomposed = PhotoFacts(id: UUID(), rating: 0, hasJPG: true, hasRAW: false, tagIDs: [], tagCategories: [],
                                    searchKey: "cafe\u{301}")
        XCTAssertTrue(PhotoQuery(searchText: "caf\u{E9}").matchesSearch(decomposed))
        let crlf = PhotoFacts(id: UUID(), rating: 0, hasJPG: true, hasRAW: false, tagIDs: [], tagCategories: [],
                              searchKey: "a\r\nb")
        XCTAssertEqual(PhotoQuery(searchText: "a").matchesSearch(crlf), "a\r\nb".contains("a"))
        XCTAssertEqual(PhotoQuery(searchText: "b").matchesSearch(crlf), "a\r\nb".contains("b"))
    }

    func testSearchAgreesWithStringContains() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["a", "b", "c", "_", "1", "é", "e\u{301}", "\u{301}", "ß", "\r", "\r\n", " ", "img", "ø", "🌅"]
        func random(_ length: ClosedRange<Int>) -> String {
            (0..<Int.random(in: length, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
        }
        for _ in 0..<2000 {
            let key = random(0...8).lowercased()
            let needle = random(1...3)
            let photo = PhotoFacts(id: UUID(), rating: 0, hasJPG: true, hasRAW: false, tagIDs: [], tagCategories: [],
                                   searchKey: key)
            XCTAssertEqual(PhotoQuery(searchText: needle).matchesSearch(photo), key.contains(needle.lowercased()),
                           "key \(Array(key.unicodeScalars)) needle \(Array(needle.unicodeScalars))")
        }
    }

    func testUpdateFacetCountsMatchesFullRecount() {
        var rng = SystemRandomNumberGenerator()
        let tagPool: [(id: UUID, name: String, category: String)] = [
            (UUID(), "alice", "people"), (UUID(), "paris", "places"), (UUID(), "misc", ""),
        ]
        func randomFacts() -> PhotoFacts {
            let jpg = Bool.random(using: &rng)
            return facts("p", rating: Int.random(in: 0...5, using: &rng), jpg: jpg,
                         raw: !jpg || Bool.random(using: &rng),
                         tags: tagPool.filter { _ in Bool.random(using: &rng) })
        }
        let queries = [
            PhotoQuery(), PhotoQuery(filters: [.rated(3)]), PhotoQuery(filters: [.jpgOnly, .tag(tagPool[0].id)]),
            PhotoQuery(filters: [.unrated, .rawOnly, .tagCategory("places")]), PhotoQuery(filters: [.bin]),
        ]
        for query in queries {
            var all = (0..<30).map { _ in randomFacts() }
            var counts = query.facetCounts(over: all)
            for _ in 0..<200 {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0 where !all.isEmpty: // change one photo
                    let i = Int.random(in: all.indices, using: &rng)
                    let old = all[i]
                    var new = randomFacts()
                    new = PhotoFacts(id: old.id, rating: new.rating, hasJPG: new.hasJPG, hasRAW: new.hasRAW,
                                     tagIDs: new.tagIDs, tagCategories: new.tagCategories, searchKey: new.searchKey)
                    all[i] = new
                    query.updateFacetCounts(&counts, replacing: old, with: new)
                case 1 where !all.isEmpty: // remove one photo
                    let old = all.remove(at: Int.random(in: all.indices, using: &rng))
                    query.updateFacetCounts(&counts, replacing: old, with: nil)
                default: // add one photo
                    let new = randomFacts()
                    all.append(new)
                    query.updateFacetCounts(&counts, replacing: nil, with: new)
                }
                XCTAssertEqual(counts, query.facetCounts(over: all), "\(query.filters)")
            }
        }
    }

    // MARK: - Matching indices

    func testMatchingIndicesKeepOrder() {
        let all = [facts("a", rating: 3), facts("b", rating: 1), facts("c", rating: 3), facts("d", rating: 3)]
        XCTAssertEqual(PhotoQuery(filters: [.rated(3)]).matchingIndices(in: all), [0, 2, 3])
        XCTAssertEqual(PhotoQuery().matchingIndices(in: all), [0, 1, 2, 3])
    }

    // MARK: - Reference implementation (randomised)

    /// The pre-task-10 algorithm (`applyActiveFilters` + `recomputeCrossFilterCounts`), transcribed onto facts.
    private func referenceFilter(_ filters: [SidebarFilter], _ all: [PhotoFacts]) -> [PhotoFacts] {
        let real = filters.filter { $0.category != .special }
        guard !real.isEmpty else { return all }
        var filtered = all
        for (_, group) in Dictionary(grouping: real, by: \.category) {
            filtered = filtered.filter { photo in group.contains { $0.matches(photo) } }
        }
        return filtered
    }

    private func referenceCounts(_ filters: Set<SidebarFilter>, _ all: [PhotoFacts]) -> FacetCounts {
        let list = Array(filters)
        var counts = FacetCounts()
        for photo in referenceFilter(list.filter { $0.category != .rating }, all) {
            counts.ratings[photo.rating, default: 0] += 1
        }
        for photo in referenceFilter(list.filter { $0.category != .tag }, all) {
            for id in photo.tagIDs { counts.tags[id, default: 0] += 1 }
            for category in photo.tagCategories { counts.categories[category, default: 0] += 1 }
        }
        for photo in referenceFilter(list.filter { $0.category != .fileType }, all) {
            if photo.hasJPG { counts.jpg += 1 }
            if photo.hasRAW { counts.raw += 1 }
        }
        return counts
    }

    func testMatchesAndFacetCountsAgreeWithReferenceImplementation() {
        var rng = SystemRandomNumberGenerator()
        let tagPool: [(id: UUID, name: String, category: String)] = [
            (UUID(), "alice", "people"), (UUID(), "bob", "people"),
            (UUID(), "paris", "places"), (UUID(), "rome", "places"),
            (UUID(), "misc", ""),
        ]
        let categories = ["people", "places", "nothing"]

        for _ in 0..<200 {
            let all: [PhotoFacts] = (0..<Int.random(in: 0...40, using: &rng)).map { i in
                let jpg = Bool.random(using: &rng)
                let tags = tagPool.filter { _ in Int.random(in: 0..<3, using: &rng) == 0 }
                return facts("p\(i)", rating: Int.random(in: 0...5, using: &rng),
                             jpg: jpg, raw: !jpg || Bool.random(using: &rng), tags: tags)
            }
            var filters = Set<SidebarFilter>()
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                switch Int.random(in: 0..<7, using: &rng) {
                case 0: filters.insert(.unrated)
                case 1: filters.insert(.rated(Int.random(in: 1...5, using: &rng)))
                case 2: filters.insert(.jpgOnly)
                case 3: filters.insert(.rawOnly)
                case 4: filters.insert(.tag(tagPool.randomElement(using: &rng)!.id))
                case 5: filters.insert(.tagCategory(categories.randomElement(using: &rng)!))
                default: filters.insert(.bin)
                }
            }
            let query = PhotoQuery(filters: filters)

            XCTAssertEqual(matching(query, all), referenceFilter(Array(filters), all).map(\.id), "\(filters)")
            XCTAssertEqual(query.matchingIndices(in: all).map { all[$0].id }, matching(query, all), "\(filters)")
            XCTAssertEqual(query.facetCounts(over: all), referenceCounts(filters, all), "\(filters)")
        }
    }
}
