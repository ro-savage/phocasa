import SwiftUI

/// Two labelled images side by side: original vs edited, or the paired JPG vs the RAW edit.
/// A side whose image is nil is left out.
struct ComparisonView: View {
    let left: (label: String, image: DisplayImage?)
    let right: (label: String, image: DisplayImage?)

    init(left: (label: String, image: DisplayImage?), right: (label: String, image: DisplayImage?)) {
        self.left = left
        self.right = right
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                side(left, width: geometry.size.width / 2)
                side(right, width: geometry.size.width / 2)
            }
        }
    }

    @ViewBuilder
    private func side(_ side: (label: String, image: DisplayImage?), width: CGFloat) -> some View {
        if let image = side.image {
            VStack(spacing: 4) {
                Text(side.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
                OrientedImage(image)
                    .aspectRatio(image.orientedSize, contentMode: .fit)
            }
            .frame(width: width)
        }
    }
}
