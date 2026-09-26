import SwiftUI

/// The window's content: the library (sidebar and grid) and, above it while open, the detail view with its edit
/// sidebar.
///
/// The library stays in the hierarchy under the detail view (spec §G4), so coming back finds the grid as it was, at
/// the same scroll position, with its cells and their thumbnails. While hidden it takes no clicks, is hidden from
/// accessibility, and its cells start no thumbnail loads.
struct MainContentView: View {
    let viewModel: PhotoLibraryViewModel

    var body: some View {
        let detailPhoto = viewModel.showingDetail ? viewModel.selectedDetailPhoto : nil
        let showsDetail = detailPhoto != nil

        ZStack {
            NavigationSplitView {
                SidebarView(viewModel: viewModel)
                    .frame(minWidth: 200)
            } detail: {
                PhotoGridView(viewModel: viewModel, thumbnailsPaused: showsDetail)
                    .frame(minWidth: 400, minHeight: 300)
            }
            .opacity(showsDetail ? 0 : 1)
            .allowsHitTesting(!showsDetail)
            .accessibilityHidden(showsDetail)

            if let detailPhoto {
                HStack(spacing: 0) {
                    PhotoDetailView(viewModel: viewModel, photo: detailPhoto)
                        .frame(minWidth: 600, minHeight: 600)

                    if let session = viewModel.editSession {
                        Divider()
                        EditSidebarView(session: session, viewModel: viewModel)
                    }
                }
            }
        }
    }
}
