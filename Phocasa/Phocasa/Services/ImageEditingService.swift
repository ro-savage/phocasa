import CoreImage
import AppKit
import ImageIO
import os

/// Renders photo edits with Core Image.
///
/// Work runs on two lanes. Each lane is an actor on its own serial dispatch queue, so a preview never queues behind a
/// full-resolution render or an export. A render that is cancelled before its lane reaches it returns `nil` without
/// doing any work, so stale slider ticks are skipped. The service holds no mutable state of its own.
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
        let context = Self.makeContext()
        previewLane = RenderLane(label: "com.phocasa.editing.preview", qos: .userInteractive, context: context, caches: caches)
        fullLane = RenderLane(label: "com.phocasa.editing.full", qos: .userInitiated, context: context, caches: caches)
    }

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

    // MARK: Renders

    func renderRAW(url: URL, parameters: EditParameters, maxSize: CGSize?) -> RenderedImage? {
        guard beginRender(), let rawFilter = rawFilter(for: url) else { return nil }

        // Draft mode for preview renders (much faster, slightly lower quality)
        rawFilter.isDraftModeEnabled = (maxSize != nil)

        EditPipeline.applyRAWParameters(rawFilter, parameters: parameters)

        guard var output = rawFilter.outputImage else { return nil }

        // Scale BEFORE post-filters — smaller image = faster filter chain
        if let maxSize {
            output = EditPipeline.scaleToFit(output, maxSize: maxSize)
        }

        output = EditPipeline.applyPostRAWFilters(to: output, parameters: parameters)
        output = EditPipeline.applyTransform(to: output, parameters: parameters)

        return render(output)
    }

    func renderStandard(url: URL, parameters: EditParameters, maxSize: CGSize?) -> RenderedImage? {
        guard beginRender(), let sourceImage = standardSource(for: url) else { return nil }

        var ciImage = sourceImage

        // Scale BEFORE filters — smaller image = faster filter chain
        if let maxSize {
            ciImage = EditPipeline.scaleToFit(ciImage, maxSize: maxSize)
        }

        ciImage = EditPipeline.applyStandardFilters(to: ciImage, parameters: parameters)
        ciImage = EditPipeline.applyTransform(to: ciImage, parameters: parameters)

        return render(ciImage)
    }

    func exportRAW(rawURL: URL, parameters: EditParameters, outputURL: URL, quality: Double) -> Bool {
        // For export, create a fresh filter with draft OFF for max quality
        guard let rawFilter = CIRAWFilter(imageURL: rawURL) else { return false }
        rawFilter.isDraftModeEnabled = false

        EditPipeline.applyRAWParameters(rawFilter, parameters: parameters)

        guard var output = rawFilter.outputImage else { return false }

        output = EditPipeline.applyPostRAWFilters(to: output, parameters: parameters)
        output = EditPipeline.applyTransform(to: output, parameters: parameters)

        return writeJPEG(output, to: outputURL, quality: quality)
    }

    func exportStandard(sourceURL: URL, parameters: EditParameters, outputURL: URL, quality: Double) -> Bool {
        guard let rawImage = CIImage(contentsOf: sourceURL) else { return false }

        var ciImage = EditPipeline.orientedImage(rawImage)
        ciImage = EditPipeline.applyStandardFilters(to: ciImage, parameters: parameters)
        ciImage = EditPipeline.applyTransform(to: ciImage, parameters: parameters)

        return writeJPEG(ciImage, to: outputURL, quality: quality)
    }

    // MARK: Output

    private func render(_ ciImage: CIImage) -> RenderedImage? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return nil }
        return RenderedImage(cgImage: cgImage, size: extent.size)
    }

    private func writeJPEG(_ image: CIImage, to url: URL, quality: Double) -> Bool {
        let originalDates = Phocasa.captureFileDates(url)

        let extent = image.extent
        guard let cgImage = ciContext.createCGImage(image, from: extent) else { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        let success = CGImageDestinationFinalize(destination)

        if success { Phocasa.restoreFileDates(url, dates: originalDates) }
        return success
    }
}

