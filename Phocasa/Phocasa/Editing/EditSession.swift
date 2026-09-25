import AppKit
import SwiftData

/// The state and behaviour of editing one photo, JPG or RAW. It exists only while editing: the view model creates
/// one in `startEditing` and drops it in `stopEditing`, so nothing needs resetting between sessions.
///
/// Rendering: setting `parameters` schedules a preview render (30 ms debounce, fit to 1600×1100, on the `.preview`
/// lane). Once the preview lands, a full-resolution render follows 300 ms later on the `.full` lane. A newer change
/// supersedes both: each render belongs to a generation, and only the current generation's result is kept.
@Observable @MainActor
final class EditSession {
    let photo: PhotoAsset
    let isRAW: Bool

    /// Setting it schedules a preview render (when the value changes).
    var parameters: EditParameters {
        didSet {
            if parameters != oldValue { scheduleRender() }
        }
    }

    /// The current parameters rendered to fit `previewSize`, or nil before the first render.
    private(set) var previewImage: NSImage?
    /// The current parameters at full resolution, or nil until the full pass has finished.
    private(set) var fullImage: NSImage?

    var showOriginal = false
    /// Turning it on turns the JPG comparison off.
    var showSideBySide = false {
        didSet {
            if showSideBySide {
                showJPGComparison = false
                jpgComparisonImage = nil
                comparisonTask?.cancel()
            }
        }
    }
    private(set) var showJPGComparison = false
    /// The paired JPG for the JPG comparison, oriented at display time.
    private(set) var jpgComparisonImage: DisplayImage?
    var isCropping = false
    var cropRect: NormalizedRect = .full
    var showExportOptions = false

    var canExport: Bool {
        isRAW ? photo.rawPath != nil : photo.jpgPath != nil
    }

    /// Whether "Copy from JPG" is available: editing RAW, and the paired JPG has saved edits.
    var canCopyFromJPG: Bool {
        isRAW && photo.jpgEditParameters != nil
    }

    /// Previews fit inside this size.
    static let previewSize = CGSize(width: 1600, height: 1100)
    static let previewDebounce: Duration = .milliseconds(30)
    static let fullPassDelay: Duration = .milliseconds(300)

    @ObservationIgnored private let modelContext: ModelContext?
    @ObservationIgnored private let service = ImageEditingService.shared
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var fullTask: Task<Void, Never>?
    @ObservationIgnored private var comparisonTask: Task<Void, Never>?
    @ObservationIgnored private var beginTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The parameters `previewImage` shows.
    @ObservationIgnored private var previewParameters: EditParameters?
    @ObservationIgnored private(set) var hasEnded = false

    /// Starts from the saved parameters: the photo's JPG edit, or the RAW sidecar's (a save still waiting for the
    /// writer included). The sidecar read is synchronous, as before: it's a small file, and reading it here means the
    /// sliders never show placeholder values that a quick save could then write over the saved edit.
    init(photo: PhotoAsset, isRAW: Bool, modelContext: ModelContext?) {
        self.photo = photo
        self.isRAW = isRAW
        self.modelContext = modelContext
        if isRAW {
            parameters = photo.rawPath.flatMap { RAWEditStore.shared.parameters(forRAWAt: $0) } ?? EditParameters()
        } else {
            parameters = photo.jpgEditParameters ?? EditParameters()
        }
    }

