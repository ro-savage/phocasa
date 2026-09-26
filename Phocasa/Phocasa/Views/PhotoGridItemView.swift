import SwiftUI

struct PhotoGridItemView: View {
    let photo: PhotoAsset
    let isSelected: Bool
    /// Long-edge pixel size bucket, from `ImageLoader.thumbnailBucket(forPixels:)`.
    let thumbnailBucket: Int
    let onRate: (Int) -> Void
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    /// While the grid is hidden under the detail view: start no thumbnail load, and cancel the one in flight.
    var thumbnailsPaused = false

    @State private var thumbnail: NSImage?
    /// The path whose thumbnail couldn't be made (the file can't be decoded): the cell says so.
    @State private var unreadablePath: String?

    /// Identity of the thumbnail load. A window resize that stays within one bucket keeps the same identity,
    /// so it never restarts the load. Pausing cancels the load, and resuming starts it again.
    struct ThumbnailTaskID: Hashable {
        let path: String
        let bucket: Int
        var paused = false
    }

    var body: some View {
        let path = photo.displayPath

        VStack(spacing: 4) {
            thumbnailArea(path: path)

            Text(photo.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            // Keeps the rating row's place (every rating has the same size). The stars you click are in the
            // overlay below.
            RatingView(rating: 0, compact: true)
                .hidden()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        // Select on the first click, without waiting to see whether a second click follows (spec §C5).
        // A double-click therefore selects, then opens, like Finder.
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        // The stars sit over the cell, outside its select and open gestures (a simultaneous double-tap on the
        // cell would fire for a double-click anywhere inside it). So a click on a star rates at once and doesn't
        // select, and a double-click on the stars rates instead of opening the photo (user decision, task 23).
        .overlay(alignment: .bottom) {
            RatingView(rating: photo.rating, compact: true, onRate: onRate)
                .padding(.bottom, 6)
        }
        .task(id: ThumbnailTaskID(path: path, bucket: thumbnailBucket, paused: thumbnailsPaused)) {
            guard !thumbnailsPaused else { return }
            await loadThumbnail(path: path)
        }
    }

    /// A square sized from the column width alone, so the grid never has to measure the image.
    private func thumbnailArea(path: String) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(minWidth: 60, minHeight: 60)
            .overlay {
                // A thumbnail that is already cached shows on the first frame (for example when scrolling back),
                // instead of flashing the placeholder until the task runs.
                if let image = thumbnail
                    ?? ImageLoader.shared.cachedThumbnail(for: path, maxSize: CGFloat(thumbnailBucket)) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if path.isEmpty || unreadablePath == path {
                    UnreadableFileView(compact: true)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                badges
            }
    }

    private var badges: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if photo.hasRawPair {
                Text("RAW")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
            }
            if photo.hasAnyEdits {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.orange.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(4)
    }

    /// Thumbnail loads started by grid cells, for tests: the grid hidden under the detail view must start none.
    @MainActor static var thumbnailLoadsStarted = 0

    private func loadThumbnail(path: String) async {
        guard !path.isEmpty else { return }

        Self.thumbnailLoadsStarted += 1
        if let img = await ImageLoader.shared.loadThumbnail(for: path, maxSize: CGFloat(thumbnailBucket)) {
            thumbnail = img
            unreadablePath = nil
        } else if !Task.isCancelled {
            // Not cancelled (scrolled away, paused under the detail view): the file couldn't be decoded.
            unreadablePath = path
        }
    }
}
