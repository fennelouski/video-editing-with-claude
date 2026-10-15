import Foundation
import Observation

@MainActor @Observable final class CutoutStudioController {
    let project: Project
    let repository: any CutoutAssetStoring
    private let detector: any CutoutSubjectDetecting
    var assets: [CutoutSourceInfo] = []
    private(set) var saved: CutoutDraftSnapshot?
    private(set) var draft: CutoutDraft?
    private(set) var source: CutoutRaster?
    private(set) var preview: CutoutRaster?
    private(set) var subjects: [Int] = []
    private(set) var busy: String?
    private(set) var saving = false
    private(set) var exporting = false
    private(set) var conflict = false
    private(set) var issue: String?
    private(set) var exportedURL: URL?
    var brushMode = CutoutBrushStroke.Mode.restore
    var brushRadius = 20.0
    private var undo: [CutoutDraft] = []
    private var redo: [CutoutDraft] = []
    private var editNumber = 0
    private var autosave: Task<Void,Never>?
    private var saveTask: Task<Bool,Never>?
    private var previewTask: Task<Void,Never>?
    private var operation: Task<Void,Never>?
    private var operationID: UUID?
    private var importAttempt: (id: UUID,milliseconds: Int64,name: String,bytes: Data)?
    private var exportAttempt: (id: UUID,created: Date,token: String)?
    private var copyAttempt: (id: UUID,milliseconds: Int64,editNumber: Int)?
    var dirty: Bool { guard let saved, let draft else { return false }; return draft != saved.draft }
    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    var hasPendingWork: Bool { dirty || saving || busy != nil || importAttempt != nil }
    init(project: Project,repository: any CutoutAssetStoring = CutoutRepository(),detector: any CutoutSubjectDetecting = LocalCutoutSubjectDetector()) {
        self.project = project; self.repository = repository; self.detector = detector
    }
    func load() async {
        do { assets = try await repository.list(project) } catch { issue = error.localizedDescription }
    }
    func open(_ id: UUID) {
        guard !hasPendingWork else { issue = "Save this correction before opening another source."; return }
        let number = editNumber
        run("Opening source…") { owner in
            let value = try await owner.repository.load(owner.project,id: id)
            let source = try await owner.repository.source(owner.project,id: id)
            let masks = try await owner.repository.masks(owner.project,snapshot: value)
            try Task.checkCancellation(); try owner.install(value,source: source.raster,subjects: masks?.detection?.subjects.map(\.id) ?? [],expectedEditNumber: number)
        }
    }
    func importFile(_ url: URL) {
        guard !hasPendingWork else { issue = "Save this correction before choosing another source."; return }
        let number = editNumber
        run("Reading the chosen image…") { owner in
            let bytes = try await owner.repository.readImageFile(url)
            try Task.checkCancellation()
            let attempt = (id: UUID(),milliseconds: Int64(Date().timeIntervalSince1970*1000),name: url.lastPathComponent,bytes: bytes)
            owner.importAttempt = attempt
            let value = try await owner.repository.create(owner.project,id: attempt.id,createdMilliseconds: attempt.milliseconds,name: attempt.name,bytes: attempt.bytes)
            let decoded = try await owner.repository.source(owner.project,id: value.source.id)
            await owner.load(); try Task.checkCancellation(); try owner.install(value,source: decoded.raster,subjects: [],expectedEditNumber: number)
            owner.importAttempt = nil
        }
    }
    func importMaskFile(_ url: URL) {
        guard busy == nil, let saved else { return }
        run("Reading the supplied mask…") { owner in
            let bytes = try await owner.repository.readImageFile(url)
            let basis = try await owner.repository.storeManualMask(owner.project,snapshot: saved,id: UUID(),encodedMask: bytes)
            try Task.checkCancellation(); guard owner.saved?.source.id == saved.source.id else { return }
            owner.subjects = []; owner.change { $0.basisID = basis.id; $0.recipe.selectedSubjects = []; $0.recipe.manualMaskSHA256 = basis.manualSHA256 }
        }
    }
    func abandonImport() { guard busy == nil else { return }; importAttempt = nil; issue = nil }
    var hasUnfinishedImport: Bool { importAttempt != nil }
    func importSource(bytes: Data,name: String) {
        guard !hasPendingWork else { issue = "Save this correction before choosing another source."; return }
        importAttempt = (UUID(),Int64(Date().timeIntervalSince1970*1000),name,bytes); retryImport()
    }
    func retryImport() {
        guard busy == nil, let attempt = importAttempt else { return }
        guard !dirty, !saving else { issue = "Save this correction before opening the copied source."; return }
        let number = editNumber
        run("Saving original on the project drive…") { owner in
            let value = try await owner.repository.create(owner.project,id: attempt.id,createdMilliseconds: attempt.milliseconds,name: attempt.name,bytes: attempt.bytes)
            let decoded = try await owner.repository.source(owner.project,id: value.source.id)
            // Publication may already have happened before cancellation. Keep the
            // retry ID until its complete acknowledged snapshot is installed.
            await owner.load(); try Task.checkCancellation(); try owner.install(value,source: decoded.raster,subjects: [],expectedEditNumber: number)
            owner.importAttempt = nil
        }
    }
    private func install(_ value: CutoutDraftSnapshot,source: CutoutRaster,subjects: [Int],expectedEditNumber: Int) throws {
        guard editNumber == expectedEditNumber else { throw WorkflowFailure.invalid("Your newer correction remains active here. Save it, then open the other source from Saved cutout sources.") }
        saved = value; draft = value.draft; self.source = source; self.subjects = subjects
        preview = nil; exportedURL = nil; undo = []; redo = []; editNumber += 1; conflict = false; issue = nil
        brushRadius = min(20,Double(max(source.width,source.height))); requestPreview()
    }
    func change(_ edit: (inout CutoutDraft) -> Void) {
        guard var value = draft, let saved else { return }
        let previous = value; edit(&value)
        do { try value.validate(source: saved.source) } catch { issue = error.localizedDescription; return }
        guard value != previous else { return }
        undo.append(previous); if undo.count > 100 { undo.removeFirst() }; redo = []
        draft = value; changed()
    }
    private func changed() {
        editNumber += 1; issue = nil; exportedURL = nil; exportAttempt = nil
        autosave?.cancel(); autosave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                if let self, exporting, let operation { await operation.value }
                guard !Task.isCancelled else { return }; _ = await self?.saveNow()
            } catch {}
        }
        requestPreview()
    }
    func addStroke(_ points: [CutoutPoint]) {
        change { $0.recipe.strokes.append(.init(mode: brushMode,radiusPixels: brushRadius,points: points)) }
    }
    func undoCorrection() {
        guard let previous = undo.popLast(), let current = draft else { return }
        redo.append(current); var value = previous; value.generation = current.generation; value.currentRevisionID = current.currentRevisionID
        draft = value; changed()
    }
    func redoCorrection() {
        guard let next = redo.popLast(), let current = draft else { return }
        undo.append(current); var value = next; value.generation = current.generation; value.currentRevisionID = current.currentRevisionID
        draft = value; changed()
    }
    func selectSubject(_ id: Int) {
        guard subjects.contains(id) else { return }
        change {
            $0.recipe.manualMaskSHA256 = nil
            if $0.recipe.selectedSubjects.contains(id) { $0.recipe.selectedSubjects.removeAll { $0 == id } }
            else { $0.recipe.selectedSubjects.append(id); $0.recipe.selectedSubjects.sort() }
        }
    }
    func detectSubjects() {
        guard busy == nil, let source, let saved else { return }
        run("Finding subjects locally…") { owner in
            let detection = try await owner.detector.detect(source)
            let basis = try await owner.repository.storeDetection(owner.project,snapshot: saved,id: UUID(),detection: detection)
            try Task.checkCancellation(); guard owner.saved?.source.id == saved.source.id else { return }
            owner.subjects = detection.subjects.map(\.id)
            owner.change { $0.basisID = basis.id; $0.recipe.manualMaskSHA256 = nil; $0.recipe.selectedSubjects = detection.subjects.count == 1 ? [detection.subjects[0].id]:[] }
        }
    }
    func useMask(_ bytes: Data) {
        guard busy == nil, let saved else { return }
        run("Saving the supplied mask…") { owner in
            let basis = try await owner.repository.storeManualMask(owner.project,snapshot: saved,id: UUID(),encodedMask: bytes)
            try Task.checkCancellation(); guard owner.saved?.source.id == saved.source.id else { return }
            owner.subjects = []; owner.change { $0.basisID = basis.id; $0.recipe.selectedSubjects = []; $0.recipe.manualMaskSHA256 = basis.manualSHA256 }
        }
    }
    func saveNow() async -> Bool {
        autosave?.cancel(); autosave = nil
        if let saveTask { return await saveTask.value }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }; saving = true; defer { saving = false }
            while dirty {
                guard let base = saved, let snapshot = draft else { return false }
                let number = editNumber
                do {
                    let next = try await repository.save(project,base: base,draft: snapshot)
                    guard saved?.source.id == base.source.id else { return false }
                    saved = next
                    if editNumber == number { draft = next.draft }
                    else { draft?.generation = next.draft.generation; draft?.currentRevisionID = next.draft.currentRevisionID }
                    conflict = false
                } catch {
                    conflict = (error as? CutoutFailure).map { if case .storageConflict = $0 { return true }; return false } ?? false
                    issue = error.localizedDescription; return false
                }
            }
            return true
        }
        saveTask = task; let value = await task.value; saveTask = nil; return value
    }
    func keepBoth() {
        guard busy == nil, conflict, let saved, let draft else { return }
        let number = editNumber
        let attempt: (id: UUID,milliseconds: Int64,editNumber: Int)
        if let old = copyAttempt, old.editNumber == number { attempt = old }
        else { attempt = (UUID(),Int64(Date().timeIntervalSince1970*1000),number); copyAttempt = attempt }
        run("Keeping this correction as another asset…") { owner in
            let next = try await owner.repository.copyDraft(owner.project,snapshot: saved,draft: draft,newID: attempt.id,createdMilliseconds: attempt.milliseconds)
            guard owner.editNumber == number else { await owner.load(); throw WorkflowFailure.invalid("The saved copy keeps your earlier correction. Your newer changes remain here; save another copy to keep those too.") }
            let source = try await owner.repository.source(owner.project,id: next.source.id), masks = try await owner.repository.masks(owner.project,snapshot: next)
            await owner.load(); try Task.checkCancellation(); try owner.install(next,source: source.raster,subjects: masks?.detection?.subjects.map(\.id) ?? [],expectedEditNumber: number); owner.copyAttempt = nil
        }
    }
    func exportPNG() {
        guard busy == nil else { return }
        run("Saving transparent PNG revision…") { owner in
            owner.exporting = true; defer { owner.exporting = false }
            let number = owner.editNumber
            guard await owner.saveNow(), let snapshot = owner.saved else { return }
            let attempt: (id: UUID,created: Date,token: String)
            if let old = owner.exportAttempt, old.token == snapshot.savedSHA256 { attempt = old }
            else { attempt = (UUID(),Date(),snapshot.savedSHA256); owner.exportAttempt = attempt }
            let result = try await owner.repository.export(owner.project,snapshot: snapshot,id: attempt.id,created: attempt.created)
            owner.saved = result.snapshot
            if owner.editNumber == number { owner.draft = result.snapshot.draft; owner.exportedURL = result.pngURL }
            else { owner.draft?.generation = result.snapshot.draft.generation; owner.draft?.currentRevisionID = result.snapshot.draft.currentRevisionID }
            owner.exportAttempt = nil
        }
    }
    private func requestPreview() {
        previewTask?.cancel()
        guard let saved, let draft else { return }
        let number = editNumber, snapshot = CutoutDraftSnapshot(source: saved.source,draft: draft,savedSHA256: saved.savedSHA256)
        previewTask = Task { [weak self,repository,project] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let output = try await repository.preview(project,snapshot: snapshot)
                let masks = try await repository.masks(project,snapshot: snapshot)
                try Task.checkCancellation(); guard let self, editNumber == number else { return }
                preview = output.image; subjects = masks?.detection?.subjects.map(\.id) ?? []
            } catch is CancellationError {} catch { guard let self, editNumber == number else { return }; preview = nil; issue = error.localizedDescription }
        }
    }
    private func run(_ label: String,work: @escaping @MainActor (CutoutStudioController) async throws -> Void) {
        guard operation == nil else { return }; let id = UUID(); operationID = id; busy = label; issue = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if operationID == id { operation = nil; operationID = nil; busy = nil } }
            do { try await work(self) } catch is CancellationError {} catch { issue = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel(); previewTask?.cancel() }
    func flushForExit() async -> Bool {
        autosave?.cancel(); previewTask?.cancel(); operation?.cancel()
        if let operation { await operation.value }
        let saved = await saveNow(); return saved && !hasPendingWork
    }
}
