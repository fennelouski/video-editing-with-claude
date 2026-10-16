import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor CutoutOwnershipGate {
    var stage: String?
    var target: UUID?
    var entered = false
    var continuation: CheckedContinuation<Void,Never>?
    func arm(_ stage: String,target: UUID? = nil) { self.stage = stage; self.target = target; entered = false }
    func pause(_ stage: String,id: UUID) async {
        guard self.stage == stage, target == nil || target == id else { return }
        self.stage = nil; entered = true; await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct GatedCutoutStore: CutoutAssetStoring {
    let base = CutoutRepository()
    let gate: CutoutOwnershipGate
    func readImageFile(_ url: URL) async throws -> Data { try await base.readImageFile(url) }
    func list(_ project: Project) async throws -> [CutoutSourceInfo] { try await base.list(project) }
    func create(_ project: Project,id: UUID,createdMilliseconds: Int64,name: String,bytes: Data) async throws -> CutoutDraftSnapshot { try await base.create(project,id: id,createdMilliseconds: createdMilliseconds,name: name,bytes: bytes) }
    func load(_ project: Project,id: UUID) async throws -> CutoutDraftSnapshot { try await base.load(project,id: id) }
    func source(_ project: Project,id: UUID) async throws -> CutoutDecodedSource { let value = try await base.source(project,id: id); await gate.pause("source",id: id); return value }
    func masks(_ project: Project,snapshot: CutoutDraftSnapshot) async throws -> CutoutBasisPixels? { try await base.masks(project,snapshot: snapshot) }
    func storeDetection(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,detection: CutoutDetection) async throws -> CutoutMaskBasis { try await base.storeDetection(project,snapshot: snapshot,id: id,detection: detection) }
    func storeManualMask(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,encodedMask: Data) async throws -> CutoutMaskBasis { try await base.storeManualMask(project,snapshot: snapshot,id: id,encodedMask: encodedMask) }
    func save(_ project: Project,base: CutoutDraftSnapshot,draft: CutoutDraft) async throws -> CutoutDraftSnapshot { await gate.pause("save",id: base.source.id); return try await self.base.save(project,base: base,draft: draft) }
    func copyDraft(_ project: Project,snapshot: CutoutDraftSnapshot,draft: CutoutDraft,newID: UUID,createdMilliseconds: Int64) async throws -> CutoutDraftSnapshot { try await base.copyDraft(project,snapshot: snapshot,draft: draft,newID: newID,createdMilliseconds: createdMilliseconds) }
    func preview(_ project: Project,snapshot: CutoutDraftSnapshot) async throws -> CutoutPixels { try await base.preview(project,snapshot: snapshot) }
    func export(_ project: Project,snapshot: CutoutDraftSnapshot,id: UUID,created: Date) async throws -> CutoutExport { let value = try await base.export(project,snapshot: snapshot,id: id,created: created); await gate.pause("export",id: snapshot.source.id); return value }
}
struct CutoutOwnershipTests {
    private func fixture() async throws -> (URL,Project,UUID,UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-cutout-ownership-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let engine = root.appendingPathComponent("engine"); try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic cutout ownership",root: root,engine: engine), a = UUID(), b = UUID()
        let bytes = try CutoutImageIO.png(.init(width: 8,height: 6,rgba: Data(repeating: 255,count: 192))), repo = CutoutRepository()
        _ = try await repo.create(project,id: a,createdMilliseconds: 1,name: "A",bytes: bytes)
        _ = try await repo.create(project,id: b,createdMilliseconds: 2,name: "B",bytes: bytes)
        return (root,project,a,b)
    }
    @MainActor private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic ownership condition timed out")
    }
    private func entered(_ gate: CutoutOwnershipGate) async throws {
        for _ in 0..<1000 { if await gate.entered { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic source gate timed out")
    }
    @MainActor @Test func delayedOpenCannotReplaceAStrokeOnTheStillVisibleSource() async throws {
        let (root,project,a,b) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CutoutOwnershipGate(), store = GatedCutoutStore(gate: gate), controller = CutoutStudioController(project: project,repository: store)
        controller.open(a); try await wait { controller.saved?.source.id == a && controller.busy == nil }
        await gate.arm("source",target: b); controller.open(b); try await entered(gate)
        controller.brushRadius = 1; controller.addStroke([.init(x: 0.5,y: 0.5)])
        await gate.release(); try await wait { controller.busy == nil }
        #expect(controller.saved?.source.id == a && controller.draft?.recipe.strokes.count == 1 && controller.canUndo)
        #expect(await controller.flushForExit())
        #expect(try await store.base.load(project,id: a).draft.recipe.strokes.count == 1)
        #expect(try await store.base.load(project,id: b).draft.recipe.strokes.isEmpty)
    }
    @MainActor @Test func lateKeepBothSourceReadPreservesNewerLocalStrokeAndBothSavedCopies() async throws {
        let (root,project,a,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CutoutOwnershipGate(), store = GatedCutoutStore(gate: gate), controller = CutoutStudioController(project: project,repository: store)
        controller.open(a); try await wait { controller.saved != nil && controller.busy == nil }
        let base = try #require(controller.saved); var foreign = base.draft; foreign.recipe.featherPixels = 4
        _ = try await store.base.save(project,base: base,draft: foreign)
        controller.brushRadius = 1; controller.addStroke([.init(x: 0.5,y: 0.5)]); #expect(!(await controller.saveNow()))
        await gate.arm("source"); controller.keepBoth(); try await entered(gate)
        controller.addStroke([.init(x: 0.25,y: 0.5)])
        await gate.release(); try await wait { controller.busy == nil }
        #expect(controller.saved?.source.id == a && controller.draft?.recipe.strokes.count == 2 && controller.dirty)
        let list = try await store.base.list(project); #expect(list.count == 3)
        let copy = try #require(list.first { $0.id != a && $0.name == "A" })
        #expect(try await store.base.load(project,id: copy.id).draft.recipe.strokes.count == 1)
        controller.keepBoth(); try await wait { controller.busy == nil }
        #expect(controller.saved?.source.id != a && controller.draft?.recipe.strokes.count == 2 && !controller.dirty)
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func oldSourceSaveCannotBlockCloseOrMarkACleanKeptCopyConflicted() async throws {
        let (root,project,a,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CutoutOwnershipGate(),store = GatedCutoutStore(gate: gate),controller = CutoutStudioController(project: project,repository: store)
        controller.open(a);try await wait { controller.saved != nil && controller.busy == nil }
        let original = try #require(controller.saved);var foreign = original.draft;foreign.recipe.featherPixels = 4
        let foreignSaved = try await store.base.save(project,base: original,draft: foreign)
        controller.brushRadius = 1;controller.addStroke([.init(x: 0.5,y: 0.5)])
        #expect(!(await controller.saveNow()) && controller.conflict)
        await gate.arm("save",target: a)
        let oldSave = Task { await controller.saveNow() };try await entered(gate)
        controller.keepBoth();try await wait { controller.busy == nil && controller.saved?.source.id != a }
        let copy = try #require(controller.saved)
        #expect(!controller.dirty && !controller.conflict && copy.draft.recipe.strokes.count == 1)
        let close = Task { await controller.flushForExit() }
        await Task.yield();await gate.release()
        #expect(!(await oldSave.value))
        #expect(await close.value)
        #expect(!controller.hasPendingWork && !controller.conflict && controller.issue == nil)
        #expect(try await store.base.load(project,id: a)==foreignSaved)
        #expect(try await store.base.load(project,id: copy.source.id)==copy)
    }
    @MainActor @Test func oldSourceFailureCannotSkipSavingANewerStrokeOnTheKeptCopy() async throws {
        let (root,project,a,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CutoutOwnershipGate(),store = GatedCutoutStore(gate: gate),controller = CutoutStudioController(project: project,repository: store)
        controller.open(a);try await wait { controller.saved != nil && controller.busy == nil }
        let original = try #require(controller.saved);var foreign = original.draft;foreign.recipe.featherPixels = 4
        let foreignSaved = try await store.base.save(project,base: original,draft: foreign)
        controller.brushRadius = 1;controller.addStroke([.init(x: 0.5,y: 0.5)])
        #expect(!(await controller.saveNow()))
        await gate.arm("save",target: a)
        let oldSave = Task { await controller.saveNow() };try await entered(gate)
        controller.keepBoth();try await wait { controller.busy == nil && controller.saved?.source.id != a }
        let copyID = try #require(controller.saved?.source.id)
        controller.addStroke([.init(x: 0.25,y: 0.5)]);#expect(controller.dirty)
        let close = Task { await controller.flushForExit() }
        await Task.yield();await gate.release()
        #expect(!(await oldSave.value));#expect(await close.value)
        let latest = try await store.base.load(project,id: copyID)
        #expect(latest.draft.recipe.strokes.count == 2 && latest == controller.saved)
        #expect(!controller.hasPendingWork && !controller.conflict && controller.issue == nil)
        #expect(try await store.base.load(project,id: a)==foreignSaved)
    }
    @MainActor @Test func joiningAFailedCurrentSourceSaveStillRefusesCloseAndRetainsItsDirtyCorrection() async throws {
        let (root,project,a,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CutoutOwnershipGate(),store = GatedCutoutStore(gate: gate),controller = CutoutStudioController(project: project,repository: store)
        controller.open(a);try await wait { controller.saved != nil && controller.busy == nil }
        let original = try #require(controller.saved);var foreign = original.draft;foreign.recipe.featherPixels = 4
        let foreignSaved = try await store.base.save(project,base: original,draft: foreign)
        controller.brushRadius = 1;controller.addStroke([.init(x: 0.5,y: 0.5)])
        await gate.arm("save",target: a)
        let pending = Task { await controller.saveNow() };try await entered(gate)
        let close = Task { await controller.flushForExit() }
        await Task.yield();await gate.release()
        #expect(!(await pending.value));#expect(!(await close.value))
        #expect(controller.dirty && controller.conflict && controller.draft?.recipe.strokes.count == 1)
        #expect(try await store.base.load(project,id: a)==foreignSaved)
    }
    @MainActor @Test func exportAcknowledgementKeepsLaterStrokesAndTheirAutomaticSave() async throws {
        let (root,project,a,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CutoutOwnershipGate(), store = GatedCutoutStore(gate: gate), controller = CutoutStudioController(project: project,repository: store)
        controller.open(a); try await wait { controller.saved != nil && controller.busy == nil }
        controller.brushRadius = 1; controller.addStroke([.init(x: 0.5,y: 0.5)]); #expect(await controller.saveNow())
        await gate.arm("export",target: a); controller.exportPNG(); try await entered(gate)
        controller.addStroke([.init(x: 0.25,y: 0.5)])
        try await Task.sleep(for: .milliseconds(350))
        await gate.release(); try await wait { controller.busy == nil && !controller.dirty && !controller.saving }
        #expect(controller.draft?.recipe.strokes.count == 2)
        let saved = try await store.base.load(project,id: a)
        #expect(saved.draft.recipe.strokes.count == 2 && saved.draft.currentRevisionID != nil)
        #expect(await controller.flushForExit())
    }
    @Test func changedOriginalCannotBeIndexedAsAValidRecoveryCopy() async throws {
        let (root,project,a,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = CutoutRepository(), base = try await repo.load(project,id: a), copyID = UUID()
        let file = project.folder.appendingPathComponent("assets/generated-cutouts/\(a)/original.image")
        let replacement = try CutoutImageIO.png(.init(width: 8,height: 6,rgba: Data(repeating: 80,count: 192)))
        try replacement.write(to: file)
        await #expect(throws: (any Error).self) { _ = try await repo.copyDraft(project,snapshot: base,draft: base.draft,newID: copyID,createdMilliseconds: 3) }
        #expect(try await repo.list(project).count == 2)
        #expect(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent("assets/generated-cutouts/\(copyID)").path))
    }
    @MainActor @Test func lateImportAndItsRetryCannotReplaceAnUnsavedCorrection() async throws {
        let (root,project,a,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = CutoutOwnershipGate(), store = GatedCutoutStore(gate: gate), controller = CutoutStudioController(project: project,repository: store)
        controller.open(a); try await wait { controller.saved?.source.id == a && controller.busy == nil }
        let base = try #require(controller.saved); var foreign = base.draft; foreign.recipe.featherPixels = 4
        _ = try await store.base.save(project,base: base,draft: foreign)
        let image = try CutoutImageIO.png(.init(width: 8,height: 6,rgba: Data(repeating: 150,count: 192)))
        await gate.arm("source"); controller.importSource(bytes: image,name: "New source C")
        try await entered(gate); controller.brushRadius = 1; controller.addStroke([.init(x: 0.5,y: 0.5)])
        await gate.release(); try await wait { controller.busy == nil }
        #expect(controller.saved?.source.id == a && controller.draft?.recipe.strokes.count == 1 && controller.hasUnfinishedImport)
        #expect(!(await controller.saveNow())); controller.retryImport()
        #expect(controller.busy == nil && controller.saved?.source.id == a && controller.draft?.recipe.strokes.count == 1)
        #expect(!(await controller.flushForExit()))
        controller.abandonImport(); controller.keepBoth(); try await wait { controller.busy == nil }
        #expect(controller.saved?.source.id != a && controller.draft?.recipe.strokes.count == 1 && !controller.dirty)
        #expect(try await store.base.list(project).contains { $0.name == "New source C" })
        #expect(await controller.flushForExit())
    }

}
