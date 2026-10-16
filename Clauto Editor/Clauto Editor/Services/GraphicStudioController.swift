import Foundation
import Observation

@MainActor @Observable final class GraphicStudioController {
    let project: Project
    let repository: GraphicStudioRepository
    private let resolver = GraphicAssetResolver()
    private let renderer = GraphicSceneRenderer()
    private(set) var scenes: [GraphicWorkspaceSummary] = []
    private(set) var cutoutChoices: [GraphicCutoutChoice] = []
    private(set) var fontChoices: [GraphicFontChoice] = []
    private(set) var saved: GraphicDraftSnapshot?
    private(set) var draft: GraphicSceneDraft?
    private(set) var exported: GraphicExportResult?
    private(set) var exportProgress = 0.0
    private(set) var preview: CutoutRaster?
    private(set) var previewing = false
    private(set) var previewIssue: String?
    private(set) var busy: String?
    private(set) var saving = false
    private(set) var issue: String?
    private(set) var conflict = false
    var previewFrame = 0 { didSet { if previewFrame != oldValue { refreshPreview() } } }
    private var editNumber = 0
    private var formulaRevision = 0
    private var formulaOrigins: [UUID:GraphicFormulaSubmission] = [:]
    private var formulaHistoryEpoch = 0
    private var undo: [GraphicSceneDraft] = []
    private var redo: [GraphicSceneDraft] = []
    private var autosave: Task<Void,Never>?
    private var saveTask: Task<Bool,Never>?
    private var operation: Task<Void,Never>?
    private var previewTask: Task<Void,Never>?
    private var previewNumber = 0
    private var copyAttempt: (id: UUID,edit: Int)?
    var dirty: Bool { guard let saved,let draft else { return false };return saved.draft != draft }
    var hasPendingWork: Bool { dirty || saving || busy != nil }
    var canUndo: Bool { !undo.isEmpty && busy == nil }
    var canRedo: Bool { !redo.isEmpty && busy == nil }
    init(project: Project,repository: GraphicStudioRepository = GraphicStudioRepository()) { self.project = project;self.repository = repository }
    func load() async { do { scenes = try await repository.list(project);let choices = try await resolver.choices(project);cutoutChoices = choices.cutouts;fontChoices = choices.fonts } catch { issue = error.localizedDescription } }
    func addCutout(_ choice: GraphicCutoutChoice,sceneID: UUID? = nil) { guard sceneID.map({ $0==draft?.id }) ?? true else { return };change { $0.scene.imageLayers.append(.init(cutoutID: choice.assetID,revisionID: choice.id,imageSHA256: choice.imageSHA256)) } }
    func addText(sceneID: UUID? = nil) { guard sceneID.map({ $0==draft?.id }) ?? true else { return };change { $0.scene.textLayers.append(.init(text: "Your words")) } }
    func setFrameCount(_ count: Int,sceneID: UUID? = nil) {
        guard sceneID.map({ $0==draft?.id }) ?? true,(1...2880).contains(count) else { return }
        change { value in
            value.scene.frameCount = count
            func bounded(_ input: GraphicLayerTransform) -> GraphicLayerTransform {
                var next = input;next.startFrame = min(next.startFrame,count-1)
                if let end = next.endFrame { next.endFrame = min(count,max(next.startFrame+1,end)) };return next
            }
            for i in value.scene.imageLayers.indices { value.scene.imageLayers[i].transform = bounded(value.scene.imageLayers[i].transform) }
            for i in value.scene.textLayers.indices { value.scene.textLayers[i].transform = bounded(value.scene.textLayers[i].transform) }
        }
    }
    func setKind(_ kind: GraphicScene.Kind,sceneID: UUID? = nil) {
        guard sceneID.map({ $0==draft?.id }) ?? true else { return }
        change { value in
            var scene = GraphicScene.preset(kind);scene.id = value.id;scene.width = value.scene.width;scene.height = value.scene.height
            scene.frameCount = value.scene.frameCount;scene.imageLayers = value.scene.imageLayers;scene.textLayers = value.scene.textLayers
            scene.assumptions = value.scene.assumptions;scene.reviewNotes = value.scene.reviewNotes
            value.scene = scene;value.objectSource = nil
        }
    }
    func create(kind: GraphicScene.Kind,label: String) {
        guard !hasPendingWork else { return };let number = editNumber,id = UUID()
        run("Creating scene…") { owner in
            let value = try await owner.repository.create(owner.project,id: id,label: label,scene: .preset(kind))
            await owner.load();try owner.adopt(value,expected: number)
        }
    }
    func open(_ id: UUID) {
        guard !hasPendingWork else { return };let number = editNumber
        run("Opening scene…") { owner in try owner.adopt(await owner.repository.load(owner.project,id: id),expected: number)
            owner.exported = try await owner.repository.currentExport(owner.project,sceneID: id)
        }
    }
    private func adopt(_ value: GraphicDraftSnapshot,expected: Int) throws {
        try Task.checkCancellation();guard editNumber==expected else { throw WorkflowFailure.invalid("Your newer scene inputs remain active. Save them before opening another scene.") }
        formulaOrigins = [:];formulaRevision += 1;formulaHistoryEpoch += 1
        exported = nil;saved = value;draft = value.draft;undo = [];redo = [];editNumber += 1;conflict = false;previewFrame = 0;refreshPreview()
    }
    func change(_ work: (inout GraphicSceneDraft) throws -> Void) {
        guard busy == nil else { return };apply(work)
    }
    func changeScene(_ sceneID: UUID,kind: GraphicScene.Kind? = nil,_ work: (inout GraphicSceneDraft) throws -> Void) {
        guard let draft,draft.id==sceneID,kind.map({ $0==draft.scene.kind }) ?? true else { return };change(work)
    }
    func formulaObservation(sceneID: UUID,termID: UUID,products: Bool) -> GraphicFormulaObservation {
        guard draft?.id==sceneID,let model = draft?.scene.reaction,let term = (products ? model.products:model.reactants).first(where: { $0.id==termID }) else {
            return .init(atoms: [:],revision: formulaRevision,origin: nil,historyEpoch: formulaHistoryEpoch)
        }
        let origin = formulaOrigins[termID].flatMap { $0.atoms==term.atoms ? $0:nil }
        return .init(atoms: term.atoms,revision: formulaRevision,origin: origin,historyEpoch: formulaHistoryEpoch)
    }
    func updateReactionTerm(sceneID: UUID,termID: UUID,products: Bool,submission: GraphicFormulaSubmission? = nil,_ work: (inout ReactionGraphicTerm) -> Void) {
        guard draft?.id==sceneID,draft?.scene.kind == .reaction,let model = draft?.scene.reaction,(products ? model.products:model.reactants).contains(where: { $0.id==termID }) else { return }
        changeScene(sceneID,kind: .reaction) { value in
            guard var model = value.scene.reaction else { return }
            if products { guard let i = model.products.firstIndex(where: { $0.id==termID }) else { return };work(&model.products[i]) }
            else { guard let i = model.reactants.firstIndex(where: { $0.id==termID }) else { return };work(&model.reactants[i]) }
            value.scene.reaction = model
        }
        if let submission,let latest = draft?.scene.reaction,(products ? latest.products:latest.reactants).contains(where: { $0.id==termID && $0.atoms==submission.atoms }) {
            formulaOrigins[termID] = submission;formulaRevision += 1
        }
    }
    func updateBond(sceneID: UUID,bondID: UUID,_ work: (inout MolecularGraphicBond) -> Void) {
        changeScene(sceneID,kind: .molecule) { value in guard let i = value.scene.molecule?.bonds.firstIndex(where: { $0.id==bondID }) else { return };work(&value.scene.molecule!.bonds[i]) }
    }
    func updateAssumption(sceneID: UUID,id: UUID,text: String) {
        changeScene(sceneID) { value in guard let i = value.scene.assumptions.firstIndex(where: { $0.id==id }) else { return };value.scene.assumptions[i].text = text }
    }
    @discardableResult private func apply(_ work: (inout GraphicSceneDraft) throws -> Void) -> Bool {
        guard var value = draft else { return false };let previous = value
        do { try work(&value);try value.validate() } catch { issue = error.localizedDescription;return false }
        guard value != previous else { return true }
        undo.append(previous);if undo.count>30 { undo.removeFirst() };redo = [];draft = value;changed();return true
    }
    private func changed(historyReset: Bool = false) {
        editNumber += 1;issue = nil;formulaRevision += 1; if historyReset { formulaHistoryEpoch += 1 }
        if historyReset { formulaOrigins = [:] }
        else if let reaction = draft?.scene.reaction {
            let current = Dictionary(uniqueKeysWithValues: (reaction.reactants+reaction.products).map { ($0.id,$0.atoms) })
            formulaOrigins = formulaOrigins.filter { current[$0.key]==$0.value.atoms }
        } else { formulaOrigins = [:] }
        if let draft { previewFrame = min(previewFrame,draft.scene.frameCount-1) }
        refreshPreview();autosave?.cancel();autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300));try Task.checkCancellation();_ = await self?.saveNow() } catch {}
        }
    }
    func undoChange() {
        guard busy == nil,let previous = undo.popLast(),let current = draft else { return }
        redo.append(current);var next = previous;next.generation = current.generation;next.currentRevisionID = current.currentRevisionID;draft = next;changed(historyReset: true)
    }
    func redoChange() {
        guard busy == nil,let next = redo.popLast(),let current = draft else { return }
        undo.append(current);var value = next;value.generation = current.generation;value.currentRevisionID = current.currentRevisionID;draft = value;changed(historyReset: true)
    }
    func refreshPreview() {
        previewTask?.cancel();previewNumber += 1;let token = previewNumber
        guard let draft else { preview = nil;previewing = false;return }
        previewing = true;let number = editNumber,index = min(max(0,previewFrame),draft.scene.frameCount-1)
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(150));try draft.scene.validate()
                var scene = draft.scene;let scale = min(1,800/Double(max(scene.width,scene.height)))
                let width = Int((Double(scene.width)*scale).rounded()),height = Int((Double(scene.height)*scale).rounded())
                if width>=320,height>=240 { scene.width = width;scene.height = height }
                let assets = try await resolver.resolve(scene,project: project),image = try await renderer.render(scene,frame: index,assets: assets)
                try Task.checkCancellation();guard previewNumber==token,editNumber==number else { return };preview = image;previewIssue = nil
            } catch is CancellationError {} catch {
                guard previewNumber==token,editNumber==number else { return };previewIssue = error.localizedDescription
            }
            if previewNumber==token { previewing = false;previewTask = nil }
        }
    }
    func importOBJ(_ url: URL,sceneID: UUID? = nil) {
        guard busy == nil,let draft,sceneID.map({ $0==draft.id }) ?? true,draft.scene.kind == .object else { return };let number = editNumber
        run("Copying mesh geometry…") { owner in
            let bytes = try await GraphicMeshIntake().read(url)
            let (source,mesh) = try await owner.repository.importOBJ(owner.project,sceneID: draft.id,id: UUID(),name: url.lastPathComponent,bytes: bytes)
            try Task.checkCancellation();guard owner.editNumber==number else { throw WorkflowFailure.invalid("Your newer scene inputs remain active. Choose the mesh again to apply it.") }
            guard owner.apply({ $0.scene.object = mesh;$0.objectSource = source }) else { return };_ = await owner.saveNow()
        }
    }
    func useCube(sceneID: UUID? = nil) { guard sceneID.map({ $0==draft?.id }) ?? true,draft?.scene.kind == .object else { return };change { $0.scene.object = .cube;$0.objectSource = nil } }
    func saveNow() async -> Bool {
        autosave?.cancel();autosave = nil;if let saveTask { return await saveTask.value }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false };saving = true;defer { saving = false }
            while dirty {
                guard let base = saved,let value = draft else { return false };let number = editNumber
                do {
                    let next = try await repository.save(project,base: base,draft: value)
                    guard saved?.draft.id==base.draft.id else { return false };saved = next
                    if editNumber==number { draft = next.draft } else { draft?.generation = next.draft.generation;draft?.currentRevisionID = next.draft.currentRevisionID }
                    conflict = false
                } catch { issue = error.localizedDescription;conflict = true;return false }
            }
            return true
        }
        saveTask = task;let result = await task.value;saveTask = nil;return result
    }
    func keepBoth() {
        guard busy == nil,conflict,let saved,let draft else { return };let number = editNumber
        let id: UUID;if let old = copyAttempt,old.edit==number { id = old.id } else { id = UUID();copyAttempt = (id,number) }
        run("Keeping both scenes…") { owner in
            let copy = try await owner.repository.copyDraft(owner.project,snapshot: saved,draft: draft,newID: id)
            await owner.load();try owner.adopt(copy,expected: number);owner.copyAttempt = nil
        }
    }
    func exportScene(sceneID: UUID? = nil) {
        guard sceneID.map({ $0==draft?.id }) ?? true,busy == nil else { return }
        run("Rendering & verifying scene…") { owner in
            guard await owner.saveNow(),let frozen = owner.saved else { return }
            let number = owner.editNumber;owner.exportProgress = 0
            let result = try await GraphicSceneExportService(repository: owner.repository).export(owner.project,snapshot: frozen) { done,total in
                await MainActor.run { owner.exportProgress = Double(done)/Double(total) }
            }
            try Task.checkCancellation();owner.exported = result
            if result.becameCurrent,owner.editNumber==number,owner.saved==frozen { owner.saved = result.snapshot;owner.draft = result.snapshot.draft }
            else {
                owner.issue = "The captured scene was exported. A newer scene input is active, so that export did not replace your current scene. Review the completed output or keep both input versions."
                owner.conflict = true
            }
        }
    }
    private func run(_ label: String,work: @escaping @MainActor (GraphicStudioController) async throws -> Void) {
        guard operation == nil else { return };busy = label;issue = nil
        operation = Task { [weak self] in
            guard let self else { return };defer { operation = nil;busy = nil }
            do { try await work(self) } catch is CancellationError {} catch { issue = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel() }
    func suspendPreview() { previewTask?.cancel();previewTask = nil;previewNumber += 1;previewing = false }
    func flushForExit() async -> Bool {
        suspendPreview();autosave?.cancel();operation?.cancel();if let operation { await operation.value }
        let result = await saveNow();return result && !hasPendingWork
    }
}
