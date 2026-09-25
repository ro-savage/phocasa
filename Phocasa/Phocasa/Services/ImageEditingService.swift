import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import os

/// Renders photo edits with Core Image.
///
/// Work runs on two lanes. Each lane is an actor on its own serial dispatch queue with its own `CIContext`, so a
/// preview never queues behind a full-resolution render or an export, on the CPU or on the GPU. A render that is
/// cancelled before its lane reaches it returns `nil` without doing any work, so stale slider ticks are skipped.
/// Rendered pixels are produced on the lane, never on first draw. The service holds no mutable state of its own.
actor ImageEditingService {
    static let shared = ImageEditingService()

    /// Priority lane for renders. Preview renders never queue behind full-resolution ones.
    enum Lane: Sendable { case preview, full }

    private let caches: SharedEditCaches
    private let previewLane: RenderLane
    private let fullLane: RenderLane

    /// App code uses `shared`; tests may create their own instance.
    init() {
        let caches = SharedEditCaches()
        self.caches = caches
        // One context per lane: a Metal-backed CIContext owns a single command queue, so a shared context would
        // serialise the preview's GPU work behind a full-resolution render.
        previewLane = RenderLane(label: "com.phocasa.editing.preview", qos: .userInteractive,
                                 context: Self.makeContext(), caches: caches)
        fullLane = RenderLane(label: "com.phocasa.editing.full", qos: .userInitiated,
                              context: Self.makeContext(), caches: caches)
    }

    /// Both lanes use identical options, so they produce identical pixels.
    private static func makeContext() -> CIContext {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .highQualityDownsample: true,
                .cacheIntermediates: false
            ])
        } else {
            return CIContext(options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB()
            ])
        }
    }

    /// `nil` picks the lane from the render size: sized renders are previews, full-resolution renders go to `.full`.
    private nonisolated func lane(_ lane: Lane?, maxSize: CGSize?) -> RenderLane {
        switch lane ?? (maxSize == nil ? .full : .preview) {
        case .preview: previewLane
        case .full: fullLane
        }
    }

    /// Number of renders that got past the cancellation check and did work. For tests.
    nonisolated var renderCount: Int { caches.renderCount }

    /// The `CIRAWFilter.scaleFactor` that demosaics a RAW of `nativeSize` (oriented) straight to a size that fits
    /// `maxSize`. Never above 1.
    static func rawScaleFactor(nativeSize: CGSize, maxSize: CGSize) -> Float {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return 1 }
        let scale = min(maxSize.width / nativeSize.width, maxSize.height / nativeSize.height)
        return Float(min(1, scale))
    }

    // MARK: - Cache Management

    /// Pre-load a RAW file into both lanes' caches so the first slider interaction is instant.
    nonisolated func prepareRAW(url: URL) async {
        async let preview: Void = previewLane.prepareRAW(url: url)
        async let full: Void = fullLane.prepareRAW(url: url)
        _ = await (preview, full)
    }

    /// Pre-load a standard image. Both lanes render the same cached source.
    nonisolated func prepareStandard(url: URL) async {
        await previewLane.prepareStandard(url: url)
    }

    /// Drops the cached sources. Callable synchronously; renders that start after this returns reload their source.
    nonisolated func clearCache() {
        caches.invalidate()
        let lanes = [previewLane, fullLane]
        Task {
            for lane in lanes { await lane.dropStaleCaches() }
        }
    }

    // MARK: - Rendering

    /// Renders a RAW file with `parameters`. `maxSize` renders a preview that fits inside it; `nil` renders at full
    /// resolution. `lane` defaults to `.preview` for sized renders and `.full` otherwise.
    nonisolated func processRAW(url: URL, parameters: EditParameters, maxSize: CGSize? = nil, lane: Lane? = nil) async -> NSImage? {
        await self.lane(lane, maxSize: maxSize).renderRAW(url: url, parameters: parameters, maxSize: maxSize)?.nsImage
    }

    /// Renders a JPEG/PNG/… file with `parameters`. See `processRAW` for `maxSize` and `lane`.
    nonisolated func processStandard(url: URL, parameters: EditParameters, maxSize: CGSize? = nil, lane: Lane? = nil) async -> NSImage? {
        await self.lane(lane, maxSize: maxSize).renderStandard(url: url, parameters: parameters, maxSize: maxSize)?.nsImage
    }

    // MARK: - Export (full quality, on the full lane)

    /// RAW → JPEG at full quality: a fresh filter with draft mode off. Exports are never skipped.
    nonisolated func exportRAWToJPEG(rawURL: URL, parameters: EditParameters, outputURL: URL, quality: Double = 0.95) async -> Bool {
        await fullLane.exportRAW(rawURL: rawURL, parameters: parameters, outputURL: outputURL, quality: quality)
    }

    /// Bakes `parameters` into a JPEG, reading the source fresh from disk. Exports are never skipped.
    nonisolated func exportStandardToJPEG(sourceURL: URL, parameters: EditParameters, outputURL: URL, quality: Double = 0.95) async -> Bool {
        await fullLane.exportStandard(sourceURL: sourceURL, parameters: parameters, outputURL: outputURL, quality: quality)
    }
}