// MARK: - Filter chains (pure)

private enum EditPipeline {
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

    // MARK: Post-RAW Filters (supplements for things CIRAWFilter can't do)

    static func applyPostRAWFilters(to image: CIImage, parameters: EditParameters) -> CIImage {
        var result = image

        // Negative brightness — boostAmount can't go below 0
        if parameters.brightness < 0 {
            result = applyFilter("CIColorControls", to: result, params: [
                "inputBrightness": parameters.brightness / 100.0 * 0.3,
                "inputContrast": 1.0,
                "inputSaturation": 1.0
            ])
        }

        // Vibrance
        if parameters.vibrance != 0 {
            result = applyFilter("CIVibrance", to: result, params: [
                "inputAmount": parameters.vibrance / 100.0
            ])
        }

        // Saturation
        if parameters.saturation != 0 {
            result = applyFilter("CIColorControls", to: result, params: [
                "inputBrightness": 0.0,
                "inputContrast": 1.0,
                "inputSaturation": 1.0 + parameters.saturation / 100.0 * 0.5
            ])
        }

        // Highlights & Shadows — tone curve for precise recovery
        if parameters.highlights != 0 || parameters.shadows != 0 {
            result = applyToneCurve(to: result, highlights: parameters.highlights, shadows: parameters.shadows)
        }

        // Sharpness — visible edge sharpening via unsharp mask (small radius)
        if parameters.sharpness > 0 {
            result = applyFilter("CIUnsharpMask", to: result, params: [
                "inputRadius": 1.5,
                "inputIntensity": parameters.sharpness / 100.0 * 2.0
            ])
        }

        // Clarity — local contrast (large-radius unsharp mask) or softening (blur)
        if parameters.clarity > 0 {
            result = applyFilter("CIUnsharpMask", to: result, params: [
                "inputRadius": 20.0,
                "inputIntensity": parameters.clarity / 100.0
            ])
        } else if parameters.clarity < 0 {
            let extent = result.extent
            result = applyFilter("CIGaussianBlur", to: result, params: [
                "inputRadius": -parameters.clarity / 100.0 * 5.0
            ])
            result = result.cropped(to: extent)
        }

        // Vignette
        if parameters.vignetteAmount != 0 {
            result = applyFilter("CIVignette", to: result, params: [
                "inputIntensity": parameters.vignetteAmount / 100.0 * 2.0,
                "inputRadius": 1.0
            ])
        }

        return result
    }

    // MARK: Standard Filter Chain (JPG/PNG)

