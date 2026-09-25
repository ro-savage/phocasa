import SwiftUI
import AppKit

/// Detail view container: loads the photo's images and chooses which one to show. Zoom and pan live in
/// `ZoomableImageView` and `MinimapView`, the chrome in `DetailOverlayControls`, so zoom and pan frames don't
/// re-evaluate this body (spec §D3).
struct PhotoDetailView: View {
    @Bindable var viewModel: PhotoLibraryViewModel
    let photo: PhotoAsset

    // Images carry their EXIF orientation, applied at display time (spec §D1).
    @State private var displayedImage: DisplayImage?
    @State private var renderedEditImage: DisplayImage?
    @State private var originalImage: DisplayImage?
    @State private var loadedPath: String?
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
    @State private var fullResolutionTask: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale

    // The active image to show. Edit-pipeline images are NSImages that are already upright.
    private var currentImage: DisplayImage? {
        if viewModel.isCropping {
            return displayedImage ?? renderedEditImage
        }
        if viewModel.showOriginal {
            return originalImage ?? displayedImage
        }
        if viewModel.isEditing {
            return (viewModel.fullResEditImage ?? viewModel.editedPreviewImage).flatMap(DisplayImage.init(nsImage:))
                ?? renderedEditImage ?? displayedImage
        }
        return renderedEditImage ?? displayedImage
    }

    // For side-by-side: the original image
    private var comparisonOriginal: DisplayImage? {
        originalImage ?? displayedImage
    }

    // For side-by-side and the JPG comparison: the edited image
    private var comparisonEdited: DisplayImage? {
        viewModel.editedPreviewImage.flatMap(DisplayImage.init(nsImage:)) ?? renderedEditImage ?? displayedImage
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.showJPGComparison && viewModel.isEditing && viewModel.editingRAW {
                // Still unrotated for portrait JPGs: the view model loads it with loadFullResolution (task 22).
                ComparisonView(left: ("JPG", viewModel.jpgComparisonImage.flatMap(DisplayImage.init(nsImage:))),
                               right: ("RAW EDIT", comparisonEdited))
            } else if viewModel.showSideBySide && viewModel.isEditing {
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
            if viewModel.isCropping {
                CropOverlayView(
                    cropRect: $viewModel.cropRect,
                    rotation: $viewModel.editParameters.rotation,
                    imageDisplayRect: imageDisplayRect,
                    onApply: { viewModel.applyCrop() },
                    onCancel: { viewModel.cancelCrop() }
                )
            }

            // UI overlays (hidden during crop)
            if !viewModel.isCropping {
                DetailOverlayControls(viewModel: viewModel, photo: photo, onShowTags: { showTagEditor.toggle() })
                    .equatable()
            }

            // Minimap (shows itself only while zoomed in)
            if let thumb = minimapThumbnail, !viewModel.isCropping {
                MinimapView(zoom: zoomState, thumbnail: thumb)
            }
        }
        .popover(isPresented: $showTagEditor) {
            TagEditorView(viewModel: viewModel, photo: photo)
                .frame(width: 300, height: 400)
        }
        .confirmationDialog("Export RAW Edit", isPresented: $viewModel.showExportOptions) {
            if photo.jpgPath != nil {
                Button("Replace existing JPG") {
                    viewModel.exportRAWToJPG(replaceExisting: true)
                }
            }
            Button("Create new file (-raw-edit)") {
                viewModel.exportRAWToJPG(replaceExisting: false)
            }
            if !viewModel.editingRAW && photo.jpgPath != nil {
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
            FullImageLoader.shared.clear()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .task(id: photo.displayPath) {
            await loadImages()
        }
        .onChange(of: viewModel.editParameters) {
            viewModel.updateEditPreview()
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
        guard path != loadedPath, !path.isEmpty else { return }
        fullResolutionTask?.cancel()
        fullResolutionTask = nil
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
                renderedEditImage = nil
            }
            loadedPath = path
            zoomState.reset()
        }
        prefetchNeighbours(of: photo, viewport: viewport)

        // Saved edits: a JPG edit render wins over a RAW one.
        var jpgRender: (() async -> NSImage?)?
        if let params = photo.jpgEditParameters, !params.isDefault, let jpgPath = photo.jpgPath {
            jpgRender = { await ImageEditingService.shared.processStandard(url: URL(fileURLWithPath: jpgPath), parameters: params) }
        }
        var rawRender: (() async -> NSImage?)?
        if let rawPath = photo.rawPath {
            rawRender = {
                guard let params = MetadataService.shared.readEditParameters(forRAWAt: rawPath), !params.isDefault else { return nil }
                return await ImageEditingService.shared.processRAW(url: URL(fileURLWithPath: rawPath), parameters: params)
            }
        }
        let savedEdit = await Self.renderSavedEdit(jpg: jpgRender, raw: rawRender)
        guard !Task.isCancelled else { return }
        renderedEditImage = savedEdit.flatMap(DisplayImage.init(nsImage:))

        let thumbnail = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 400)
        guard !Task.isCancelled else { return }
        minimapThumbnail = thumbnail.flatMap(DisplayImage.init(nsImage:))
    }

    /// Prefetches the photos either side, plus a second one in the direction of travel. One `firstIndex` per
    /// navigation (task 30 swaps it for an index lookup).
    private func prefetchNeighbours(of photo: PhotoAsset, viewport: CGSize) {
        let photos = viewModel.photos
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
        // Only for the loader's image: edit renders are produced at full resolution by the view model.
        guard fullResolutionTask == nil, currentImage == displayedImage, let path = loadedPath, let shown = displayedImage,
              let info = FullImageLoader.shared.cachedInfo(path: path),
              shown.pixelSize != info.pixelSize || shown.orientation != info.orientation else { return }
        fullResolutionTask = Task {
            let full = await FullImageLoader.shared.load(path: path, subsample: 1)
            guard !Task.isCancelled, let full, loadedPath == path, displayedImage == shown else { return }
            displayedImage = full
            originalImage = full
        }
    }

    /// The saved-edit render to show. The JPG render takes precedence, so the RAW render, which takes seconds
    /// at full resolution, runs only when there is no JPG render. Before, both ran and the RAW result was
    /// thrown away whenever the photo had both (spec §D4).
    static func renderSavedEdit(jpg: (() async -> NSImage?)?, raw: (() async -> NSImage?)?) async -> NSImage? {
        if let jpg, let rendered = await jpg() { return rendered }
        if let raw { return await raw() }
        return nil
    }
}