// MARK: - Render result

/// A rendered frame. `size` is the image extent, which can be fractional (rotation), as the `NSImage` size.
private struct RenderedImage: Sendable {
    let cgImage: CGImage
    let size: CGSize

    var nsImage: NSImage { NSImage(cgImage: cgImage, size: NSSize(width: size.width, height: size.height)) }
}

// MARK: - Shared caches

/// State both lanes share, behind a lock.
/// - The standard-image source is an immutable `CIImage`, so both lanes render the same decoded source.
/// - `generation` is bumped by `clearCache()`. A lane drops its own caches (its `CIRAWFilter`) when it sees a new
///   value, so a render that starts after `clearCache()` returns never uses a cleared source.
private final class SharedEditCaches: Sendable {
    private struct State {
        var generation = 0
        var standardURL: URL?
        var standardImage: CIImage?
        var renders = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var generation: Int { state.withLock { $0.generation } }
    var renderCount: Int { state.withLock { $0.renders } }

    func invalidate() {
        state.withLock {
            $0.generation += 1
            $0.standardURL = nil
            $0.standardImage = nil
        }
    }

    func standardImage(for url: URL) -> CIImage? {
        state.withLock { $0.standardURL == url ? $0.standardImage : nil }
    }

    /// Stores `image` unless the caches were cleared after `generation` was read.
    func storeStandardImage(_ image: CIImage, for url: URL, generation: Int) {
        state.withLock {
            guard $0.generation == generation else { return }
            $0.standardURL = url
            $0.standardImage = image
        }
    }

