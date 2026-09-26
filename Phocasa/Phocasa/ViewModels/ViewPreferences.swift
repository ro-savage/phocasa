import Foundation

/// Where `ViewPreferences` keeps its values: `UserDefaults`, or memory.
protocol PreferenceStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

/// Preferences that last as long as the store: the test host's, so no test reads or changes the owner's.
final class InMemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// What the window remembers across launches: the sort order and the grid's zoom (its column count).
///
/// Not the sidebar filter, the search or the bin: a launch that opened on a filter or a search would look like photos
/// had gone missing, and a tag filter names tags a rescan or another app may have removed since. Every launch opens on
/// All Photos.
///
/// The user's library keeps them in the app's `UserDefaults`; the development library in a suite of its own, so
/// real-app checks don't change the owner's; the test host in memory, fresh for each view model.
struct ViewPreferences {
    static let sortNewestFirstKey = "sortNewestFirst"
    static let gridColumnsKey = "gridColumns"
    static let developmentSuiteName = "com.phocasa.app.development"

    /// The grid's column counts (zoom in: fewer). `PhotoLibraryViewModel.zoomIn()`/`zoomOut()` stay within them.
    static let columnRange = 2...20
    static let defaultColumns = 6

    let store: PreferenceStore

    /// The preferences for this launch's library (`LibraryLocation.current`).
    static func forLaunch(_ location: LibraryLocation = .current) -> ViewPreferences {
        switch location.store {
        case .inMemory:
            return ViewPreferences(store: InMemoryPreferenceStore())
        case .user:
            return ViewPreferences(store: UserDefaults.standard)
        case .development:
            return ViewPreferences(store: UserDefaults(suiteName: developmentSuiteName) ?? InMemoryPreferenceStore())
        }
    }

    /// Newest first unless the owner last chose oldest first.
    var sortNewestFirst: Bool {
        get { store.object(forKey: Self.sortNewestFirstKey) as? Bool ?? true }
        nonmutating set { store.set(newValue, forKey: Self.sortNewestFirstKey) }
    }

    /// The last column count, within `columnRange`.
    var gridColumns: Int {
        get {
            let stored = store.object(forKey: Self.gridColumnsKey) as? Int ?? Self.defaultColumns
            return min(max(stored, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        }
        nonmutating set { store.set(newValue, forKey: Self.gridColumnsKey) }
    }
}
