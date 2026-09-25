import SwiftUI
import SwiftData

/// The window's coordinator. It owns the library (`LibraryStore`), the selection (`SelectionModel`) and the edit in
/// progress (`EditSession`), holds the UI flags, and runs the actions that span them: the detail view, the delete
/// flows, rating and tagging the selection, and the editing entry points.
///
/// Views read `library` and `selection` directly.
@Observable @MainActor
final class PhotoLibraryViewModel {
    let library: LibraryStore
    let selection: SelectionModel

    var gridColumns: Int = 6
    var selectedDetailPhoto: PhotoAsset?
    var showingDetail: Bool = false
    var showFolderPicker: Bool = false
    var showPermanentDeleteConfirmation: Bool = false
    var photosToDelete: [PhotoAsset] = []
    var showGridTagEditor: Bool = false
    var tagEditorTarget: PhotoAsset?

    // MARK: - Image Editing State
    /// The edit in progress: its photo, parameters, renders, comparison and crop state. Exists only while editing.
    private(set) var editSession: EditSession?
    var isEditing: Bool { editSession != nil }
    /// What the last editing session saved, so the detail view shows the saved edit at once rather than the
    /// unedited photo. Cleared when the detail photo changes or the detail view closes.
    private(set) var savedEditHandoff: SavedEditHandoff?
    /// Bumped when an export rewrites a photo's file, so the detail view decodes it again.
    private(set) var editedFilesVersion = 0
    /// Why the last export didn't happen, for the alert; nil when there is nothing to report.
    var exportFailure: String?
    var editPresets: [EditPreset] = []
    var presetNameInput: String = ""

    init() {
        let library = LibraryStore()
        self.library = library
        self.selection = SelectionModel(library: library)
    }

    /// Launch. `library.open` shows the stored library and starts the launch rescan; work that should start after
    /// launch goes after it here (`await library.waitForScans()` waits for that rescan).
    func setModelContext(_ context: ModelContext) {
        library.open(context)
        library.backfillCaptureDatesAfterScans()
        loadPresets()
    }

    /// Reloads the library from the store (see `LibraryStore.loadExistingData()`).
    func loadExistingData() {
        library.loadExistingData()
    }

    func openFolder() {
        showFolderPicker = true
    }

    // MARK: - Rating and Tagging the Selection

    func setRatingForSelection(_ rating: Int) {
        library.setRating(rating, for: selection.selectedPhotosList)
    }

    /// Keyboard rating: the photo in the detail view, or else the selection.
    func setRatingForSelectionOrCurrent(_ rating: Int) {
        if showingDetail, let photo = selectedDetailPhoto {
            library.setRating(rating, for: photo)
        } else if !selection.selectedPhotos.isEmpty {
            setRatingForSelection(rating)
        }
    }

    func addTagToSelection(name: String, category: String) {
        library.addTag(name: name, category: category, to: selection.selectedPhotosList)
    }

    /// The context menu's tag toggle: on the whole selection when `photo` is part of a multi-selection (removes the
    /// tag if every selected photo has it, else adds it), otherwise on `photo`.
    func toggleTag(_ tag: Tag, for photo: PhotoAsset) {
        if selection.isPartOfMultiSelection(photo) {
            let selected = selection.selectedPhotosList
            if Self.tagIDsAllHave(selected, in: library).contains(tag.id) {
                library.removeTag(tag, from: selected)
            } else {
                addTagToSelection(name: tag.name, category: tag.category)
            }
        } else {
            if photo.tags.contains(where: { $0.id == tag.id }) {
                library.removeTag(tag, from: photo)
            } else {
                library.addTag(name: tag.name, category: tag.category, to: photo)
            }
        }
    }

    /// Whether the context menu on `photo` shows `tag` as checked (see `contextMenuTagIDs(for:)`).
    func contextMenuTagState(_ tag: Tag, for photo: PhotoAsset) -> Bool {
        contextMenuTagIDs(for: photo).contains(tag.id)
    }

    /// The tags the context menu on `photo` shows as checked: those every photo `toggleTag` would act on has (the
    /// selection when `photo` is part of a multi-selection). Computed once per menu from the in-memory facts, not by
    /// reading every selected photo's tags for each tag in the menu.
    func contextMenuTagIDs(for photo: PhotoAsset) -> Set<UUID> {
        if selection.isPartOfMultiSelection(photo) {
            return Self.tagIDsAllHave(selection.selectedPhotosList, in: library)
        }
        return library.tagIDs(of: photo)
    }

