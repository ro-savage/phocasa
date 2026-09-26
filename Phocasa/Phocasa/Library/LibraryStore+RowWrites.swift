import SwiftData
import Foundation

// Writing photos' changed ratings, tags, bin flags and saved edits (and permanent deletes) to their rows.
//
// A change shows in memory at once: the facts, the counts and the grid are patched by the action, and the views read
// `rating(of:)`, `tags(of:)` and `hasAnyEdits(of:)`, which see changes not written yet. The rows are written through
// this queue:
// - An action on at most `rowWrites.immediateLimit` photos writes them in the turn it's made, in one save, as before.
// - A bigger one is written by `rowWrites.task` in chunks sized by time (`WriteChunkSizer`), with a pause between
//   them for the run loop. A main-context save costs about 1 µs per loaded photo plus 0.1–0.15 ms per row it writes,
//   so one save of 150,000 ratings held the window for 23 s.
// - A photo's changes merge, the latest value of each field winning, so a second action during the chunks can't be
//   lost or overwritten by the first one's later chunk. Photos are written in the order they were first changed.
// - A photo's rating and keywords go to its files (`MetadataWriter`) when its row is written, read from the row: the
//   files never get a value the store doesn't hold, and never one older than the last queued.
// - Tags are linked and unlinked on the tag's side, once per tag and chunk (`tag.photos`): SwiftData rewrites the
//   whole inverse list for every photo-side change, which made tagging k photos cost O(k × tag size).
// - Whatever reads these fields from the store, or writes them on the models directly, first waits for the queue or
//   writes the photos it touches (`writePendingRows(of:)`): scans (`waitForRowWrites()`), `loadExistingData()`, the
//   detail view and edit sessions, file-type deletes, and quitting (`writeAllPendingRows()`).
// - If the app is killed before a chunk, the rows written so far are each whole (a chunk is one save), the others keep
//   their old values, and so do their files: their metadata writes weren't queued yet.
extension LibraryStore {
    /// What a change sets on one photo's row. Nil fields (and empty tag lists) don't change.
    struct RowChange {
        var rating: Int?
        var isInBin: Bool?
        /// Tags the row gains and tags it loses, against the row as stored. Disjoint.
        var addedTags: [Tag] = []
        var removedTags: [Tag] = []
        var edits: SavedEdits?
        /// The row is deleted (a permanent delete, once its files are in the Trash); nothing else is written.
        var deletes = false
        /// Once the row is written, the photo's rating and keywords are written to its files.
        var writesMetadata = false

        var hasTagChanges: Bool { !addedTags.isEmpty || !removedTags.isEmpty }

        /// Takes in a newer change to the same photo: its values win.
        mutating func merge(_ newer: RowChange) {
            if let rating = newer.rating { self.rating = rating }
            if let isInBin = newer.isInBin { self.isInBin = isInBin }
            if let edits = newer.edits { self.edits = edits }
            for tag in newer.addedTags {
                if let index = removedTags.firstIndex(where: { $0 === tag }) {
                    removedTags.remove(at: index) // the row still has it
                } else if !addedTags.contains(where: { $0 === tag }) {
                    addedTags.append(tag)
                }
            }
            for tag in newer.removedTags {
                if let index = addedTags.firstIndex(where: { $0 === tag }) {
                    addedTags.remove(at: index) // the row never had it
                } else if !removedTags.contains(where: { $0 === tag }) {
                    removedTags.append(tag)
                }
            }
            deletes = deletes || newer.deletes
            writesMetadata = writesMetadata || newer.writesMetadata
        }
    }

    /// A photo's saved JPG edit (`jpgEditParametersData`) and whether its RAW has one (in its sidecar).
    struct SavedEdits: Equatable {
        var jpgEditParametersData: Data?
        var hasRawEdits: Bool

        var isEmpty: Bool { jpgEditParametersData == nil && !hasRawEdits }
    }

