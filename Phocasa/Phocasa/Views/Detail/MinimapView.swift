import SwiftUI

/// Bottom-left overview of the whole photo with the visible region outlined, shown while zoomed in.
/// Reads `ZoomPanState`, so it re-renders on zoom and pan frames; nothing above it does.
struct MinimapView: View {
    let zoom: ZoomPanState
    let thumbnail: DisplayImage

    private let minimapWidth: CGFloat = 180

    var body: some View {
        if zoom.magnification > 1.01 {
            minimap
        }
    }

    private var minimap: some View {
        let size = thumbnail.orientedSize
        let aspect = size.height / max(size.width, 1)
        let minimapHeight = minimapWidth * aspect
        let visRect = visibleRectNormalized()

        return VStack {
            Spacer()
            HStack {
                ZStack(alignment: .topLeading) {
                    OrientedImage(thumbnail, interpolation: .medium)
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
                    Text("\(Int(zoom.magnification * 100))%")
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
        let fs = zoom.fitSize
        let mag = zoom.magnification
        let off = zoom.imageOffset
        let vp = zoom.viewportSize

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
            x: (0.5 - nx) * zoom.fitSize.width * zoom.magnification,
            y: (0.5 - ny) * zoom.fitSize.height * zoom.magnification
        )
        withAnimation(.easeOut(duration: 0.15)) {
            zoom.imageOffset = zoom.clamped(newOffset)
            zoom.dragStartOffset = zoom.imageOffset
        }
    }
}
