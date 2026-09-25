import SwiftUI
import AppKit

/// Detail view container: loads the photo's images and chooses which one to show. Zoom and pan live in
/// `ZoomableImageView` and `MinimapView`, the chrome in `DetailOverlayControls`, so zoom and pan frames don't
/// re-evaluate this body (spec §D3). Editing state lives in the view model's `EditSession`; this body reads its
/// renders, not its parameters, so slider ticks don't re-evaluate it either.
///
/// Edit renders (the session's passes and the saved edit) are rendered to fill this view at fit. When the view is
/// zoomed in past one, `ZoomableImageView`'s "needs more pixels" hook asks for it at native resolution.
struct PhotoDetailView: View {
    @Bindable var viewModel: PhotoLibraryViewModel
    let photo: PhotoAsset

    // Images carry their EXIF orientation, applied at display time (spec §D1).
    @State private var displayedImage: DisplayImage?
    /// The photo's saved edit, rendered (spec §D4). Edit-pipeline images are already upright.
    @State private var savedEdit: SavedEditState
    @State private var originalImage: DisplayImage?
    @State private var loadedPath: String?
    /// `viewModel.editedFilesVersion` when `loadedPath` was decoded.
    @State private var loadedFilesVersion: Int?
    @State private var showTagEditor = false
    @State private var minimapThumbnail: DisplayImage?
    /// Created here so zoom survives switching to a comparison view and back. This view only resets it; it
    /// never reads it in `body`, so zoom and pan don't invalidate this body.
    @State private var zoomState: ZoomPanState
    @State private var imageDisplayRect: CGRect = .zero
    /// This view's size in points, for choosing how many pixels to decode and render. Not read by `body`.
    @State private var viewportSize: CGSize = .zero
    /// Index of the photo shown last, to prefetch in the direction of travel.
    @State private var lastIndex: Int?
    /// The photo `loadImages` is loading or has loaded. While the next photo loads, the previous image is
    /// still on screen and must not start a full-resolution decode.
    @State private var requestedPath: String?
    @State private var fullResolutionTask: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale

    /// `zoom` and `savedEdit` are created here unless given (tests pass their own, to drive and observe them).
    init(viewModel: PhotoLibraryViewModel, photo: PhotoAsset, zoom: ZoomPanState? = nil,
         savedEdit: SavedEditState? = nil) {
        self.viewModel = viewModel
        self.photo = photo
        _zoomState = State(initialValue: zoom ?? ZoomPanState())
        _savedEdit = State(initialValue: savedEdit ?? SavedEditState())
    }

    /// The session editing this photo, if any.
    private var session: EditSession? {
        viewModel.editSession.flatMap { $0.photo.id == photo.id ? $0 : nil }
    }

