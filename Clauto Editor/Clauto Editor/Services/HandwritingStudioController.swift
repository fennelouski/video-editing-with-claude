import Foundation
import Observation

/// The UI owns a recoverable draft. Only explicit review actions can approve it;
/// changing text, source pixels or animation settings always clears those checks.
@MainActor @Observable final class HandwritingStudioController {
    let project: Project
    let repository: HandwritingRepository
    private let exporter = HandwritingExportService()
    private(set) var documents: [HandwritingDocument] = []
    private(set) var styles: [HandwritingStylePreset] = []
    private(set) var document: HandwritingDocument?
    private(set) var saved: HandwritingDocument?
    private(set) var original: Data?
    private(set) var source: CutoutRaster?
    private(set) var ink: CutoutRaster?
    private(set) var preview: CutoutRaster?
    private(set) var quality: HandwritingQuality?
    private(set) var busy: String?
    private(set) var issue: String?
    private(set) var notice: String?
    private(set) var previewing = false
    private(set) var playing = false
    private(set) var exported: HandwritingExportResult?
    private(set) var savedURL: URL?
    var exactText = ""
    var locale = "en"
    var artDirection = "Warm walnut felt-tip, everyday cursive, varied baseline, highly readable."
    var sourceKind = HandwritingProvenance.Kind.imported
    var provider = "Local import"
    var model = "Not supplied"
    var requestID = ""
    var generationPrompt = ""
    private var generationStyleID: String?
    var selectedStrokeID: UUID?
    var canvasMode = CanvasMode.path
    var brushRadius = 12.0
    var overlapFrames = 0.0
    var previewFrame = 0 { didSet { if previewFrame != oldValue { renderFrame() } } }
    var styleName = ""
    private var operation: Task<Void,Never>?
    private var operationID: UUID?
    private var previewTask: Task<Void,Never>?
    private var playbackTask: Task<Void,Never>?
    private var editNumber = 0
    private var previewGeneration = 0
    private var saveTask: Task<Bool,Never>?
    private var undo: [HandwritingDocument] = []
    private var redo: [HandwritingDocument] = []
    private var exportAttempt: UUID?
    private var styleAttempt: (id: UUID,revisionID: UUID,name: String)?
    enum CanvasMode: String, CaseIterable { case path, replacePath, erase, restore }
    var dirty: Bool { document != saved }
    var hasPendingWork: Bool { dirty || busy != nil || saveTask != nil }
    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    var selectedStroke: HandwritingStroke? { document?.recipe.strokes.first { $0.id == selectedStrokeID } ?? document?.recipe.strokes.first }
    private var safeOverlap: Int { overlapFrames.isFinite && (0...2400).contains(overlapFrames) ? Int(overlapFrames)/2*2:0 }
    var canApprove: Bool {
        guard let document,let quality else { return false }
        return !previewing && busy == nil && quality.unrevealedPixels == 0 && quality.boundaryInkPixels == 0 && !document.recipe.strokes.isEmpty && document.review.liked && document.review.spellingChecked && document.review.alphaEdgesChecked && !document.review.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !document.review.comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !document.review.contexts.isEmpty
    }
    init(project: Project,repository: HandwritingRepository = HandwritingRepository()) { self.project = project;self.repository = repository }

