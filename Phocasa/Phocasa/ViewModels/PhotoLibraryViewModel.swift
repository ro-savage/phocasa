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
    /// A delete with the RAW or JPG filter on, waiting for its confirmation: it moves files to the Trash.
    var pendingFileTypeDelete: FileTypeDelete?
    /// Photos whose saved edits "Revert All Edits" clears once confirmed (`confirmRevertEdits()`); empty otherwise.
    var photosToRevert: [PhotoAsset] = []
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
    /// Where the last new-file export went ("Saved IMG_1234-raw-edit.jpg"), for the alert; nil when there is nothing
    /// to report.
    var exportNotice: String?
    var editPresets: [EditPreset] = []
    var presetNameInput: String = ""

    init() {
        let library = LibraryStore()
        self.library = library
        self.selection = SelectionModel(library: library)
    }

    /// Launch. `library.open` shows the stored library and starts the launch rescan; work that should start after
    /// launch goes after it here (`await library.waitForScans()` waits for that rescan).
    ///
    /// A no-op for the context the library already has: the app owns this view model, so a window that closes and
    /// opens again appears with it, and must not load and rescan the library a second time.
    func setModelContext(_ context: ModelContext) {
        guard library.modelContext !== context else { return }
        library.open(context)
        library.backfillCaptureDatesAfterScans()
        loadPresets()
        Self.openViewModels.removeAll { $0.viewModel == nil }
        Self.openViewModels.append(WeakViewModel(viewModel: self))
    }

    // MARK: - Quitting

    private struct WeakViewModel { weak var viewModel: PhotoLibraryViewModel? }
    /// Every view model that opened a library (one per window), weakly, for `saveEditsBeforeQuit()`.
    private static var openViewModels: [WeakViewModel] = []

    /// Quitting (`AppDelegate.applicationShouldTerminate`), before it waits for the metadata writes: every open edit
    /// session is ended with a save, as closing the detail view would, so its writes (a RAW edit's sidecar) are among
    /// those quit waits for. A session otherwise saves only when it ends, which a quit never did.
    static func saveEditsBeforeQuit() {
        for entry in openViewModels {
            entry.viewModel?.stopEditing(save: true)
        }
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

    // MARK: - The Tag Editor

    /// Whether the tag editor changes the whole selection: opened from the grid on a multi-selection. The detail view's
    /// editor changes only the photo on screen, whatever the (hidden) grid has selected.
    var tagEditorEditsSelection: Bool {
        !showingDetail && selection.selectedPhotos.count > 1
    }

    /// The tag editor's tap on an existing tag: adds it to the selection (see `tagEditorEditsSelection`), or toggles
    /// it on `photo`.
    func toggleTagFromEditor(_ tag: Tag, photo: PhotoAsset?) {
        if tagEditorEditsSelection {
            addTagToSelection(name: tag.name, category: tag.category)
        } else if let photo {
            if photo.tags.contains(where: { $0.id == tag.id }) {
                library.removeTag(tag, from: photo)
            } else {
                library.addTag(name: tag.name, category: tag.category, to: photo)
            }
        }
    }

    /// The tag editor's new tag: on the selection (see `tagEditorEditsSelection`), or on `photo`.
    func addTagFromEditor(name: String, category: String, photo: PhotoAsset?) {
        if tagEditorEditsSelection {
            addTagToSelection(name: name, category: category)
        } else if let photo {
            library.addTag(name: name, category: category, to: photo)
        }
    }

    // MARK: - Deletion / Bin
    // Moving to the bin is immediate. Deletes that trash files return their task: the files go to the Trash off the
    // main actor, then the store changes (spec §G5). In the detail view they act on the photo on screen, never on the
    // grid's (hidden) selection, and the detail view then moves on (`moveDetailOff(_:saveEdit:)`).

    /// ⌫ and the toolbar's delete button: the photo in the detail view, or else the grid's selection.
    @discardableResult
    func deleteSelectionOrCurrent() -> Task<Void, Never>? {
        guard showingDetail, let photo = selectedDetailPhoto else { return deleteSelected() }
        return deletePhoto(photo)
    }

    /// The toolbar's Restore: the photo in the detail view, or else the grid's selection.
    func restoreSelectionOrCurrent() {
        if showingDetail, let photo = selectedDetailPhoto {
            restoreFromBin([photo])
        } else {
            restoreSelected()
        }
    }

    @discardableResult
    func deleteSelected() -> Task<Void, Never>? {
        let toDelete = selection.selectedPhotosList
        guard !toDelete.isEmpty else { return nil }

        if library.viewingBin {
            photosToDelete = toDelete
            showPermanentDeleteConfirmation = true
        } else if let fileType = fileTypeToDelete {
            pendingFileTypeDelete = FileTypeDelete(toDelete, fileType: fileType)
        } else {
            moveToBin(toDelete)
        }
        return nil
    }

    @discardableResult
    func deletePhoto(_ photo: PhotoAsset) -> Task<Void, Never>? {
        deletePhotos([photo])
    }

    /// The context menu's delete: `photos`, as `deleteSelected()` treats the selection.
    @discardableResult
    func deletePhotos(_ photos: [PhotoAsset]) -> Task<Void, Never>? {
        guard !photos.isEmpty else { return nil }
        if library.viewingBin {
            photosToDelete = photos
            showPermanentDeleteConfirmation = true
        } else if let fileType = fileTypeToDelete {
            pendingFileTypeDelete = FileTypeDelete(photos, fileType: fileType)
        } else {
            moveToBin(photos)
        }
        return nil
    }

    /// The file a delete takes off each photo: the RAW or JPG sidebar filter's, when exactly one of them is on. (With
    /// both on, a delete moves the photos to the bin, as with neither.)
    var fileTypeToDelete: FileTypeDelete.FileType? {
        let raw = library.activeFilters.contains(.rawOnly)
        let jpg = library.activeFilters.contains(.jpgOnly)
        guard raw != jpg, !library.viewingBin else { return nil }
        return raw ? .raw : .jpg
    }

    /// The delete buttons' title for `count` photos: what they do here. With the RAW or JPG filter on they delete that
    /// file of each photo, after a confirmation; in the bin, the photos themselves, after one too.
    func deleteActionTitle(count: Int) -> String {
        if library.viewingBin { return "Delete Forever…" }
        guard let fileType = fileTypeToDelete else { return "Move to Bin" }
        return "Delete \(fileType.name) File\(count == 1 ? "" : "s")…"
    }

    /// Confirms `pendingFileTypeDelete` (the request the dialog showed): each pair's file of that type goes to the
    /// Trash, and a photo with only that file goes to the bin.
    @discardableResult
    func confirmFileTypeDelete(_ request: FileTypeDelete) -> Task<Void, Never>? {
        pendingFileTypeDelete = nil
        return deleteFileTypeOnly(request.photos, raw: request.fileType == .raw)
    }

    private func deleteFileTypeOnly(_ photosToRemove: [PhotoAsset], raw deletingRAW: Bool) -> Task<Void, Never> {
        selection.deselect(photosToRemove.map(\.id))
        let raw = deletingRAW
        let jpg = !deletingRAW
        // Each photo leaves the filtered grid: a pair loses the filtered file, a photo with only one goes to the bin.
        // The session isn't saved when the file it edits is going to the Trash (its sidecar with it).
        let trashesEditedFile = editSession.map { $0.photo.hasRawPair && $0.isRAW == raw } == true
        moveDetailOff(Set(photosToRemove.map(\.id)), saveEdit: !trashesEditedFile)
        return Task { await library.deleteFileType(of: photosToRemove, raw: raw, jpg: jpg) }
    }

    private func moveToBin(_ photosToMove: [PhotoAsset]) {
        moveDetailOff(Set(photosToMove.map(\.id)), saveEdit: true)
        selection.deselect(library.moveToBin(photosToMove))
    }

    func restoreFromBin(_ photosToRestore: [PhotoAsset]) {
        moveDetailOff(Set(photosToRestore.map(\.id)), saveEdit: true)
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
        // Before the models go: the detail view must not go on showing (or saving an edit of) a deleted photo.
        moveDetailOff(Set(photos.map(\.id)), saveEdit: false)
        return Task { await library.deletePermanently(photos) }
    }

    /// `leaving` photos are about to leave the grid. When the detail view shows one of them, it moves to the next
    /// photo that stays (the previous one at the end), or closes when none is left. The edit session is ended first,
    /// saved when `saveEdit`, and editing carries on on the next photo, as when navigating.
    private func moveDetailOff(_ leaving: Set<UUID>, saveEdit: Bool) {
        guard showingDetail, let current = selectedDetailPhoto, leaving.contains(current.id) else { return }
        if let next = photoStaying(besides: current, leaving: leaving) {
            showInDetail(next, saveEdit: saveEdit)
        } else {
            stopEditing(save: saveEdit)
            savedEditHandoff = nil
            showingDetail = false
            selectedDetailPhoto = nil
        }
    }

    /// The first photo after `photo` in the grid that isn't `leaving`, else the last one before it.
    private func photoStaying(besides photo: PhotoAsset, leaving: Set<UUID>) -> PhotoAsset? {
        let ids = library.shownIDs
        let place = library.gridPlace(of: photo)
        let after = place.isShown ? place.index + 1 : place.index
        if after < ids.count, let index = ids[after...].firstIndex(where: { !leaving.contains($0) }) {
            return library.photos[index]
        }
        let before = place.index - 1
        if before >= 0, let index = ids[...before].lastIndex(where: { !leaving.contains($0) }) {
            return library.photos[index]
        }
        return nil
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

    /// The next (`direction` 1) or previous (-1) photo in the grid. A detail photo the grid no longer shows (rated,
    /// tagged or binned out of the filter while on screen) is where it was (`LibraryStore.gridPlace(of:)`): next is
    /// the photo after its place, previous the one before it.
    func navigateDetail(direction: Int) {
        guard let current = selectedDetailPhoto else { return }
        let photos = library.photos
        let place = library.gridPlace(of: current)
        let newIndex = place.index + direction - (!place.isShown && direction > 0 ? 1 : 0)
        guard photos.indices.contains(newIndex) else { return }
        showInDetail(photos[newIndex])
    }

    /// Shows `photo` in the detail view. The session is ended first, saved unless `saveEdit` is false, and editing
    /// carries on on `photo` when it has a file of the kind being edited (a session belongs to one photo).
    private func showInDetail(_ photo: PhotoAsset, saveEdit: Bool = true) {
        let editingRAW = editSession?.isRAW
        editSession?.end(save: saveEdit)
        editSession = nil
        savedEditHandoff = nil
        selectedDetailPhoto = photo
        if let editingRAW {
            continueEditing(photo, isRAW: editingRAW)
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
        revertEdits(of: [photo])
    }

    /// The context menu's "Revert All Edits", asked first (`photosToRevert`, confirmed by `confirmRevertEdits()`): the
    /// selected photos that have edits when `photo` is part of a multi-selection, else `photo`.
    func requestRevertEdits(from photo: PhotoAsset) {
        photosToRevert = selection.isPartOfMultiSelection(photo)
            ? selection.selectedPhotosList.filter(\.hasAnyEdits) : [photo]
    }

    func confirmRevertEdits() {
        let photos = photosToRevert
        photosToRevert = []
        revertEdits(of: photos)
    }

    /// Clears the photos' saved JPG and RAW edits, in one save. The sidecar writes go through `MetadataWriter`.
    private func revertEdits(of photos: [PhotoAsset]) {
        guard !photos.isEmpty else { return }
        for photo in photos {
            photo.jpgEditParametersData = nil
            photo.hasRawEdits = false
            if let rawPath = photo.rawPath {
                RAWEditStore.shared.save(nil, forRAWAt: rawPath)
            }
        }
        try? library.modelContext?.save()
    }

    // MARK: - Export
    // The export dialog's choices (see `EditSession`'s export section). Exports that replace a file put a copy of the
    // original in the Trash first, through the library's `fileTrasher`.

    /// Saves the session's edit as a new JPG beside the photo (`EditSession.exportToNewFile()`) and adds it to the
    /// library as a photo of its own, with the photo's rating and tags, next to it in the order. The photo itself and
    /// its files don't change. `exportNotice` then says where it went.
    func exportToNewFile() {
        guard let session = editSession else { return }
        let source = session.photo
        Task {
            let (result, url) = await session.exportToNewFile()
            guard result == .written, let url else {
                exportFailure = Self.failureMessage(result, replacing: false)
                return
            }
            library.addExportedPhoto(at: url, copying: source)
            exportNotice = "Saved \(url.lastPathComponent)"
        }
    }

    /// Replaces the pair's camera JPG with the session's RAW edit (`EditSession.exportReplacingCameraJPG`), a copy of
    /// the original going to the Trash first.
    func exportReplacingCameraJPG() {
        guard let session = editSession, let jpgPath = session.photo.jpgPath else { return }
        let trasher = library.fileTrasher
        Task {
            let result = await session.exportReplacingCameraJPG(originalTo: trasher)
            guard result == .written else {
                exportFailure = Self.failureMessage(result, replacing: true)
                return
            }
            fileWasRewritten(jpgPath)
        }
    }

    /// Bakes the session's edits into the JPG file (see `EditSession.exportJPGPermanent`), a copy of the original
    /// going to the Trash first.
    func exportJPGPermanent() {
        guard let session = editSession, let jpgPath = session.photo.jpgPath else { return }
        let trasher = library.fileTrasher
        Task {
            let result = await session.exportJPGPermanent(originalTo: trasher)
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
                + "location, captions) into the new file. Use \"Save as New JPG\" instead."
        case .metadataNotKept:
            return "No file was written. Phocasa couldn't carry the photo's metadata into the new file."
        case .notAJPEG:
            return "The file wasn't changed: it isn't a JPEG, and Phocasa only rewrites JPEG files. Use \"Save as New "
                + "JPG\" instead."
        case .originalNotTrashed:
            return "The file wasn't changed: Phocasa couldn't put a copy of the original in the Trash first (this drive "
                + "may have no Trash). Use \"Save as New JPG\" instead."
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

    /// Saves the session's current look (defaults when not editing) as a preset named `presetNameInput`. Not its crop,
    /// rotation or flips (`EditParameters.look`): a preset applied to many photos must not crop or turn them.
    func savePreset() {
        guard let context = library.modelContext else { return }
        let name = presetNameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let preset = EditPreset(name: name, parameters: (editSession?.parameters ?? EditParameters()).look)
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

    /// Saves `preset`'s look as the edits of every selected photo, each keeping its own crop, rotation and flips: JPG
    /// edits in the model, RAW edits in the sidecar (through `MetadataWriter`).
    func applyPresetToSelection(_ preset: EditPreset) {
        let params = preset.parameters

        for photo in selection.selectedPhotosList {
            if photo.jpgPath != nil {
                photo.jpgEditParameters = (photo.jpgEditParameters ?? EditParameters()).applyingLook(of: params)
            }
            if let rawPath = photo.rawPath {
                // The sidecar is read only for photos with RAW edits: only those can have a transform to keep.
                let saved = photo.hasRawEdits ? RAWEditStore.shared.parameters(forRAWAt: rawPath) : nil
                RAWEditStore.shared.save((saved ?? EditParameters()).applyingLook(of: params), forRAWAt: rawPath)
                photo.hasRawEdits = true
            }
        }

        try? library.modelContext?.save()
    }
}

/// A delete with the RAW or JPG sidebar filter on, as its confirmation shows it: each pair's file of that type (a RAW
/// with its sidecar) goes to the Trash and the photo stays with its other file; a photo with only that file goes to
/// the bin.
struct FileTypeDelete {
    enum FileType {
        case raw, jpg
        var name: String { self == .raw ? "RAW" : "JPG" }
        var other: String { self == .raw ? "JPG" : "RAW" }
    }

    let photos: [PhotoAsset]
    let fileType: FileType
    /// Pairs: they lose their file of this type, which goes to the Trash.
    let fileCount: Int
    /// Photos with only a file of this type: they go to the bin.
    let binCount: Int

    @MainActor init(_ photos: [PhotoAsset], fileType: FileType) {
        self.photos = photos
        self.fileType = fileType
        fileCount = photos.filter(\.hasRawPair).count
        binCount = photos.count - fileCount
    }

    var title: String {
        if fileCount > 0 {
            return "Move \(fileCount.formatted()) \(fileType.name) file\(fileCount == 1 ? "" : "s") to the Trash?"
        }
        return "Move \(binCount.formatted()) photo\(binCount == 1 ? "" : "s") to the Bin?"
    }

    var message: String {
        let alone = "\(binCount.formatted()) photo\(binCount == 1 ? " has" : "s have") only a \(fileType.name) file"
        guard fileCount > 0 else { return "\(binCount == 1 ? "It has" : "They have") only a \(fileType.name) file, so " +
            "\(binCount == 1 ? "it goes" : "they go") to the Bin. No file is deleted." }
        let kept = "The \(fileType.other)s stay in the library."
        return binCount == 0 ? kept : "\(kept) \(alone) and \(binCount == 1 ? "goes" : "go") to the Bin instead."
    }

    var confirmTitle: String { fileCount > 0 ? "Move to Trash" : "Move to Bin" }
}
