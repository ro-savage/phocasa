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
    let isFullResolution: Bool

    /// The session's render, if it is a finished full-resolution render of exactly `key`.
    func fullResolutionImage(for key: SavedEditKey) -> NSImage? {
        guard isFullResolution, key == saved, imageParameters == saved.parameters else { return nil }
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

    /// Renders `photo`'s saved edit at full resolution, on the `.full` lane so it never delays edit previews.
    /// - The RAW sidecar is read only when there is no JPG render, and off the main thread.
    /// - `handoff`: a session that just saved this photo. Its full-resolution render is reused when it shows
    ///   exactly the saved edit that wins, instead of rendering it again.
    @MainActor
    static func render(for photo: PhotoAsset, reusing handoff: SavedEditHandoff? = nil) async -> SavedEditRender? {
        let service = ImageEditingService.shared
        var jpg: (() async -> SavedEditRender?)?
        if let params = photo.jpgEditParameters, !params.isDefault, let jpgPath = photo.jpgPath {
            let key = SavedEditKey(isRAW: false, parameters: params)
            jpg = {
                if let image = handoff?.fullResolutionImage(for: key) { return SavedEditRender(key: key, image: image) }
                let image = await service.processStandard(url: URL(fileURLWithPath: jpgPath), parameters: params, lane: .full)
                return image.map { SavedEditRender(key: key, image: $0) }
            }
        }
        var raw: (() async -> SavedEditRender?)?
        if let rawPath = photo.rawPath {
            raw = {
                guard let params = await RAWEditStore.shared.load(forRAWAt: rawPath), !params.isDefault else { return nil }
                let key = SavedEditKey(isRAW: true, parameters: params)
                if let image = handoff?.fullResolutionImage(for: key) { return SavedEditRender(key: key, image: image) }
                let image = await service.processRAW(url: URL(fileURLWithPath: rawPath), parameters: params, lane: .full)
                return image.map { SavedEditRender(key: key, image: $0) }
            }
        }
        return await render(jpg: jpg, raw: raw)
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
