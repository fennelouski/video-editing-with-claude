import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor CutoutMockDetector: CutoutSubjectDetecting {
    let output: CutoutDetection
    var entered = false
    var releaseGate: CheckedContinuation<Void,Never>?
    init() {
        output = .init(width: 8,height: 6,subjects: [.init(id: 1,mask: Data((0..<48).map { (2...5).contains($0%8) && (1...4).contains($0/8) ? 255:0 }))],model: "Synthetic detector",modelRevision: 1)
    }
    func detect(_ image: CutoutRaster) async throws -> CutoutDetection {
        entered = true; await withCheckedContinuation { releaseGate = $0 }; try Task.checkCancellation(); return output
    }
    func release() { releaseGate?.resume(); releaseGate = nil }
}
struct CutoutStudioControllerTests {
    private func fixture() async throws -> (URL,Project,UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-cutout-controller-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let engine = root.appendingPathComponent("engine"); try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic cutout controller",root: root,engine: engine)
        let id = UUID(), raster = CutoutRaster(width: 8,height: 6,rgba: Data(repeating: 255,count: 8*6*4))
        _ = try await CutoutRepository().create(project,id: id,createdMilliseconds: 1,name: "Synthetic.png",bytes: CutoutImageIO.png(raster))
        return (root,project,id)
    }
    @MainActor private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic cutout condition timed out")
    }
    @MainActor @Test func editsUndoRedoAutosaveAndExportReopenTheSameAsset() async throws {
        let (root,project,id) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = CutoutStudioController(project: project)
        controller.open(id); try await wait { controller.saved != nil && controller.busy == nil }
        controller.brushRadius = 1; controller.addStroke([.init(x: 0.5,y: 0.5)])
        #expect(controller.dirty && controller.canUndo)
        controller.undoCorrection(); #expect(controller.draft?.recipe.strokes.isEmpty == true && controller.canRedo)
        controller.redoCorrection(); #expect(controller.draft?.recipe.strokes.count == 1)
        #expect(await controller.saveNow()); try await wait { controller.preview != nil }
        controller.exportPNG(); try await wait { controller.busy == nil }
        let output = try #require(controller.exportedURL)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(await controller.flushForExit())
        let reopened = CutoutStudioController(project: project); reopened.open(id)
        try await wait { reopened.saved != nil && reopened.busy == nil }
        #expect(reopened.draft?.currentRevisionID == controller.draft?.currentRevisionID && reopened.draft?.recipe.strokes.count == 1)
        #expect(await reopened.flushForExit())
    }
    @MainActor @Test func detectorAcknowledgementPreservesNewerBrushCorrectionsAndCancellationCannotPublish() async throws {
        let (root,project,id) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let detector = CutoutMockDetector(), controller = CutoutStudioController(project: project,detector: detector)
        controller.open(id); try await wait { controller.saved != nil && controller.busy == nil }
        controller.detectSubjects()
        for _ in 0..<1000 { if await detector.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await detector.entered)
        controller.brushMode = .erase; controller.brushRadius = 0.5
        controller.addStroke([.init(x: 2.5/8,y: 1.5/6)])
        await detector.release(); try await wait { controller.busy == nil }
        #expect(controller.draft?.recipe.strokes.count == 1 && controller.draft?.recipe.selectedSubjects == [1])
        #expect(await controller.flushForExit())
        let cancelled = CutoutMockDetector(), second = CutoutStudioController(project: project,detector: cancelled)
        second.open(id); try await wait { second.saved != nil && second.busy == nil }
        let base = try #require(second.saved)
        second.detectSubjects(); for _ in 0..<1000 { if await cancelled.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
        second.cancel(); await cancelled.release(); try await wait { second.busy == nil }
        #expect(second.saved == base && !second.dirty)
        #expect(await second.flushForExit())
    }
    @MainActor @Test func failedSaveKeepsTheDraftBlocksQuitAndKeepBothCopiesItWithoutChangingTheOtherWriter() async throws {
        let (root,project,id) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = CutoutStudioController(project: project)
        controller.open(id); try await wait { controller.saved != nil && controller.busy == nil }
        let repo = CutoutRepository(), base = try #require(controller.saved)
        var foreign = base.draft; foreign.recipe.featherPixels = 4
        let other = try await repo.save(project,base: base,draft: foreign)
        controller.brushRadius = 1; controller.addStroke([.init(x: 0.5,y: 0.5)])
        #expect(!(await controller.saveNow()) && controller.dirty && controller.conflict)
        #expect(!(await controller.flushForExit()))
        controller.keepBoth(); try await wait { controller.busy == nil }
        #expect(controller.saved?.source.id != id && !controller.dirty)
        #expect(try await repo.load(project,id: id) == other)
        #expect(controller.draft?.recipe.strokes.count == 1 && controller.draft?.recipe.featherPixels == 0)
        #expect(try await repo.list(project).count == 2)
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func invalidOriginalStaysAvailableForRetryOrAnExplicitNewChoice() async throws {
        let (root,project,_) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = CutoutStudioController(project: project)
        controller.importSource(bytes: Data("not an image".utf8),name: "bad.png")
        try await wait { controller.busy == nil }
        let permitsExit = await controller.flushForExit()
        #expect(controller.hasUnfinishedImport && controller.issue != nil && !permitsExit)
        controller.abandonImport(); #expect(await controller.flushForExit())
    }
}