    /// The tags every one of `photos` has. With no photos, every tag (as `allSatisfy` over nothing is true).
    private static func tagIDsAllHave(_ photos: [PhotoAsset], in library: LibraryStore) -> Set<UUID> {
        guard let first = photos.first else { return Set(library.allTags.map(\.id)) }
        var common = library.tagIDs(of: first)
        for photo in photos.dropFirst() where !common.isEmpty {
            common.formIntersection(library.tagIDs(of: photo))
        }
        return common
    }

    func openTagEditorForContextMenu(photo: PhotoAsset) {
        if !selection.isPartOfMultiSelection(photo) {
            selection.select(only: photo.id)
        }
        tagEditorTarget = photo
        showGridTagEditor = true
    }

    // MARK: - Deletion / Bin
    // Moving to the bin is immediate. Deletes that trash files return their task: the files go to the Trash off the
    // main actor, then the store changes (spec §G5).

    @discardableResult
    func deleteSelected() -> Task<Void, Never>? {
        let toDelete = selection.selectedPhotosList
        guard !toDelete.isEmpty else { return nil }

        if library.viewingBin {
            photosToDelete = toDelete
            showPermanentDeleteConfirmation = true
        } else if library.hasFileTypeFilter {
            return deleteFileTypeOnly(toDelete)
        } else {
            moveToBin(toDelete)
        }
        return nil
    }

    @discardableResult
    func deletePhoto(_ photo: PhotoAsset) -> Task<Void, Never>? {
        if library.viewingBin {
            photosToDelete = [photo]
            showPermanentDeleteConfirmation = true
        } else if library.hasFileTypeFilter && photo.hasRawPair {
            return deleteFileTypeOnly([photo])
        } else {
            moveToBin([photo])
        }
        return nil
    }

    private func deleteFileTypeOnly(_ photosToRemove: [PhotoAsset]) -> Task<Void, Never> {
        selection.deselect(photosToRemove.map(\.id))
        let raw = library.activeFilters.contains(.rawOnly)
        let jpg = library.activeFilters.contains(.jpgOnly)
        return Task { await library.deleteFileType(of: photosToRemove, raw: raw, jpg: jpg) }
    }

    private func moveToBin(_ photosToMove: [PhotoAsset]) {
        selection.deselect(library.moveToBin(photosToMove))
    }

    func restoreFromBin(_ photosToRestore: [PhotoAsset]) {
        selection.deselect(library.restoreFromBin(photosToRestore))
    }

    func restoreSelected() {
        restoreFromBin(selection.selectedPhotosList)
    }

    @discardableResult
    func confirmPermanentDelete() -> Task<Void, Never>? {
        guard library.modelContext != nil else { return nil }
        let photos = photosToDelete
        photosToDelete = []
        selection.deselect(photos.map(\.id))
        return Task { await library.deletePermanently(photos) }
    }

    func emptyBin() {
        guard library.modelContext != nil else { return }
        photosToDelete = library.binPhotos
        showPermanentDeleteConfirmation = true
    }

    // MARK: - Detail View

    func openDetail(for photo: PhotoAsset) {
        selectedDetailPhoto = photo
        showingDetail = true
    }

    func navigateDetail(direction: Int) {
        guard let current = selectedDetailPhoto,
              let index = library.index(of: current.id) else { return }

        let photos = library.photos
        let newIndex = index + direction
        if newIndex >= 0 && newIndex < photos.count {
            // Save edits before navigating, then keep editing on the next photo (a session belongs to one photo).
            let editingRAW = editSession?.isRAW
            editSession?.end(save: true)
            editSession = nil
            savedEditHandoff = nil
            selectedDetailPhoto = photos[newIndex]
            if let editingRAW {
                continueEditing(photos[newIndex], isRAW: editingRAW)
            }
        }
    }

    func closeDetail() {
        if isEditing {
            stopEditing(save: true)
        }
        savedEditHandoff = nil
        if let photo = selectedDetailPhoto {
            selection.select(only: photo.id)
        }
        showingDetail = false
        selectedDetailPhoto = nil
    }

    // MARK: - Zoom

    func zoomIn() {
        if gridColumns > 2 {
            gridColumns -= 1
        }
    }

    func zoomOut() {
        if gridColumns < 20 {
            gridColumns += 1
        }
    }
    // MARK: - Image Editing

    /// Saves the current session, if any, then starts editing `photo` in a new one.
    func startEditing(photo: PhotoAsset, isRAW: Bool) {
        if let current = editSession {
            if let handoff = current.end(save: true) { savedEditHandoff = handoff }
            editSession = nil
        }
        selectedDetailPhoto = photo
        let session = EditSession(photo: photo, isRAW: isRAW, modelContext: library.modelContext)
        editSession = session
        Task { await session.begin() }
    }

