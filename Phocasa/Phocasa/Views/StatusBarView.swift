import SwiftUI

/// The bar along the bottom of the window: files going to the Trash, scan progress, or the photo, shown and selected
/// counts; on the right, the last export, metadata writes still to make and the ones that didn't reach their files.
/// Its own view, so selection changes re-evaluate it rather than the whole `ContentView`. `ContentView` puts it in the
/// window's bottom safe area, so it covers none of the content.
struct StatusBarView: View {
    let library: LibraryStore
    let selection: SelectionModel
    /// For the export notice and the write problems' Retry.
    let viewModel: PhotoLibraryViewModel

    /// Body evaluations, for tests.
    @MainActor static var bodyEvaluations = 0
    /// Fewer metadata writes left than this aren't shown (a few ratings take a moment), as with `trashProgressMinimum`.
    static let writesShownFrom = LibraryStore.trashProgressMinimum

    var body: some View {
        let _ = Self.bodyEvaluations += 1
        HStack {
            if let trash = library.trashProgress {
                ProgressView(value: Double(trash.done), total: Double(trash.total))
                    .frame(width: 60)
                Text("Moving \(trash.total.counted("file")) to the Trash… \(trash.done.formatted())/\(trash.total.formatted())")
                    .font(.caption)
            } else if library.isScanning {
                ProgressView()
                    .scaleEffect(0.6)
                Text(library.scanProgress)
                    .font(.caption)
            } else if library.viewingBin {
                Text("\(library.binCount.counted("photo")) in the Bin")
                    .font(.caption)
                selectedCount
            } else {
                Text(library.allPhotos.count.counted("photo"))
                    .font(.caption)
                if library.photos.count != library.allPhotos.count {
                    Text("(\(library.photos.count.formatted()) shown)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                selectedCount
            }
            if !library.isScanning, let message = library.statusMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(message)
            }
            Spacer()
            if let notice = viewModel.exportNotice {
                ExportNoticeView(notice: notice, viewModel: viewModel)
            }
            let writesLeft = MetadataWriteProgress.shared.pending
            if writesLeft > Self.writesShownFrom {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
                Text("Saving to files… \(writesLeft.formatted()) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Ratings, keywords and RAW edits being written into the photos’ files. Anything not written "
                          + "when Phocasa quits is written the next time it opens.")
            }
            WriteProblemsIndicator(viewModel: viewModel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var selectedCount: some View {
        if !selection.selectedPhotos.isEmpty {
            Text("• \(selection.selectedPhotos.count.formatted()) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Saved IMG_1234-raw-edit.jpg · Show in Finder", for `ExportNotice.duration`.
private struct ExportNoticeView: View {
    let notice: ExportNotice
    let viewModel: PhotoLibraryViewModel

    var body: some View {
        HStack(spacing: 6) {
            Label(notice.message, systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Show in Finder") { ShowInFinder.reveal([notice.url.path]) }
                .buttonStyle(.link)
        }
        .font(.caption)
        .help("Saved in the same folder as the photo, and added to the library next to it.")
        .task(id: notice.id) {
            try? await Task.sleep(for: ExportNotice.duration)
            guard !Task.isCancelled, viewModel.exportNotice?.id == notice.id else { return }
            viewModel.exportNotice = nil
        }
    }
}
