import SwiftUI

/// File name, position, tags, edit buttons, rating and the previous/next chevrons over the detail image.
///
/// Equatable by identity (`.equatable()` at the call site): the container re-evaluates on every slider tick, and
/// this body needn't. Changes to what this view reads from the view model and the photo still re-render it through
/// Observation.
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

                    // A photo rated, tagged or binned out of the grid's filter shows no position of its own; the
                    // arrows move on from where it was.
                    let place = viewModel.library.gridPlace(of: photo)
                    let count = viewModel.library.photos.count.formatted()
                    Text(place.isShown ? "\((place.index + 1).formatted()) / \(count)" : "– / \(count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))

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
                chevron(direction: -1)

                Spacer()

                VStack(spacing: 8) {
                    RatingView(rating: photo.rating) { newRating in
                        viewModel.library.setRating(newRating, for: photo)
                    }

                    Button(action: onShowTags) {
                        Text("Tags")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.2), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Add or remove this photo’s tags")
                    .accessibilityLabel("Tags")
                }
                .padding()
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                chevron(direction: 1)
            }
            .padding()
        }
        // White on black, whatever the window's appearance: the stars and `.secondary` take their dark-mode colours.
        .environment(\.colorScheme, .dark)
    }

    /// The previous (-1) or next (1) photo, as ← and → do; disabled at either end of the grid.
    private func chevron(direction: Int) -> some View {
        let previous = direction < 0
        let canGo = viewModel.canNavigateDetail(direction: direction)
        return Button(action: { viewModel.navigateDetail(direction: direction) }) {
            Image(systemName: previous ? "chevron.left" : "chevron.right")
                .font(.title2)
                .foregroundStyle(.white.opacity(canGo ? 1 : 0.35))
                .padding(12)
                .background(.black.opacity(0.5), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canGo)
        .help(previous ? "Previous photo (←)" : "Next photo (→)")
        .accessibilityLabel(previous ? "Previous Photo" : "Next Photo")
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
                // The file's kind: a HEIC, PNG or TIFF isn't called a JPG.
                Text(isRAW ? "RAW" : EditSession.kind(ofStandardFileAt: photo.jpgPath))
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
