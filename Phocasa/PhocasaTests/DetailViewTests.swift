import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftData
@testable import Phocasa

/// Detail-view logic that can be checked without UI automation.
final class DetailViewTests: XCTestCase {

    // MARK: - Scroll-wheel monitor (spec §D5)

    /// Window 1000×700 (AppKit, bottom-left origin); image viewport 800×600 at the top-left, below a
    /// 100 pt band (title bar and toolbar); an edit sidebar to its right.
    private let windowHeight: CGFloat = 700
    private let viewport = CGRect(x: 0, y: 100, width: 800, height: 600)

    func testScrollInsideViewportIsHandled() {
        // AppKit y 300 → top-left y 400, inside 100..<700.
        XCTAssertTrue(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 400, y: 300), windowHeight: windowHeight, viewportFrame: viewport))
    }

    func testScrollOverEditSidebarIsNotHandled() {
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 900, y: 300), windowHeight: windowHeight, viewportFrame: viewport))
    }

    func testScrollConvertsFromBottomLeftOrigin() {
        // Near the top of the window in AppKit terms (y 650) is the toolbar band in top-left terms (y 50).
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 400, y: 650), windowHeight: windowHeight, viewportFrame: viewport))
        // Near the bottom in AppKit terms (y 50) is inside the viewport (top-left y 650).
        XCTAssertTrue(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 400, y: 50), windowHeight: windowHeight, viewportFrame: viewport))
    }

    func testScrollWithoutViewportIsNotHandled() {
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            locationInWindow: CGPoint(x: 10, y: 10), windowHeight: windowHeight, viewportFrame: .zero))
    }

    func testScrollInAnotherWindowIsNotHandled() {
        let host = NSObject(), popover = NSObject()
        let inside = CGPoint(x: 400, y: 300)
        XCTAssertTrue(ZoomPanState.shouldHandleScroll(
            eventWindow: host, hostWindow: host, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport))
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            eventWindow: popover, hostWindow: host, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport), "e.g. the tag popover's own window")
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            eventWindow: nil, hostWindow: host, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport))
        XCTAssertFalse(ZoomPanState.shouldHandleScroll(
            eventWindow: nil, hostWindow: nil, locationInWindow: inside,
            windowHeight: windowHeight, viewportFrame: viewport), "no host window captured: never consume")
    }

    // MARK: - Portrait photos in the detail image view (spec §D1)

    /// A 60×40 bitmap tagged orientation 6 (`.right`) displays as 40×60. In a 120×120 viewport it must be fitted
    /// by its oriented size (80×120, letterboxed left and right) and drawn upright.
    @MainActor
    func testZoomableImageViewFitsAndDrawsPortraitPhotoUpright() throws {
        let stored = try makeQuadrantBitmap(width: 60, height: 40)
        let display = DisplayImage(cgImage: stored, orientation: .right)
        let renderer = ImageRenderer(content: ZoomableImageView(image: display, zoom: ZoomPanState())
            .frame(width: 120, height: 120))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.cgImage)
        let pixels = try readRGBA(rendered)

        // Letterbox: nothing drawn left of x = 20 or right of x = 100.
        XCTAssertEqual(pixels(5, 60).a, 0, "left of the fitted image")
        XCTAssertEqual(pixels(114, 60).a, 0, "right of the fitted image")
        // EXIF 6: stored row 0 is the displayed right edge, stored column 0 the displayed top edge. So the
        // stored quadrants red TL, blue TR, green BL, white BR display as green TL, red TR, white BL, blue BR.
        XCTAssertTrue(pixels(40, 30).isClose(to: RGBA(r: 0, g: 255, b: 0, a: 255)), "top-left: \(pixels(40, 30))")
        XCTAssertTrue(pixels(80, 30).isClose(to: RGBA(r: 255, g: 0, b: 0, a: 255)), "top-right: \(pixels(80, 30))")
        XCTAssertTrue(pixels(40, 90).isClose(to: RGBA(r: 255, g: 255, b: 255, a: 255)), "bottom-left: \(pixels(40, 90))")
        XCTAssertTrue(pixels(80, 90).isClose(to: RGBA(r: 0, g: 0, b: 255, a: 255)), "bottom-right: \(pixels(80, 90))")
    }

    /// Full resolution is requested once the image is drawn with more device pixels than it has.
    func testNeedsMorePixels() {
        // A subsample-2 decode (3000 px) fitted at 1500 pt on a 2× display is exactly 1:1.
        XCTAssertFalse(ZoomableImageView.needsMorePixels(imagePixelSize: CGSize(width: 3000, height: 2000),
                                                         fitSize: CGSize(width: 1500, height: 1000),
                                                         magnification: 1, displayScale: 2))
        // Zooming in past that needs the full decode.
        XCTAssertTrue(ZoomableImageView.needsMorePixels(imagePixelSize: CGSize(width: 3000, height: 2000),
                                                        fitSize: CGSize(width: 1500, height: 1000),
                                                        magnification: 1.1, displayScale: 2))
        // A 1616 px RAW preview in a 1728 pt wide fit on a 2× display is short of pixels without zooming.
        XCTAssertTrue(ZoomableImageView.needsMorePixels(imagePixelSize: CGSize(width: 1616, height: 1080),
                                                        fitSize: CGSize(width: 1728, height: 1155),
                                                        magnification: 1, displayScale: 2))
        XCTAssertFalse(ZoomableImageView.needsMorePixels(imagePixelSize: .zero, fitSize: CGSize(width: 10, height: 10),
                                                         magnification: 5, displayScale: 2))
    }

    /// The crop overlay's `imageDisplayRect` comes from the oriented size.
    func testCropDisplayRectUsesOrientedSize() throws {
        let display = DisplayImage(cgImage: try makeQuadrantBitmap(width: 60, height: 40), orientation: .left)
        let container = CGSize(width: 120, height: 120)
        let fit = ZoomableImageView.fittedSize(imageSize: display.orientedSize, in: container)
        XCTAssertEqual(fit, CGSize(width: 80, height: 120))
        XCTAssertEqual(ZoomableImageView.displayRect(fitSize: fit, in: container), CGRect(x: 20, y: 0, width: 80, height: 120))
    }

    // MARK: - Loading, prefetch and full resolution, in a hosted window

    /// Opens the detail view on photo 0 of 3 in a small window and checks, through the shared loader's cache:
    /// the neighbours are prefetched at the fit subsample; navigating to photo 1 needs no decode; growing the
    /// window past the fit image's pixels loads full resolution.
    @MainActor
    func testDetailViewPrefetchesNeighboursAndUpgradesToFullResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhocasaDetailViewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = FullImageLoader.shared
        loader.clear()
        defer { loader.clear() }

        let paths = try (0..<3).map { i -> String in
            let url = dir.appendingPathComponent("photo\(i).jpg")
            try writeJPEG(makeQuadrantBitmap(width: 2400, height: 1600), to: url)
            return url.path
        }
        // The library is read from the store by loadExistingData(), so seed it there. Newest first, so the grid
        // order is photo0, photo1, photo2.
        let container = try ModelContainer(
            for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let base = Date()
        for (i, path) in paths.enumerated() {
            context.insert(PhotoAsset(fileName: (path as NSString).lastPathComponent, jpgPath: path, folderPath: dir.path,
                                      creationDate: base.addingTimeInterval(Double(-i) * 60)))
        }
        try context.save()
        let viewModel = PhotoLibraryViewModel()
        viewModel.setModelContext(context)
        let photos = viewModel.library.photos
        XCTAssertEqual(photos.map(\.jpgPath), paths)
        viewModel.openDetail(for: photos[0])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: DetailHost(viewModel: viewModel))
        let scale = window.backingScaleFactor
        let small = CGSize(width: 400 * scale, height: 300 * scale)
        let smallFactor = FullImageLoader.subsampleFactor(imagePixelSize: CGSize(width: 2400, height: 1600),
                                                          viewportPixelSize: small)
        XCTAssertGreaterThan(smallFactor, 1, "the small window should need fewer pixels than the photo has")

        // Photo 0 at the fit subsample, then photos 1 and 2 (forward) prefetched at theirs.
        for path in paths {
            let cached = spin(until: { loader.cachedImage(path: path, subsample: smallFactor) })
            XCTAssertNotNil(cached, "\((path as NSString).lastPathComponent) at subsample \(smallFactor)")
        }
        XCTAssertNil(loader.cachedImage(path: paths[0], subsample: 1), "no full-resolution decode at fit")
        let decodesBeforeNavigation = loader.decodeCount

        viewModel.navigateDetail(direction: 1)
        _ = spin(seconds: 0.5, until: { nil as Int? })
        XCTAssertEqual(loader.decodeCount, decodesBeforeNavigation, "photo 1 came from the prefetch cache")

        // A bigger window draws photo 1 with more pixels than the fit decode has: full resolution loads.
        window.setContentSize(NSSize(width: 1400, height: 1000))
        let full = spin(until: { loader.cachedImage(path: paths[1], subsample: 1) })
        XCTAssertNotNil(full, "growing the viewport loads full resolution")
        XCTAssertEqual(full?.cgImage.width, 2400)
    }

    // MARK: - Saved edit renders (spec §D4)

    @MainActor
    func testSavedJPGEditSkipsRAWRender() async {
        let jpgImage = NSImage(size: NSSize(width: 4, height: 4))
        var rawRendered = false
        let shown = await SavedEdit.render(
            jpg: { jpgImage },
            raw: { rawRendered = true; return NSImage(size: NSSize(width: 8, height: 8)) })
        XCTAssertTrue(shown === jpgImage)
        XCTAssertFalse(rawRendered, "the RAW render would be discarded, so it must not run")
    }

    @MainActor
    func testSavedRAWEditRendersWithoutJPGEdit() async {
        let rawImage = NSImage(size: NSSize(width: 8, height: 8))
        let shown = await SavedEdit.render(jpg: nil, raw: { rawImage })
        XCTAssertTrue(shown === rawImage)
    }

    @MainActor
    func testSavedRAWEditRendersWhenJPGRenderFails() async {
        let rawImage = NSImage(size: NSSize(width: 8, height: 8))
        let shown = await SavedEdit.render(jpg: { nil }, raw: { rawImage })
        XCTAssertTrue(shown === rawImage)
    }

    @MainActor
    func testNoSavedEditsRenderNothing() async {
        let shown: NSImage? = await SavedEdit.render(jpg: nil, raw: nil)
        XCTAssertNil(shown)
    }

    // MARK: - After a save, the detail view shows the saved edit (task 22)

    /// Bug (found in the wave-1 app check): after saving an edit (Escape, or the edit button), the detail view
    /// showed the unedited photo until you navigated away and back. Here the full-resolution pass has finished
    /// before the save, so the saved edit is shown straight from the session's render, without rendering again.
    @MainActor
    func testDetailViewShowsSavedEditAfterSaving() throws {
        let setup = try SavedEditHost()
        defer { setup.close() }
        let original = try XCTUnwrap(setup.waitForPhoto())

        let session = try setup.editBrightly()
        XCTAssertNotNil(spin(until: { session.fullImage }), "the full-resolution pass finishes")
        let edited = try XCTUnwrap(spin(until: { setup.centreLuma() > original + 50 ? setup.centreLuma() : nil }))

        let rendersBeforeSave = ImageEditingService.shared.renderCount
        setup.viewModel.stopEditing(save: true)
        let darkest = setup.darkestLuma(over: 1)
        XCTAssertGreaterThan(darkest, original + 50,
                             "after saving, the detail view shows the saved edit (luma \(edited)), not the unedited image (luma \(original)); darkest seen \(darkest)")
        XCTAssertEqual(ImageEditingService.shared.renderCount, rendersBeforeSave,
                       "the session's full-resolution render is reused, not rendered again")
        XCTAssertNotNil(setup.photo.jpgEditParameters, "the edit was saved")
    }

    /// Same, but the save comes right after the first preview, before the 300 ms full pass: the preview stands in
    /// until the saved edit has been rendered at full resolution.
    @MainActor
    func testDetailViewShowsSavedEditWhenSavedBeforeTheFullPass() throws {
        let setup = try SavedEditHost()
        defer { setup.close() }
        let original = try XCTUnwrap(setup.waitForPhoto())

        let session = try setup.editBrightly()
        XCTAssertNotNil(spin(until: { session.previewImage }))
        // The preview is on screen (drawn on a later run-loop pass than the one that set it).
        XCTAssertNotNil(spin(seconds: 0.25, until: { setup.centreLuma() > original + 50 ? true : nil }))
        XCTAssertNil(session.fullImage, "saving before the full-resolution pass")
        setup.viewModel.stopEditing(save: true)

        let darkest = setup.darkestLuma(over: 1)
        XCTAssertGreaterThan(darkest, original + 50, "the unedited photo (luma \(original)) must not show; darkest \(darkest)")
    }

    // MARK: - What shows between the save and the saved edit's render

    private func handoff(isRAW: Bool, exposure: Double, image: NSImage?, full: Bool = true) -> SavedEditHandoff {
        var params = EditParameters()
        params.exposure = exposure
        return SavedEditHandoff(photoID: UUID(), saved: SavedEditKey(isRAW: isRAW, parameters: params), image: image,
                                imageParameters: params, isFullResolution: full)
    }

    private func params(exposure: Double) -> EditParameters {
        var params = EditParameters()
        params.exposure = exposure
        return params
    }

    func testInterimShowsTheSessionWhenItsEditWins() {
        let sessionImage = NSImage(size: NSSize(width: 2, height: 2))
        // A JPG session with edits: the JPG edit wins.
        XCTAssertTrue(SavedEdit.interimImage(after: handoff(isRAW: false, exposure: 1, image: sessionImage),
                                             jpgParameters: params(exposure: 1), current: nil) === sessionImage)
        // A RAW session, no JPG edit: the RAW edit wins.
        XCTAssertTrue(SavedEdit.interimImage(after: handoff(isRAW: true, exposure: 1, image: sessionImage),
                                             jpgParameters: nil, current: nil) === sessionImage)
    }

    func testInterimKeepsTheJPGEditOverASavedRAWEdit() {
        let sessionImage = NSImage(size: NSSize(width: 2, height: 2))
        let jpgRender = SavedEditRender(key: SavedEditKey(isRAW: false, parameters: params(exposure: 2)),
                                        image: NSImage(size: NSSize(width: 3, height: 3)))
        let shown = SavedEdit.interimImage(after: handoff(isRAW: true, exposure: 1, image: sessionImage),
                                           jpgParameters: params(exposure: 2), current: jpgRender)
        XCTAssertTrue(shown === jpgRender.image, "a JPG edit wins over a RAW one, as when the photo is reopened")
    }

    func testInterimAfterClearingEdits() {
        let rawRender = SavedEditRender(key: SavedEditKey(isRAW: true, parameters: params(exposure: 2)),
                                        image: NSImage(size: NSSize(width: 3, height: 3)))
        // Clearing the JPG edit uncovers the RAW edit already known.
        XCTAssertTrue(SavedEdit.interimImage(after: handoff(isRAW: false, exposure: 0, image: nil),
                                             jpgParameters: nil, current: rawRender) === rawRender.image)
        // Clearing the RAW edit, with no JPG edit: nothing to show but the photo.
        XCTAssertNil(SavedEdit.interimImage(after: handoff(isRAW: true, exposure: 0, image: nil),
                                            jpgParameters: nil, current: rawRender))
        // Clearing the JPG edit when the RAW edit isn't known yet: the photo until it has been read.
        XCTAssertNil(SavedEdit.interimImage(after: handoff(isRAW: false, exposure: 0, image: nil),
                                            jpgParameters: nil, current: nil))
    }

    func testInterimKeepsTheRenderOnScreenWhenTheSessionSavedItUnchanged() {
        // A RAW session started and stopped before its first render: no session image, same edit as on screen.
        let rawRender = SavedEditRender(key: SavedEditKey(isRAW: true, parameters: params(exposure: 1)),
                                        image: NSImage(size: NSSize(width: 3, height: 3)))
        XCTAssertTrue(SavedEdit.interimImage(after: handoff(isRAW: true, exposure: 1, image: nil, full: false),
                                             jpgParameters: nil, current: rawRender) === rawRender.image)
        // Changed in the session: the session's render, not the stale one on screen.
        let sessionImage = NSImage(size: NSSize(width: 2, height: 2))
        XCTAssertTrue(SavedEdit.interimImage(after: handoff(isRAW: true, exposure: 2, image: sessionImage),
                                             jpgParameters: nil, current: rawRender) === sessionImage)
    }

    func testHandoffReusesOnlyAFinishedFullResolutionRenderOfTheSavedEdit() {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let key = SavedEditKey(isRAW: false, parameters: params(exposure: 1))
        XCTAssertTrue(handoff(isRAW: false, exposure: 1, image: image).fullResolutionImage(for: key) === image)
        XCTAssertNil(handoff(isRAW: false, exposure: 1, image: image, full: false).fullResolutionImage(for: key),
                     "a preview is too small to keep")
        XCTAssertNil(handoff(isRAW: true, exposure: 1, image: image).fullResolutionImage(for: key), "another kind")
        let lagging = SavedEditHandoff(photoID: UUID(), saved: key, image: image,
                                       imageParameters: params(exposure: 0.5), isFullResolution: true)
        XCTAssertNil(lagging.fullResolutionImage(for: key), "the render shows an earlier slider value")
    }

    /// The monitor compares `NSEvent.locationInWindow`, flipped with the window's height, against a SwiftUI
    /// `.global` frame. Check that against ground truth in a real hosting window, with and without a full-size
    /// content view: an AppKit probe view placed exactly where the viewport is reports its own window-coordinate
    /// rect. (Flipping with the *content view's* height instead is off by the title bar in the non-full-size case.)
    @MainActor
    func testGlobalFrameMatchesFlippedWindowCoordinates() throws {
        for fullSize in [false, true] {
            let probe = FrameProbe()
            let root = VStack(spacing: 0) {
                Color.clear.frame(height: 40)
                HStack(spacing: 0) {
                    Color.clear.frame(width: 30)
                    GeometryReader { geo in
                        ProbeView(probe: probe)
                            .onAppear { probe.frame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, new in probe.frame = new }
                    }
                    .frame(width: 200, height: 150)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 300, height: 260)

            var style: NSWindow.StyleMask = [.titled]
            if fullSize { style.insert(.fullSizeContentView) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                                  styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: root)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(2)
            while (probe.frame == .zero || probe.view?.window == nil) && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                hosting.layoutSubtreeIfNeeded()
            }
            // Let any follow-up layout pass (safe-area insets) settle.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            let frame = probe.frame
            let probeView = try XCTUnwrap(probe.view, "fullSize=\(fullSize)")
            XCTAssertEqual(frame.size, CGSize(width: 200, height: 150), "fullSize=\(fullSize)")

            // Ground truth: where the viewport really is, in window coordinates (bottom-left origin).
            let truth = probeView.convert(probeView.bounds, to: nil)
            XCTAssertEqual(truth.size, CGSize(width: 200, height: 150), "fullSize=\(fullSize)")
            let windowHeight = window.frame.height
            func handles(_ p: CGPoint) -> Bool {
                ZoomPanState.shouldHandleScroll(locationInWindow: p, windowHeight: windowHeight, viewportFrame: frame)
            }
            let context = "fullSize=\(fullSize) global=\(frame) truth(window)=\(truth) windowHeight=\(windowHeight)"
            XCTAssertTrue(handles(CGPoint(x: truth.midX, y: truth.midY)), context)
            XCTAssertTrue(handles(CGPoint(x: truth.minX + 3, y: truth.maxY - 3)), "top-left corner: " + context)
            XCTAssertTrue(handles(CGPoint(x: truth.maxX - 3, y: truth.minY + 3)), "bottom-right corner: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.maxX + 3, y: truth.midY)), "right of it: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.minX - 3, y: truth.midY)), "left of it: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.midX, y: truth.maxY + 3)), "above it: " + context)
            XCTAssertFalse(handles(CGPoint(x: truth.midX, y: truth.minY - 3)), "below it: " + context)
            window.close()
        }
    }
}

