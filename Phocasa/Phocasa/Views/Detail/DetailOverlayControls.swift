import SwiftUI

/// File name, position, tags, edit buttons, rating and the previous/next chevrons over the detail image.
///
/// Equatable by identity (`.equatable()` at the call site): the container re-evaluates on every slider tick,
/// and without this the `firstIndex` lookup below (O(N) in the library) would run each time. Changes to
/// what this view reads from the view model and the photo still re-render it through Observation.
/// (`@preconcurrency`: SwiftUI compares views on the main actor.)
struct DetailOverlayControls: View, @preconcurrency Equatable {
    let viewModel: PhotoLibraryViewModel
    let photo: PhotoAsset
    var onShowTags: () -> Void

    static func == (lhs: DetailOverlayControls, rhs: DetailOverlayControls) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.photo === rhs.photo
    }

    var body: some View {
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

                    // O(N); runs only when this view re-renders (not on zoom or pan frames). Task 30 swaps it
                    // for an index lookup.
                    if let index = viewModel.library.photos.firstIndex(where: { $0.id == photo.id }) {
                        Text("\(index + 1) / \(viewModel.library.photos.count)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    if photo.hasAnyEdits {
                        Text("Edited")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.6), in: Capsule())
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

                    // Edit buttons
                    HStack(spacing: 8) {
                        if photo.rawPath != nil {
                            editButton(isRAW: true)
                        }
                        if photo.jpgPath != nil {
                            editButton(isRAW: false)
                        }
                    }
                    .padding(.top, 4)
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
                    .onTapGesture { viewModel.navigateDetail(direction: -1) }

                Spacer()

                VStack(spacing: 8) {
                    RatingView(rating: photo.rating) { newRating in
                        viewModel.library.setRating(newRating, for: photo)
                    }

                    HStack(spacing: 12) {
                        Text("Tags")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.2), in: Capsule())
                            .contentShape(Capsule())
                            .onTapGesture { onShowTags() }
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
                    .onTapGesture { viewModel.navigateDetail(direction: 1) }
            }
            .padding()
        }
    }

    // MARK: - Edit Buttons

    private func editButton(isRAW: Bool) -> some View {
        let isActive = viewModel.editSession.map { $0.photo.id == photo.id && $0.isRAW == isRAW } ?? false
        return Button(action: {
            if isActive {
                viewModel.stopEditing(save: true)
            } else {
                viewModel.startEditing(photo: photo, isRAW: isRAW)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isRAW ? "camera.filters" : "photo.on.rectangle")
                    .font(.caption)
                Text(isRAW ? "RAW" : "JPG")
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isActive
                    ? (isRAW ? Color.blue : Color.orange)
                    : (isRAW ? Color.blue.opacity(0.4) : Color.orange.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