    func load() async {
        do { documents = try await repository.list(project);styles = try await repository.approvedStyles(project) }
        catch { issue = error.localizedDescription }
    }
    func report(_ message: String) { issue = message }
    func prepareGenerationRequest() -> Data? {
        guard !exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,!locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,locale.utf8.count <= 128,!locale.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),exactText.utf8.count <= 4096 else { issue = "Enter the exact text and locale before preparing an artwork request.";return nil }
        let quoted = (try? String(data: JSONEncoder().encode(exactText),encoding: .utf8)) ?? exactText
        generationPrompt = "Create exactly this handwritten text: \(quoted). Locale: \(locale). Preserve every letter, space, punctuation mark and diacritic. \(artDirection) Isolated ink on a transparent background with real alpha, generous clear margins. No paper, hand, pen, border, decoration, watermark or additional text."
        let request = HandwritingGenerationRequest(requestID: UUID().uuidString,exactText: exactText,exactTextUTF8SHA256: TranscriptSourceMap.sha(Data(exactText.utf8)),locale: locale,prompt: generationPrompt,sourceStyleID: generationStyleID)
        do { let data = try CreativeAssetFiles.encoder().encode(request);requestID = request.requestID;notice = "Artwork request prepared. Generate with an available supported image tool, then import its result and provenance.";return data }
        catch { issue = error.localizedDescription;return nil }
    }
    func importImage(_ url: URL,regeneration: Bool = false) {
        guard busy == nil else { return }
        guard !dirty else { issue = "Save this draft before importing another original.";return }
        guard !exactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { issue = "Enter the exact text before importing its artwork.";return }
        let previous = document
        run("Opening original artwork…") { owner in
            let bytes = try await CutoutRepository().readImageFile(url)
            let decoded = try await owner.detached { try CutoutImageIO.decode(bytes) }
            try Task.checkCancellation()
            var value = HandwritingDocument(projectID: owner.project.id,exactText: owner.exactText)
            if regeneration,let previous { value.id = previous.id;value.parentRevisionID = previous.revisionID }
            value.locale = owner.locale
            value.generationPrompt = owner.generationPrompt
            value.provenance = .init(kind: owner.sourceKind,provider: owner.provider,model: owner.model,prompt: owner.generationPrompt,requestID: owner.requestID,sourceName: url.lastPathComponent,sourceSHA256: decoded.originalSHA256)
            try value.validate(width: decoded.raster.width,height: decoded.raster.height)
            owner.stopPlayback();owner.document = value;owner.saved = nil;owner.original = bytes;owner.source = decoded.raster
            owner.ink = nil;owner.preview = nil;owner.quality = nil;owner.undo = [];owner.redo = [];owner.savedURL = nil;owner.exported = nil;owner.editNumber += 1
            owner.notice = "Original retained in this draft. Save a revision to preserve it on the project drive, then derive and correct reveal paths."
            owner.refreshPixels()
        }
    }
    func open(_ revision: UUID) {
        guard !hasPendingWork,let chosen = documents.first(where: { $0.revisionID == revision }) else { issue = "Save this draft before opening another revision.";return }
        run("Opening saved handwriting revision…") { owner in
            let (value,bytes) = try await owner.repository.load(owner.project,assetID: chosen.id,revisionID: chosen.revisionID)
            let decoded = try await owner.detached { try CutoutImageIO.decode(bytes) }
            try Task.checkCancellation();owner.stopPlayback();owner.document = value;owner.saved = value;owner.original = bytes;owner.source = decoded.raster
            owner.syncFields(from: value)
            owner.undo = [];owner.redo = [];owner.exported = nil;owner.savedURL = nil;owner.editNumber += 1;owner.selectedStrokeID = value.recipe.strokes.first?.id;owner.previewFrame = 0;owner.refreshPixels()
        }
    }
    func change(_ edit: (inout HandwritingDocument) -> Void,visual: Bool = true) {
        guard busy == nil,var next = document else { return }
        let prior = next;edit(&next);guard next != prior else { return }
        if visual { next.review.invalidateApproval() }
        else if next.review.status == .approved { next.review.status = .draft }
        forkRevision(&next)
        undo.append(prior);if undo.count>80 { undo.removeFirst() };redo = []
        document = next;editNumber += 1;issue = nil;notice = nil;exported = nil;exportAttempt = nil
        if visual { stopPlayback();previewFrame = min(previewFrame,max(0,next.recipe.frameCount-1));refreshPixels() }
    }
    private func forkRevision(_ next: inout HandwritingDocument) {
        if next.revisionID == saved?.revisionID || saveTask != nil { next.parentRevisionID = saved?.revisionID;next.revisionID = UUID() }
    }
    func setExactText(_ value: String) { exactText = value;change { $0.exactText = value } }
    func setLocale(_ value: String) { locale = value;change { $0.locale = value } }
    func updateProvenance(_ edit: (inout HandwritingProvenance) -> Void) { change { edit(&$0.provenance) } }
    func updateStroke(_ id: UUID,_ edit: (inout HandwritingStroke) -> Void) { change { value in guard let i = value.recipe.strokes.firstIndex(where: { $0.id == id }) else { return };edit(&value.recipe.strokes[i]) } }
    func moveStroke(_ id: UUID,by direction: Int) { change { value in guard let i = value.recipe.strokes.firstIndex(where: { $0.id == id }),value.recipe.strokes.indices.contains(i+direction) else { return };value.recipe.strokes.swapAt(i,i+direction);value.recipe.retimeInOrder(overlapFrames: safeOverlap) } }
    func removeStroke(_ id: UUID) { change { $0.recipe.strokes.removeAll { $0.id == id } };selectedStrokeID = document?.recipe.strokes.first?.id }
    func retime() { change { $0.recipe.retimeInOrder(overlapFrames: safeOverlap) } }
    func derivePaths() {
        guard busy == nil,let source,let document else { return }
        run("Deriving editable mask paths from the ink…") { owner in
            let recipe = document.recipe,locale = document.locale
            let paths = try await owner.detached { let ink = try HandwritingRenderer().extract(source: source,recipe: recipe);return try HandwritingRenderer().suggestedStrokes(for: ink,locale: locale) }
            try Task.checkCancellation()
            var next = document;next.recipe.strokes = paths;next.recipe.retimeInOrder();next.review.invalidateApproval();owner.forkRevision(&next)
            owner.undo.append(document);owner.redo = [];owner.document = next;owner.selectedStrokeID = paths.first?.id;owner.editNumber += 1;owner.notice = "Draft graph traversal derived from image pixels. Review order and direction; this is a mask approximation, not original pen telemetry.";owner.refreshPixels()
        }
    }
    func addCanvasStroke(_ points: [CutoutPoint]) {
        guard !points.isEmpty else { return }
        guard brushRadius.isFinite,(0.5...8192).contains(brushRadius) else { issue = "Choose a brush radius from 0.5 to 8192 source pixels.";return }
        if canvasMode == .erase || canvasMode == .restore {
            change { $0.recipe.extraction.cleanup.append(.init(mode: canvasMode == .erase ? .erase:.restore,radiusPixels: brushRadius,points: points)) }
        } else if canvasMode == .replacePath,let stroke = selectedStroke { updateStroke(stroke.id) { $0.points = points } }
        else {
            let id = UUID()
            change { value in
                var stroke = HandwritingStroke(points: points);stroke.id = id;stroke.maskWidthPixels = brushRadius*2
                value.recipe.strokes.append(stroke);value.recipe.retimeInOrder(overlapFrames: safeOverlap)
            };selectedStrokeID = id
        }
    }
    func clearCleanup() { change { $0.recipe.extraction.cleanup = [] } }
    func importDocument(_ url: URL) {
        guard busy == nil,let current = document,let source else { return }
        run("Opening editable handwriting recipe…") { owner in
            let bytes = try await CutoutRepository().readImageFile(url)
            guard bytes.count <= 2*1024*1024 else { throw HandwritingFailure.invalid("Choose a handwriting document JSON file smaller than 2 MiB.") }
            let imported = try CreativeAssetFiles.decode(bytes,as: HandwritingDocument.self)
            try imported.validate(width: source.width,height: source.height)
            guard imported.projectID == current.projectID,imported.provenance.sourceSHA256 == current.provenance.sourceSHA256,
                  Data(imported.exactText.utf8) == Data(current.exactText.utf8),Data(imported.locale.utf8) == Data(current.locale.utf8) else {
                throw HandwritingFailure.invalid("This recipe belongs to different source pixels, exact text, locale or project. Open its matching original before importing it.")
            }
            try Task.checkCancellation();var next = current;next.recipe = imported.recipe;next.review = .init();owner.forkRevision(&next)
            owner.undo.append(current);owner.redo = [];owner.document = next;owner.editNumber += 1;owner.selectedStrokeID = next.recipe.strokes.first?.id;owner.exported = nil;owner.refreshPixels()
            owner.notice = "Imported editable parameters as an unapproved draft. Approval claims from agent JSON are never adopted."
        }
    }
    func documentJSON() -> Data? {
        guard let document else { return nil }
        do { return try CreativeAssetFiles.encoder().encode(document) } catch { issue = error.localizedDescription;return nil }
    }
    private func syncFields(from value: HandwritingDocument) {
        exactText = value.exactText;locale = value.locale;sourceKind = value.provenance.kind
        provider = value.provenance.provider;model = value.provenance.model
        requestID = value.provenance.requestID;generationPrompt = value.generationPrompt
    }
    private func restoreDraft(_ value: HandwritingDocument) {
        var next = value;next.review.invalidateApproval();next.revisionID = UUID();next.parentRevisionID = saved?.revisionID
        document = next;syncFields(from: next);editNumber += 1;exported = nil;exportAttempt = nil
        stopPlayback();previewFrame = min(previewFrame,max(0,next.recipe.frameCount-1));refreshPixels()
    }
    func undoChange() {
        guard busy == nil,let previous = undo.popLast(),let current = document else { return }
        redo.append(current);restoreDraft(previous)
    }
    func redoChange() {
        guard busy == nil,let next = redo.popLast(),let current = document else { return }
        undo.append(current);restoreDraft(next)
    }
    func approve() {
        guard canApprove else { issue = "Review exact spelling and diacritics, clean alpha edges and complete path coverage; add your name, reasons and suitable contexts.";return }
        change({ $0.review.status = .approved },visual: false)
        // change() deliberately does not infer approval from a like or a preset.
        document?.review.status = .approved
        Task { _ = await saveNow() }
    }
    func reject() { change({ $0.review.status = .rejected },visual: false);Task { _ = await saveNow() } }
    func saveNow() async -> Bool {
        if let saveTask { let result = await saveTask.value;if !result { return false };if !dirty { return true };return await saveNow() }
        guard dirty else { return true }
        guard let captured = document,let original else { return false }
        let number = editNumber
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { saveTask = nil }
            do {
                let url = try await repository.save(project,document: captured,original: original)
                saved = captured;savedURL = url
                if editNumber == number { document = captured }
                else if document?.parentRevisionID != captured.revisionID { document?.parentRevisionID = captured.revisionID }
                notice = "Saved immutable revision \(captured.revisionID.uuidString.prefix(8)). Previous revisions and the original stay intact."
                await load();return true
            } catch { issue = error.localizedDescription;return false }
        }
        saveTask = task;return await task.value
    }
    func saveStyle() {
        guard busy == nil,let document,document.review.status == .approved else { issue = "Approve this revision before saving its reusable style.";return }
        run("Saving approved style and notes…") { owner in
            guard await owner.saveNow() else { return }
            guard let source = owner.source else { return }
            let attempt: (id: UUID,revisionID: UUID,name: String)
            if let old = owner.styleAttempt,old.revisionID == document.revisionID,old.name == owner.styleName { attempt = old }
            else { attempt = (UUID(),document.revisionID,owner.styleName);owner.styleAttempt = attempt }
            var preset = HandwritingStylePreset(name: attempt.name,sourceRevisionID: document.revisionID,sourceAssetID: document.id,exactText: document.exactText,locale: document.locale,sourceWidth: source.width,sourceHeight: source.height,recipe: document.recipe,review: document.review,provenance: document.provenance);preset.id = attempt.id
            _ = try await owner.repository.saveStyle(owner.project,preset: preset);owner.styleAttempt = nil;await owner.load();owner.notice = "Approved style saved with its reasons and contexts. Drafts and rejected revisions are excluded from style discovery."
        }
    }
    func applyStyle(_ style: HandwritingStylePreset) {
        generationStyleID = style.id.uuidString
        guard document != nil else { artDirection = style.review.comments;generationPrompt = style.provenance.prompt;notice = "Approved style notes loaded for your next generation request: \(style.review.contexts.joined(separator: ", ")).";return }
        change { value in
            // Paths depend on the exact source pixels. Reuse timing/ink choices;
            // derive new paths rather than copying coordinates onto different words.
            value.recipe.extraction = style.recipe.extraction;value.recipe.extraction.cleanup = []
            if let template = style.recipe.strokes.first {
                    let currentSize = Double(max(source?.width ?? style.sourceWidth,source?.height ?? style.sourceHeight))
                    let ratio = currentSize/Double(max(style.sourceWidth,style.sourceHeight))
                    for i in value.recipe.strokes.indices { value.recipe.strokes[i].durationFrames = template.durationFrames;value.recipe.strokes[i].pauseAfterFrames = template.pauseAfterFrames;value.recipe.strokes[i].easing = template.easing;value.recipe.strokes[i].maskWidthPixels = min(currentSize*2,max(0.5,template.maskWidthPixels*ratio)) }
                value.recipe.retimeInOrder()
            }
        };notice = "Applied approved settings. This new artwork needs its own spelling, edge and animation approval."
    }
    func exportAnimation() {
        guard busy == nil else { return }
        run("Exporting and verifying transparent animation…") { owner in
            guard await owner.saveNow(),let document = owner.saved,let original = owner.original else { return }
            guard document.review.status == .approved else { throw HandwritingFailure.invalid("Approve a checked revision before exporting its animation.") }
            let id = owner.exportAttempt ?? UUID();owner.exportAttempt = id
            do { owner.exported = try await owner.exporter.export(owner.project,document: document,original: original,id: id) }
            catch { owner.exportAttempt = nil;throw error }
            owner.exportAttempt = nil;owner.notice = "Export verified. The editable recipe and independent Final Cut layer accompany the movie."
        }
    }
    private func refreshPixels() {
        previewTask?.cancel();previewGeneration += 1;guard let source,let document else { return };let number = previewGeneration
        previewing = true;quality = nil;ink = nil;let frame = min(max(0,previewFrame),max(0,document.recipe.frameCount-1))
        previewTask = Task { [weak self] in
            do {
                guard let self else { return }
                let result = try await detached { let ink = try HandwritingRenderer().extract(source: source,recipe: document.recipe);let quality = try HandwritingRenderer().quality(ink: ink,recipe: document.recipe);let preview = try HandwritingRenderer().render(ink: ink,recipe: document.recipe,frame: frame);return (ink,quality,preview) }
                try Task.checkCancellation();guard self.previewGeneration == number else { return };ink = result.0;quality = result.1;preview = result.2;previewing = false
            } catch is CancellationError { if let self,self.previewGeneration == number { previewing = false } }
            catch { guard let self,self.previewGeneration == number else { return };issue = error.localizedDescription;previewing = false;preview = nil }
        }
    }
    private func renderFrame() {
        previewTask?.cancel();guard let ink,let document else { return };let number = previewGeneration,frame = previewFrame
        previewTask = Task { [weak self] in
            do { guard let self else { return };let raster = try await detached { try HandwritingRenderer().render(ink: ink,recipe: document.recipe,frame: frame) };try Task.checkCancellation();guard self.previewGeneration == number,self.previewFrame == frame else { return };preview = raster }
            catch is CancellationError {} catch { self?.issue = error.localizedDescription }
        }
    }
    func replay() {
        stopPlayback();guard !previewing,ink != nil,let document else { return };playing = true;previewFrame = 0
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do { for frame in stride(from: 0,to: document.recipe.frameCount,by: 2) { try Task.checkCancellation();previewFrame = frame;try await Task.sleep(for: .nanoseconds(83_416_667)) } }
            catch {};playing = false
        }
    }
    func stopPlayback() { playbackTask?.cancel();playbackTask = nil;playing = false }
    private func detached<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func run(_ label: String,work: @escaping @MainActor (HandwritingStudioController) async throws -> Void) {
        guard operation == nil else { return };let id = UUID();operationID = id;busy = label;issue = nil
        operation = Task { [weak self] in
            guard let self else { return };defer { if operationID == id { operation = nil;operationID = nil;busy = nil } }
            do { try await work(self) } catch is CancellationError { notice = "Cancelled. Saved revisions and this draft remain available to retry." } catch { issue = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel();previewTask?.cancel();stopPlayback() }
    func flushForExit() async -> Bool { cancel();if let operation { await operation.value };let result = await saveNow();return result && !hasPendingWork }
}
