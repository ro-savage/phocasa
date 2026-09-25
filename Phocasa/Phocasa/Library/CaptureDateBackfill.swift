import Foundation
import SwiftData

extension PhotoAsset {
    /// Stores what a metadata read found about the photo's capture date. Scans call it when they insert a photo
    /// (`found.metadata` is nil when no read was attempted, and then nothing is recorded).
    func setCaptureDate(from metadata: MetadataService.PhotoMetadata?) {
        guard let metadata else { return }
        captureDate = metadata.captureDate
        captureDateChecked = metadata.captureDateChecked
    }
}
