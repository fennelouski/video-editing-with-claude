import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private struct FrozenRegionCapture: ReviewFrameCapturing {
    let frame: FrozenReviewFrame
    func capture(_ request: FrameCommentRequest,project: Project) async throws -> FrozenReviewFrame { frame }
    func cancel(_ id: UUID) async {}
}

struct RegionDictationTests {
    private func shape(note: String? = nil) -> FrameEllipse { .init(id: UUID(),kind: .highlight,bounds: .init(x: 0.1,y: 0.2,width: 0.3,height: 0.4),note: note) }
    private func record(_ frame: FrozenReviewFrame,region: FrameEllipse) -> RegionDictationRecord {
        .init(schemaVersion: 1,id: UUID(),draftID: UUID(),request: frame.request,region: region,frameSHA256: frame.pngSHA256,width: frame.width,height: frame.height,actualFrameTime: frame.actualTime,locale: "en_US",deviceUID: "synthetic-mic",created: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func speech(_ text: String,segment: String = "a",final: Bool = false) -> VoiceSpeechResult {
        .init(segmentID: segment,text: text,isFinal: final,audioStart: 0,audioEnd: 1)
    }
    @MainActor private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw WorkflowFailure.invalid("Synthetic dictation condition timed out.")
    }
    @Test func projectionRetainsManualEditsDeletionUndoAndUnicodeVerbatim() throws {
        var projection = RegionDictationProjection(draftID: UUID(),regionID: UUID(),base: "🥖 Keep",applied: "🥖 Keep")
        #expect(projection.next(transcript: "the hands",current: "🥖 Keep") == "🥖 Keep the hands")
        #expect(projection.next(transcript: "the bowl",current: "my own words") == nil)
        #expect(projection.next(transcript: "new",current: "🥖 Keep the hands") == nil)
        var deleted = RegionDictationProjection(draftID: UUID(),regionID: UUID(),base: "",applied: "")
        #expect(deleted.next(transcript: "late words",current: nil) == nil && deleted.conflicted)
    }
    @Test func latestFinalWinsWithoutDiscardingOriginalRevisionsOrMisreadingInvalidTimes() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        var value = record(frame,region: shape())
        value.revisions = [.init(speech("Keep")),.init(speech("Keep the bowl",final: true)),.init(speech("stale partial")),.init(speech("and the hands",segment: "b",final: true))]
        #expect(value.transcript == "Keep the bowl and the hands" && value.revisions.count == 4)
        let invalid = RegionSpeechRevision(.init(segmentID: "bad",text: "original",isFinal: true,audioStart: .nan,audioEnd: 1))
        #expect(throws: (any Error).self) { try invalid.validate() }
    }
    @Test func durableAnchorPrecedesSpeechAndCASPreservesAllRevisionsAcrossRestart() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), region = shape(), initial = record(frame,region: region)
        let repo = RegionDictationRepository(project: f.project)
        try await repo.begin(initial,frame: frame)
        var next = initial; next.state = .recording; next.revisions.append(.init(speech("Keep the hands")))
        try await repo.update(next,from: initial); try await repo.update(next,from: initial)
        let reopened = RegionDictationRepository(project: f.project), saved = try await reopened.read(initial.id)
        #expect(saved.0 == next && saved.1.png == frame.png)
        var stale = initial; stale.revisions.append(.init(speech("conflicting writer")))
        await #expect(throws: (any Error).self) { try await reopened.update(stale,from: initial) }
        var terminal = next; terminal.state = .finished; try await repo.update(terminal,from: next)
        var late = terminal; late.revisions.append(.init(speech("after closure")))
        await #expect(throws: (any Error).self) { try await repo.update(late,from: terminal) }
        #expect(try await repo.list() == [terminal])
    }
    @MainActor @Test func guidedSetupPinsTheRegionAndSavingAutomaticallyDrainsFinalWords() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
        await provider.configureSetup()
        await provider.configure(finals: [.speech(speech("Keep the original hands",final: true))])
        let dictation = RegionDictationController(project: f.project,provider: provider)
        let controller = FrameCommentController(project: f.project,capture: FrozenRegionCapture(frame: frame),dictation: dictation)
        try controller.begin(frame.request); try await wait { controller.draft?.frame != nil }
        let draft = try #require(controller.draft)
        try draft.add(shape().bounds,kind: .highlight); let original = try #require(draft.selectedShapeID)
        controller.dictateRegion(original); try await wait { dictation.mode == .recording }
        #expect(await provider.microphoneRequests == 1)
        #expect(await provider.speechRequests == 1)
        #expect(await provider.modelPreparations == 1)
        let id = try #require(dictation.record?.id)
        #expect(try await dictation.repository.read(id).0.region.id == original)
        await provider.emit(.speech(speech("Keep the")))
        try await wait { draft.history.shapes.first?.note == "Keep the" }
        try draft.add(.init(x: 0.6,y: 0.6,width: 0.2,height: 0.2),kind: .ellipse)
        let other = try #require(draft.selectedShapeID)
        #expect(await controller.save())
        let saved = try #require(controller.comments.last)
        #expect(saved.annotations.first?.note == "Keep the original hands")
        #expect(saved.annotations.last?.id == other && saved.annotations.last?.note == nil)
        #expect(saved.annotations.first?.dictationSessionIDs == [id] && dictation.mode == .idle)
        #expect(try await dictation.repository.read(id).0.revisions.map(\.text) == ["Keep the","Keep the original hands"])
    }
    @MainActor @Test func manualEditsWinAndCancelRetainsRecoverableOriginalFrameAndWords() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
        let dictation = RegionDictationController(project: f.project,provider: provider)
        let controller = FrameCommentController(project: f.project,capture: FrozenRegionCapture(frame: frame),dictation: dictation)
        try controller.begin(frame.request); try await wait { controller.draft?.frame != nil }
        let draft = try #require(controller.draft); try draft.add(shape().bounds,kind: .highlight)
        let id = try #require(draft.selectedShapeID); controller.dictateRegion(id); try await wait { dictation.mode == .recording }
        await provider.emit(.speech(speech("spoken partial"))); try await wait { draft.history.shapes.first?.note == "spoken partial" }
        try draft.updateRegion(id,tag: "Hands",note: "my own wording")
        await provider.emit(.speech(speech("spoken final",final: true))); try await wait { dictation.record?.revisions.count == 2 }
        #expect(draft.history.shapes.first?.note == "my own wording")
        #expect(await controller.closeDictationAndCancel())
        let rawID = try #require(dictation.record?.id)
        #expect(try await controller.repository.list().isEmpty)
        try controller.beginRecoverDictation(rawID); try await wait { controller.draft?.frame != nil }
        #expect(controller.draft?.request == frame.request && controller.draft?.frame?.png == frame.png)
        #expect(controller.draft?.history.shapes.first?.note == "spoken final")
    }
    @MainActor @Test func cancellationDuringSetupNeverStartsMicrophoneOrRetargetsNewDraft() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
        await provider.configureSetup(holdModel: true)
        let dictation = RegionDictationController(project: f.project,provider: provider)
        dictation.start(frame: frame,region: shape(),draftID: UUID()) { _ in Issue.record("Cancelled setup projected words") }
        try await wait { dictation.phase == .model }
        #expect(await dictation.finish())
        #expect(await provider.starts == 0)
        #expect(try await dictation.repository.list().isEmpty && !dictation.hasPendingWork)
    }
    @MainActor @Test func deletedRegionIsNotRecreatedAndRawSpeechStillSaves() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
        let dictation = RegionDictationController(project: f.project,provider: provider)
        let controller = FrameCommentController(project: f.project,capture: FrozenRegionCapture(frame: frame),dictation: dictation)
        try controller.begin(frame.request); try await wait { controller.draft?.frame != nil }
        let draft = try #require(controller.draft); try draft.add(shape().bounds,kind: .highlight)
        controller.dictateRegion(try #require(draft.selectedShapeID)); try await wait { dictation.mode == .recording }
        try draft.removeSelected(); await provider.emit(.speech(speech("late original words",final: true)))
        try await wait { dictation.record?.revisions.count == 1 }
        #expect(draft.history.shapes.isEmpty)
        #expect(await dictation.finish())
        #expect(dictation.history.last?.transcript == "late original words")
    }
    @Test func forgedRegionReferencesAndChangedProjectRootCannotSave() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), original = shape(note: "Keep this")
        let value = record(frame,region: original), repo = RegionDictationRepository(project: f.project)
        try await repo.begin(value,frame: frame)
        var linked = original; linked.dictationSessionIDs = [value.id]
        _ = try await FrameCommentRepository(project: f.project).save(frame: frame,text: "",annotations: [linked])
        var forged = shape(note: "Wrong region"); forged.dictationSessionIDs = [value.id]
        await #expect(throws: (any Error).self) { _ = try await FrameCommentRepository(project: f.project).save(frame: frame,text: "",annotations: [forged]) }
        let moved = f.project.folder.appendingPathExtension("original")
        try FileManager.default.moveItem(at: f.project.folder,to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: f.project.folder,withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { _ = try await repo.list() }
    }
    @MainActor @Test func disconnectedStorageRetainsDeliveredWordsAndBlocksCloseUntilRetry() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
        let dictation = RegionDictationController(project: f.project,provider: provider)
        dictation.start(frame: frame,region: shape(),draftID: UUID()) { _ in }
        try await wait { dictation.mode == .recording }
        let folder = f.project.folder.appendingPathComponent(".clauto/region-dictation"), held = f.project.folder.appendingPathComponent(".clauto/held-dictation")
        try FileManager.default.moveItem(at: folder,to: held)
        await provider.emit(.speech(speech("retain these original words",final: true)))
        try await wait { dictation.storagePending && !dictation.active }
        #expect(dictation.record?.transcript == "retain these original words")
        #expect(!(await dictation.finish()))
        try FileManager.default.moveItem(at: held,to: folder)
        #expect(await dictation.finish())
        let id = try #require(dictation.record?.id)
        #expect(try await dictation.repository.read(id).0.transcript == "retain these original words")
    }
    @MainActor @Test func captureReturningAfterCancellationStillDrainsItsOriginalSession() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
        await provider.configure(holdStart: true,finals: [.speech(speech("late start final",final: true))])
        let dictation = RegionDictationController(project: f.project,provider: provider)
        dictation.start(frame: frame,region: shape(),draftID: UUID()) { _ in }
        try await wait { dictation.record != nil }
        let ending = Task { await dictation.finish() }
        try await Task.sleep(for: .milliseconds(20)); await provider.releaseStart()
        #expect(await ending.value)
        #expect(dictation.record?.transcript == "late start final" && !dictation.hasPendingWork)
    }
    @MainActor @Test func editUndoAndDeleteUndoKeepPermanentPriorityOverLaterSpeech() async throws {
        for deleted in [false,true] {
            let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
            let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
            let dictation = RegionDictationController(project: f.project,provider: provider)
            let controller = FrameCommentController(project: f.project,capture: FrozenRegionCapture(frame: frame),dictation: dictation)
            try controller.begin(frame.request); try await wait { controller.draft?.frame != nil }
            let draft = try #require(controller.draft); try draft.add(shape().bounds,kind: .highlight)
            let id = try #require(draft.selectedShapeID); controller.dictateRegion(id); try await wait { dictation.mode == .recording }
            await provider.emit(.speech(speech("original partial"))); try await wait { draft.history.shapes.first?.note == "original partial" }
            if deleted { try draft.removeSelected() } else { try draft.updateRegion(id,tag: "",note: "manual words") }
            draft.undo()
            #expect(draft.history.shapes.first?.note == "original partial")
            await provider.emit(.speech(speech("later final",final: true)))
            try await wait { dictation.record?.revisions.count == 2 }
            #expect(await dictation.finish())
            #expect(draft.history.shapes.first?.note == "original partial")
            #expect(dictation.record?.transcript == "later final")
        }
    }
    @MainActor @Test func sharedSaveAdmissionIncludesFinalOnlyCaptureWithoutMicrophoneOff() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider()
        await provider.configure(finals: [.speech(speech("Only final words",final: true))])
        let dictation = RegionDictationController(project: f.project,provider: provider)
        let controller = FrameCommentController(project: f.project,capture: FrozenRegionCapture(frame: frame),dictation: dictation)
        try controller.begin(frame.request); try await wait { controller.draft?.frame != nil }
        let draft = try #require(controller.draft); try draft.add(shape().bounds,kind: .highlight)
        #expect(!controller.canSaveFrameComment)
        controller.dictateRegion(try #require(draft.selectedShapeID)); try await wait { dictation.mode == .recording }
        #expect(!draft.canSave && controller.canSaveFrameComment)
        #expect(await controller.save())
        #expect(controller.comments.last?.annotations.first?.note == "Only final words" && controller.draft == nil)
    }
    @MainActor @Test func twoWindowsUseOneSynchronousAdmissionAndReleaseWithoutTaskCycles() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), provider = MockVoiceProvider(), admission = RegionDictationAdmission()
        let first = RegionDictationController(project: f.project,provider: provider,admission: admission)
        let second = RegionDictationController(project: f.project,provider: provider,admission: admission)
        first.start(frame: frame,region: shape(),draftID: UUID()) { _ in }
        second.start(frame: frame,region: shape(),draftID: UUID()) { _ in }
        #expect(!second.active && second.error != nil)
        try await wait { first.mode == .recording }; #expect(await provider.starts == 1)
        #expect(await first.finish())
        second.start(frame: frame,region: shape(),draftID: UUID()) { _ in }
        try await wait { second.mode == .recording }; #expect(await provider.starts == 2)
        #expect(await second.finish())
    }
}