    /// The queue's state, stored in `rowWrites`.
    struct RowWriteState {
        /// Changes not written yet, by photo (the entry keeps the photo, so its identifier stays unique).
        fileprivate var pending: [ObjectIdentifier: (photo: PhotoAsset, change: RowChange)] = [:]
        /// The photos in `pending` in the order they were first changed, from `next` on. Photos written early
        /// (`writePendingRows(of:)`) leave their place behind; it is skipped.
        fileprivate var order: [ObjectIdentifier] = []
        fileprivate var next = 0
        /// Writes the queue in chunks while it isn't empty.
        fileprivate(set) var task: Task<Void, Never>?
        var sizer = WriteChunkSizer()
        /// Whether the task leaves the run loop a pause between chunks. Tests turn it off.
        var pausesBetweenChunks = true
        /// Test hook: called after each save of the queue's rows, with how many photos it wrote.
        var didWriteRows: ((Int) -> Void)?

        /// Photos with changes not written yet.
        var count: Int { pending.count }

        /// An action on at most this many photos writes them in the turn it's made: at least `immediateMinimum`, or
        /// what one chunk of the write task would take.
        var immediateLimit: Int { max(immediateMinimum, sizer.steadyRows(fallback: immediateMinimum)) }
        /// Tests make it small, with `sizer.maximumRows`, to have small libraries written in chunks.
        var immediateMinimum = 256
    }

    // MARK: - Queueing

    /// Adds changes to the queue (one per photo; a photo's newer change merges into its older one) without writing
    /// anything. The caller patches the in-memory library, then calls `writeQueuedRows(changedNow:)`.
    func enqueueRowChanges(_ changes: [(photo: PhotoAsset, change: RowChange)]) {
        guard !changes.isEmpty else { return }
        for (photo, change) in changes {
            let key = ObjectIdentifier(photo)
            if var entry = rowWrites.pending[key] {
                entry.change.merge(change)
                rowWrites.pending[key] = entry
            } else {
                rowWrites.pending[key] = (photo, change)
                rowWrites.order.append(key)
            }
        }
        pendingRowsVersion &+= 1
    }

    /// After `enqueueRowChanges`: an action on few photos (`photos`, at most `rowWrites.immediateLimit`) writes them
    /// now, in one save, even while a bigger action's chunks are still being written; a bigger one leaves them to the
    /// write task.
    func writeQueuedRows(changedNow photos: [PhotoAsset]) {
        if photos.count <= rowWrites.immediateLimit {
            writePendingRows(of: photos)
        }
        startRowWriteTask()
    }

    /// `enqueueRowChanges` then `writeQueuedRows`, for callers with nothing to patch in between.
    func queueRowChanges(_ changes: [(photo: PhotoAsset, change: RowChange)]) {
        enqueueRowChanges(changes)
        writeQueuedRows(changedNow: changes.map(\.photo))
    }

    // MARK: - Writing

    /// Whether some photos' changes aren't in the store yet.
    var hasPendingRowWrites: Bool { !rowWrites.pending.isEmpty }

    /// Writes the queued changes of `photos` now, in one save (the others stay queued): for code about to read or
    /// write their fields on the models, and for small actions.
    func writePendingRows(of photos: [PhotoAsset]) {
        guard !rowWrites.pending.isEmpty, let context = modelContext else { return }
        let entries = photos.compactMap { rowWrites.pending.removeValue(forKey: ObjectIdentifier($0)) }
        guard !entries.isEmpty else { return }
        let clock = ContinuousClock()
        let start = clock.now
        writeRows(entries, in: context)
        rowWrites.sizer.record(rows: entries.count, took: clock.now - start)
        compactRowOrder()
    }

