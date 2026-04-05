import SwiftUI

struct CropOverlayView: View {
    @Binding var cropRect: NormalizedRect
    @Binding var rotation: Double
    let imageDisplayRect: CGRect
    var onApply: () -> Void
    var onCancel: () -> Void

    @State private var activeHandle: CropHandle?
    @State private var rectAtDragStart: NormalizedRect = .full
    @State private var aspectRatio: CropAspectRatio = .free

    private let handleSize: CGFloat = 14
    private let hitAreaSize: CGFloat = 30

    var body: some View {
        ZStack {
            // Dim overlay with crop window cut out
            dimOverlay
                .allowsHitTesting(false)

            // Rule of thirds
            ruleOfThirdsGrid
                .allowsHitTesting(false)

            // Crop border
            cropBorder
                .allowsHitTesting(false)

            // Handle hit areas
            ForEach(CropHandle.allCases, id: \.self) { handle in
                handleView(for: handle)
            }

            // Drag gesture on crop area (move)
            cropAreaDragGesture

            // Bottom controls
            VStack {
                Spacer()
                bottomControls
            }
        }
    }

    // MARK: - Dim Overlay

    private var dimOverlay: some View {
        Canvas { context, size in
            let cropViewRect = normalizedToView(cropRect)
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(cropViewRect)
            context.fill(path, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        }
    }

    // MARK: - Grid

    private var ruleOfThirdsGrid: some View {
        Canvas { context, _ in
            let rect = normalizedToView(cropRect)
            var path = Path()
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3.0
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for i in 1...2 {
                let y = rect.minY + rect.height * CGFloat(i) / 3.0
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
        }
    }

    // MARK: - Crop Border

    private var cropBorder: some View {
        let rect = normalizedToView(cropRect)
        return Rectangle()
            .stroke(.white, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Handles

    private func handleView(for handle: CropHandle) -> some View {
        let pos = handlePosition(handle)
        return Circle()
            .fill(.white)
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .frame(width: hitAreaSize, height: hitAreaSize)
            .contentShape(Rectangle())
            .position(pos)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if activeHandle == nil {
                            activeHandle = handle
                            rectAtDragStart = cropRect
                        }
                        handleDrag(handle, translation: value.translation)
                    }
                    .onEnded { _ in activeHandle = nil }
            )
    }

    // MARK: - Move gesture (center area)

    private var cropAreaDragGesture: some View {
        let rect = normalizedToView(cropRect)
        let insetRect = rect.insetBy(dx: hitAreaSize, dy: hitAreaSize)
        return Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: max(insetRect.width, 20), height: max(insetRect.height, 20))
            .position(x: rect.midX, y: rect.midY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if activeHandle == nil {
                            activeHandle = .center
                            rectAtDragStart = cropRect
                        }
                        handleDrag(.center, translation: value.translation)
                    }
                    .onEnded { _ in activeHandle = nil }
            )
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Rotation slider
            HStack(spacing: 8) {
                Image(systemName: "rotate.left")
                    .font(.caption)
                    .foregroundStyle(.white)
                Slider(value: $rotation, in: -45...45)
                    .controlSize(.small)
                    .frame(width: 200)
                Image(systemName: "rotate.right")
                    .font(.caption)
                    .foregroundStyle(.white)
                Text(String(format: "%.1f°", rotation))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 45)
            }

            // Aspect ratio buttons
            HStack(spacing: 8) {
                ForEach(CropAspectRatio.allCases, id: \.self) { ratio in
                    Button(ratio.rawValue) {
                        aspectRatio = ratio
                        applyAspectRatio(ratio)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(aspectRatio == ratio ? .white : .gray)
                }
            }

            // Apply / Cancel
            HStack(spacing: 16) {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.bordered)

                Button("Apply") { onApply() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 20)
    }

    // MARK: - Coordinate Helpers

    private func normalizedToView(_ rect: NormalizedRect) -> CGRect {
        CGRect(
            x: imageDisplayRect.origin.x + CGFloat(rect.x) * imageDisplayRect.width,
            y: imageDisplayRect.origin.y + CGFloat(rect.y) * imageDisplayRect.height,
            width: CGFloat(rect.width) * imageDisplayRect.width,
            height: CGFloat(rect.height) * imageDisplayRect.height
        )
    }

