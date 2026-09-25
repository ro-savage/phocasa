import SwiftUI

struct PhotoGridItemView: View {
    let photo: PhotoAsset
    let isSelected: Bool
    /// Long-edge pixel size bucket, from `ImageLoader.thumbnailBucket(forPixels:)`.
    let thumbnailBucket: Int
    let onRate: (Int) -> Void
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}

    @State private var thumbnail: NSImage?

    /// Identity of the thumbnail load. A window resize that stays within one bucket keeps the same identity,
    /// so it never restarts the load.
    struct ThumbnailTaskID: Hashable {
        let path: String
        let bucket: Int
    }

    var body: some View {
        let path = photo.displayPath

        VStack(spacing: 4) {
            thumbnailArea(path: path)

            Text(photo.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            RatingView(rating: photo.rating, compact: true, onRate: onRate)
                // The cell selects on a plain tap and opens on a simultaneous double-tap (below). Without this,
                // a double-click on a star would rate twice (set, then clear). With it, the stars wait out
                // double-click detection as they always have, and a double-click on them opens the photo.
                .highPriorityGesture(TapGesture(count: 2).onEnded {})
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
        .task(id: ThumbnailTaskID(path: path, bucket: thumbnailBucket)) {
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

    private func loadThumbnail(path: String) async {
        guard !path.isEmpty else { return }

        if let img = await ImageLoader.shared.loadThumbnail(for: path, maxSize: CGFloat(thumbnailBucket)) {
            thumbnail = img
        }
    }
}
