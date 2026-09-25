import AppKit
import SwiftData

/// The state and behaviour of editing one photo, JPG or RAW. It exists only while editing: the view model creates
/// one in `startEditing` and drops it in `stopEditing`, so nothing needs resetting between sessions.
///
/// Rendering:
/// - Setting `parameters` schedules a preview render (30 ms debounce, fit to 1600×1100, on the `.preview` lane).
/// - 300 ms after the preview lands, the pass (`fullImage`) follows on the `.full` lane. It is sized to fill
///   `viewportPixelSize` at fit when the caller gave one, and native otherwise, or once `requestNativeResolution()`
///   asked for it (the detail view does when it is zoomed in past the pass).
/// - A newer change supersedes all of them: each render belongs to a generation, and only the current generation's
///   result is kept.
/// Every render is `ImageEditingService`'s output for its size: a fitted pass passes `maxSize`, a native one doesn't.
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
    /// The current parameters after the pause: fitted to `viewportPixelSize`, or at native resolution (see
    /// `fullImageIsNative`). Nil until the pass has finished, and after every change.
    private(set) var fullImage: NSImage?

    /// Device pixels the photo is fitted into on screen; the detail view sets it. Nil (a caller without a view, such
    /// as a test or a benchmark): every pass renders at native resolution, as before viewport-sized passes. A larger
    /// value re-renders a fitted pass that no longer fills it.
    @ObservationIgnored var viewportPixelSize: CGSize? {
        didSet {
            if viewportPixelSize != oldValue { refitIfShort() }
        }
    }
    /// Whether `fullImage` is at native resolution; false when it is fitted to the viewport. Set with `fullImage`.
    @ObservationIgnored private(set) var fullImageIsNative = false
    /// `fullImage`'s size at native resolution (crop and rotation applied), for the view's 1:1 zoom. Set with
    /// `fullImage`; nil when unknown.
    @ObservationIgnored private(set) var fullImageNativePixelSize: CGSize?
    /// The `maxSize` a fitted `fullImage` was rendered with.
    @ObservationIgnored private var fullImageMaxSize: CGSize?

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
    /// The source's pixel size after orientation, read from its header once.
    @ObservationIgnored private var nativeSize: CGSize?
    /// Where the current generation's pass is: waiting for the preview and the pause, rendering, or finished.
    @ObservationIgnored private var passPhase = PassPhase.waiting
    /// Whether the current generation's pass renders at native resolution.
    @ObservationIgnored private var passIsNative = false
    /// `requestNativeResolution()` was called for the current generation.
    @ObservationIgnored private var nativeRequested = false
    @ObservationIgnored private var nativeTask: Task<Void, Never>?

    private enum PassPhase { case waiting, rendering, finished }
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
        // The header read (for the pass's size) runs beside the cache warm-up.
        async let native = EditRenderSize.loadNativeSize(ofImageAt: url)
        if isRAW {
            await service.prepareRAW(url: url)
        } else {
            await service.prepareStandard(url: url)
        }
        let size = await native
        if nativeSize == nil { nativeSize = size }
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
        nativeTask?.cancel()
        comparisonTask?.cancel()
        previewImage = nil
        setFullImage(nil)
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
            isFullResolution: full != nil && fullImageIsNative,
            fittedMaxSize: full != nil && !fullImageIsNative ? fullImageMaxSize : nil,
            sourceSize: nativeSize)
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

    /// Renders a preview of the current parameters after the debounce, then the pass.
    private func scheduleRender() {
        guard !hasEnded else { return }
        previewTask?.cancel()
        fullTask?.cancel()
        nativeTask?.cancel()
        setFullImage(nil)
        generation += 1
        passPhase = .waiting
        nativeRequested = false
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

    /// The pass, after the pause: fitted to the viewport; native when there is no viewport, when the viewport needs
    /// the photo's full resolution, or when `requestNativeResolution()` came first.
    private func scheduleFullRender(url: URL, params: EditParameters, generation: Int) {
        fullTask?.cancel()
        let isRAW = self.isRAW
        let service = self.service
        fullTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fullPassDelay)
            guard !Task.isCancelled, let pass = await self?.startPass(params: params, generation: generation),
                  !Task.isCancelled else { return }

            let result = await Self.render(service, isRAW: isRAW, url: url, parameters: params, maxSize: pass.maxSize)

            self?.finishPass(result, pass, generation: generation)
        }
    }

    private struct Pass {
        /// Nil: native.
        let maxSize: CGSize?
        let nativePixelSize: CGSize?
    }

    /// Decides the pass's size; nil when the pass is stale.
    private func startPass(params: EditParameters, generation: Int) async -> Pass? {
        guard !hasEnded, self.generation == generation else { return nil }
        let native = await sourceNativeSize()
        guard !hasEnded, self.generation == generation else { return nil }
        var maxSize: CGSize?
        if !nativeRequested, let viewport = viewportPixelSize, let native {
            maxSize = EditRenderSize.fitMaxSize(native: native, parameters: params, viewport: viewport)
        }
        passPhase = .rendering
        passIsNative = maxSize == nil
        return Pass(maxSize: maxSize,
                    nativePixelSize: native.map { EditRenderSize.outputSize(native: $0, parameters: params) })
    }

    private func finishPass(_ result: NSImage?, _ pass: Pass, generation: Int) {
        guard !hasEnded, self.generation == generation else { return }
        passPhase = .finished
        // A native render asked for while this fitted pass ran may have landed first; it stays.
        if pass.maxSize != nil, fullImageIsNative { return }
        setFullImage(result, maxSize: pass.maxSize, nativePixelSize: pass.nativePixelSize)
        if pass.maxSize != nil { refitIfShort() }
    }

    /// Asks for the current parameters at native resolution: the detail view is zoomed in past the fitted pass.
    /// Before the pass has started, the pass itself renders natively; after that, a native render follows at once.
    /// It holds until the parameters change (the detail view asks again while it stays zoomed in).
    func requestNativeResolution() {
        guard !hasEnded, !nativeRequested else { return }
        nativeRequested = true
        guard passPhase != .waiting, !passIsNative, !fullImageIsNative, let url = sourceURL else { return }
        let generation = self.generation
        let params = parameters
        let isRAW = self.isRAW
        let service = self.service
        nativeTask?.cancel()
        nativeTask = Task { [weak self] in
            let native = await self?.sourceNativeSize()
            let result = await Self.render(service, isRAW: isRAW, url: url, parameters: params, maxSize: nil)
            guard let self, !self.hasEnded, self.generation == generation, let result else { return }
            self.setFullImage(result, maxSize: nil,
                              nativePixelSize: native.map { EditRenderSize.outputSize(native: $0, parameters: params) })
        }
    }

    /// The viewport grew past the fitted pass on screen (or while it rendered): render a larger one after the usual
    /// pause, so a live resize renders once it stops.
    private func refitIfShort() {
        guard !hasEnded, passPhase == .finished, fullImage != nil, !fullImageIsNative,
              let viewport = viewportPixelSize, let native = nativeSize, let url = sourceURL else { return }
        let wanted = EditRenderSize.fitMaxSize(native: native, parameters: parameters, viewport: viewport)
        guard !EditRenderSize.covers(fullImageMaxSize, wanted) else { return }
        passPhase = .waiting
        scheduleFullRender(url: url, params: parameters, generation: generation)
    }

    private func setFullImage(_ image: NSImage?, maxSize: CGSize? = nil, nativePixelSize: CGSize? = nil) {
        fullImageIsNative = image != nil && maxSize == nil
        fullImageMaxSize = image != nil ? maxSize : nil
        fullImageNativePixelSize = image != nil ? nativePixelSize : nil
        fullImage = image
    }

    private static func render(_ service: ImageEditingService, isRAW: Bool, url: URL, parameters: EditParameters,
                               maxSize: CGSize?) async -> NSImage? {
        if isRAW {
            await service.processRAW(url: url, parameters: parameters, maxSize: maxSize, lane: .full)
        } else {
            await service.processStandard(url: url, parameters: parameters, maxSize: maxSize, lane: .full)
        }
    }

    /// The source's oriented pixel size, read from its header (off the main thread) the first time.
    private func sourceNativeSize() async -> CGSize? {
        if let nativeSize { return nativeSize }
        guard let url = sourceURL else { return nil }
        let size = await EditRenderSize.loadNativeSize(ofImageAt: url)
        if nativeSize == nil { nativeSize = size }
        return size
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

    /// The paired JPG with its saved edits rendered (to fill its half of the comparison when the viewport is known),
    /// or else its decode (hardware path, subsample 2, which covers half the window; a cached full-resolution decode
    /// is reused), oriented at display time.
    private func loadJPGComparisonImage() {
        guard let jpgPath = photo.jpgPath else { return }
        let savedJPG = photo.jpgEditParameters.flatMap { $0.isDefault ? nil : $0 }
        let service = self.service
        let half = viewportPixelSize.map { CGSize(width: $0.width / 2, height: $0.height) }
        comparisonTask = Task { [weak self] in
            let image: DisplayImage?
            if let savedJPG {
                let url = URL(fileURLWithPath: jpgPath)
                var maxSize: CGSize?
                if let half, let native = await EditRenderSize.loadNativeSize(ofImageAt: url) {
                    maxSize = EditRenderSize.fitMaxSize(native: native, parameters: savedJPG, viewport: half)
                }
                let rendered = await service.processStandard(url: url, parameters: savedJPG, maxSize: maxSize, lane: .full)
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
    /// `<stem>-raw-edit.jpg`, which becomes the photo's JPG. The JPEG carries the original metadata
    /// (`metadataSources(forRAWExportTo:replacing:)`) and then gets the photo's rating and keywords.
    func exportRAWToJPG(replaceExisting: Bool) async -> ExportResult {
        guard let rawPath = photo.rawPath else { return .failed }

        let rawURL = URL(fileURLWithPath: rawPath)
        let params = parameters

        let outputURL: URL
        let replacing = replaceExisting && photo.jpgPath != nil
        if replacing, let jpgPath = photo.jpgPath {
            outputURL = URL(fileURLWithPath: jpgPath)
        } else {
            let dir = rawURL.deletingLastPathComponent()
            let stem = rawURL.deletingPathExtension().lastPathComponent
            outputURL = dir.appendingPathComponent("\(stem)-raw-edit.jpg")
        }

        let result = await service.exportRAWToJPEG(
            rawURL: rawURL, parameters: params, outputURL: outputURL,
            metadataSources: metadataSources(forRAWExportTo: outputURL, replacing: replacing))
        if result == .written {
            // Update the photo's jpgPath if a new file was created
            if !replaceExisting || photo.jpgPath == nil {
                photo.jpgPath = outputURL.path
            }
            try? modelContext?.save()
            writeRatingAndKeywords(to: outputURL)
        }
        return result
    }

    /// Where a RAW export takes its metadata from, in order of preference:
    /// - replacing the paired JPG: that JPG, read before it's replaced, and nothing else (it must keep its own);
    /// - a new file: the pair's camera JPG (the photo's JPG unless that is the export itself, as after an earlier
    ///   export, else the JPG beside the RAW with its stem), then the RAW.
    private func metadataSources(forRAWExportTo output: URL, replacing: Bool) -> [URL] {
        guard let rawPath = photo.rawPath else { return [] }
        let raw = URL(fileURLWithPath: rawPath)
        if replacing { return [output] }
        let fm = FileManager.default
        let cameraJPG = photo.jpgPath.map(URL.init(fileURLWithPath:)).flatMap { $0.path == output.path ? nil : $0 }
            ?? ["jpg", "JPG", "jpeg", "JPEG"].lazy
                .map { raw.deletingPathExtension().appendingPathExtension($0) }
                .first { $0.path != output.path && fm.fileExists(atPath: $0.path) }
        return (cameraJPG.map { [$0] } ?? []) + [raw]
    }

    /// Bakes the current parameters into the JPG file, keeping its metadata, and clears its saved edits. Nothing is
    /// written, and the edit stays, if the metadata can't be kept.
    func exportJPGPermanent() async -> ExportResult {
        guard let jpgPath = photo.jpgPath else { return .failed }

        let url = URL(fileURLWithPath: jpgPath)
        let params = parameters

        let result = await service.exportStandardToJPEG(sourceURL: url, parameters: params, outputURL: url)
        guard result == .written else { return result }
        writeRatingAndKeywords(to: url)
        // Clear saved edit parameters since they're baked in
        photo.jpgEditParametersData = nil
        try? modelContext?.save()
        guard !hasEnded else { return result }
        // The file changed under the cached source: render the baked file, not the old pixels. A baked crop also
        // changed its size.
        service.clearCache()
        nativeSize = nil
        previewImage = nil
        setFullImage(nil)
        parameters = EditParameters()
        return result
    }

    /// An export carries the source's metadata; Phocasa's own rating and keywords then go in like any rating write
    /// (into the file, or its sidecar when the file can't take them without losing something). The export itself
    /// never goes through this: it changes pixels, and the writer's thumbnail re-key is for metadata-only rewrites.
    private func writeRatingAndKeywords(to url: URL) {
        MetadataWriter.shared.enqueue([MetadataWriteItem(path: url.path, rating: photo.rating,
                                                         keywords: photo.tags.map(\.fullName))])
    }
}