    func countRender() {
        state.withLock { $0.renders += 1 }
    }
}

// MARK: - Render lane

/// One serial render lane. Runs on its own dispatch queue and keeps its own `CIRAWFilter`, which isn't thread-safe.
private actor RenderLane {
    private let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let ciContext: CIContext
    private let caches: SharedEditCaches
    private var generation: Int

    // Cached RAW source. The expensive part is loading from disk, so we do it once.
    private var cachedRAWFilter: CIRAWFilter?
    private var cachedRAWURL: URL?

    init(label: String, qos: DispatchQoS, context: CIContext, caches: SharedEditCaches) {
        queue = DispatchSerialQueue(label: label, qos: qos, autoreleaseFrequency: .workItem)
        ciContext = context
        self.caches = caches
        generation = caches.generation
    }

    // MARK: Caches

    func prepareRAW(url: URL) {
        dropStaleCaches()
        _ = rawFilter(for: url)
    }

    func prepareStandard(url: URL) {
        dropStaleCaches()
        _ = standardSource(for: url)
    }

    func dropStaleCaches() {
        let current = caches.generation
        guard current != generation else { return }
        generation = current
        cachedRAWFilter = nil
        cachedRAWURL = nil
    }

    private func rawFilter(for url: URL) -> CIRAWFilter? {
        if let cached = cachedRAWFilter, cachedRAWURL == url { return cached }
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        cachedRAWFilter = filter
        cachedRAWURL = url
        return filter
    }

    private func standardSource(for url: URL) -> CIImage? {
        if let cached = caches.standardImage(for: url) { return cached }
        guard let image = CIImage(contentsOf: url) else { return nil }
        let oriented = EditPipeline.orientedImage(image)
        caches.storeStandardImage(oriented, for: url, generation: generation)
        return oriented
    }

    /// The stale-skip check: a render whose task was cancelled while it waited for this lane does no work.
    private func beginRender() -> Bool {
        guard !Task.isCancelled else { return false }
        dropStaleCaches()
        caches.countRender()
        return true
    }

    // MARK: Renders and exports

    func renderRAW(url: URL, parameters: EditParameters, maxSize: CGSize?) -> RenderedImage? {
        guard beginRender(), let filter = rawFilter(for: url),
              let edited = EditPipeline.editedRAW(filter, parameters: parameters, maxSize: maxSize) else { return nil }
        return render(edited)
    }

    func renderStandard(url: URL, parameters: EditParameters, maxSize: CGSize?) -> RenderedImage? {
        guard beginRender(), let source = standardSource(for: url) else { return nil }
        return render(EditPipeline.editedStandard(source, parameters: parameters, maxSize: maxSize))
    }

    func exportRAW(rawURL: URL, parameters: EditParameters, outputURL: URL, quality: Double) -> Bool {
        // A fresh filter, not the cached one: full quality, and no preview state.
        guard let filter = CIRAWFilter(imageURL: rawURL),
              let edited = EditPipeline.editedRAW(filter, parameters: parameters, maxSize: nil) else { return false }
        return writeJPEG(edited, to: outputURL, quality: quality)
    }

    func exportStandard(sourceURL: URL, parameters: EditParameters, outputURL: URL, quality: Double) -> Bool {
        // Read fresh from disk: the export may overwrite the source file.
        guard let image = CIImage(contentsOf: sourceURL) else { return false }
        let edited = EditPipeline.editedStandard(EditPipeline.orientedImage(image), parameters: parameters, maxSize: nil)
        return writeJPEG(edited, to: outputURL, quality: quality)
    }

    // MARK: Output

    /// Renders the pixels now, on this lane. The default `createCGImage(_:from:)` returns a deferred image for large
    /// outputs, whose pixels are then produced on first draw, on the main thread. Same format and colour-space tag
    /// as that default: 8-bit RGBA, tagged Device RGB (not sRGB, whatever its header says).
    private func render(_ image: CIImage) -> RenderedImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let cgImage = ciContext.createCGImage(image, from: extent, format: .RGBA8,
                                                    colorSpace: CGColorSpaceCreateDeviceRGB(), deferred: false)
        else { return nil }
        return RenderedImage(cgImage: cgImage, size: extent.size)
    }

    private func writeJPEG(_ image: CIImage, to url: URL, quality: Double) -> Bool {
        let originalDates = Phocasa.captureFileDates(url)

        // Deferred on purpose: the encoder pulls the pixels here, on the lane, so nothing lands on the main thread,
        // and the file stays byte-identical to what earlier versions wrote.
        guard let cgImage = ciContext.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        let success = CGImageDestinationFinalize(destination)

        if success { Phocasa.restoreFileDates(url, dates: originalDates) }
        return success
    }
}

// MARK: - Edit pipeline (pure)

/// The filter chains. Every step returns its input unchanged when its parameter is neutral.
private enum EditPipeline {
    // MARK: Load → filter

    /// RAW: decode (a preview demosaics straight to the target size, in draft mode), then the post-RAW chain and
    /// the transform.
    static func editedRAW(_ filter: CIRAWFilter, parameters: EditParameters, maxSize: CGSize?) -> CIImage? {
        // Previews: ~2x faster than decoding at full size and scaling afterwards. Full renders and exports decode
        // at native size. Both properties are set on every render because the filter is cached.
        if let maxSize {
            filter.isDraftModeEnabled = true
            filter.scaleFactor = ImageEditingService.rawScaleFactor(nativeSize: orientedNativeSize(of: filter),
                                                                    maxSize: maxSize)
        } else {
            filter.isDraftModeEnabled = false
            filter.scaleFactor = 1
        }
        applyRAWParameters(filter, parameters: parameters)

        guard var image = filter.outputImage else { return nil }
        // scaleFactor lands within a pixel of the target; scale BEFORE post-filters only if it's still too big.
        if let maxSize, image.extent.width > maxSize.width + 1 || image.extent.height > maxSize.height + 1 {
            image = scaleToFit(image, maxSize: maxSize)
        }
        image = applyPostRAWFilters(to: image, parameters: parameters)
        return applyTransform(to: image, parameters: parameters)
    }

    /// Standard: scale (previews; BEFORE filters, so the chain runs on fewer pixels), the chain, the transform.
    static func editedStandard(_ source: CIImage, parameters: EditParameters, maxSize: CGSize?) -> CIImage {
        var image = source
        if let maxSize {
            image = scaleToFit(image, maxSize: maxSize)
        }
        image = applyStandardFilters(to: image, parameters: parameters)
        return applyTransform(to: image, parameters: parameters)
    }