    private var sourceURL: URL? {
        (isRAW ? photo.rawPath : photo.jpgPath).map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Lifecycle

    /// Warms the render caches so the first slider move is instant, then renders the first preview. Runs once; later
    /// calls wait for that run.
    func begin() async {
        if let beginTask {
            await beginTask.value
            return
        }
        let task = Task { await performBegin() }
        beginTask = task
        await task.value
    }

    private func performBegin() async {
        guard !hasEnded, let url = sourceURL else { return }
        if isRAW {
            await service.prepareRAW(url: url)
        } else {
            await service.prepareStandard(url: url)
        }
        guard !hasEnded else { return }
        scheduleRender()
    }

    /// Cancels pending renders and clears the editing service's caches. With `save`, saves first and returns what
    /// was saved, with the session's latest render, for the detail view to show.
    @discardableResult
    func end(save: Bool) -> SavedEditHandoff? {
        guard !hasEnded else { return nil }
        var handoff: SavedEditHandoff?
        if save {
            self.save()
            handoff = makeHandoff()
        }
        hasEnded = true
        generation += 1
        previewTask?.cancel()
        fullTask?.cancel()
        comparisonTask?.cancel()
        previewImage = nil
        fullImage = nil
        jpgComparisonImage = nil
        service.clearCache()
        return handoff
    }

    private func makeHandoff() -> SavedEditHandoff {
        let full = fullImage
        return SavedEditHandoff(
            photoID: photo.id,
            saved: SavedEditKey(isRAW: isRAW, parameters: parameters),
            image: full ?? previewImage,
            imageParameters: full != nil ? parameters : previewParameters,
            isFullResolution: full != nil)
    }

    // MARK: - Saving

    /// JPG edits go into the model. RAW edits go to the sidecar through `MetadataWriter` (off the main thread,
    /// ordered with rating writes), and `hasRawEdits` is set. Default parameters clear the saved edits.
    func save() {
        if isRAW {
            guard let rawPath = photo.rawPath else { return }
            if parameters.isDefault {
                photo.hasRawEdits = false
                RAWEditStore.shared.save(nil, forRAWAt: rawPath)
            } else {
                RAWEditStore.shared.save(parameters, forRAWAt: rawPath)
                photo.hasRawEdits = true
            }
        } else {
            photo.jpgEditParameters = parameters.isDefault ? nil : parameters
        }
        try? modelContext?.save()
    }

    /// Resets all sliders to zero without saving.
    func resetAllParameters() {
        parameters = EditParameters()
    }

    /// Resets all sliders and clears this kind's saved edits.
    func revert() {
        parameters = EditParameters()
        if isRAW {
            photo.hasRawEdits = false
            if let rawPath = photo.rawPath { RAWEditStore.shared.save(nil, forRAWAt: rawPath) }
        } else {
            photo.jpgEditParametersData = nil
        }
        try? modelContext?.save()
    }

    /// When editing RAW, copies the paired JPG's saved edit parameters.
    func copyJPGSettings() {
        guard isRAW, let jpgParameters = photo.jpgEditParameters else { return }
        parameters = jpgParameters
    }

    func apply(_ preset: EditPreset) {
        parameters = preset.parameters
    }

    // MARK: - Rendering

    /// Renders a preview of the current parameters after the debounce, then the full-resolution pass.
    private func scheduleRender() {
        guard !hasEnded else { return }
        previewTask?.cancel()
        fullTask?.cancel()
        fullImage = nil
        generation += 1
        let generation = self.generation
        let params = parameters
        let isRAW = self.isRAW
        let service = self.service
        guard let url = sourceURL else { return }

        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDebounce)
            guard !Task.isCancelled, self?.generation == generation else { return }

            let result: NSImage?
            if isRAW {
                result = await service.processRAW(url: url, parameters: params, maxSize: Self.previewSize, lane: .preview)
            } else {
                result = await service.processStandard(url: url, parameters: params, maxSize: Self.previewSize, lane: .preview)
            }

            guard let self, self.generation == generation else { return }
            self.previewImage = result
            self.previewParameters = params
            self.scheduleFullRender(url: url, params: params, generation: generation)
        }
    }

    private func scheduleFullRender(url: URL, params: EditParameters, generation: Int) {
        fullTask?.cancel()
        let isRAW = self.isRAW
        let service = self.service
        fullTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fullPassDelay)
            guard !Task.isCancelled, self?.generation == generation else { return }

            let result: NSImage?
            if isRAW {
                result = await service.processRAW(url: url, parameters: params, lane: .full)
            } else {
                result = await service.processStandard(url: url, parameters: params, lane: .full)
            }

            guard let self, self.generation == generation else { return }
            self.fullImage = result
        }
    }

    // MARK: - JPG Comparison

    func toggleJPGComparison() {
        showJPGComparison.toggle()
        comparisonTask?.cancel()
        jpgComparisonImage = nil
        if showJPGComparison {
            showSideBySide = false
            loadJPGComparisonImage()
        }
    }

    /// The paired JPG with its saved edits rendered, or else its decode (hardware path, subsample 2, which covers
    /// half the window; a cached full-resolution decode is reused), oriented at display time.
    private func loadJPGComparisonImage() {
        guard let jpgPath = photo.jpgPath else { return }
        let savedJPG = photo.jpgEditParameters.flatMap { $0.isDefault ? nil : $0 }
        let service = self.service
        comparisonTask = Task { [weak self] in
            let image: DisplayImage?
            if let savedJPG {
                let rendered = await service.processStandard(url: URL(fileURLWithPath: jpgPath), parameters: savedJPG, lane: .full)
                image = rendered.flatMap(DisplayImage.init(nsImage:))
            } else {
                let loader = FullImageLoader.shared
                if let cached = loader.cachedImage(path: jpgPath, subsample: 1) {
                    image = cached
                } else {
                    image = await loader.load(path: jpgPath, subsample: 2)
                }
            }
            guard !Task.isCancelled, let self, !self.hasEnded, self.showJPGComparison else { return }
            self.jpgComparisonImage = image
        }
    }

    // MARK: - Crop

    func enterCropMode() {
        isCropping = true
        cropRect = parameters.cropRect ?? .full
    }

    func applyCrop() {
        parameters.cropRect = cropRect.isApproximatelyFull ? nil : cropRect
        isCropping = false
    }

    func cancelCrop() {
        cropRect = parameters.cropRect ?? .full
        isCropping = false
    }

    // MARK: - Export

    /// Renders the RAW with the current parameters to a JPEG: over the paired JPG (`replaceExisting`), or to a new
    /// `<stem>-raw-edit.jpg`, which becomes the photo's JPG. Returns whether the file was written.
    func exportRAWToJPG(replaceExisting: Bool) async -> Bool {
        guard let rawPath = photo.rawPath else { return false }

        let rawURL = URL(fileURLWithPath: rawPath)
        let params = parameters

        let outputURL: URL
        if replaceExisting, let jpgPath = photo.jpgPath {
            outputURL = URL(fileURLWithPath: jpgPath)
        } else {
            let dir = rawURL.deletingLastPathComponent()
            let stem = rawURL.deletingPathExtension().lastPathComponent
            outputURL = dir.appendingPathComponent("\(stem)-raw-edit.jpg")
        }

        let success = await service.exportRAWToJPEG(rawURL: rawURL, parameters: params, outputURL: outputURL)
        if success {
            // Update the photo's jpgPath if a new file was created
            if !replaceExisting || photo.jpgPath == nil {
                photo.jpgPath = outputURL.path
            }
            try? modelContext?.save()
        }
        return success
    }

    /// Bakes the current parameters into the JPG file and clears its saved edits. Returns whether the file was
    /// written.
    func exportJPGPermanent() async -> Bool {
        guard let jpgPath = photo.jpgPath else { return false }

        let url = URL(fileURLWithPath: jpgPath)
        let params = parameters

        let success = await service.exportStandardToJPEG(sourceURL: url, parameters: params, outputURL: url)
        guard success else { return false }
        // Clear saved edit parameters since they're baked in
        photo.jpgEditParametersData = nil
        try? modelContext?.save()
        guard !hasEnded else { return true }
        // The file changed under the cached source: render the baked file, not the old pixels.
        service.clearCache()
        previewImage = nil
        fullImage = nil
        parameters = EditParameters()
        return true
    }
}
