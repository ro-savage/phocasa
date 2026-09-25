import SwiftData
import Foundation

// What the grid shows: the sidebar filters, the search text and the sort direction, plus the tag lists the sidebar and
// the search suggestions are built from. All of it works on the in-memory library.
extension LibraryStore {
    // MARK: - Filtering

    func applyFilter(_ filter: SidebarFilter, isShiftHeld: Bool = false) {
        if filter == .all {
            activeFilters.removeAll()
            viewingBin = false
            refreshVisiblePhotos()
            return
        }

        if filter == .bin {
            activeFilters = [.bin]
            viewingBin = true
            refreshVisiblePhotos()
            return
        }

        // Leaving bin mode
        if viewingBin {
            activeFilters.removeAll()
            viewingBin = false
        }

        if isShiftHeld {
            if activeFilters.contains(filter) {
                activeFilters.remove(filter)
            } else {
                activeFilters.insert(filter)
            }
        } else {
            // Auto-combine: replace within same category, keep different categories
            let newCategory = filter.category
            activeFilters = activeFilters.filter { $0.category != newCategory }
            activeFilters.insert(filter)
        }

        refreshVisiblePhotos()
    }

    /// Re-applies the active filters and the search text to the in-memory library.
    func applyCurrentFilter() {
        refreshVisiblePhotos()
    }

    /// Re-applies the search text (together with the active filters) to the in-memory library.
    func applySearch() {
        refreshVisiblePhotos()
    }

    var hasFileTypeFilter: Bool {
        activeFilters.contains(.rawOnly) || activeFilters.contains(.jpgOnly)
    }

    /// Categories, then tag names, containing the search text (case-insensitive); at most 10.
    var searchSuggestions: [String] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        var seen = Set<String>()
        var results: [String] = []

        for entry in categorySearchKeys {
            if entry.key.contains(query) && seen.insert(entry.category).inserted {
                results.append(entry.category)
            }
        }

        for entry in tagNameSearchKeys {
            if entry.key.contains(query) && seen.insert(entry.name).inserted {
                results.append(entry.name)
            }
        }

        return Array(results.prefix(10))
    }

    // MARK: - Sorting

    /// Switches between newest and oldest first in memory (see `LibrarySort.reorderAfterToggle(_:)`). Counts don't
    /// change, so only the grid is rebuilt.
    func toggleSortOrder() {
        sort.toggle()
        LibrarySort.reorderAfterToggle(&allPhotos)
        LibrarySort.reorderAfterToggle(&allFacts)
        LibrarySort.reorderAfterToggle(&binPhotos)
        LibrarySort.reorderAfterToggle(&binFacts)
        libraryVersion += 1
        binVersion += 1
        refreshVisiblePhotos()
    }

    // MARK: - Tag Lists

    /// `allTags` order: by category, then name (the same descriptors sort the fetch and in-memory inserts).
    static var tagSortOrder: [SortDescriptor<Tag>] {
        [SortDescriptor(\.category), SortDescriptor(\.name)]
    }

    /// Rebuilds everything derived from the tag list. `tags` must be sorted by `tagSortOrder`.
    /// `tagCategories` keeps its order until the next `sortTagCategories()`.
    func setTagLists(_ tags: [Tag]) {
        var byCategory: [String: [Tag]] = [:]
        var uncategorized: [Tag] = []
        var nameKeys: [(name: String, key: String)] = []
        nameKeys.reserveCapacity(tags.count)
        for tag in tags {
            let name = tag.name
            let category = tag.category
            if category.isEmpty {
                uncategorized.append(tag)
            } else {
                byCategory[category, default: []].append(tag)
            }
            nameKeys.append((name, name.lowercased()))
        }
        allTags = tags
        tagsByCategory = byCategory
        uncategorizedTags = uncategorized
        tagNameSearchKeys = nameKeys
    }

    /// Orders `tagCategories` by how many library photos have a tag in each (descending), then by
    /// name. Called after loads and after changes to tags or to which photos are in the library.
    func sortTagCategories() {
        let counts = libraryCounts.categories
        let sorted = tagsByCategory.keys.sorted { a, b in
            let countA = counts[a, default: 0]
            let countB = counts[b, default: 0]
            if countA != countB { return countA > countB }
            return a < b
        }
        if sorted != tagCategories { tagCategories = sorted }
        categorySearchKeys = sorted.map { ($0, $0.lowercased()) }
    }

    /// Adds a tag that was just created (or found) to the in-memory tag lists, without a fetch.
    /// The caller re-sorts `tagCategories` with `sortTagCategories()` once the counts are current.
    func refreshTagLists(newTag: Tag) {
        guard !allTags.contains(where: { $0.id == newTag.id }) else { return }
        var tags = allTags
        tags.append(newTag)
        tags.sort(using: Self.tagSortOrder)
        setTagLists(tags)
    }
}
