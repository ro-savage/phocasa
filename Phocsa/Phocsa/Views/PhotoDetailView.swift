import SwiftUI

struct PhotoDetailView: View {
    @Bindable var viewModel: PhotoLibraryViewModel
    let photo: PhotoAsset

    @State private var displayedImage: NSImage?
    @State private var loadedPath: String?
    @State private var magnification: CGFloat = 1.0
    @State private var showTagEditor = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let displayedImage {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: displayedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: geometry.size.width * magnification,
                                height: geometry.size.height * magnification
                            )
                            .frame(
                                minWidth: geometry.size.width,
                                minHeight: geometry.size.height
                            )
                    }
                }
                .transition(.opacity)
            }

            // Overlays
            VStack {
                HStack {
                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(photo.fileName)
                            .font(.headline)
                            .foregroundStyle(.white)

                        if photo.hasRawPair {
                            Text("JPG + RAW")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        if let index = viewModel.photos.firstIndex(where: { $0.id == photo.id }) {
                            Text("\(index + 1) / \(viewModel.photos.count)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        if !photo.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(photo.tags, id: \.id) { tag in
                                    Text(tag.name)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.white.opacity(0.2), in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }

                Spacer()

                HStack {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                        .contentShape(Circle())
                        .onTapGesture {
                            viewModel.navigateDetail(direction: -1)
                        }

                    Spacer()

                    VStack(spacing: 8) {
                        RatingView(rating: photo.rating) { newRating in
                            viewModel.setRating(newRating, for: photo)
                        }

                        HStack(spacing: 12) {
                            Text("Tags")
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.2), in: Capsule())
                                .contentShape(Capsule())
                                .onTapGesture {
                                    showTagEditor.toggle()
                                }

                            Text("Zoom: \(Int(magnification * 100))%")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding()
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.5), in: Circle())
                        .contentShape(Circle())
                        .onTapGesture {
                            viewModel.navigateDetail(direction: 1)
                        }
                }
                .padding()
            }
        }
        .popover(isPresented: $showTagEditor) {
            TagEditorView(viewModel: viewModel, photo: photo)
                .frame(width: 300, height: 400)
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    magnification = max(0.25, min(magnification * value.magnification, 10.0))
                }
        )
        .task(id: photo.displayPath) {
            let path = photo.displayPath
            guard path != loadedPath, !path.isEmpty else { return }

            // Load new image in background — keep old one visible
            if let newImage = await ImageLoader.shared.loadFullResolution(for: path) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    displayedImage = newImage
                }
                loadedPath = path
                magnification = 1.0
            }
        }
    }
}