    /// `nativeSize` ignores orientation; the output image doesn't.
    private static func orientedNativeSize(of filter: CIRAWFilter) -> CGSize {
        let size = filter.nativeSize
        switch filter.orientation {
        case .leftMirrored, .right, .rightMirrored, .left: return CGSize(width: size.height, height: size.width)
        default: return size
        }
    }

    // MARK: RAW Filter Configuration

    static func applyRAWParameters(_ filter: CIRAWFilter, parameters: EditParameters) {
        filter.exposure = Float(parameters.exposure)
        // shadowBias: negative darkens shadows, positive lifts them
        filter.shadowBias = Float(parameters.shadows / 100.0)
        // boostAmount only goes 0–1 (positive brightness)
        filter.boostAmount = Float(max(0, parameters.brightness / 100.0))
        // boostShadowAmount only goes 0–1 (positive shadow lift)
        filter.boostShadowAmount = Float(max(0, parameters.shadows / 100.0))
        // contrastAmount: 0.25–1.75, default 1.0
        filter.contrastAmount = Float(1.0 + parameters.contrast / 200.0)
        filter.sharpnessAmount = Float(parameters.sharpness / 100.0)
        filter.luminanceNoiseReductionAmount = Float(parameters.noiseReduction / 100.0)
        filter.colorNoiseReductionAmount = Float(parameters.colorNoiseReduction / 100.0)
        filter.localToneMapAmount = Float(parameters.localToneMap / 100.0)
        filter.moireReductionAmount = Float(parameters.moireReduction / 100.0)
        filter.isGamutMappingEnabled = parameters.enableGamutMapping

        if parameters.enableLensCorrection && filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = true
        }

