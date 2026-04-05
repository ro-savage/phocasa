import CoreImage
import AppKit
import ImageIO

final class ImageEditingService: @unchecked Sendable {
    static let shared = ImageEditingService()

    private let ciContext: CIContext
    // Serial queue — prevents concurrent RAW decodes competing for resources
    private let renderQueue = DispatchQueue(label: "com.phocsa.editing", qos: .userInteractive)

    // Cached sources — the expensive part is loading from disk, so we do it once
    private var cachedRAWFilter: CIRAWFilter?
    private var cachedRAWURL: URL?
    private var cachedStandardImage: CIImage?
    private var cachedStandardURL: URL?

    private init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .highQualityDownsample: true,
                .cacheIntermediates: false
            ])
        } else {
            ciContext = CIContext(options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB()
            ])
        }
    }

    // MARK: - Cache Management

    /// Pre-load a RAW file into cache so the first slider interaction is instant.
    func prepareRAW(url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            renderQueue.async { [self] in
                if cachedRAWURL != url {
                    cachedRAWFilter = CIRAWFilter(imageURL: url)
                    cachedRAWURL = url
                }
                continuation.resume()
            }
        }
    }

    /// Pre-load a standard image into cache.
    func prepareStandard(url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            renderQueue.async { [self] in
                if cachedStandardURL != url {
                    if var img = CIImage(contentsOf: url) {
                        let o = img.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
                        img = img.oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
                        cachedStandardImage = img
                    }
                    cachedStandardURL = url
                }
                continuation.resume()
            }
        }
    }

    func clearCache() {
        renderQueue.async { [self] in
            cachedRAWFilter = nil
            cachedRAWURL = nil
            cachedStandardImage = nil
            cachedStandardURL = nil
        }
    }

    // MARK: - RAW Processing (uses cache)

    func processRAW(url: URL, parameters: EditParameters, maxSize: CGSize? = nil) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            renderQueue.async { [self] in
                // Reuse cached filter — avoids re-reading the RAW file from disk
                let rawFilter: CIRAWFilter
                if let cached = cachedRAWFilter, cachedRAWURL == url {
                    rawFilter = cached
                } else {
                    guard let newFilter = CIRAWFilter(imageURL: url) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    rawFilter = newFilter
                    cachedRAWFilter = newFilter
                    cachedRAWURL = url
                }

                // Draft mode for preview renders (much faster, slightly lower quality)
                rawFilter.isDraftModeEnabled = (maxSize != nil)

                applyRAWParameters(rawFilter, parameters: parameters)

                guard var output = rawFilter.outputImage else {
                    continuation.resume(returning: nil)
                    return
                }

                // Scale BEFORE post-filters — smaller image = faster filter chain
                if let maxSize {
                    output = scaleToFit(output, maxSize: maxSize)
                }

                output = applyPostRAWFilters(to: output, parameters: parameters)
                output = applyTransform(to: output, parameters: parameters)

                continuation.resume(returning: renderToNSImage(output))
            }
        }
    }

    // MARK: - Standard Processing (uses cache)

    func processStandard(url: URL, parameters: EditParameters, maxSize: CGSize? = nil) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            renderQueue.async { [self] in
                // Reuse cached image — avoids re-reading from disk
                let sourceImage: CIImage
                if let cached = cachedStandardImage, cachedStandardURL == url {
                    sourceImage = cached
                } else {
                    guard var img = CIImage(contentsOf: url) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let o = img.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
                    img = img.oriented(CGImagePropertyOrientation(rawValue: o) ?? .up)
                    cachedStandardImage = img
                    cachedStandardURL = url
                    sourceImage = img
                }

                var ciImage = sourceImage

                // Scale BEFORE filters — smaller image = faster filter chain
                if let maxSize {
                    ciImage = scaleToFit(ciImage, maxSize: maxSize)
                }

                ciImage = applyStandardFilters(to: ciImage, parameters: parameters)
                ciImage = applyTransform(to: ciImage, parameters: parameters)

                continuation.resume(returning: renderToNSImage(ciImage))
            }
        }
    }

    // MARK: - Export RAW → JPEG (full quality, no draft, no cache needed)

    func exportRAWToJPEG(rawURL: URL, parameters: EditParameters, outputURL: URL, quality: Double = 0.95) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            renderQueue.async { [self] in
                // For export, create a fresh filter with draft OFF for max quality
                guard let rawFilter = CIRAWFilter(imageURL: rawURL) else {
                    continuation.resume(returning: false)
                    return
                }
                rawFilter.isDraftModeEnabled = false

                applyRAWParameters(rawFilter, parameters: parameters)

                guard var output = rawFilter.outputImage else {
                    continuation.resume(returning: false)
                    return
                }

                output = applyPostRAWFilters(to: output, parameters: parameters)
                output = applyTransform(to: output, parameters: parameters)

                let success = writeJPEG(output, to: outputURL, quality: quality)
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Export JPG overwrite

    func exportStandardToJPEG(sourceURL: URL, parameters: EditParameters, outputURL: URL, quality: Double = 0.95) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            renderQueue.async { [self] in
                guard var ciImage = CIImage(contentsOf: sourceURL) else {
                    continuation.resume(returning: false)
                    return
                }

                let orientVal = ciImage.properties[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
                ciImage = ciImage.oriented(CGImagePropertyOrientation(rawValue: orientVal) ?? .up)
                ciImage = applyStandardFilters(to: ciImage, parameters: parameters)
                ciImage = applyTransform(to: ciImage, parameters: parameters)

                let success = writeJPEG(ciImage, to: outputURL, quality: quality)
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - RAW Filter Configuration

    private func applyRAWParameters(_ filter: CIRAWFilter, parameters: EditParameters) {
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

    // MARK: - Post-RAW Filters (supplements for things CIRAWFilter can't do)

    private func applyPostRAWFilters(to image: CIImage, parameters: EditParameters) -> CIImage {
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

    // MARK: - Standard Filter Chain (JPG/PNG)

    private func applyStandardFilters(to image: CIImage, parameters: EditParameters) -> CIImage {
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

    // MARK: - Transform

    private func applyTransform(to image: CIImage, parameters: EditParameters) -> CIImage {
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

    // MARK: - Helpers

    /// Tone curve for highlight recovery and shadow lifting.
    /// h: -100 to +100 (positive = recover/darken highlights, negative = brighten)
    /// s: -100 to +100 (positive = lift/brighten shadows, negative = crush)
    private func applyToneCurve(to image: CIImage, highlights h: Double, shadows s: Double) -> CIImage {
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

    private func applyFilter(_ name: String, to image: CIImage, params: [String: Any]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in params {
            filter.setValue(value, forKey: key)
        }
        return filter.outputImage ?? image
    }

    private func scaleToFit(_ image: CIImage, maxSize: CGSize) -> CIImage {
        let scale = min(maxSize.width / image.extent.width, maxSize.height / image.extent.height)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func renderToNSImage(_ ciImage: CIImage) -> NSImage? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: extent.width, height: extent.height))
    }

    private func writeJPEG(_ image: CIImage, to url: URL, quality: Double) -> Bool {
        let extent = image.extent
        guard let cgImage = ciContext.createCGImage(image, from: extent) else { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
