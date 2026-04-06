import SwiftUI
import AppKit

// MARK: - Zoom & Pan State

@Observable
@MainActor
final class ZoomPanState {
    var magnification: CGFloat = 1.0
    var baseMagnification: CGFloat = 1.0
    var imageOffset: CGPoint = .zero
    var dragStartOffset: CGPoint = .zero

    // Updated by the view on layout changes
    var fitSize: CGSize = .zero
    var viewportSize: CGSize = .zero

    @ObservationIgnored private var scrollMonitor: Any?

    func startMonitoring() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event) ?? event
        }
    }

    func stopMonitoring() {
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }

    func reset() {
        magnification = 1.0
        baseMagnification = 1.0
        imageOffset = .zero
        dragStartOffset = .zero
    }

    func clampOffset() {
        imageOffset = clamped(imageOffset)
    }

    func clamped(_ offset: CGPoint) -> CGPoint {
        let maxX = max(0, (fitSize.width * magnification - viewportSize.width) / 2)
        let maxY = max(0, (fitSize.height * magnification - viewportSize.height) / 2)
        return CGPoint(
            x: min(max(offset.x, -maxX), maxX),
            y: min(max(offset.y, -maxY), maxY)
        )
    }

    func zoomTo(_ newMagnification: CGFloat) {
        let target = max(1.0, min(newMagnification, 20.0))
        let ratio = target / max(magnification, 0.001)
        magnification = target
        baseMagnification = target
        imageOffset = CGPoint(x: imageOffset.x * ratio, y: imageOffset.y * ratio)
        clampOffset()
        dragStartOffset = imageOffset
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard fitSize.width > 0 else { return event }

        let delta: CGFloat
        if event.hasPreciseScrollingDeltas {
            delta = event.scrollingDeltaY * 0.004
        } else {
            delta = event.scrollingDeltaY * 0.04
        }

        guard abs(delta) > 0.0001 else { return nil }

        let newMag = max(1.0, min(magnification * (1 + delta), 20.0))
        guard abs(newMag - magnification) > 0.001 else { return nil }

        zoomTo(newMag)
        return nil
    }
}

// MARK: - PhotoDetailView

struct PhotoDetailView: View {
    @Bindable var viewModel: PhotoLibraryViewModel
    let photo: PhotoAsset

    @State private var displayedImage: NSImage?
    @State private var renderedEditImage: NSImage?
    @State private var originalImage: NSImage?
    @State private var loadedPath: String?
    @State private var showTagEditor = false
    @State private var minimapThumbnail: NSImage?
    @State private var zoomState = ZoomPanState()
    @State private var imageDisplayRect: CGRect = .zero

    // The active image to show
    private var currentImage: NSImage? {
        if viewModel.isCropping {
            return displayedImage ?? renderedEditImage
        }
        if viewModel.showOriginal {
            return originalImage ?? displayedImage
        }
        if viewModel.isEditing {
            return viewModel.editedPreviewImage ?? renderedEditImage ?? displayedImage
        }
        return renderedEditImage ?? displayedImage
    }