    static func applyStandardFilters(to image: CIImage, parameters: EditParameters) -> CIImage {
        var result = image

        // Exposure — direct EV mapping, works well
        if parameters.exposure != 0 {
            result = applyFilter("CIExposureAdjust", to: result, params: [
                "inputEV": parameters.exposure
            ])
        }

        // Highlights & Shadows — tone curve for precise tonal recovery
        // Positive highlights: pull down bright areas (recover cloud detail)
        // Negative highlights: push up bright areas
        // Positive shadows: lift dark areas (reveal shadow detail)
        // Negative shadows: crush dark areas
        if parameters.highlights != 0 || parameters.shadows != 0 {
            result = applyToneCurve(to: result, highlights: parameters.highlights, shadows: parameters.shadows)
        }

        // Brightness, Contrast, Saturation
        // inputBrightness: -1 to 1 (default 0)
        // inputContrast: 0.25 to 4.0 (default 1.0)
        // inputSaturation: 0 to 3.0 (default 1.0)
        if parameters.brightness != 0 || parameters.contrast != 0 || parameters.saturation != 0 {
            result = applyFilter("CIColorControls", to: result, params: [
                "inputBrightness": parameters.brightness / 100.0 * 0.3,
                "inputContrast": 1.0 + parameters.contrast / 100.0 * 0.5,
                "inputSaturation": 1.0 + parameters.saturation / 100.0 * 0.5
            ])
        }

        // Temperature & Tint
        if parameters.temperature != 0 || parameters.tint != 0 {
            result = applyFilter("CITemperatureAndTint", to: result, params: [
                "inputNeutral": CIVector(x: 6500.0 + parameters.temperature * 25.0, y: parameters.tint),
                "inputTargetNeutral": CIVector(x: 6500.0, y: 0.0)
            ])
        }

        // Vibrance
        if parameters.vibrance != 0 {
            result = applyFilter("CIVibrance", to: result, params: [
                "inputAmount": parameters.vibrance / 100.0
            ])
        }

        // Sharpness — CIUnsharpMask with small radius for visible edge sharpening
        if parameters.sharpness > 0 {
            result = applyFilter("CIUnsharpMask", to: result, params: [
                "inputRadius": 1.5,
                "inputIntensity": parameters.sharpness / 100.0 * 2.0
            ])
        }

        // Noise Reduction
        if parameters.noiseReduction > 0 {
            result = applyFilter("CINoiseReduction", to: result, params: [
                "inputNoiseLevel": parameters.noiseReduction / 100.0 * 0.1,
                "inputSharpness": 0.5
            ])
        }

        // Clarity — local contrast (large-radius unsharp mask) or softening
        if parameters.clarity > 0 {
            result = applyFilter("CIUnsharpMask", to: result, params: [
                "inputRadius": 20.0,
                "inputIntensity": parameters.clarity / 100.0
            ])
        } else if parameters.clarity < 0 {
            let extent = result.extent
            result = applyFilter("CIGaussianBlur", to: result, params: [
                "inputRadius": -parameters.clarity / 100.0 * 5.0
            ])
            result = result.cropped(to: extent)
        }

        // Vignette
        if parameters.vignetteAmount != 0 {
            result = applyFilter("CIVignette", to: result, params: [
                "inputIntensity": parameters.vignetteAmount / 100.0 * 2.0,
                "inputRadius": 1.0
            ])
        }

        return result
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

    /// Tone curve for highlight recovery and shadow lifting.
    /// h: -100 to +100 (positive = recover/darken highlights, negative = brighten)
    /// s: -100 to +100 (positive = lift/brighten shadows, negative = crush)
    static func applyToneCurve(to image: CIImage, highlights h: Double, shadows s: Double) -> CIImage {
        let hNorm = h / 100.0  // -1 to 1
        let sNorm = s / 100.0  // -1 to 1

        // Shadow region (points 0 and 1)
        // Positive s lifts shadows, negative crushes them
        let p0y = max(0, sNorm * 0.08)                       // slight black point lift
        let p1y = min(1.0, max(0, 0.25 + sNorm * 0.20))      // shadow midpoint shift

        // Highlight region (points 3 and 4)
        // Positive h pulls down highlights (recover cloud detail), negative pushes them up
        let p3y = min(1.0, max(0, 0.75 - hNorm * 0.20))      // upper-mid shift
        let p4y = min(1.0, max(0.3, 1.0 - hNorm * 0.30))     // white point pull-down

        return applyFilter("CIToneCurve", to: image, params: [
            "inputPoint0": CIVector(x: 0.0,  y: CGFloat(p0y)),
            "inputPoint1": CIVector(x: 0.25, y: CGFloat(p1y)),
            "inputPoint2": CIVector(x: 0.5,  y: 0.5),            // midtones untouched
            "inputPoint3": CIVector(x: 0.75, y: CGFloat(p3y)),
            "inputPoint4": CIVector(x: 1.0,  y: CGFloat(p4y))
        ])
    }

    static func applyFilter(_ name: String, to image: CIImage, params: [String: Any]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in params {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage ?? image
    }

    static func scaleToFit(_ image: CIImage, maxSize: CGSize) -> CIImage {
        let scale = min(maxSize.width / image.extent.width, maxSize.height / image.extent.height)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