    private func handlePosition(_ handle: CropHandle) -> CGPoint {
        let rect = normalizedToView(cropRect)
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .center:      return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    // MARK: - Drag Handling

    private func handleDrag(_ handle: CropHandle, translation: CGSize) {
        let dx = translation.width / imageDisplayRect.width
        let dy = translation.height / imageDisplayRect.height
        let start = rectAtDragStart

        var newRect: NormalizedRect
        switch handle {
        case .center:
            let nx = clamp(start.x + dx, 0, 1.0 - start.width)
            let ny = clamp(start.y + dy, 0, 1.0 - start.height)
            newRect = NormalizedRect(x: nx, y: ny, width: start.width, height: start.height)

        case .topLeft:
            let nx = clamp(start.x + dx, 0, start.x + start.width - 0.05)
            let ny = clamp(start.y + dy, 0, start.y + start.height - 0.05)
            let nw = start.x + start.width - nx
            let nh = start.y + start.height - ny
            newRect = NormalizedRect(x: nx, y: ny, width: nw, height: nh)

        case .topRight:
            let nw = clamp(start.width + dx, 0.05, 1.0 - start.x)
            let ny = clamp(start.y + dy, 0, start.y + start.height - 0.05)
            let nh = start.y + start.height - ny
            newRect = NormalizedRect(x: start.x, y: ny, width: nw, height: nh)

        case .bottomLeft:
            let nx = clamp(start.x + dx, 0, start.x + start.width - 0.05)
            let nw = start.x + start.width - nx
            let nh = clamp(start.height + dy, 0.05, 1.0 - start.y)
            newRect = NormalizedRect(x: nx, y: start.y, width: nw, height: nh)

        case .bottomRight:
            let nw = clamp(start.width + dx, 0.05, 1.0 - start.x)
            let nh = clamp(start.height + dy, 0.05, 1.0 - start.y)
            newRect = NormalizedRect(x: start.x, y: start.y, width: nw, height: nh)

        case .top:
            let ny = clamp(start.y + dy, 0, start.y + start.height - 0.05)
            let nh = start.y + start.height - ny
            newRect = NormalizedRect(x: start.x, y: ny, width: start.width, height: nh)

        case .bottom:
            let nh = clamp(start.height + dy, 0.05, 1.0 - start.y)
            newRect = NormalizedRect(x: start.x, y: start.y, width: start.width, height: nh)

        case .left:
            let nx = clamp(start.x + dx, 0, start.x + start.width - 0.05)
            let nw = start.x + start.width - nx
            newRect = NormalizedRect(x: nx, y: start.y, width: nw, height: start.height)

        case .right:
            let nw = clamp(start.width + dx, 0.05, 1.0 - start.x)
            newRect = NormalizedRect(x: start.x, y: start.y, width: nw, height: start.height)
        }

        // Apply aspect ratio constraint if needed
        if let ratio = aspectRatio.value, handle != .center {
            newRect = constrainToAspect(newRect, ratio: ratio, handle: handle)
        }

        cropRect = newRect
    }

    private func applyAspectRatio(_ ratio: CropAspectRatio) {
        guard let r = ratio.value else { return }
        var rect = cropRect
        let currentRatio = rect.width / rect.height
        if currentRatio > r {
            let newW = rect.height * r
            rect.x += (rect.width - newW) / 2
            rect.width = newW
        } else {
            let newH = rect.width / r
            rect.y += (rect.height - newH) / 2
            rect.height = newH
        }
        // Clamp to bounds
        rect.x = clamp(rect.x, 0, 1.0 - rect.width)
        rect.y = clamp(rect.y, 0, 1.0 - rect.height)
        cropRect = rect
    }

    private func constrainToAspect(_ rect: NormalizedRect, ratio: Double, handle: CropHandle) -> NormalizedRect {
        var r = rect
        let currentRatio = r.width / r.height
        if currentRatio > ratio {
            r.width = r.height * ratio
        } else {
            r.height = r.width / ratio
        }
        r.width = min(r.width, 1.0 - r.x)
        r.height = min(r.height, 1.0 - r.y)
        return r
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

// MARK: - Types

enum CropHandle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, left, right
    case center
}

enum CropAspectRatio: String, CaseIterable {
    case free = "Free"
    case ratio1x1 = "1:1"
    case ratio4x3 = "4:3"
    case ratio3x2 = "3:2"
    case ratio16x9 = "16:9"

    var value: Double? {
        switch self {
        case .free: return nil
        case .ratio1x1: return 1.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio3x2: return 3.0 / 2.0
        case .ratio16x9: return 16.0 / 9.0
        }
    }
}