    /// Ends the session. With `save`, its edits are saved and the detail view shows them.
    func stopEditing(save: Bool = true) {
        guard let session = editSession else { return }
        let handoff = session.end(save: save)
        editSession = nil
        if let handoff { savedEditHandoff = handoff }
    }

    /// After navigating while editing: edit the new photo too, if it has a file of the kind being edited.
    private func continueEditing(_ photo: PhotoAsset, isRAW: Bool) {
        guard (isRAW ? photo.rawPath : photo.jpgPath) != nil else { return }
        startEditing(photo: photo, isRAW: isRAW)
    }

    /// Clears the photo's saved JPG and RAW edits. The sidecar write goes through `MetadataWriter`.
    func revertEditsForPhoto(_ photo: PhotoAsset) {
        photo.jpgEditParametersData = nil
        photo.hasRawEdits = false
        if let rawPath = photo.rawPath {
            RAWEditStore.shared.save(nil, forRAWAt: rawPath)
        }
        try? library.modelContext?.save()
    }

    // MARK: - Export

    /// Exports the session's RAW edit to a JPEG (see `EditSession.exportRAWToJPG`), then refreshes what depends
    /// on the file: the in-memory library facts when the photo got a new JPG, and cached decodes of the written file.
    func exportRAWToJPG(replaceExisting: Bool) {
        guard let session = editSession else { return }
        let photo = session.photo
        let jpgBefore = photo.jpgPath
        let replacing = replaceExisting && jpgBefore != nil
        Task {
            let result = await session.exportRAWToJPG(replaceExisting: replaceExisting)
            guard result == .written else {
                exportFailure = Self.failureMessage(result, replacing: replacing)
                return
            }
            if photo.jpgPath != jpgBefore {
                library.photosDidChange([photo])
            }
            if let written = photo.jpgPath {
                fileWasRewritten(written)
            }
        }
    }

    /// Bakes the session's edits into the JPG file (see `EditSession.exportJPGPermanent`).
    func exportJPGPermanent() {
        guard let session = editSession, let jpgPath = session.photo.jpgPath else { return }
        Task {
            let result = await session.exportJPGPermanent()
            guard result == .written else {
                exportFailure = Self.failureMessage(result, bakingEdits: true)
                return
            }
            fileWasRewritten(jpgPath)
        }
    }

    private static func failureMessage(_ result: ExportResult, replacing: Bool = false, bakingEdits: Bool = false) -> String? {
        switch result {
        case .written:
            return nil
        case .failed:
            return "The file couldn't be written."
        case .metadataNotKept where bakingEdits:
            return "The edits weren't applied. Phocasa couldn't carry this photo's metadata (camera details, capture "
                + "date, location, captions) into the edited file, so applying them would have lost it. The edits are "
                + "kept as a saved edit."
        case .metadataNotKept where replacing:
            return "The JPG wasn't replaced. Phocasa couldn't carry its metadata (camera details, capture date, "
                + "location, captions) into the new file. Use \"Create new file\" instead."
        case .metadataNotKept:
            return "No file was written. Phocasa couldn't carry the photo's metadata into the new file."
        }
    }

    /// An export rewrote `path`: drop its cached thumbnails and have the detail view decode it again.
    private func fileWasRewritten(_ path: String) {
        ImageLoader.shared.invalidate(path: path)
        editedFilesVersion += 1
    }

    // MARK: - Presets

    func loadPresets() {
        guard let context = library.modelContext else { return }
        let descriptor = FetchDescriptor<EditPreset>(sortBy: [SortDescriptor(\.name)])
        editPresets = (try? context.fetch(descriptor)) ?? []
    }

    /// Saves the session's current parameters (defaults when not editing) as a preset named `presetNameInput`.
    func savePreset() {
        guard let context = library.modelContext else { return }
        let name = presetNameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let preset = EditPreset(name: name, parameters: editSession?.parameters ?? EditParameters())
        context.insert(preset)
        try? context.save()
        presetNameInput = ""
        loadPresets()
    }

    func deletePreset(_ preset: EditPreset) {
        library.modelContext?.delete(preset)
        try? library.modelContext?.save()
        loadPresets()
    }

    func applyPreset(_ preset: EditPreset) {
        editSession?.apply(preset)
    }

    /// Saves `preset` as the edits of every selected photo: JPG edits in the model, RAW edits in the sidecar
    /// (through `MetadataWriter`).
    func applyPresetToSelection(_ preset: EditPreset) {
        let params = preset.parameters

        for photo in selection.selectedPhotosList {
            if photo.jpgPath != nil {
                photo.jpgEditParameters = params
            }
            if let rawPath = photo.rawPath {
                RAWEditStore.shared.save(params, forRAWAt: rawPath)
                photo.hasRawEdits = true
            }
        }

        try? library.modelContext?.save()
    }
}