        filter.neutralTemperature = Float(6500.0 + parameters.temperature * 25.0)
        filter.neutralTint = Float(parameters.tint * 1.5)
    }

    // MARK: Chains

    /// Post-RAW (things CIRAWFilter can't do): negative brightness → vibrance → saturation → tone curve →
    /// sharpness → clarity → vignette.
    static func applyPostRAWFilters(to image: CIImage, parameters p: EditParameters) -> CIImage {
        var result = image
        // Negative brightness — boostAmount can't go below 0
        if p.brightness < 0 {
            result = colorControls(result, brightness: p.brightness / 100.0 * 0.3, contrast: 1.0, saturation: 1.0)
        }
        result = vibrance(result, p)
        if p.saturation != 0 {
            result = colorControls(result, brightness: 0.0, contrast: 1.0, saturation: 1.0 + p.saturation / 100.0 * 0.5)
        }
        result = toneCurve(result, p)
        result = sharpness(result, p)
        result = clarity(result, p)
        return vignette(result, p)
    }

    /// Standard (JPG/PNG): exposure → tone curve → colour controls → temperature/tint → vibrance → sharpness →
    /// noise reduction → clarity → vignette.
    static func applyStandardFilters(to image: CIImage, parameters p: EditParameters) -> CIImage {
        var result = image
        // Exposure — direct EV mapping
        if p.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = result
            filter.ev = Float(p.exposure)
            result = filter.outputImage ?? result
        }
        result = toneCurve(result, p)
        // Brightness -1…1 (default 0), contrast 0.25…4 (default 1), saturation 0…3 (default 1)
        if p.brightness != 0 || p.contrast != 0 || p.saturation != 0 {
            result = colorControls(result, brightness: p.brightness / 100.0 * 0.3,
                                   contrast: 1.0 + p.contrast / 100.0 * 0.5,
                                   saturation: 1.0 + p.saturation / 100.0 * 0.5)
        }
        if p.temperature != 0 || p.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = result
            filter.neutral = CIVector(x: 6500.0 + p.temperature * 25.0, y: p.tint)
            filter.targetNeutral = CIVector(x: 6500.0, y: 0.0)
            result = filter.outputImage ?? result
        }
        result = vibrance(result, p)
        result = sharpness(result, p)
        if p.noiseReduction > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = result
            filter.noiseLevel = Float(p.noiseReduction / 100.0 * 0.1)
            filter.sharpness = 0.5
            result = filter.outputImage ?? result
        }
        result = clarity(result, p)
        return vignette(result, p)
    }

    // MARK: Shared steps

    private static func colorControls(_ image: CIImage, brightness: Double, contrast: Double, saturation: Double) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = Float(brightness)
        filter.contrast = Float(contrast)
        filter.saturation = Float(saturation)
        return filter.outputImage ?? image
    }

    private static func vibrance(_ image: CIImage, _ p: EditParameters) -> CIImage {
        guard p.vibrance != 0 else { return image }
        let filter = CIFilter.vibrance()
        filter.inputImage = image
        filter.amount = Float(p.vibrance / 100.0)
        return filter.outputImage ?? image
    }

    /// Visible edge sharpening: a small-radius unsharp mask.
    private static func sharpness(_ image: CIImage, _ p: EditParameters) -> CIImage {
        guard p.sharpness > 0 else { return image }
        return unsharpMask(image, radius: 1.5, intensity: p.sharpness / 100.0 * 2.0)
    }

    /// Local contrast (a large-radius unsharp mask) or softening (a blur, cropped back to the input extent).
    private static func clarity(_ image: CIImage, _ p: EditParameters) -> CIImage {
        if p.clarity > 0 {
            return unsharpMask(image, radius: 20.0, intensity: p.clarity / 100.0)
        }
        guard p.clarity < 0 else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image
        filter.radius = Float(-p.clarity / 100.0 * 5.0)
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    private static func vignette(_ image: CIImage, _ p: EditParameters) -> CIImage {
        guard p.vignetteAmount != 0 else { return image }
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = Float(p.vignetteAmount / 100.0 * 2.0)
        filter.radius = 1.0
        return filter.outputImage ?? image
    }

    private static func unsharpMask(_ image: CIImage, radius: Double, intensity: Double) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Float(radius)
        filter.intensity = Float(intensity)
        return filter.outputImage ?? image
    }

    /// Highlights & shadows via a tone curve. h, s: -100…+100.
    /// - Positive highlights pull bright areas down (recover cloud detail); negative push them up.
    /// - Positive shadows lift dark areas; negative crush them. Midtones are untouched.
    private static func toneCurve(_ image: CIImage, _ p: EditParameters) -> CIImage {
        guard p.highlights != 0 || p.shadows != 0 else { return image }
        let hNorm = p.highlights / 100.0  // -1 to 1
        let sNorm = p.shadows / 100.0     // -1 to 1

        let p0y = max(0, sNorm * 0.08)                       // slight black point lift
        let p1y = min(1.0, max(0, 0.25 + sNorm * 0.20))      // shadow midpoint shift
        let p3y = min(1.0, max(0, 0.75 - hNorm * 0.20))      // upper-mid shift
        let p4y = min(1.0, max(0.3, 1.0 - hNorm * 0.30))     // white point pull-down

        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0.0, y: p0y)
        filter.point1 = CGPoint(x: 0.25, y: p1y)
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: p3y)
        filter.point4 = CGPoint(x: 1.0, y: p4y)
        return filter.outputImage ?? image
    }

    // MARK: Transform

    static func applyTransform(to image: CIImage, parameters: EditParameters) -> CIImage {
        var result = image

        if parameters.rotation != 0 {
            let radians = parameters.rotation * .pi / 180.0
            result = result.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
            let ext = result.extent
            if ext.origin.x < 0 || ext.origin.y < 0 {
                result = result.transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            }
        }

        if parameters.flipHorizontal {
            result = result.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -result.extent.width, y: 0))
        }
        if parameters.flipVertical {
            result = result.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -result.extent.height))
        }

        if let crop = parameters.cropRect, crop != .full {
            let ext = result.extent
            let rect = CGRect(
                x: ext.origin.x + CGFloat(crop.x) * ext.width,
                y: ext.origin.y + (1.0 - CGFloat(crop.y) - CGFloat(crop.height)) * ext.height,
                width: CGFloat(crop.width) * ext.width,
                height: CGFloat(crop.height) * ext.height
            )
            result = result.cropped(to: rect)
            result = result.transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        }

        return result
    }

    // MARK: Helpers

    static func orientedImage(_ image: CIImage) -> CIImage {
        let o = image.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
        return image.oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
    }

    static func scaleToFit(_ image: CIImage, maxSize: CGSize) -> CIImage {
        let scale = min(maxSize.width / image.extent.width, maxSize.height / image.extent.height)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
