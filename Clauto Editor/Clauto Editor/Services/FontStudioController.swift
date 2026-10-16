import Foundation
import Observation

@MainActor @Observable final class FontStudioController {
    let project: Project
    let engine: URL
    let repository: FontStudioRepository
    let compiler: FontCompilerService
    private(set) var fonts: [FontWorkspaceSummary] = []
    private(set) var saved: FontDraftSnapshot?
    private(set) var draft: FontStudioDraft?
    private(set) var busy: String?
    private(set) var saving = false
    private(set) var issue: String?
    private(set) var exported: FontExportResult?
    private(set) var conflict = false
    var selectedMappingID: UUID?
    var selectedGlyphID: UUID?
    private var editNumber = 0
    private var autosave: Task<Void,Never>?
    private var saveTask: Task<Bool,Never>?
    private var operation: Task<Void,Never>?
    private var undo: [FontStudioDraft] = []
    private var redo: [FontStudioDraft] = []
    private var copyAttempt: (id: UUID,edit: Int)?
    private var compileAttempt: (id: UUID,milliseconds: Int64,token: String)?
    var dirty: Bool { guard let saved,let draft else { return false };return saved.draft != draft }
    var hasPendingWork: Bool { dirty || saving || busy != nil }
    var canUndo: Bool { !undo.isEmpty && busy == nil }
    var canRedo: Bool { !redo.isEmpty && busy == nil }
    init(project: Project,engine: URL,repository: FontStudioRepository = FontStudioRepository(),compiler: FontCompilerService = FontCompilerService()) {
        self.project = project;self.engine = engine;self.repository = repository;self.compiler = compiler
    }
    func load() async { do { fonts = try await repository.list(project) } catch { issue = error.localizedDescription } }
    func create(label: String) {
        guard !hasPendingWork else { issue = "Save this mapping before starting another font.";return }
        let number = editNumber,id = UUID()
        run("Creating font workspace…") { owner in
            let next = try await owner.repository.create(owner.project,id: id,label: label)
            await owner.load();try owner.adopt(next,expected: number)
        }
    }
    func open(_ id: UUID) {
        guard !hasPendingWork else { issue = "Save this mapping before opening another font.";return }
        let number = editNumber
        run("Opening font workspace…") { owner in try owner.adopt(await owner.repository.load(owner.project,id: id),expected: number) }
    }
    private func adopt(_ next: FontDraftSnapshot,expected: Int) throws {
        try Task.checkCancellation()
        guard editNumber == expected else { throw WorkflowFailure.invalid("Your newer outline remains active. Save it before opening the other font.") }
        saved = next;draft = next.draft;undo = [];redo = [];conflict = false;exported = nil;editNumber += 1
        selectedMappingID = next.draft.pendingMappings.first?.id;selectedGlyphID = next.draft.glyphs.first?.id
    }
    func change(_ work: (inout FontStudioDraft) throws -> Void) {
        guard busy == nil else { return };apply(work)
    }
    @discardableResult private func apply(_ work: (inout FontStudioDraft) throws -> Void) -> Bool {
        guard var value = draft else { return false };let previous = value
        do { try work(&value);try value.validate() } catch { issue = error.localizedDescription;return false }
        guard value != previous else { return true }
        undo.append(previous);if undo.count>30 { undo.removeFirst() };redo = [];draft = value;changed();return true
    }
    private func changed() {
        if !(draft?.pendingMappings.contains(where: { $0.id==selectedMappingID }) ?? false) { selectedMappingID = draft?.pendingMappings.first?.id }
        if !(draft?.glyphs.contains(where: { $0.id==selectedGlyphID }) ?? false) { selectedGlyphID = draft?.glyphs.first?.id }
        editNumber += 1;issue = nil;exported = nil;compileAttempt = nil
        autosave?.cancel();autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300));try Task.checkCancellation();_ = await self?.saveNow() } catch {}
        }
    }
    func undoChange() {
        guard busy == nil,let previous = undo.popLast(),let current = draft else { return }
        redo.append(current);var next = previous;next.generation = current.generation;next.currentFontRevisionID = current.currentFontRevisionID;draft = next;changed()
    }
    func redoChange() {
        guard busy == nil,let next = redo.popLast(),let current = draft else { return }
        undo.append(current);var value = next;value.generation = current.generation;value.currentFontRevisionID = current.currentFontRevisionID;draft = value;changed()
    }
    func importSelection(_ selections: [URL]) {
        guard busy == nil,draft != nil,!selections.isEmpty else { return }
        run("Finding glyph images…") { owner in
            let urls = try await FontImageIntake().candidates(in: selections)
            try await owner.addImages(urls)
        }
    }
    func importImages(_ urls: [URL]) {
        guard busy == nil,draft != nil,!urls.isEmpty else { return }
        run("Copying glyph originals to the project drive…") { owner in try await owner.addImages(FontImageIntake().candidates(in: urls)) }
    }
    private func addImages(_ urls: [FontImageCandidate]) async throws {
        guard let font = draft,urls.count<=1024 else { throw WorkflowFailure.invalid("Choose at most 1024 glyph images in one batch.") }
        for candidate in urls {
            try Task.checkCancellation();let url = candidate.url
            let bytes = try await FontImageIntake().read(candidate),hash = TranscriptSourceMap.sha(bytes)
            if draft?.sources.contains(where: { $0.sha256==hash && $0.name==url.lastPathComponent }) == true { continue }
            let source = try await repository.importImage(project,fontID: font.id,id: UUID(),name: url.lastPathComponent,bytes: bytes)
            try Task.checkCancellation()
            let stem = url.deletingPathExtension().lastPathComponent
            let mapping = FontPendingMapping(sourceID: source.id,character: stem.unicodeScalars.count==1 ? stem:"")
            guard apply({ $0.sources.append(source);$0.pendingMappings.append(mapping) }) else { throw WorkflowFailure.invalid(issue ?? "This image could not be added to the mapping.") }
            selectedMappingID = mapping.id
            guard await saveNow() else { return }
        }
    }
    func addMapping(sourceID: UUID) {
        guard busy == nil,draft?.sources.contains(where: { $0.id==sourceID }) == true else { return }
        let mapping = FontPendingMapping(sourceID: sourceID)
        change { $0.pendingMappings.append(mapping) };selectedMappingID = mapping.id
    }
    func removeMapping(_ id: UUID) { change { $0.pendingMappings.removeAll { $0.id==id } };selectedMappingID = draft?.pendingMappings.first?.id }
    func remapGlyph(_ glyph: FontGlyph) {
        guard busy == nil else { return }
        let mapping = FontPendingMapping(sourceID: glyph.sourceID,character: glyph.character,
            crop: glyph.crop?.map { String($0) } ?? ["0","0","1","1"],baseline: String(glyph.baseline ?? 0.8),threshold: String(glyph.inkThreshold ?? 0.55),replaceGlyphID: glyph.id)
        change { $0.pendingMappings.append(mapping) };selectedMappingID = mapping.id
    }
    func updateMapping(_ id: UUID,_ work: (inout FontPendingMapping) -> Void) {
        change { value in guard let index = value.pendingMappings.firstIndex(where: { $0.id==id }) else { return };work(&value.pendingMappings[index]) }
    }
    func setAdvance(glyphID: UUID,advance: Int) {
        change {
            guard let index = $0.glyphs.firstIndex(where: { $0.id==glyphID }) else { return }
            $0.glyphs[index].outline.advance = advance;$0.glyphs[index].outlineSHA256 = try $0.glyphs[index].outline.sha256
            $0.glyphs[index].origin = .editedOutline;$0.glyphs[index].revisionID = UUID()
        }
    }
    func addGeneratedMapping() {
        guard busy == nil else { return }
        let value = FontPendingMapping(sourceID: nil)
        change { $0.pendingMappings.append(value) };selectedMappingID = value.id
    }
    func trace(_ id: UUID) {
        guard busy == nil,let current = draft,let mapping = current.pendingMappings.first(where: { $0.id==id }) else { return }
        run(mapping.sourceID == nil ? "Preparing licensed fallback glyph…":"Tracing the selected image cell…") { owner in
            let code = try mapping.scalar(),target = mapping.replaceGlyphID
            if let existing = owner.draft?.glyphs.first(where: { $0.scalar==code }),existing.id != target { throw WorkflowFailure.invalid("This character already has a glyph. Select Replace Existing Character to make an explicit replacement.") }
            let number = owner.editNumber,files: FontCompilerFiles
            var expectedImage: FontImageMapping?,expectedFallback: (fontSHA256: String,licenseSHA256: String)?
            if let sourceID = mapping.sourceID {
                guard let source = current.sources.first(where: { $0.id==sourceID }) else { throw CutoutFailure.changedSource }
                let request = try mapping.request(source: source),bytes = try await owner.repository.imageBytes(owner.project,fontID: current.id,source: source)
                expectedImage = request
                var inputs = [request.sourceFile:bytes]
                if let rasterFile = request.rasterFile,let raster = try await owner.repository.rasterBytes(owner.project,fontID: current.id,source: source) { inputs[rasterFile] = raster }
                files = try await owner.compiler.execute(action: "trace",request: FontCompilerRequest.data(request),inputs: inputs,project: owner.project,engine: owner.engine)
            } else {
                let fontURL = Bundle.main.url(forResource: "ClautoWorkSans",withExtension: "ttf") ?? owner.engine.appendingPathComponent("Clauto Editor/Clauto Editor/Resources/ClautoWorkSans.ttf")
                let licenseURL = Bundle.main.url(forResource: "WorkSans-OFL",withExtension: "txt") ?? owner.engine.appendingPathComponent("Clauto Editor/Clauto Editor/Resources/WorkSans-OFL.txt")
                let reader = CutoutRepository(),font = try await reader.readImageFile(fontURL),license = try await reader.readImageFile(licenseURL)
                let hashes = try await owner.repository.retainFallback(owner.project,fontID: current.id,font: font,license: license)
                expectedFallback = hashes
                let request = try JSONSerialization.data(withJSONObject: ["schema_version":1,"scalar":code,"font_sha256":hashes.fontSHA256,"license_sha256":hashes.licenseSHA256],options: [.sortedKeys])
                files = try await owner.compiler.execute(action: "fallback",request: request,inputs: ["fallback.ttf":font,"fallback-license.txt":license],project: owner.project,engine: owner.engine)
            }
            try Task.checkCancellation()
            guard owner.editNumber == number,owner.draft?.pendingMappings.first(where: { $0.id==id }) == mapping,let bytes = files.files["glyph.json"] else { throw WorkflowFailure.invalid("The mapping changed during tracing. Its saved input remains available to trace again.") }
            let glyph = try FontGlyph.fromCompiler(bytes,id: target ?? UUID(),sourceID: mapping.sourceID)
            guard glyph.scalar==code else { throw WorkflowFailure.invalid("The tracer returned a different character. Your original mapping remains pending; retry tracing it.") }
            if let expected = expectedImage {
                guard glyph.origin == .suppliedImage,glyph.sourceID==mapping.sourceID,glyph.sourceFile==expected.sourceFile,glyph.sourceSHA256==expected.sourceSHA256,
                      glyph.rasterFile==expected.rasterFile,glyph.rasterSHA256==expected.rasterSHA256,glyph.crop==expected.crop,glyph.baseline==expected.baseline,
                      glyph.inkThreshold==expected.inkThreshold,glyph.toleranceUnits==expected.toleranceUnits,glyph.sidebearing==expected.sidebearing,
                      glyph.licenseSHA256==nil else { throw WorkflowFailure.invalid("The traced glyph did not match the selected source and settings. Its mapping remains pending.") }
            } else if let expected = expectedFallback {
                guard glyph.origin == .generatedFallback,glyph.sourceID==nil,glyph.sourceFile=="fallback.ttf",glyph.sourceSHA256==expected.fontSHA256,glyph.licenseSHA256==expected.licenseSHA256,
                      glyph.rasterFile==nil,glyph.rasterSHA256==nil else { throw WorkflowFailure.invalid("The generated character did not match its selected licensed source. Its mapping remains pending.") }
            } else { throw ProjectFailure.invalidProject }
            guard owner.apply({
                if let target { guard let index = $0.glyphs.firstIndex(where: { $0.id==target }) else { throw ProjectFailure.invalidProject };$0.glyphs[index] = glyph }
                else { $0.glyphs.append(glyph) }
                $0.pendingMappings.removeAll { $0.id==id }
            }) else { throw WorkflowFailure.invalid(owner.issue ?? "This outline could not be added to the font.") }
            owner.selectedGlyphID = glyph.id;owner.selectedMappingID = owner.draft?.pendingMappings.first?.id
            _ = await owner.saveNow()
        }
    }
    func editPoint(glyphID: UUID,contour: Int,point: Int,x: Int,y: Int,onCurve: Bool) {
        change {
            guard let index = $0.glyphs.firstIndex(where: { $0.id==glyphID }),$0.glyphs[index].outline.contours.indices.contains(contour),$0.glyphs[index].outline.contours[contour].indices.contains(point) else { throw ProjectFailure.invalidProject }
            $0.glyphs[index].outline.contours[contour][point] = .init(x: x,y: y,onCurve: onCurve)
            $0.glyphs[index].outlineSHA256 = try $0.glyphs[index].outline.sha256;$0.glyphs[index].origin = .editedOutline;$0.glyphs[index].revisionID = UUID()
        }
    }
    func saveNow() async -> Bool {
        autosave?.cancel();autosave = nil;if let saveTask { return await saveTask.value }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false };saving = true;defer { saving = false }
            while dirty {
                guard let base = saved,let value = draft else { return false };let number = editNumber
                do {
                    let next = try await repository.save(project,base: base,draft: value)
                    guard saved?.draft.id==base.draft.id else { return false };saved = next
                    if editNumber==number { draft = next.draft } else { draft?.generation = next.draft.generation;draft?.currentFontRevisionID = next.draft.currentFontRevisionID }
                    conflict = false
                    let summary = FontWorkspaceSummary(id: next.draft.id,label: next.draft.label,glyphCount: next.draft.glyphs.count)
                    if let index = fonts.firstIndex(where: { $0.id==summary.id }) { fonts[index] = summary }
                } catch { issue = error.localizedDescription;conflict = true;return false }
            }
            return true
        }
        saveTask = task;let success = await task.value;saveTask = nil;return success
    }
    func keepBoth() {
        guard busy == nil,conflict,let saved,let draft else { return };let number = editNumber
        let id: UUID;if let old = copyAttempt,old.edit==number { id = old.id } else { id = UUID();copyAttempt = (id,number) }
        run("Keeping both font workspaces…") { owner in
            let copy = try await owner.repository.copyDraft(owner.project,snapshot: saved,draft: draft,newID: id)
            await owner.load();try owner.adopt(copy,expected: number);owner.copyAttempt = nil
        }
    }
    func compileFont() {
        guard busy == nil else { return }
        run("Compiling TTF and WOFF2…") { owner in
            let number = owner.editNumber
            guard await owner.saveNow(),let snapshot = owner.saved else { return }
            let attempt: (id: UUID,milliseconds: Int64,token: String)
            if let old = owner.compileAttempt,old.token==snapshot.savedSHA256 { attempt = old }
            else { attempt = (UUID(),Int64(Date().timeIntervalSince1970*1000),snapshot.savedSHA256);owner.compileAttempt = attempt }
            let family = "Clauto Custom "+String(snapshot.draft.id.uuidString.prefix(8))+" "+String(attempt.id.uuidString.prefix(8))
            let inputs = try await owner.repository.compilationInputs(owner.project,snapshot: snapshot)
            let files = try await owner.compiler.execute(action: "build",request: FontCompilerRequest.build(family: family,glyphs: snapshot.draft.glyphs),inputs: inputs,project: owner.project,engine: owner.engine,hasFallback: snapshot.draft.glyphs.contains(where: { $0.sourceID==nil }))
            guard let ttf = files.files["font.ttf"],let woff = files.files["font.woff2"] else { throw ProjectFailure.invalidProject }
            let revision = FontExportRevision(schemaVersion: 1,id: attempt.id,fontID: snapshot.draft.id,projectID: owner.project.id,parentRevisionID: snapshot.draft.currentFontRevisionID,createdMilliseconds: attempt.milliseconds,family: family,draftSHA256: snapshot.savedSHA256,glyphsSHA256: TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(snapshot.draft.glyphs)),ttfSHA256: TranscriptSourceMap.sha(ttf),woff2SHA256: TranscriptSourceMap.sha(woff),compilerSHA256: files.scriptSHA256,compilerDependenciesSHA256: files.dependenciesSHA256,engineVersion: files.engineVersion,licenseSHA256: files.files["OFL.txt"].map(TranscriptSourceMap.sha))
            let result = try await owner.repository.publish(owner.project,snapshot: snapshot,revision: revision,compiled: files)
            owner.saved = result.snapshot
            if owner.editNumber==number { owner.draft = result.snapshot.draft;owner.exported = result }
            else { owner.draft?.generation = result.snapshot.draft.generation;owner.draft?.currentFontRevisionID = result.snapshot.draft.currentFontRevisionID }
            owner.compileAttempt = nil
        }
    }
    private func run(_ label: String,work: @escaping @MainActor (FontStudioController) async throws -> Void) {
        guard operation == nil else { return };busy = label;issue = nil
        operation = Task { [weak self] in
            guard let self else { return };defer { operation = nil;busy = nil }
            do { try await work(self) } catch is CancellationError {} catch { issue = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel() }
    func flushForExit() async -> Bool {
        autosave?.cancel();operation?.cancel();if let operation { await operation.value }
        let success = await saveNow();return success && !hasPendingWork
    }
}
