import Foundation
import CoreGraphics

struct EditParameters: Codable, Equatable, Sendable {
    // Light
    var exposure: Double = 0        // -5 to +5 EV
    var highlights: Double = 0      // -100 to +100
    var shadows: Double = 0         // -100 to +100
    var brightness: Double = 0      // -100 to +100
    var contrast: Double = 0        // -100 to +100

    // Color
    var temperature: Double = 0     // -100 to +100 (relative shift)
    var tint: Double = 0            // -100 to +100 (relative shift)
    var saturation: Double = 0      // -100 to +100 (0 = no change)
    var vibrance: Double = 0        // -100 to +100

    // Detail
    var sharpness: Double = 0       // 0 to +100
    var noiseReduction: Double = 0  // 0 to +100
    var colorNoiseReduction: Double = 0  // 0 to +100

    // Effects
    var clarity: Double = 0         // -100 to +100
    var vignetteAmount: Double = 0  // -100 to +100

    // RAW-specific
    var localToneMap: Double = 0    // 0 to +100
    var moireReduction: Double = 0  // 0 to +100
    var enableLensCorrection: Bool = false
    var enableGamutMapping: Bool = true

    // Transform
    var cropRect: NormalizedRect?
    var rotation: Double = 0        // degrees, -45 to +45
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    var isDefault: Bool { self == EditParameters() }

    mutating func reset() { self = EditParameters() }

    mutating func resetTransform() {
        cropRect = nil
        rotation = 0
        flipHorizontal = false
        flipVertical = false
    }
}

struct NormalizedRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}
