import SwiftUI

struct PhotoGridItemView: View {
    let photo: PhotoAsset
    let isSelected: Bool
    let onRate: (Int) -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
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
                .frame(minWidth: 60, minHeight: 60)
                .aspectRatio(1, contentMode: .fill)
                .clipped()
                .cornerRadius(6)

                if photo.hasRawPair {
                    Text("RAW")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }

            Text(photo.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            RatingView(rating: photo.rating, compact: true, onRate: onRate)
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
        .task(id: photo.displayPath) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if let data = photo.thumbnailData, let img = NSImage(data: data) {
            thumbnail = img
            return
        }

        let path = photo.displayPath
        guard !path.isEmpty else { return }

        if let img = await ImageLoader.shared.loadThumbnail(for: path) {
            thumbnail = img
        }
    }
}
