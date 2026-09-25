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
    func navigateGrid(direction: GridDirection, extendSelection: Bool, columns: Int) {
        let ids = library.shownIDs
        guard !ids.isEmpty else { return }

        let currentIndex: Int
        if let lastId = lastSelectedId,
           let idx = library.index(of: lastId) {
            currentIndex = idx
        } else {
            let id = ids[0]
            selectedPhotos = [id]
            lastSelectedId = id
            return
        }

        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = max(0, currentIndex - 1)
        case .right:
            targetIndex = min(ids.count - 1, currentIndex + 1)
        case .up:
            targetIndex = max(0, currentIndex - columns)
        case .down:
            targetIndex = min(ids.count - 1, currentIndex + columns)
        }

        guard targetIndex != currentIndex else { return }

        let targetID = ids[targetIndex]

        if extendSelection {
            let rangeStart = min(currentIndex, targetIndex)
            let rangeEnd = max(currentIndex, targetIndex)
            selectedPhotos.formUnion(ids[rangeStart...rangeEnd])
        } else {
            selectedPhotos = [targetID]
        }
        lastSelectedId = targetID
    }
}
