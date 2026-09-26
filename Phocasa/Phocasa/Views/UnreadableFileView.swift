import SwiftUI

/// What the grid and the detail view show for a file ImageIO can't decode (damaged, empty, missing, or a format macOS
/// can't open), in place of a spinner that never ends or a black screen.
struct UnreadableFileView: View {
    /// The grid cell's size, or the detail view's.
    var compact = false
    /// The file's name, for the detail view.
    var fileName: String?

    static let title = "Can’t Show This File"
    static let explanation = "Phocasa can’t read it as an image. It may be damaged, empty or missing, or in a format "
        + "macOS can’t open. Its rating and tags still work."

    var body: some View {
        if compact {
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                Text(Self.title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
            .help(Self.explanation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.title)
        } else {
            ContentUnavailableView {
                Label(Self.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text([fileName, Self.explanation].compactMap { $0 }.joined(separator: "\n"))
            }
            .environment(\.colorScheme, .dark)
        }
    }
}