/// Shows the detail view for the view model's current detail photo, as `ContentView` does.
private struct DetailHost: View {
    let viewModel: PhotoLibraryViewModel
    var body: some View {
        if let photo = viewModel.selectedDetailPhoto {
            PhotoDetailView(viewModel: viewModel, photo: photo)
        }
    }
}

/// A mid-grey 300×200 JPG in a temp folder, shown by `PhotoDetailView` in a 400×300 window. The luma of the pixel at
/// the window's centre tells what the detail view draws: the photo, or an edit of it.
@MainActor
private final class SavedEditHost {
    let dir: URL
    let viewModel = PhotoLibraryViewModel()
    let photo: PhotoAsset
    private let container: ModelContainer
    private let window: NSWindow
    private let hosting: NSView

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhocasaSavedEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("grey.jpg")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        try writeJPEG(XCTUnwrap(ctx.makeImage()), to: url)

        container = try ModelContainer(for: PhotoAsset.self, Tag.self, PhotoLibrary.self, EditPreset.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        photo = PhotoAsset(fileName: "grey.jpg", jpgPath: url.path, folderPath: dir.path, creationDate: Date())
        context.insert(photo)
        try context.save()
        viewModel.setModelContext(context)
        viewModel.openDetail(for: photo)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting = NSHostingView(rootView: DetailHost(viewModel: viewModel))
        window.contentView = hosting
    }

