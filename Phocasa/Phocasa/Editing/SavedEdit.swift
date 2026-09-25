import AppKit

/// Which saved edit an image shows: the JPG's or the RAW's, and with which parameters.
struct SavedEditKey: Equatable, Sendable {
    let isRAW: Bool
    let parameters: EditParameters
}

/// A render of a photo's saved edit.
struct SavedEditRender {
    let key: SavedEditKey
    let image: NSImage
    /// The `maxSize` it was rendered with to fill a viewport at fit; nil: native resolution.
    var fittedMaxSize: CGSize? = nil
    /// The edited file's pixel size after orientation, when known.
    var sourceSize: CGSize? = nil

    /// The edit's size at native resolution (crop and rotation applied), for the view's 1:1 zoom.
    var nativePixelSize: CGSize? {
        sourceSize.map { EditRenderSize.outputSize(native: $0, parameters: key.parameters) }
    }
}

/// What an editing session saved, handed to the detail view when the session ends, so the detail view shows the
/// saved edit straight away instead of the unedited photo.
struct SavedEditHandoff: Identifiable {
    let id = UUID()
    let photoID: UUID
    /// What was saved. Default parameters mean the session cleared its kind's saved edits.
    let saved: SavedEditKey
    /// The session's latest render and the parameters it shows. It can lag `saved` by a slider tick whose render
    /// hadn't landed yet.
    let image: NSImage?
    let imageParameters: EditParameters?
    /// `image` is the session's pass at native resolution.
    let isFullResolution: Bool
    /// `image` is the session's pass fitted to its viewport, rendered with this `maxSize`.
    var fittedMaxSize: CGSize? = nil
    /// The edited file's pixel size after orientation, when the session knew it.
    var sourceSize: CGSize? = nil

    /// The session's render, if it is a finished full-resolution render of exactly `key`.
    func fullResolutionImage(for key: SavedEditKey) -> NSImage? {
        image(for: key, covering: nil)
    }

    /// The session's render, if it is a finished pass of exactly `key` with the pixels of a render made with
    /// `maxSize` (nil: native): a native pass covers any size, a fitted one covers sizes up to its own.
    func image(for key: SavedEditKey, covering maxSize: CGSize?) -> NSImage? {
        guard key == saved, imageParameters == saved.parameters else { return nil }
        if isFullResolution { return image }
        guard let fittedMaxSize, EditRenderSize.covers(fittedMaxSize, maxSize) else { return nil }
        return image
    }
}

/// How the detail view picks and renders a photo's saved edit.
enum SavedEdit {
    /// The saved-edit render to show. The JPG render takes precedence, so the RAW render, which takes seconds at
    /// full resolution, runs only when there is no JPG render. Before task 12, both ran and the RAW result was
    /// thrown away whenever the photo had both (spec §D4).
    @MainActor
    static func render<T>(jpg: (() async -> T?)?, raw: (() async -> T?)?) async -> T? {
        if let jpg, let rendered = await jpg() { return rendered }
        if let raw { return await raw() }
        return nil
    }

    /// Renders `photo`'s saved edit on the `.full` lane, so it never delays edit previews.
    /// - `viewport` (device pixels): render just enough to fill it at fit (`EditRenderSize.fitMaxSize`); nil, or a
    ///   viewport that needs the photo's full resolution, renders natively.
    /// - The RAW sidecar is read only when there is no JPG render, and off the main thread.
    /// - `handoff`: a session that just saved this photo. Its render is reused when it shows exactly the saved edit
    ///   that wins and has the pixels wanted, instead of rendering it again.
    @MainActor
    static func render(for photo: PhotoAsset, fitting viewport: CGSize? = nil,
                       reusing handoff: SavedEditHandoff? = nil) async -> SavedEditRender? {
        var jpg: (() async -> SavedEditRender?)?
        if let params = photo.jpgEditParameters, !params.isDefault, let jpgPath = photo.jpgPath {
            let key = SavedEditKey(isRAW: false, parameters: params)
            jpg = { await renderEdit(key, of: URL(fileURLWithPath: jpgPath), fitting: viewport, reusing: handoff) }
        }
        var raw: (() async -> SavedEditRender?)?
        if let rawPath = photo.rawPath {
            raw = {
                guard let params = await RAWEditStore.shared.load(forRAWAt: rawPath), !params.isDefault else { return nil }
                return await renderEdit(SavedEditKey(isRAW: true, parameters: params), of: URL(fileURLWithPath: rawPath),
                                        fitting: viewport, reusing: handoff)
            }
        }
        return await render(jpg: jpg, raw: raw)
    }