    // For side-by-side: the original image
    private var comparisonOriginal: NSImage? {
        originalImage ?? displayedImage
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.showJPGComparison && viewModel.isEditing && viewModel.editingRAW {
                jpgComparisonView
            } else if viewModel.showSideBySide && viewModel.isEditing {
                sideBySideView
            } else if let image = currentImage {
                singleImageView(image: image)
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
                overlayControls
            }

            // Minimap
            if zoomState.magnification > 1.01, let thumb = minimapThumbnail, !viewModel.isCropping {
                minimapOverlay(thumbnail: thumb)
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
        .onAppear { zoomState.startMonitoring() }
        .onDisappear {
            zoomState.stopMonitoring()
            if viewModel.isEditing {
                viewModel.stopEditing(save: true)
            }
        }
        .task(id: photo.displayPath) {
            await loadImages()
        }
        .onChange(of: viewModel.editParameters) {
            viewModel.updateEditPreview()
        }
    }

    // MARK: - Image Loading

    private func loadImages() async {
        let path = photo.displayPath
        guard path != loadedPath, !path.isEmpty else { return }

        // Load original full-resolution
        if let newImage = await ImageLoader.shared.loadFullResolution(for: path) {
            withAnimation(.easeInOut(duration: 0.15)) {
                displayedImage = newImage
                originalImage = newImage
            }
            loadedPath = path
            zoomState.reset()
        }

        // Check for saved JPG edits and render
        if let params = photo.jpgEditParameters, !params.isDefault, let jpgPath = photo.jpgPath {
            let url = URL(fileURLWithPath: jpgPath)
            renderedEditImage = await ImageEditingService.shared.processStandard(url: url, parameters: params)
        } else {
            renderedEditImage = nil
        }

        // Check for saved RAW edits
        if let rawPath = photo.rawPath {
            if let params = MetadataService.shared.readEditParameters(forRAWAt: rawPath), !params.isDefault {
                let url = URL(fileURLWithPath: rawPath)
                let rendered = await ImageEditingService.shared.processRAW(url: url, parameters: params)
                if rendered != nil && renderedEditImage == nil {
                    renderedEditImage = rendered
                }
            }
        }

        minimapThumbnail = await ImageLoader.shared.loadThumbnail(for: path, maxSize: 400)
    }

    // MARK: - Single Image View

    @ViewBuilder
    private func singleImageView(image: NSImage) -> some View {
        GeometryReader { geometry in
            let fitSize = Self.fittedSize(imageSize: image.size, in: geometry.size)

            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(zoomState.magnification > 4 ? .none : .high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: fitSize.width * zoomState.magnification,
                        height: fitSize.height * zoomState.magnification
                    )
                    .position(
                        x: geometry.size.width / 2 + zoomState.imageOffset.x,
                        y: geometry.size.height / 2 + zoomState.imageOffset.y
                    )

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture())
                    .simultaneousGesture(pinchGesture())
                    .onTapGesture(count: 2) {
                        handleDoubleClick(imageSize: image.size, fitSize: fitSize)
                    }
            }
            .onAppear {
                zoomState.viewportSize = geometry.size
                zoomState.fitSize = fitSize
                updateImageDisplayRect(fitSize: fitSize, geometrySize: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                zoomState.viewportSize = newSize
                let newFit = Self.fittedSize(imageSize: image.size, in: newSize)
                zoomState.fitSize = newFit
                zoomState.clampOffset()
                updateImageDisplayRect(fitSize: newFit, geometrySize: newSize)
            }
        }
        .clipped()
        .transition(.opacity)
    }

    // MARK: - Side-by-Side

    private var sideBySideView: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                if let orig = comparisonOriginal {
                    VStack(spacing: 4) {
                        Text("ORIGINAL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Image(nsImage: orig)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: geometry.size.width / 2)
                }
                if let edited = viewModel.editedPreviewImage ?? renderedEditImage ?? displayedImage {
                    VStack(spacing: 4) {
                        Text("EDITED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Image(nsImage: edited)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: geometry.size.width / 2)
                }
            }
        }
    }

    // MARK: - JPG Comparison

    private var jpgComparisonView: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                if let jpgImage = viewModel.jpgComparisonImage {
                    VStack(spacing: 4) {
                        Text("JPG")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Image(nsImage: jpgImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: geometry.size.width / 2)
                }
                if let edited = viewModel.editedPreviewImage ?? renderedEditImage ?? displayedImage {
                    VStack(spacing: 4) {
                        Text("RAW EDIT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Image(nsImage: edited)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: geometry.size.width / 2)
                }
            }
        }
    }

    private func updateImageDisplayRect(fitSize: CGSize, geometrySize: CGSize) {
        imageDisplayRect = CGRect(
            x: (geometrySize.width - fitSize.width) / 2,
            y: (geometrySize.height - fitSize.height) / 2,
            width: fitSize.width,
            height: fitSize.height
        )
    }

    // MARK: - Geometry

    static func fittedSize(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    // MARK: - Gestures

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard zoomState.magnification > 1.0 else { return }
                let newOffset = CGPoint(
                    x: zoomState.dragStartOffset.x + value.translation.width,
                    y: zoomState.dragStartOffset.y + value.translation.height
                )
                zoomState.imageOffset = zoomState.clamped(newOffset)
            }
            .onEnded { _ in
                zoomState.dragStartOffset = zoomState.imageOffset
            }
    }