    func close() {
        viewModel.stopEditing(save: false)
        window.close()
        FullImageLoader.shared.clear()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Waits for the photo to be on screen and its fade-in to finish; returns its luma.
    func waitForPhoto() -> Int? {
        guard spinRunLoop(until: { centreLuma() > 40 ? true : nil }) != nil else { return nil }
        _ = spinRunLoop(seconds: 0.4, until: { nil as Bool? })
        return centreLuma()
    }

    /// Starts a JPG edit with exposure +2 (much brighter than the photo).
    func editBrightly() throws -> EditSession {
        viewModel.startEditing(photo: photo, isRAW: false)
        let session = try XCTUnwrap(viewModel.editSession)
        session.parameters.exposure = 2
        return session
    }

    /// The darkest centre luma seen while running the run loop for `seconds`.
    func darkestLuma(over seconds: TimeInterval) -> Int {
        var darkest = 255
        _ = spinRunLoop(seconds: seconds, until: { darkest = min(darkest, centreLuma()); return nil as Bool? })
        return darkest
    }

    /// Luma of the pixel at the centre of what the window draws, rendered from its layer tree.
    func centreLuma() -> Int {
        let w = Int(hosting.bounds.width), h = Int(hosting.bounds.height)
        guard w > 0, h > 0, let layer = hosting.layer,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        layer.render(in: ctx)
        let p = data.assumingMemoryBound(to: UInt8.self) + ((h / 2) * w + w / 2) * 4
        return (Int(p[0]) * 299 + Int(p[1]) * 587 + Int(p[2]) * 114) / 1000
    }
}

/// Runs the main run loop (SwiftUI layout, main-actor tasks) until `body` returns non-nil or time runs out.
@MainActor
private func spinRunLoop<T>(seconds: TimeInterval = 5, until body: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let value = body() { return value }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return body()
}

extension DetailViewTests {
    /// Runs the main run loop (so SwiftUI lays out and main-actor tasks run) until `body` returns non-nil or
    /// time runs out.
    @MainActor
    fileprivate func spin<T>(seconds: TimeInterval = 5, until body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = body() { return value }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return body()
    }
}

private func writeJPEG(_ image: CGImage, to url: URL) throws {
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

// MARK: - Bitmap helpers

private struct RGBA: CustomStringConvertible {
    let r: Int, g: Int, b: Int, a: Int
    func isClose(to o: RGBA, tolerance: Int = 8) -> Bool {
        abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance && abs(a - o.a) <= tolerance
    }
    var description: String { "(\(r), \(g), \(b), \(a))" }
}

/// Red top-left, blue top-right, green bottom-left, white bottom-right (as stored).
private func makeQuadrantBitmap(width w: Int, height h: Int) throws -> CGImage {
    let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // CGContext's origin is bottom-left.
    let quadrants: [(CGRect, CGColor)] = [
        (CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
        (CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
        (CGRect(x: 0, y: 0, width: w / 2, height: h / 2), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
        (CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
    ]
    for (rect, colour) in quadrants {
        ctx.setFillColor(colour)
        ctx.fill(rect)
    }
    return try XCTUnwrap(ctx.makeImage())
}

/// Reads `image` through an sRGB RGBA8 bitmap; the returned function takes top-left-origin coordinates.
private func readRGBA(_ image: CGImage) throws -> (Int, Int) -> RGBA {
    let w = image.width, h = image.height, bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
    try pixels.withUnsafeMutableBytes { buffer in
        let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let snapshot = pixels
    return { x, y in
        let i = y * bytesPerRow + x * 4
        return RGBA(r: Int(snapshot[i]), g: Int(snapshot[i + 1]), b: Int(snapshot[i + 2]), a: Int(snapshot[i + 3]))
    }
}

private final class FrameProbe {
    var frame: CGRect = .zero
    weak var view: NSView?
}

/// Test-only AppKit view used as ground truth for where SwiftUI placed the viewport.
private struct ProbeView: NSViewRepresentable {
    let probe: FrameProbe
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        probe.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