    @MainActor
    private static func renderEdit(_ key: SavedEditKey, of url: URL, fitting viewport: CGSize?,
                                   reusing handoff: SavedEditHandoff?) async -> SavedEditRender? {
        let source = await EditRenderSize.loadNativeSize(ofImageAt: url)
        var maxSize: CGSize?
        if let viewport, let source {
            maxSize = EditRenderSize.fitMaxSize(native: source, parameters: key.parameters, viewport: viewport)
        }
        if let handoff, let image = handoff.image(for: key, covering: maxSize) {
            return SavedEditRender(key: key, image: image,
                                   fittedMaxSize: handoff.isFullResolution ? nil : handoff.fittedMaxSize,
                                   sourceSize: source)
        }
        let service = ImageEditingService.shared
        let image = key.isRAW
            ? await service.processRAW(url: url, parameters: key.parameters, maxSize: maxSize, lane: .full)
            : await service.processStandard(url: url, parameters: key.parameters, maxSize: maxSize, lane: .full)
        return image.map { SavedEditRender(key: key, image: $0, fittedMaxSize: maxSize, sourceSize: source) }
    }

    /// The saved edit `render(for:)` would show first for `photo`: its JPG edit, else its RAW edit (the sidecar read
    /// off the main thread).
    @MainActor
    static func winningKey(for photo: PhotoAsset) async -> SavedEditKey? {
        if let params = photo.jpgEditParameters, !params.isDefault, photo.jpgPath != nil {
            return SavedEditKey(isRAW: false, parameters: params)
        }
        guard let rawPath = photo.rawPath, let params = await RAWEditStore.shared.load(forRAWAt: rawPath),
              !params.isDefault else { return nil }
        return SavedEditKey(isRAW: true, parameters: params)
    }

    /// Whether `render`, made earlier, still shows `photo`'s saved edit, with the pixels of a render fitting
    /// `viewport` (nil: native).
    @MainActor
    static func isCurrent(_ render: SavedEditRender, for photo: PhotoAsset, fitting viewport: CGSize?) async -> Bool {
        guard await winningKey(for: photo) == render.key else { return false }
        var wanted: CGSize?
        if let viewport, let source = render.sourceSize {
            wanted = EditRenderSize.fitMaxSize(native: source, parameters: render.key.parameters, viewport: viewport)
        }
        return EditRenderSize.covers(render.fittedMaxSize, wanted)
    }

    /// Whether the model says `photo` has a saved edit worth rendering ahead: a JPG edit, or a RAW edit flagged by
    /// `hasRawEdits` (set whenever Phocasa saves one).
    static func mayHaveSavedEdit(_ photo: PhotoAsset) -> Bool {
        if let params = photo.jpgEditParameters, !params.isDefault, photo.jpgPath != nil { return true }
        return photo.hasRawEdits && photo.rawPath != nil
    }

    /// What the detail view shows right after `handoff`, until `render(for:reusing:)` has resolved the saved edit
    /// again. It follows the same precedence (a JPG edit wins over a RAW one) with what is known without reading the
    /// sidecar:
    /// - `jpgParameters`: the photo's saved JPG parameters now (the session has already updated the model);
    /// - `current`: the saved edit the view showed before the session ended.
    /// A render already on screen of exactly the winning edit is kept (the session may not have rendered at all);
    /// otherwise the session's render of it. Returns nil when the winner isn't known yet or there is no saved edit:
    /// the unedited photo shows.
    static func interimImage(after handoff: SavedEditHandoff, jpgParameters: EditParameters?,
                             current: SavedEditRender?) -> NSImage? {
        let winner: SavedEditKey?
        if let jpg = jpgParameters, !jpg.isDefault {
            winner = SavedEditKey(isRAW: false, parameters: jpg)
        } else if handoff.saved.isRAW {
            // No JPG edit: the RAW edit shows, if there is one.
            winner = handoff.saved.parameters.isDefault ? nil : handoff.saved
        } else if let current, current.key.isRAW {
            // A JPG session doesn't change the RAW edit, so a RAW render already on screen is still right.
            winner = current.key
        } else {
            winner = nil
        }
        guard let winner else { return nil }
        if let current, current.key == winner { return current.image }
        return handoff.saved == winner ? handoff.image : nil
    }
}