    private func pinchGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newMag = max(1.0, min(zoomState.baseMagnification * value.magnification, 20.0))
                let ratio = newMag / max(zoomState.magnification, 0.001)
                zoomState.magnification = newMag
                zoomState.imageOffset = CGPoint(
                    x: zoomState.imageOffset.x * ratio,
                    y: zoomState.imageOffset.y * ratio
                )
                zoomState.clampOffset()
            }
            .onEnded { _ in
                zoomState.baseMagnification = zoomState.magnification
                zoomState.dragStartOffset = zoomState.imageOffset
            }
    }

    private func handleDoubleClick(imageSize: CGSize, fitSize: CGSize) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if zoomState.magnification > 1.01 {
                zoomState.reset()
            } else {
                let pixelScale = imageSize.width / fitSize.width
                let target = pixelScale > 2 ? min(pixelScale, 10.0) : 2.0
                zoomState.magnification = target
                zoomState.baseMagnification = target
            }
        }
    }

    // MARK: - Minimap

    private func minimapOverlay(thumbnail: NSImage) -> some View {
        let minimapWidth: CGFloat = 180
        let aspect = thumbnail.size.height / max(thumbnail.size.width, 1)
        let minimapHeight = minimapWidth * aspect
        let visRect = visibleRectNormalized()

        return VStack {
            Spacer()
            HStack {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: minimapWidth, height: minimapHeight)

                    Canvas { context, size in
                        var path = Path(CGRect(origin: .zero, size: size))
                        let vr = CGRect(
                            x: visRect.minX * size.width,
                            y: visRect.minY * size.height,
                            width: visRect.width * size.width,
                            height: visRect.height * size.height
                        )
                        path.addRect(vr)
                        context.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                        context.stroke(Path(vr), with: .color(.white), lineWidth: 1.5)
                    }
                    .frame(width: minimapWidth, height: minimapHeight)
                    .allowsHitTesting(false)
                }
                .frame(width: minimapWidth, height: minimapHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.3), lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.7)))
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            navigateToNormalized(CGPoint(
                                x: value.location.x / minimapWidth,
                                y: value.location.y / minimapHeight
                            ))
                        }
                )
                .overlay(alignment: .topTrailing) {
                    Text("\(Int(zoomState.magnification * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
                .padding(16)

                Spacer()
            }
        }
    }

    private func visibleRectNormalized() -> CGRect {
        let fs = zoomState.fitSize
        let mag = zoomState.magnification
        let off = zoomState.imageOffset
        let vp = zoomState.viewportSize

        guard fs.width > 0, fs.height > 0, mag > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let visW = min(1.0, vp.width / (fs.width * mag))
        let visH = min(1.0, vp.height / (fs.height * mag))
        let cx = 0.5 - off.x / (fs.width * mag)
        let cy = 0.5 - off.y / (fs.height * mag)

        return CGRect(
            x: max(0, min(cx - visW / 2, 1 - visW)),
            y: max(0, min(cy - visH / 2, 1 - visH)),
            width: visW,
            height: visH
        )
    }

    private func navigateToNormalized(_ point: CGPoint) {
        let nx = min(max(point.x, 0), 1)
        let ny = min(max(point.y, 0), 1)
        let newOffset = CGPoint(
            x: (0.5 - nx) * zoomState.fitSize.width * zoomState.magnification,
            y: (0.5 - ny) * zoomState.fitSize.height * zoomState.magnification
        )
        withAnimation(.easeOut(duration: 0.15)) {
            zoomState.imageOffset = zoomState.clamped(newOffset)
            zoomState.dragStartOffset = zoomState.imageOffset
        }
    }

    // MARK: - Overlay Controls

    private var overlayControls: some View {
        VStack {
            HStack {
                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(photo.fileName)
                        .font(.headline)
                        .foregroundStyle(.white)

                    if photo.hasRawPair {
                        Text("JPG + RAW")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    if let index = viewModel.photos.firstIndex(where: { $0.id == photo.id }) {
                        Text("\(index + 1) / \(viewModel.photos.count)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    if photo.hasAnyEdits {
                        Text("Edited")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.6), in: Capsule())
                    }

                    if !photo.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(photo.tags, id: \.id) { tag in
                                Text(tag.name)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }

                    // Edit buttons
                    HStack(spacing: 8) {
                        if photo.rawPath != nil {
                            editButton(isRAW: true)
                        }
                        if photo.jpgPath != nil {
                            editButton(isRAW: false)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding()
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }

            Spacer()

            HStack {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: Circle())
                    .contentShape(Circle())
                    .onTapGesture { viewModel.navigateDetail(direction: -1) }

                Spacer()

                VStack(spacing: 8) {
                    RatingView(rating: photo.rating) { newRating in
                        viewModel.setRating(newRating, for: photo)
                    }

                    HStack(spacing: 12) {
                        Text("Tags")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.2), in: Capsule())
                            .contentShape(Capsule())
                            .onTapGesture { showTagEditor.toggle() }
                    }
                }
                .padding()
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: Circle())
                    .contentShape(Circle())
                    .onTapGesture { viewModel.navigateDetail(direction: 1) }
            }
            .padding()
        }
    }

    // MARK: - Edit Buttons

    private func editButton(isRAW: Bool) -> some View {
        let isActive = viewModel.isEditing && viewModel.editingRAW == isRAW
        return Button(action: {
            if isActive {
                viewModel.stopEditing(save: true)
            } else {
                viewModel.startEditing(photo: photo, isRAW: isRAW)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isRAW ? "camera.filters" : "photo.on.rectangle")
                    .font(.caption)
                Text(isRAW ? "RAW" : "JPG")
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isActive
                    ? (isRAW ? Color.blue : Color.orange)
                    : (isRAW ? Color.blue.opacity(0.4) : Color.orange.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
