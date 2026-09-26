import SwiftUI

/// Which photos in the grid are selected, and the grid's keyboard navigation. Positions come from the library's grid
/// (`LibraryStore.index(of:)`, O(1)), so nothing here scans the library.
@Observable @MainActor
final class SelectionModel {
    var selectedPhotos: Set<UUID> = []
    /// The photo clicked or moved to last: the anchor of range selections and keyboard navigation.
    var lastSelectedId: UUID?

    @ObservationIgnored let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
    }

    /// The selected photos that the grid shows, in grid order. O(k log k) for k selected photos.
    var selectedPhotosList: [PhotoAsset] {
        let photos = library.photos
        return selectedPhotos.compactMap { library.index(of: $0) }.sorted().map { photos[$0] }
    }

    func isPartOfMultiSelection(_ photo: PhotoAsset) -> Bool {
        selectedPhotos.count > 1 && selectedPhotos.contains(photo.id)
    }

    /// The photo Space/Return should open: the last-clicked photo if it is still selected and in the
    /// grid, otherwise the selected photo that comes first in the grid.
    var primarySelectedPhoto: PhotoAsset? {
        let photos = library.photos
        if let id = lastSelectedId, selectedPhotos.contains(id), let position = library.index(of: id) {
            return photos[position]
        }
        return selectedPhotos.compactMap { library.index(of: $0) }.min().map { photos[$0] }
    }

    // MARK: - Clicks

    func toggleSelection(for photo: PhotoAsset, addToSelection: Bool) {
        if addToSelection {
            if selectedPhotos.contains(photo.id) {
                selectedPhotos.remove(photo.id)
            } else {
                selectedPhotos.insert(photo.id)
            }
        } else {
            selectedPhotos = [photo.id]
        }
        lastSelectedId = photo.id
    }

    /// Selects only `id`, and makes it the anchor.
    func select(only id: UUID) {
        selectedPhotos = [id]
        lastSelectedId = id
    }

    func selectAll() {
        selectedPhotos = Set(library.shownIDs)
    }

    func clearSelection() {
        selectedPhotos.removeAll()
        lastSelectedId = nil
    }

    /// Photos that left the grid's list (moved to or from the bin, deleted).
    func deselect(_ ids: [UUID]) {
        selectedPhotos.subtract(ids)
    }

    func rangeSelect(to photo: PhotoAsset) {
        guard let lastId = lastSelectedId,
              let lastIndex = library.index(of: lastId),
              let currentIndex = library.index(of: photo.id) else {
            selectedPhotos.insert(photo.id)
            lastSelectedId = photo.id
            return
        }

        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        selectedPhotos.formUnion(library.shownIDs[range])
        lastSelectedId = photo.id
    }

    // MARK: - Grid Keyboard Navigation

    enum GridDirection {
        case left, right, up, down
    }

    /// Moves the selection one photo (left/right) or one row of `columns` (up/down); with `extendSelection`, selects
    /// everything in between too.
    ///
    /// An anchor the grid no longer shows (rated or tagged out of the filter, moved to the bin) is where it was:
    /// between the photos either side of its place (`LibraryStore.gridPlace(of:)`), so the arrows move on from there
    /// rather than jumping to the first photo. Without an anchor, or with one that is gone, they select the first photo.
    func navigateGrid(direction: GridDirection, extendSelection: Bool, columns: Int) {
        let ids = library.shownIDs
        guard !ids.isEmpty else { return }

        guard let lastId = lastSelectedId, let place = library.gridPlace(of: lastId) else {
            let id = ids[0]
            selectedPhotos = [id]
            lastSelectedId = id
            return
        }
        // An anchor that left the grid sits between `place.index - 1` and `place.index`: stepping forward lands on the
        // photo after it, back on the one before it, and a row down on the photo that was below it.
        let currentIndex = place.index
        let gone = place.isShown ? 0 : 1
        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = max(0, currentIndex - 1)
        case .right:
            targetIndex = min(ids.count - 1, currentIndex + 1 - gone)
        case .up:
            targetIndex = max(0, currentIndex - columns)
        case .down:
            targetIndex = min(ids.count - 1, currentIndex + columns - gone)
        }

        guard targetIndex != currentIndex || !place.isShown else { return }

        let targetID = ids[targetIndex]

        if extendSelection {
            // From the anchor, or from the first photo on the way when the anchor is gone.
            let forward = direction == .right || direction == .down
            let from = place.isShown ? currentIndex
                : forward ? min(ids.count - 1, currentIndex) : max(0, currentIndex - 1)
            let rangeStart = min(from, targetIndex)
            let rangeEnd = max(from, targetIndex)
            selectedPhotos.formUnion(ids[rangeStart...rangeEnd])
        } else {
            selectedPhotos = [targetID]
        }
        lastSelectedId = targetID
    }
}