/// The detail view's saved edit for the photo it shows.
/// - It is rendered to fill the viewport at fit (`SavedEdit.render(for:fitting:reusing:)`), not at native
///   resolution: for a 16 MP RAW, a quarter to a third of the bytes.
/// - `needsMorePixels` renders it natively once the view is zoomed in past that, or larger when the viewport grew.
/// - After an editing session saved this photo, `adopt` resolves it again, reusing the session's render.
/// - `prefetch` renders the next photo's saved edit ahead, so navigating to it shows the edit at once. At fit size a
///   render is small enough to keep one ahead; a RAW's cost is mostly its decode, which a smaller size doesn't cut.
/// Only the latest request may assign `render`: a new photo, a hand-off or an upgrade supersedes older ones.
/// Prefetches outlive navigation (`invalidate`), and are checked against the photo's saved edit when used.
@Observable @MainActor
final class SavedEditState {
    /// The saved edit on screen; nil when the photo has none, or while it is being resolved.
    private(set) var render: SavedEditRender?
    /// The session hand-off `render` already reflects.
    private(set) var adoptedHandoffID: UUID?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var adoptTask: Task<Void, Never>?
    /// Saved-edit renders started ahead (`prefetch`), by photo. `resolve` takes its photo's.
    @ObservationIgnored private var prefetched: [UUID: Task<SavedEditRender?, Never>] = [:]
    /// The upgrade in flight and the size it renders (nil: native).
    @ObservationIgnored private var upgrade: (task: Task<Void, Never>, target: CGSize?)?

    /// A new photo: nothing still in flight may assign `render`.
    func invalidate() {
        generation += 1
        adoptTask?.cancel()
        upgrade?.task.cancel()
        upgrade = nil
    }

    /// Drops the previous photo's render, once the next photo is on screen.
    func clear() {
        render = nil
    }

    /// Resolves `photo`'s saved edit and renders it to fill `viewport` (device pixels) at fit; nil renders natively.
    /// A prefetched render is used (waiting for it if it is still running) when it still shows the photo's saved
    /// edit with the pixels wanted. `handoff`: a session that just saved this photo, whose render is reused when it
    /// has the pixels.
    func resolve(for photo: PhotoAsset, fitting viewport: CGSize?, reusing handoff: SavedEditHandoff?) async {
        generation += 1
        let generation = self.generation
        upgrade?.task.cancel()
        upgrade = nil
        let ahead = prefetched.removeValue(forKey: photo.id)
        var rendered: SavedEditRender?
        if handoff == nil, let ahead, let candidate = await ahead.value,
           await SavedEdit.isCurrent(candidate, for: photo, fitting: viewport) {
            rendered = candidate
        } else {
            guard !Task.isCancelled, generation == self.generation else { return }
            rendered = await SavedEdit.render(for: photo, fitting: viewport, reusing: handoff)
        }
        guard !Task.isCancelled, generation == self.generation else { return }
        render = rendered
        if let handoff { adoptedHandoffID = handoff.id }
    }

    /// Renders the saved edits of `photos` (the next photos the view may show) ahead, to fill `viewport` at fit.
    /// Photos without a saved edit are skipped. Renders for photos no longer in `photos` are dropped.
    func prefetch(_ photos: [PhotoAsset], fitting viewport: CGSize?) {
        let wanted = Set(photos.map(\.id))
        for (id, task) in prefetched where !wanted.contains(id) {
            task.cancel()
            prefetched[id] = nil
        }
        for photo in photos where prefetched[photo.id] == nil && SavedEdit.mayHaveSavedEdit(photo) {
            prefetched[photo.id] = Task { await SavedEdit.render(for: photo, fitting: viewport) }
        }
    }

    /// Drops every prefetched render (the detail view closed, or an export rewrote a file).
    func discardPrefetches() {
        for task in prefetched.values { task.cancel() }
        prefetched = [:]
    }

    /// The photos with a prefetched saved edit. For tests.
    var prefetchedPhotoIDs: Set<UUID> { Set(prefetched.keys) }

    /// A session just saved `photo`: resolves its saved edit again, reusing the session's render.
    func adopt(_ handoff: SavedEditHandoff, for photo: PhotoAsset, fitting viewport: CGSize?) {
        adoptTask?.cancel()
        adoptTask = Task { await resolve(for: photo, fitting: viewport, reusing: handoff) }
    }

    /// `render` is drawn with more device pixels than it has. Zoomed in: render it natively. At fit (the viewport
    /// grew): render it to fill `viewport` (natively once that needs the photo's full resolution), if the one on
    /// screen doesn't.
    func needsMorePixels(for photo: PhotoAsset, zoomedIn: Bool, fitting viewport: CGSize?) {
        guard let current = render, let fitted = current.fittedMaxSize else { return }   // native already
        let target: CGSize?
        if zoomedIn {
            target = nil
        } else {
            guard let viewport, let source = current.sourceSize else { return }
            // Nil: the viewport needs the photo's full resolution.
            let wanted = EditRenderSize.fitMaxSize(native: source, parameters: current.key.parameters, viewport: viewport)
            guard !EditRenderSize.covers(fitted, wanted) else { return }
            target = wanted == nil ? nil : viewport
        }
        if let upgrade, upgrade.target == target { return }
        generation += 1
        let generation = self.generation
        upgrade?.task.cancel()
        let task = Task { [weak self] in
            let rendered = await SavedEdit.render(for: photo, fitting: target)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.upgrade = nil
            if let rendered { self.render = rendered }
        }
        upgrade = (task, target)
    }
}
