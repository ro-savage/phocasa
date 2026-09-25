import SwiftUI
import AppKit

/// Detail view container: loads the photo's images and chooses which one to show. Zoom and pan live in
/// `ZoomableImageView` and `MinimapView`, the chrome in `DetailOverlayControls`, so zoom and pan frames don't
/// re-evaluate this body (spec §D3). Editing state lives in the view model's `EditSession`; this body reads its
/// renders, not its parameters, so slider ticks don't re-evaluate it either.
struct PhotoDetailView: View {
    @Bindable var viewModel: PhotoLibraryViewModel
    let photo: PhotoAsset

    // Images carry their EXIF orientation, applied at display time (spec §D1).
    @State private var displayedImage: DisplayImage?
    /// The photo's saved edit, rendered (spec §D4). Edit-pipeline images are already upright.
    @State private var renderedEdit: SavedEditRender?
    @State private var originalImage: DisplayImage?
    @State private var loadedPath: String?
    /// `viewModel.editedFilesVersion` when `loadedPath` was decoded.
    @State private var loadedFilesVersion: Int?
    /// Bumped by every saved-edit resolution; only the latest one may assign `renderedEdit`.
    @State private var savedEditGeneration = 0
    @State private var savedEditTask: Task<Void, Never>?
    /// The session hand-off that `renderedEdit` already reflects.
    @State private var adoptedHandoffID: UUID?
    @State private var showTagEditor = false
    @State private var minimapThumbnail: DisplayImage?
    /// Created here so zoom survives switching to a comparison view and back. This view only resets it; it
    /// never reads it, so zoom and pan don't invalidate this body.
    @State private var zoomState = ZoomPanState()
    @State private var imageDisplayRect: CGRect = .zero
    /// This view's size in points, for choosing how many pixels to decode. Not read by `body`.
    @State private var viewportSize: CGSize = .zero
    /// Index of the photo shown last, to prefetch in the direction of travel.
    @State private var lastIndex: Int?
    /// The photo `loadImages` is loading or has loaded. While the next photo loads, the previous image is
    /// still on screen and must not start a full-resolution decode.
    @State private var requestedPath: String?
    @State private var fullResolutionTask: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale

    /// The session editing this photo, if any.
    private var session: EditSession? {
        viewModel.editSession.flatMap { $0.photo.id == photo.id ? $0 : nil }
    }

    /// The saved edit to show when not editing. Right after a session saved this photo, its render stands in
    /// until the saved edit has been resolved again, so the unedited photo doesn't flash up.
    private var savedEditImage: DisplayImage? {
        if let handoff = viewModel.savedEditHandoff, handoff.photoID == photo.id, handoff.id != adoptedHandoffID {
            return SavedEdit.interimImage(after: handoff, jpgParameters: photo.jpgEditParameters, current: renderedEdit)
                .flatMap(DisplayImage.init(nsImage:))
        }
        return renderedEdit.flatMap { DisplayImage(nsImage: $0.image) }
    }

    // The active image to show. Edit-pipeline images are NSImages that are already upright.
    private var currentImage: DisplayImage? {
        guard let session else { return savedEditImage ?? displayedImage }
        if session.isCropping {
            return displayedImage ?? savedEditImage
        }
        if session.showOriginal {
            return originalImage ?? displayedImage
        }
        return (session.fullImage ?? session.previewImage).flatMap(DisplayImage.init(nsImage:))
            ?? savedEditImage ?? displayedImage
    }

    // For side-by-side: the original image
    private var comparisonOriginal: DisplayImage? {
        originalImage ?? displayedImage
    }

    // For side-by-side and the JPG comparison: the edited image
    private var comparisonEdited: DisplayImage? {
        session?.previewImage.flatMap(DisplayImage.init(nsImage:)) ?? savedEditImage ?? displayedImage
    }

