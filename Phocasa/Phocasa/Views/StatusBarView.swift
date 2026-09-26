import SwiftUI

/// The bar along the bottom of the window: files going to the Trash, scan progress, or the photo, shown and selected
/// counts. Its own view, so selection changes re-evaluate it rather than the whole `ContentView`.
struct StatusBarView: View {
    let library: LibraryStore
    let selection: SelectionModel

    /// Body evaluations, for tests.
    @MainActor static var bodyEvaluations = 0

    var body: some View {
        let _ = Self.bodyEvaluations += 1
        HStack {
            if let trash = library.trashProgress {
                ProgressView(value: Double(trash.done), total: Double(trash.total))
                    .frame(width: 60)
                Text("Moving \(trash.total) files to the Trash... \(trash.done)/\(trash.total)")
                    .font(.caption)
            } else if library.isScanning {
                ProgressView()
                    .scaleEffect(0.6)
                Text(library.scanProgress)
                    .font(.caption)
            } else if library.viewingBin {
                Text("\(library.binCount) in bin")
                    .font(.caption)
                if !selection.selectedPhotos.isEmpty {
                    Text("• \(selection.selectedPhotos.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(library.allPhotos.count) photos")
                    .font(.caption)
                if library.photos.count != library.allPhotos.count {
                    Text("(\(library.photos.count) shown)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !selection.selectedPhotos.isEmpty {
                    Text("• \(selection.selectedPhotos.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !library.isScanning, let message = library.statusMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(message)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
