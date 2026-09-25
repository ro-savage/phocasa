import SwiftUI
import AppKit

// MARK: - Zoom & Pan State

/// Zoom and pan for the detail image. Only `ZoomableImageView` and `MinimapView` read it, so zoom and pan
/// frames invalidate only those two views (spec §D3). `PhotoDetailView` creates it (so it survives switching
/// to a comparison view and back) and resets it on navigation, but never reads it.
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

    /// The image viewport in the window's content coordinates (SwiftUI `.global`, top-left origin).
    /// `.zero` while no single image is shown, so no scroll event is taken.
    @ObservationIgnored var viewportFrame: CGRect = .zero

    @ObservationIgnored private var scrollMonitor: Any?
    @ObservationIgnored private weak var hostWindow: NSWindow?

    func startMonitoring() {
        guard scrollMonitor == nil else { return }
        // The detail view opens from a click or key press in its own window, so that window is key.
        hostWindow = NSApp.keyWindow ?? NSApp.mainWindow
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

    /// The monitor is app-wide, so only take scroll events over the image viewport in the detail view's own
    /// window. Everything else (the edit sidebar's `ScrollView`, the tag popover's `List`, other windows)
    /// gets its event back untouched (spec §D5).
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard Self.shouldHandleScroll(eventWindow: event.window, hostWindow: hostWindow,
                                      locationInWindow: event.locationInWindow,
                                      windowHeight: event.window?.frame.height ?? 0,
                                      viewportFrame: viewportFrame) else { return event }
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

    /// Whether a scroll at `locationInWindow` (AppKit window coordinates, bottom-left origin) falls inside
    /// `viewportFrame` (SwiftUI `.global`, top-left origin).
    ///
    /// `windowHeight` is the height of the window's *frame*: SwiftUI's `.global` space starts at the top of the
    /// window frame, title bar included, not at the top of the content view (checked in
    /// `DetailViewTests.testGlobalFrameMatchesFlippedWindowCoordinates`). The two only agree for windows with a
    /// full-size content view.
    nonisolated static func shouldHandleScroll(locationInWindow: CGPoint, windowHeight: CGFloat,
                                               viewportFrame: CGRect) -> Bool {
        guard viewportFrame.width > 0, viewportFrame.height > 0 else { return false }
        let flipped = CGPoint(x: locationInWindow.x, y: windowHeight - locationInWindow.y)
        return viewportFrame.contains(flipped)
    }

    /// As above, and only for events in the detail view's own window.
    nonisolated static func shouldHandleScroll(eventWindow: AnyObject?, hostWindow: AnyObject?,
                                               locationInWindow: CGPoint, windowHeight: CGFloat,
                                               viewportFrame: CGRect) -> Bool {
        guard let hostWindow, let eventWindow, eventWindow === hostWindow else { return false }
        return shouldHandleScroll(locationInWindow: locationInWindow, windowHeight: windowHeight,
                                  viewportFrame: viewportFrame)
    }
}

// MARK: - ZoomableImageView

/// The detail image with zoom, pan, pinch and double-click. All fit and zoom maths use the image's
/// `orientedSize`, so rotated photos fit, zoom and crop as displayed.
///
/// Equatable on its inputs (`.equatable()` at the call site), so a container re-evaluation that doesn't change
/// the image (every edit slider tick) doesn't re-run this body; zoom and pan changes arrive via Observation.
struct ZoomableImageView: View, @preconcurrency Equatable {
    let image: DisplayImage
    let zoom: ZoomPanState
    /// Oriented pixel size of the photo itself, when `image` is a subsampled decode or a RAW preview of it.
    /// The double-click zoom target is computed from it, as it was from the full-resolution image before.
    var sourcePixelSize: CGSize?
    /// The unzoomed image rect in this view's coordinates (the crop overlay's `imageDisplayRect`).
    var onDisplayRectChange: (CGRect) -> Void = { _ in }
    /// Called when the image is shown with more screen pixels than it has (zoomed in, or the viewport grew),
    /// so the container can swap in a higher-resolution decode.
    var onNeedsMorePixels: () -> Void = {}

    @Environment(\.displayScale) private var displayScale

    static func == (lhs: ZoomableImageView, rhs: ZoomableImageView) -> Bool {
        lhs.image == rhs.image && lhs.zoom === rhs.zoom && lhs.sourcePixelSize == rhs.sourcePixelSize
    }

