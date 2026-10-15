import Foundation
import Testing
import CoreGraphics
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor SpatialSyntheticCapture: ReviewFrameCapturing {
    let frozen: FrozenReviewFrame
    init(_ frame: FrozenReviewFrame) { frozen = frame }
    func capture(_ request: FrameCommentRequest,project: Project) async throws -> FrozenReviewFrame { frozen }
    func cancel(_ id: UUID) async {}
}
private actor SpatialSaveGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void,any Error>?
    func checkpoint() async throws {
        guard !entered else { return }; entered = true
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release(failing: Bool = false) {
        if failing { continuation?.resume(throwing: WorkflowFailure.invalid("Synthetic lost acknowledgement")) }
        else { continuation?.resume() }
        continuation = nil
    }
}

struct FrameSpatialNoteTests {
    @Test func closedFreehandGestureRetainsDragIntentWhenItsEndpointReturnsToTheStart() throws {
        let path = [CGPoint(x: 10,y: 10),.init(x: 90,y: 10),.init(x: 90,y: 90),.init(x: 10,y: 90),.init(x: 10,y: 10)]
        var gesture = FrameMarkGesture(start: path[0])
        for point in path.dropFirst() { gesture.observe(point) }
        #expect(!gesture.isClick && path.first == path.last)
        #expect(VideoAnnotationGeometry.stroke(path,video: .init(x: 0,y: 0,width: 100,height: 100),image: .init(width: 100,height: 100))?.kind == .freehand)
        var click = FrameMarkGesture(start: path[0]); click.observe(.init(x: 11,y: 11)); #expect(click.isClick)
    }
    @Test func earlierEllipseEncodingRemainsUnchangedWithoutNewOptionalFields() throws {
        let old = Data(#"{"bounds":{"height":0.3,"width":0.2,"x":0.1,"y":0.2},"id":"C9BC4EAE-9861-439F-A026-87E1B5260335","kind":"ellipse"}"#.utf8)
        let decoded = try JSONDecoder().decode(FrameEllipse.self,from: old)
        try decoded.validate(width: 1920,height: 1080)
        #expect(decoded.points == nil && decoded.tag == nil && decoded.note == nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(decoded) == old)
    }
    @Test func freehandClipsToVideoAndSurvivesLetterboxResizeWithoutCoordinateChanges() throws {
        let image = CGSize(width: 1920,height: 1080), video = try #require(VideoAnnotationGeometry.videoRect(image: image,canvas: .init(x: 0,y: 0,width: 600,height: 600)))
        let shape = try #require(VideoAnnotationGeometry.stroke([.init(x: 150,y: 200),.init(x: 350,y: 350),.init(x: 900,y: 900)],video: video,image: image))
        #expect(shape.kind == .freehand && shape.points?.last == .init(x: 1,y: 1))
        try shape.validate(width: 1920,height: 1080)
        let resized = try #require(VideoAnnotationGeometry.videoRect(image: image,canvas: .init(x: 0,y: 0,width: 1200,height: 1200)))
        #expect(VideoAnnotationGeometry.display(shape.bounds,video: resized).width == 2*VideoAnnotationGeometry.display(shape.bounds,video: video).width)
        #expect(VideoAnnotationGeometry.stroke([.init(x: 0,y: 0),.init(x: 20,y: 20)],video: video,image: image) == nil)
        #expect(VideoAnnotationGeometry.stroke([.init(x: 150,y: 200),.init(x: Double.nan,y: 250)],video: video,image: image) == nil)
        #expect(VideoAnnotationGeometry.stroke(Array(repeating: .init(x: 150,y: 200),count: 513),video: video,image: image) == nil)
        #expect(VideoAnnotationGeometry.stroke([.init(x: 150,y: 200),.init(x: 200,y: 250)],video: video,image: .init(width: Double.infinity,height: 1080)) == nil)
    }
    @Test func horizontalDrawingsRemainAtLeastOneSourcePixelAndClickPinsStayCircular() throws {
        let image = CGSize(width: 1920,height: 1080), video = CGRect(x: 0,y: 0,width: 480,height: 270)
        let stroke = try #require(VideoAnnotationGeometry.stroke([.init(x: 30,y: 20),.init(x: 400,y: 20)],video: video,image: image))
        #expect(stroke.bounds.height*image.height >= 1)
        for point in [CGPoint(x: 1,y: 1),.init(x: 240,y: 130),.init(x: 479,y: 269)] {
            let pin = try #require(VideoAnnotationGeometry.pin(at: point,video: video))
            try FrameEllipse(id: UUID(),kind: .circle,bounds: pin).validate(width: 1920,height: 1080)
        }
        #expect(VideoAnnotationGeometry.pin(at: .init(x: -1,y: 100),video: video) == nil)
    }
    @MainActor @Test func regionTextResizeUndoAndRedoKeepMarkIdentityAndAllWords() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), draft = FrameCommentDraft(request: frame.request,frame: frame)
        try draft.addStroke([.init(x: 20,y: 20),.init(x: 80,y: 50)],video: .init(x: 0,y: 0,width: 160,height: 90))
        let id = try #require(draft.selectedShapeID)
        try draft.updateSelected(tag: "Dough",note: "Keep this hand movement visible")
        let tagged = try #require(draft.history.shapes.first)
        #expect(draft.canSave && tagged.note == "Keep this hand movement visible")
        try draft.resizeSelected(.init(x: 0.3,y: 0.3,width: 0.5,height: 0.4))
        #expect(draft.history.shapes.first?.id == id && draft.history.shapes.first?.note == tagged.note)
        draft.undo(); #expect(draft.history.shapes == [tagged])
        draft.redo(); #expect(draft.history.shapes.first?.bounds.x == 0.3)
        draft.selectedShapeID = id
        let words = String(repeating: "User words ",count: 500)
        try draft.updateSelected(tag: "Dough",note: words)
        #expect(draft.history.shapes.first?.note == words && !draft.canSave && draft.validationIssue != nil)
        draft.undo(); #expect(draft.canSave && draft.history.shapes.first?.note == tagged.note)
    }
    @Test func savedSpatialNotesKeepExactFrameAndHistoryWithoutChangingTheMovie() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), repo = FrameCommentRepository(project: f.project)
        let mark = FrameEllipse(id: UUID(),kind: .highlight,bounds: .init(x: 0.2,y: 0.2,width: 0.5,height: 0.3),tag: "Hands",note: "Keep the mixing visible")
        let first = try await repo.save(frame: frame,text: "",annotations: [mark])
        var changed = mark; changed.note = "Show the bowl for longer"
        let next = try await repo.save(frame: frame,text: "",annotations: [changed],supersedes: first.id)
        #expect(try await repo.list().map(\.id) == [next.id])
        #expect(try await repo.read(first.id).0.annotations == [mark])
        #expect(try await repo.read(next.id).0.annotations == [changed])
        #expect(next.request == first.request && next.framePNG_SHA256 == first.framePNG_SHA256)
        #expect(next.reviewOnly && !next.productionAuthorized && !next.appliedToVideo)
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == f.target.preview.sha256)
    }
    @Test func malformedPointsAndEmptyOrOversizedRegionNotesRefuse() throws {
        let bounds = NormalizedVideoRect(x: 0.1,y: 0.1,width: 0.5,height: 0.5)
        for shape in [FrameEllipse(id: UUID(),kind: .freehand,bounds: bounds),
                      .init(id: UUID(),kind: .freehand,bounds: bounds,points: [.init(x: 0.2,y: 0.2),.init(x: 0.9,y: 0.9)]),
                      .init(id: UUID(),kind: .highlight,bounds: bounds,points: [.init(x: 0.2,y: 0.2)]),
                      .init(id: UUID(),kind: .highlight,bounds: bounds,tag: "\n"),
                      .init(id: UUID(),kind: .highlight,bounds: bounds,note: " "),
                      .init(id: UUID(),kind: .highlight,bounds: bounds,note: String(repeating: "x",count: 4097))] {
            #expect(throws: (any Error).self) { try shape.validate(width: 1920,height: 1080) }
        }
    }
    @MainActor @Test func delayedRegionFieldEditCannotRetargetAnotherSelectionOrResurrectDeletion() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), draft = FrameCommentDraft(request: frame.request,frame: frame)
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.2,height: 0.2),kind: .highlight)
        let first = try #require(draft.selectedShapeID)
        try draft.add(.init(x: 0.6,y: 0.6,width: 0.2,height: 0.2),kind: .ellipse)
        let second = try #require(draft.selectedShapeID)
        try draft.updateRegion(first,tag: "First detail",note: "Delayed original words")
        #expect(draft.selectedShapeID == second && draft.history.shapes.first(where: { $0.id == second })?.note == nil)
        draft.selectedShapeID = first; try draft.removeSelected()
        try draft.updateRegion(first,tag: "Must not return",note: "Late field callback")
        #expect(draft.history.shapes.map(\.id) == [second])
        draft.undo()
        #expect(draft.history.shapes.first(where: { $0.id == first })?.note == "Delayed original words")
    }
    @MainActor private func preparedController(_ frame: FrozenReviewFrame, project: Project, gate: SpatialSaveGate) async throws -> FrameCommentController {
        let controller = FrameCommentController(project: project,capture: SpatialSyntheticCapture(frame),saveCheckpoint: { try await gate.checkpoint() })
        try controller.begin(frame.request)
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.preparing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.draft?.frame != nil && !controller.preparing); return controller
    }
    private func waitForSave(_ gate: SpatialSaveGate) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered)
    }
    @MainActor @Test func lateRegionWordsDuringSaveBecomeAChildRevisionAndKeepOriginalWords() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), gate = SpatialSaveGate()
        let controller = try await preparedController(frame,project: f.project,gate: gate), draft = try #require(controller.draft)
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.4,height: 0.4),kind: .highlight)
        let mark = try #require(draft.selectedShapeID); try draft.updateRegion(mark,tag: "Bowl",note: "Original words")
        let save = Task { await controller.save() }; try await waitForSave(gate)
        #expect(controller.saving)
        try draft.updateRegion(mark,tag: "Bowl",note: "Newer region words")
        await gate.release(); let saved = await save.value
        let latest = try #require(controller.comments.last), original = try await controller.repository.read(draft.id).0
        #expect(saved && controller.draft == nil && latest.id != original.id && latest.supersedesID == original.id)
        #expect(original.annotations.first?.note == "Original words" && latest.annotations.first?.note == "Newer region words")
        #expect(try await controller.repository.list().map(\.id) == [latest.id])
    }
    @MainActor @Test func retryAfterALostAcknowledgementKeepsItsExactAttemptThenSavesNewerWords() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), gate = SpatialSaveGate()
        let controller = try await preparedController(frame,project: f.project,gate: gate), draft = try #require(controller.draft)
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.4,height: 0.4),kind: .highlight)
        let mark = try #require(draft.selectedShapeID); try draft.updateRegion(mark,tag: "Bowl",note: "Earlier exact attempt")
        let save = Task { await controller.save() }; try await waitForSave(gate)
        let attempt = try #require(draft.pendingSave)
        // Commit the frozen attempt but lose its acknowledgement to the caller.
        let committed = try await controller.repository.save(frame: frame,text: attempt.text,annotations: attempt.annotations,supersedes: attempt.supersedesID,id: attempt.id)
        let persistedOriginal = try await controller.repository.read(committed.id).0
        await gate.release(failing: true); let first = await save.value
        #expect(!first && draft.pendingSave == attempt && controller.draft?.id == draft.id)
        try draft.updateRegion(mark,tag: "Bowl",note: "Words after uncertain save")
        let retried = await controller.save(), latest = try #require(controller.comments.last)
        #expect(retried && controller.draft == nil && latest.supersedesID == committed.id)
        #expect(latest.annotations.first?.note == "Words after uncertain save")
        #expect(try await controller.repository.read(committed.id).0 == persistedOriginal)
        #expect(try await controller.repository.list().map(\.id) == [latest.id])
    }
    @Test func stalePhysicalProjectCannotSaveEvenWhenReplacementSharesExactMediaArtifacts() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let fm = FileManager.default, replacement = f.root.appendingPathComponent("Replacement root")
        try fm.copyItem(at: f.project.folder,to: replacement)
        for path in ["exports/review.mp4","exports/cut.fcpxml","clauto-version.json","plan/cut.plan.json","inputs/script/approved.md","inputs/brief.md"] {
            let relative = "cuts/v001/"+path
            try fm.removeItem(at: replacement.appendingPathComponent(relative)); try fm.linkItem(at: f.project.folder.appendingPathComponent(relative),to: replacement.appendingPathComponent(relative))
        }
        let old = f.target
        let target = try VoiceReviewTarget(id: old.id,projectID: old.projectID,versionID: old.versionID,versionNumber: old.versionNumber,versionMetadataSHA256: old.versionMetadataSHA256,timeline: VoiceReviewProvenance.inspect(old.timeline.relativePath,project: f.project),preview: VoiceReviewProvenance.inspect(old.preview.relativePath,project: f.project),approvedPlanSHA256: old.approvedPlanSHA256,approvedPlanPath: old.approvedPlanPath,approvedScriptSHA256: old.approvedScriptSHA256,approvedScriptPath: old.approvedScriptPath,approvedBriefSHA256: old.approvedBriefSHA256,engineVersion: old.engineVersion,duration: old.duration)
        let request = FrameCommentRequest(id: UUID(),target: target,frame: try .capture(.init(value: 1001,timescale: 24000),duration: target.duration))
        let frame = try await ReviewFrameCaptureService().capture(request,project: f.project)
        try fm.moveItem(at: f.project.folder,to: f.root.appendingPathComponent("Displaced root")); try fm.moveItem(at: replacement,to: f.project.folder)
        try VoiceReviewProvenance.check(target,project: f.project)
        #expect(try SourceRenderDirectory.open(f.project.folder).identity != f.project.folderIdentity)
        await #expect(throws: (any Error).self) { _ = try await FrameCommentRepository(project: f.project).save(frame: frame,text: "Must stay unsaved",annotations: []) }
        await #expect(throws: (any Error).self) { _ = try await FrameCommentRepository(project: f.project).list() }
        #expect(!fm.fileExists(atPath: f.project.folder.appendingPathComponent("notes/frame-comments").path))
    }
}
