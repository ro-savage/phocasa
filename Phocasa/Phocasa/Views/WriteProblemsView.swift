import SwiftUI

/// One row of the status bar's list of write problems: a problem of its own, or every problem that shares a read-only
/// folder or drive (noticed once, not file by file).
struct WriteProblemRow: Identifiable, Equatable {
    enum ID: Hashable {
        case shared(MetadataWriteProblem.ReadOnlyPlace)
        case single(MetadataWriteProblem.Key)
    }

    let id: ID
    /// Newest first.
    let problems: [MetadataWriteProblem]

    /// The rows for `problems`, the newest first; the problems that share a read-only folder or drive make one row.
    static func rows(_ problems: [MetadataWriteProblem]) -> [WriteProblemRow] {
        var rows: [WriteProblemRow] = []
        var shared: [MetadataWriteProblem.ReadOnlyPlace: Int] = [:]
        for problem in problems.reversed() {
            guard let place = problem.sharedReadOnlyPlace else {
                rows.append(WriteProblemRow(id: .single(problem.key), problems: [problem]))
                continue
            }
            if let index = shared[place] {
                rows[index] = WriteProblemRow(id: rows[index].id, problems: rows[index].problems + [problem])
            } else {
                shared[place] = rows.count
                rows.append(WriteProblemRow(id: .shared(place), problems: [problem]))
            }
        }
        return rows
    }

    /// The files the row stands for, each once.
    var fileCount: Int { Set(problems.map(\.path)).count }

    var title: String {
        switch id {
        case .shared(.folder(let path)): "“\((path as NSString).lastPathComponent)” is read-only"
        case .shared(.volume(let name, _)): "“\(name)” is read-only"
        case .shared: ""
        case .single: problems.first?.fileName ?? ""
        }
    }

    var detail: String {
        let notUpdated = fileCount == 1 ? "wasn’t updated" : "weren’t updated"
        switch id {
        case .shared(.folder):
            return "\(fileCount.counted("file")) in this folder \(notUpdated)."
        case .shared(.volume):
            return "\(fileCount.counted("file")) on this drive \(notUpdated). It can’t be written to: it may be "
                + "formatted as NTFS, locked, or shared read-only."
        case .shared, .single:
            return problems.first?.reason ?? ""
        }
    }

    /// Where it is, for the row's last line.
    var location: String {
        switch id {
        case .shared(.folder(let path)): (path as NSString).abbreviatingWithTildeInPath
        case .shared(.volume(_, let path)): path
        case .shared: ""
        case .single: (((problems.first?.path ?? "") as NSString).deletingLastPathComponent as NSString)
            .abbreviatingWithTildeInPath
        }
    }

    /// What Show in Finder selects: the folder or drive, the sidecar a problem is about, or the file.
    var pathsToShow: [String] {
        switch id {
        case .shared(.folder(let path)), .shared(.volume(_, let path)):
            return [path]
        case .shared:
            return []
        case .single:
            guard let problem = problems.first else { return [] }
            switch problem.issue {
            case .keptInSidecar, .unparseableSidecar, .readOnly(.sidecar):
                return [URL(fileURLWithPath: problem.path).xmpSidecarURL.path]
            default:
                return [problem.path]
            }
        }
    }
}

/// "⚠︎ 3 files not updated" (and "2 kept in a sidecar") in the status bar: writes that didn't reach their files
/// (`MetadataWriteProblems`). Opens the list, with Show in Finder and Retry.
struct WriteProblemsIndicator: View {
    let viewModel: PhotoLibraryViewModel
    @State private var showingList = false

    var body: some View {
        let report = MetadataWriteProblems.shared.report
        let failed = report.failedFileCount
        let kept = report.keptInSidecarFileCount
        if failed > 0 || kept > 0 {
            Button { showingList.toggle() } label: {
                HStack(spacing: 6) {
                    if failed > 0 {
                        Label(report.failures.droppedCount > 0 ? "\(failed.formatted())+ files not updated"
                                                                : "\(failed.counted("file")) not updated",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if kept > 0 {
                        Label("\(kept.counted("file")) kept in a sidecar", systemImage: "doc.badge.ellipsis")
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .help(failed > 0 ? "Ratings, keywords or edits Phocasa couldn’t write into their files. Click for the list."
                             : "Files whose rating and keywords are in an .xmp sidecar. Click for the list.")
            .popover(isPresented: $showingList, arrowEdge: .top) {
                WriteProblemsList(viewModel: viewModel)
            }
        }
    }
}

/// The list the status bar's indicator opens: the files not updated, by row (`WriteProblemRow`), and the files kept in
/// a sidecar. Show in Finder for each; Retry for those not updated.
struct WriteProblemsList: View {
    let viewModel: PhotoLibraryViewModel

    /// Rows listed per section, at most (the report keeps up to `MetadataWriteProblemList.limit` problems).
    static let rowLimit = 200

    var body: some View {
        let report = MetadataWriteProblems.shared.report
        let failures = WriteProblemRow.rows(report.failures.problems)
        let kept = WriteProblemRow.rows(report.keptInSidecar.problems)
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !failures.isEmpty {
                        section("Not Updated",
                                "Phocasa couldn’t write these ratings, keywords or edits into the files. The library "
                                + "still has them: Retry once the files can be written.")
                        rows(failures, retry: true)
                    }
                    if report.failures.droppedCount > 0 {
                        Text("More files weren’t updated than can be listed here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !kept.isEmpty {
                        section("Kept in a Sidecar",
                                "These files can’t take their rating and keywords without losing some of their own "
                                + "metadata, so Phocasa put them in the .xmp sidecar beside each file. Apps that "
                                + "read sidecars see them.")
                        rows(kept, retry: false)
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                Button("Clear List") {
                    Task { await MetadataWriter.shared.clearProblems() }
                }
                .help("Forget these problems. The files stay as they are.")
                Spacer()
                if !failures.isEmpty {
                    Button("Retry All") { viewModel.retryWrites(report.failures.problems) }
                        .help("Write every file in the list again, with each photo’s current rating, keywords and edits.")
                }
            }
            .padding(10)
        }
        .frame(width: 460, height: 380)
    }

    private func section(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func rows(_ rows: [WriteProblemRow], retry: Bool) -> some View {
        ForEach(rows.prefix(Self.rowLimit)) { row in
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.detail)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.location)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button {
                    ShowInFinder.reveal(row.pathsToShow)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show \(row.title) in Finder")
                if retry {
                    Button("Retry") { viewModel.retryWrites(row.problems) }
                        .help("Write \(row.fileCount == 1 ? "it" : "them") again")
                }
            }
            .controlSize(.small)
        }
        if rows.count > Self.rowLimit {
            Text("And \((rows.count - Self.rowLimit).counted("more row")).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