    var body: some View {
        GeometryReader { geometry in
            let fitSize = Self.fittedSize(imageSize: image.orientedSize, in: geometry.size)
            let needsMorePixels = Self.needsMorePixels(imagePixelSize: image.orientedSize, fitSize: fitSize,
                                                       magnification: zoom.magnification, displayScale: displayScale)

            ZStack {
                OrientedImage(image, interpolation: zoom.magnification > 4 ? .none : .high)
                    .aspectRatio(image.orientedSize, contentMode: .fit)
                    .frame(
                        width: fitSize.width * zoom.magnification,
                        height: fitSize.height * zoom.magnification
                    )
                    .position(
                        x: geometry.size.width / 2 + zoom.imageOffset.x,
                        y: geometry.size.height / 2 + zoom.imageOffset.y
                    )

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture())
                    .simultaneousGesture(pinchGesture())
                    .onTapGesture(count: 2) {
                        handleDoubleClick(imageSize: sourcePixelSize ?? image.orientedSize, fitSize: fitSize)
                    }
            }
            .onAppear {
                zoom.viewportSize = geometry.size
                zoom.viewportFrame = geometry.frame(in: .global)
                zoom.fitSize = fitSize
                onDisplayRectChange(Self.displayRect(fitSize: fitSize, in: geometry.size))
                zoom.startMonitoring()
            }
            .onChange(of: geometry.size) { _, newSize in
                zoom.viewportSize = newSize
                let newFit = Self.fittedSize(imageSize: image.orientedSize, in: newSize)
                zoom.fitSize = newFit
                zoom.clampOffset()
                onDisplayRectChange(Self.displayRect(fitSize: newFit, in: newSize))
            }
            .onChange(of: fitSize) { _, newFit in
                // A new image with another aspect ratio (a portrait photo after a landscape one, a crop).
                zoom.fitSize = newFit
                zoom.clampOffset()
                onDisplayRectChange(Self.displayRect(fitSize: newFit, in: geometry.size))
            }
            .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                zoom.viewportFrame = newFrame
            }
            // Keyed on the image too: a new image that is also short of pixels must ask again.
            .onChange(of: needsMorePixels ? ObjectIdentifier(image.cgImage) : nil, initial: true) { _, short in
                if short != nil { onNeedsMorePixels() }
            }
            .onDisappear {
                zoom.viewportFrame = .zero
                zoom.stopMonitoring()
            }
        }
        .clipped()
        .transition(.opacity)
    }

    // MARK: - Geometry

    nonisolated static func fittedSize(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Whether the image is drawn with more device pixels than it has.
    nonisolated static func needsMorePixels(imagePixelSize: CGSize, fitSize: CGSize, magnification: CGFloat,
                                            displayScale: CGFloat) -> Bool {
        guard imagePixelSize.width > 0, fitSize.width > 0 else { return false }
        return fitSize.width * magnification * displayScale > imagePixelSize.width + 0.5
    }

    nonisolated static func displayRect(fitSize: CGSize, in container: CGSize) -> CGRect {
        CGRect(
            x: (container.width - fitSize.width) / 2,
            y: (container.height - fitSize.height) / 2,
            width: fitSize.width,
            height: fitSize.height
        )
    }

    // MARK: - Gestures

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard zoom.magnification > 1.0 else { return }
                let newOffset = CGPoint(
                    x: zoom.dragStartOffset.x + value.translation.width,
                    y: zoom.dragStartOffset.y + value.translation.height
                )
                zoom.imageOffset = zoom.clamped(newOffset)
            }
            .onEnded { _ in
                zoom.dragStartOffset = zoom.imageOffset
            }
    }

    private func pinchGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newMag = max(1.0, min(zoom.baseMagnification * value.magnification, 20.0))
                let ratio = newMag / max(zoom.magnification, 0.001)
                zoom.magnification = newMag
                zoom.imageOffset = CGPoint(
                    x: zoom.imageOffset.x * ratio,
                    y: zoom.imageOffset.y * ratio
                )
                zoom.clampOffset()
            }
            .onEnded { _ in
                zoom.baseMagnification = zoom.magnification
                zoom.dragStartOffset = zoom.imageOffset
            }
    }

    private func handleDoubleClick(imageSize: CGSize, fitSize: CGSize) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if zoom.magnification > 1.01 {
                zoom.reset()
            } else {
                let pixelScale = imageSize.width / fitSize.width
                let target = pixelScale > 2 ? min(pixelScale, 10.0) : 2.0
                zoom.magnification = target
                zoom.baseMagnification = target
            }
        }
    }
}