    /// Writes every queued change now, in one save: quitting, and full loads, which read the store.
    func writeAllPendingRows() {
        guard !rowWrites.pending.isEmpty, let context = modelContext else { return }
        var entries: [(photo: PhotoAsset, change: RowChange)] = []
        entries.reserveCapacity(rowWrites.pending.count)
        for key in rowWrites.order[rowWrites.next...] {
            if let entry = rowWrites.pending.removeValue(forKey: key) { entries.append(entry) }
        }
        entries += rowWrites.pending.values // none: every queued photo has a place from `next` on
        rowWrites.pending = [:]
        rowWrites.order = []
        rowWrites.next = 0
        writeRows(entries, in: context)
    }

    /// Returns once the queue is written (the write task has finished).
    func waitForRowWrites() async {
        while let task = rowWrites.task {
            await task.value
        }
    }

    /// Starts the write task if there is something to write and it isn't running. It holds the library and the
    /// container weakly, like other work that runs later against the context: a context doesn't keep its container
    /// alive, and a store that outlived its container writes nothing more.
    private func startRowWriteTask() {
        guard rowWrites.task == nil, !rowWrites.pending.isEmpty, let context = modelContext else { return }
        let container = context.container
        rowWrites.task = Task { [weak self, weak container] in
            var pause = self?.writeRowChunk(containerIsAlive: container != nil)
            while let wait = pause {
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                } else {
                    await Task.yield()
                }
                pause = self?.writeRowChunk(containerIsAlive: container != nil)
            }
        }
    }

    /// One chunk for the write task. Returns the pause before the next one, or nil (and the task ends) once the queue
    /// is empty.
    private func writeRowChunk(containerIsAlive: Bool) -> Duration? {
        guard containerIsAlive, let context = modelContext, !rowWrites.pending.isEmpty else {
            rowWrites.task = nil
            return nil
        }
        let clock = ContinuousClock()
        let start = clock.now
        var entries: [(photo: PhotoAsset, change: RowChange)] = []
        let limit = rowWrites.sizer.rows
        while entries.count < limit, rowWrites.next < rowWrites.order.count {
            let key = rowWrites.order[rowWrites.next]
            rowWrites.next += 1
            if let entry = rowWrites.pending.removeValue(forKey: key) { entries.append(entry) }
        }
        compactRowOrder()
        writeRows(entries, in: context)
        let elapsed = clock.now - start
        rowWrites.sizer.record(rows: entries.count, took: elapsed)
        guard !rowWrites.pending.isEmpty else {
            rowWrites.task = nil
            return nil
        }
        return rowWrites.pausesBetweenChunks ? WriteChunkSizer.pause(after: elapsed) : .zero
    }

    private func compactRowOrder() {
        if rowWrites.pending.isEmpty || rowWrites.next >= rowWrites.order.count {
            rowWrites.order = Array(rowWrites.order[min(rowWrites.next, rowWrites.order.count)...])
                .filter { rowWrites.pending[$0] != nil }
            rowWrites.next = 0
        } else if rowWrites.next > 4_096 && rowWrites.next * 2 > rowWrites.order.count {
            rowWrites.order.removeFirst(rowWrites.next)
            rowWrites.next = 0
        }
    }

    /// Writes `entries` into their rows and saves once. Tag links change on each tag's side, once per tag (the tag's
    /// inverse list is rewritten once, not once per photo). Rows deleted from the context since are skipped. Then the
    /// rating and keywords of the photos that asked for it go to their files, as the rows now hold them.
    private func writeRows(_ entries: [(photo: PhotoAsset, change: RowChange)], in context: ModelContext) {
        guard !entries.isEmpty else { return }
        var gained: [ObjectIdentifier: (tag: Tag, photos: [PhotoAsset])] = [:]
        var lost: [ObjectIdentifier: (tag: Tag, photos: [ObjectIdentifier: PhotoAsset])] = [:]
        var deleting: [PhotoAsset] = []
        var metadata: [PhotoAsset] = []
        for (photo, change) in entries where photo.modelContext != nil && !photo.isDeleted {
            if change.deletes {
                for tag in photo.tags {
                    lost[ObjectIdentifier(tag), default: (tag, [:])].photos[ObjectIdentifier(photo)] = photo
                }
                deleting.append(photo)
                continue
            }
            if let rating = change.rating, photo.rating != rating { photo.rating = rating }
            if let isInBin = change.isInBin, photo.isInBin != isInBin { photo.isInBin = isInBin }
            if let edits = change.edits {
                if photo.jpgEditParametersData != edits.jpgEditParametersData {
                    photo.jpgEditParametersData = edits.jpgEditParametersData
                }
                if photo.hasRawEdits != edits.hasRawEdits { photo.hasRawEdits = edits.hasRawEdits }
            }
            for tag in change.addedTags {
                gained[ObjectIdentifier(tag), default: (tag, [])].photos.append(photo)
            }
            for tag in change.removedTags {
                lost[ObjectIdentifier(tag), default: (tag, [:])].photos[ObjectIdentifier(photo)] = photo
            }
            if change.writesMetadata { metadata.append(photo) }
        }
        // One photo is cheaper on its own side (the tag's list isn't read here, only diffed by the save).
        for (tag, photos) in gained.values {
            let adding = photos.filter { photo in !photo.tags.contains { $0 === tag } }
            if adding.count == 1 {
                adding[0].tags.append(tag)
            } else if !adding.isEmpty {
                tag.photos.append(contentsOf: adding)
            }
        }
        for (tag, photos) in lost.values {
            if photos.count == 1, let photo = photos.values.first {
                photo.tags.removeAll { $0 === tag }
            } else {
                tag.photos.removeAll { photos[ObjectIdentifier($0)] != nil }
            }
        }
        for photo in deleting {
            context.delete(photo)
        }
        try? context.save()
        if !metadata.isEmpty {
            MetadataWriter.shared.enqueue(metadata.map { metadataWriteItem(for: $0) })
        }
        pendingRowsVersion &+= 1
        rowWrites.didWriteRows?(entries.count)
    }

    // MARK: - What the views read

    /// The photo's rating as the library shows it: a change not written to its row yet, else the row's.
    func rating(of photo: PhotoAsset) -> Int {
        _ = pendingRowsVersion
        return rowWrites.pending[ObjectIdentifier(photo)]?.change.rating ?? photo.rating
    }

    /// The photo's tags as the library shows it (the row's, with changes not written yet: added ones last).
    func tags(of photo: PhotoAsset) -> [Tag] {
        _ = pendingRowsVersion
        guard let change = rowWrites.pending[ObjectIdentifier(photo)]?.change, change.hasTagChanges else {
            return photo.tags
        }
        var tags = photo.tags.filter { tag in !change.removedTags.contains { $0 === tag } }
        for tag in change.addedTags where !tags.contains(where: { $0 === tag }) {
            tags.append(tag)
        }
        return tags
    }

    /// The photo's saved edits as the library shows them.
    func savedEdits(of photo: PhotoAsset) -> SavedEdits {
        _ = pendingRowsVersion
        return rowWrites.pending[ObjectIdentifier(photo)]?.change.edits
            ?? SavedEdits(jpgEditParametersData: photo.jpgEditParametersData, hasRawEdits: photo.hasRawEdits)
    }

    /// `PhotoAsset.hasAnyEdits`, with changes not written yet.
    func hasAnyEdits(of photo: PhotoAsset) -> Bool {
        !savedEdits(of: photo).isEmpty
    }

    /// The photo's facts, from its model and the changes not written to its row yet.
    func facts(of photo: PhotoAsset) -> PhotoFacts {
        guard let change = rowWrites.pending[ObjectIdentifier(photo)]?.change,
              change.rating != nil || change.hasTagChanges else {
            return PhotoFacts(photo, tags: &tagFacts)
        }
        return PhotoFacts(photo, rating: rating(of: photo), tags: tags(of: photo), tagFacts: &tagFacts)
    }
}