    var body: some View {
        let session = self.session
        let isCropping = session?.isCropping == true
        let showExportOptions = session?.showExportOptions == true
        ZStack {
            Color.black.ignoresSafeArea()

            if let session, session.showJPGComparison && session.isRAW {
                ComparisonView(left: ("JPG", session.jpgComparisonImage), right: ("RAW EDIT", comparisonEdited))
            } else if let session, session.showSideBySide {
                ComparisonView(left: ("ORIGINAL", comparisonOriginal), right: ("EDITED", comparisonEdited))
            } else if let image = currentImage {
                let isLoaderImage = image == displayedImage
                ZoomableImageView(
                    image: image,
                    zoom: zoomState,
                    sourcePixelSize: isLoaderImage
                        ? loadedPath.flatMap { FullImageLoader.shared.cachedInfo(path: $0)?.orientedSize } : nil,
                    onDisplayRectChange: { imageDisplayRect = $0 },
                    onNeedsMorePixels: { loadFullResolution() }
                )
                .equatable()
            }

            // Crop overlay
            if let session, isCropping {
                CropOverlayView(
                    cropRect: Bindable(session).cropRect,
                    rotation: Bindable(session).parameters.rotation,
                    imageDisplayRect: imageDisplayRect,
                    onApply: { session.applyCrop() },
                    onCancel: { session.cancelCrop() }
                )
            }

            // UI overlays (hidden during crop)
            if !isCropping {
                DetailOverlayControls(viewModel: viewModel, photo: photo, onShowTags: { showTagEditor.toggle() })
                    .equatable()
            }

            // Minimap (shows itself only while zoomed in)
            if let thumb = minimapThumbnail, !isCropping {
                MinimapView(zoom: zoomState, thumbnail: thumb)
            }
        }
        .popover(isPresented: $showTagEditor) {
            TagEditorView(viewModel: viewModel, photo: photo)
                .frame(width: 300, height: 400)
        }
        .confirmationDialog("Export RAW Edit", isPresented: Binding(
            get: { showExportOptions },
            set: { viewModel.editSession?.showExportOptions = $0 }
        )) {
            if photo.jpgPath != nil {
                Button("Replace existing JPG") {
                    viewModel.exportRAWToJPG(replaceExisting: true)
                }
            }
            Button("Create new file (-raw-edit)") {
                viewModel.exportRAWToJPG(replaceExisting: false)
            }
            if session?.isRAW == false && photo.jpgPath != nil {
                Button("Apply edits permanently to JPG", role: .destructive) {
                    viewModel.exportJPGPermanent()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onDisappear {
            if viewModel.isEditing {
                viewModel.stopEditing(save: true)
            }
            // Leaving the detail view: give back the decoded photos (up to 512 MB), as before task 12.
            fullResolutionTask?.cancel()
            savedEditTask?.cancel()
            FullImageLoader.shared.clear()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .task(id: "\(viewModel.editedFilesVersion)|\(photo.displayPath)") {
            await loadImages()
        }
        .onChange(of: viewModel.savedEditHandoff?.id) {
            adoptSavedEditHandoff()
        }
    }

    // MARK: - Image Loading

    /// Device pixels available to the image. Before the first layout, a size large enough that nothing is
    /// subsampled (the zoom check upgrades later anyway).
    private var viewportPixelSize: CGSize {
        guard viewportSize.width >= 1, viewportSize.height >= 1 else { return CGSize(width: 16384, height: 16384) }
        return CGSize(width: viewportSize.width * displayScale, height: viewportSize.height * displayScale)
    }

    private func loadImages() async {
        let path = photo.displayPath
        let filesVersion = viewModel.editedFilesVersion
        guard path != loadedPath || filesVersion != loadedFilesVersion, !path.isEmpty else { return }
        if let loadedFilesVersion, loadedFilesVersion != filesVersion {
            // An export rewrote a photo file, so cached decodes may hold its old pixels.
            FullImageLoader.shared.clear()
        }
        requestedPath = path
        fullResolutionTask?.cancel()
        fullResolutionTask = nil
        // A saved-edit render still running for the previous photo must not land on this one.
        savedEditGeneration += 1
        let viewport = viewportPixelSize

        // The fit image: the smallest decode that still fills the viewport (hardware path, orientation applied
        // at display time), or a RAW file's embedded preview. Usually already prefetched.
        let loader = FullImageLoader.shared
        var newImage = loader.cachedFit(path: path, viewportPixelSize: viewport)
        if newImage == nil {
            newImage = await loader.loadFit(path: path, viewportPixelSize: viewport)
        }
        // A newer navigation cancels this task; don't let a slow load overwrite the newer photo.
        guard !Task.isCancelled else { return }
        if let newImage {
            withAnimation(.easeInOut(duration: 0.15)) {
                displayedImage = newImage
                originalImage = newImage
                // The previous photo's saved-edit render must not stay on screen under this photo.
                renderedEdit = nil
            }
            loadedPath = path
            loadedFilesVersion = filesVersion
            zoomState.reset()
        }
        prefetchNeighbours(of: photo, viewport: viewport)

        // Saved edits: a JPG edit render wins over a RAW one, rendered on the .full lane.
        await refreshSavedEdit(reusing: viewModel.savedEditHandoff.flatMap { $0.photoID == photo.id ? $0 : nil })
        guard !Task.isCancelled else { return }

        let thumbnail = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 400)
        guard !Task.isCancelled else { return }
        minimapThumbnail = thumbnail.flatMap(DisplayImage.init(nsImage:))
    }

    /// Prefetches the photos either side, plus a second one in the direction of travel. One `firstIndex` per
    /// navigation (task 30 swaps it for an index lookup).
    private func prefetchNeighbours(of photo: PhotoAsset, viewport: CGSize) {
        let photos = viewModel.library.photos
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        let step = (lastIndex.map { index < $0 } ?? false) ? -1 : 1
        lastIndex = index
        let paths = [index + step, index + 2 * step, index - step]
            .filter { photos.indices.contains($0) }
            .map { photos[$0].displayPath }
            .filter { !$0.isEmpty }
        FullImageLoader.shared.prefetchFit(paths: paths, viewportPixelSize: viewport)
    }

    /// Swaps in the full-resolution decode when the fit image has fewer pixels than it is drawn with (zoomed
    /// in, the viewport grew, or a RAW preview). Keeps zoom and pan. At most once per photo.
    private func loadFullResolution() {
        // Only for the loader's image: edit renders are produced at full resolution by the edit session.
        guard fullResolutionTask == nil, currentImage == displayedImage, let path = loadedPath, path == requestedPath,
              let shown = displayedImage, let info = FullImageLoader.shared.cachedInfo(path: path),
              shown.pixelSize != info.pixelSize || shown.orientation != info.orientation else { return }
        fullResolutionTask = Task {
            let full = await FullImageLoader.shared.load(path: path, subsample: 1)
            guard !Task.isCancelled, let full, loadedPath == path, displayedImage == shown else { return }
            displayedImage = full
            originalImage = full
        }
    }

    // MARK: - Saved edits

    /// Resolves and renders this photo's saved edit (`SavedEdit.render(for:reusing:)`) and shows it, unless a
    /// newer resolution, or another photo, has taken over meanwhile.
    private func refreshSavedEdit(reusing handoff: SavedEditHandoff?) async {
        savedEditGeneration += 1
        let generation = savedEditGeneration
        let rendered = await SavedEdit.render(for: photo, reusing: handoff)
        guard !Task.isCancelled, generation == savedEditGeneration else { return }
        renderedEdit = rendered
        if let handoff { adoptedHandoffID = handoff.id }
    }

    /// A session just saved this photo. `savedEditImage` shows the session's render until the saved edit has been
    /// resolved again, reusing that render when it is the finished full-resolution one.
    private func adoptSavedEditHandoff() {
        guard let handoff = viewModel.savedEditHandoff, handoff.photoID == photo.id else { return }
        savedEditTask?.cancel()
        savedEditTask = Task { await refreshSavedEdit(reusing: handoff) }
    }
}