    /// The saved edit to show when not editing. Right after a session saved this photo, its render stands in
    /// until the saved edit has been resolved again, so the unedited photo doesn't flash up.
    private var savedEditImage: DisplayImage? {
        if let handoff = viewModel.savedEditHandoff, handoff.photoID == photo.id, handoff.id != savedEdit.adoptedHandoffID {
            return SavedEdit.interimImage(after: handoff, jpgParameters: photo.jpgEditParameters, current: savedEdit.render)
                .flatMap(DisplayImage.init(nsImage:))
        }
        return savedEdit.render.flatMap { DisplayImage(nsImage: $0.image) }
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

    /// Whether `image` shows `nsImage` (the same bitmap).
    private static func image(_ image: DisplayImage, shows nsImage: NSImage?) -> Bool {
        nsImage.flatMap(DisplayImage.init(nsImage:)) == image
    }

    /// The oriented pixel size of the photo, or of the edit at native resolution, that `image` stands for: the
    /// double-click "1:1" zoom target. Nil when `image` is that size itself (or unknown).
    private func sourcePixelSize(of image: DisplayImage) -> CGSize? {
        if image == displayedImage {
            return loadedPath.flatMap { FullImageLoader.shared.cachedInfo(path: $0)?.orientedSize }
        }
        if let session, Self.image(image, shows: session.fullImage) {
            return session.fullImageNativePixelSize
        }
        if let render = savedEdit.render, Self.image(image, shows: render.image) {
            return render.nativePixelSize
        }
        return nil
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
                ZoomableImageView(
                    image: image,
                    zoom: zoomState,
                    sourcePixelSize: sourcePixelSize(of: image),
                    onDisplayRectChange: { imageDisplayRect = $0 },
                    onNeedsMorePixels: { imageNeedsMorePixels() }
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
        .alert("Export", isPresented: Binding(
            get: { viewModel.exportFailure != nil },
            set: { if !$0 { viewModel.exportFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.exportFailure ?? "")
        }
        .onDisappear {
            if viewModel.isEditing {
                viewModel.stopEditing(save: true)
            }
            // Leaving the detail view: give back the decoded photos (up to 512 MB), as before task 12.
            fullResolutionTask?.cancel()
            savedEdit.invalidate()
            savedEdit.discardPrefetches()
            FullImageLoader.shared.clear()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewportSize = size
            self.session?.viewportPixelSize = Self.pixelSize(of: size, scale: displayScale)
        }
        // The session renders its passes to fill this view: give each new session the viewport.
        .onChange(of: session.map(ObjectIdentifier.init), initial: true) {
            self.session?.viewportPixelSize = Self.pixelSize(of: viewportSize, scale: displayScale)
        }
        .onChange(of: displayScale) {
            self.session?.viewportPixelSize = Self.pixelSize(of: viewportSize, scale: displayScale)
        }
        .task(id: "\(viewModel.editedFilesVersion)|\(photo.displayPath)") {
            await loadImages()
        }
        .onChange(of: viewModel.savedEditHandoff?.id) {
            adoptSavedEditHandoff()
        }
    }

    // MARK: - Image Loading

    /// Device pixels for `size` points, or nil before the first layout.
    private static func pixelSize(of size: CGSize, scale: CGFloat) -> CGSize? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Device pixels available to the image, or nil before the first layout.
    private var knownViewportPixelSize: CGSize? {
        Self.pixelSize(of: viewportSize, scale: displayScale)
    }

    /// Device pixels available to the image. Before the first layout, a size large enough that nothing is
    /// subsampled (the zoom check upgrades later anyway).
    private var viewportPixelSize: CGSize {
        knownViewportPixelSize ?? CGSize(width: 16384, height: 16384)
    }

    private func loadImages() async {
        let path = photo.displayPath
        let filesVersion = viewModel.editedFilesVersion
        guard path != loadedPath || filesVersion != loadedFilesVersion, !path.isEmpty else { return }
        if let loadedFilesVersion, loadedFilesVersion != filesVersion {
            // An export rewrote a photo file, so cached decodes and renders may hold its old pixels.
            FullImageLoader.shared.clear()
            savedEdit.discardPrefetches()
        }
        requestedPath = path
        fullResolutionTask?.cancel()
        fullResolutionTask = nil
        // A saved-edit render still running for the previous photo must not land on this one.
        savedEdit.invalidate()
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
                savedEdit.clear()
            }
            loadedPath = path
            loadedFilesVersion = filesVersion
            zoomState.reset()
        }
        let next = prefetchNeighbours(of: photo, viewport: viewport)

        // Saved edits: a JPG edit render wins over a RAW one, rendered on the .full lane to fill the viewport.
        await savedEdit.resolve(for: photo, fitting: knownViewportPixelSize,
                                reusing: viewModel.savedEditHandoff.flatMap { $0.photoID == photo.id ? $0 : nil })
        guard !Task.isCancelled else { return }
        // Then the next photo's saved edit, ahead. Not while editing: the session's passes use the same lane.
        if viewModel.editSession == nil {
            savedEdit.prefetch(next.map { [$0] } ?? [], fitting: knownViewportPixelSize)
        }

        let thumbnail = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 400)
        guard !Task.isCancelled else { return }
        minimapThumbnail = thumbnail.flatMap(DisplayImage.init(nsImage:))
    }

    /// Prefetches the photos either side, plus a second one in the direction of travel. Returns the next photo in
    /// the direction of travel, if any.
    private func prefetchNeighbours(of photo: PhotoAsset, viewport: CGSize) -> PhotoAsset? {
        let photos = viewModel.library.photos
        guard let index = viewModel.library.index(of: photo.id) else { return nil }
        let step = (lastIndex.map { index < $0 } ?? false) ? -1 : 1
        lastIndex = index
        let paths = [index + step, index + 2 * step, index - step]
            .filter { photos.indices.contains($0) }
            .map { photos[$0].displayPath }
            .filter { !$0.isEmpty }
        FullImageLoader.shared.prefetchFit(paths: paths, viewportPixelSize: viewport)
        return photos.indices.contains(index + step) ? photos[index + step] : nil
    }

    /// The image on screen is drawn with more device pixels than it has (zoomed in, the viewport grew, a RAW
    /// preview, an edit preview on a large window).
    /// - The session's renders: native once zoomed in past the fitted pass. At fit, the pass after the pause
    ///   fills the viewport (and follows it when it grows).
    /// - The saved edit: native once zoomed in; at fit, a larger render if the viewport grew.
    /// - The loader's image: its full-resolution decode.
    private func imageNeedsMorePixels() {
        guard let shown = currentImage else { return }
        let zoomedIn = zoomState.magnification > 1.001
        if let session, Self.image(shown, shows: session.fullImage) || Self.image(shown, shows: session.previewImage) {
            if zoomedIn { session.requestNativeResolution() }
            return
        }
        if let render = savedEdit.render, Self.image(shown, shows: render.image) {
            savedEdit.needsMorePixels(for: photo, zoomedIn: zoomedIn, fitting: knownViewportPixelSize)
            return
        }
        loadFullResolution()
    }

    /// Swaps in the full-resolution decode when the fit image has fewer pixels than it is drawn with (zoomed
    /// in, the viewport grew, or a RAW preview). Keeps zoom and pan. At most once per photo.
    private func loadFullResolution() {
        // Only for the loader's image; edit renders go through `imageNeedsMorePixels`.
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

    /// A session just saved this photo. `savedEditImage` shows the session's render until the saved edit has been
    /// resolved again, reusing that render when it has the pixels the viewport needs.
    private func adoptSavedEditHandoff() {
        guard let handoff = viewModel.savedEditHandoff, handoff.photoID == photo.id else { return }
        savedEdit.adopt(handoff, for: photo, fitting: knownViewportPixelSize)
    }
}
