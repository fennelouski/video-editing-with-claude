import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor PeopleFrozenCapture: ReviewFrameCapturing {
    let frame: FrozenReviewFrame
    init(_ frame: FrozenReviewFrame) { self.frame = frame }
    func capture(_ request: FrameCommentRequest,project: Project) async throws -> FrozenReviewFrame { frame }
    func cancel(_ id: UUID) async {}
}
private actor SyntheticPeopleDetector: ReviewPeopleDetecting {
    let invalid: Bool
    init(invalid: Bool = false) { self.invalid = invalid }
    func detect(_ frame: FrozenReviewFrame) throws -> [FramePersonProposal] {
        [.init(id: UUID(),requestID: frame.request.id,frameSHA256: invalid ? String(repeating: "0",count: 64):frame.pngSHA256,
               bounds: .init(x: 0.1,y: 0.1,width: 0.3,height: 0.5),confidence: 0.9)]
    }
}
private actor GatedPeopleDetector: ReviewPeopleDetecting {
    private(set) var entered = false
    private(set) var returned = false
    private var continuation: CheckedContinuation<Void,Never>?
    func detect(_ frame: FrozenReviewFrame) async throws -> [FramePersonProposal] {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        returned = true // Deliberately ignores cancellation to test the receiver.
        return [.init(id: UUID(),requestID: frame.request.id,frameSHA256: frame.pngSHA256,bounds: .init(x: 0.1,y: 0.1,width: 0.3,height: 0.5),confidence: 0.9)]
    }
    func release() { continuation?.resume(); continuation = nil }
}
struct ProjectPeopleTests {
    @Test func delayedRenameFieldAndAcknowledgementStayWithTheirOriginalPersonAndProject() {
        let project = UUID(), otherProject = UUID(), first = ProjectPerson(id: UUID(),name: "Host"), second = ProjectPerson(id: UUID(),name: "Guest")
        var drafts = ProjectPersonNameDrafts()
        drafts.update("Corrected host",person: first.id,project: project)
        // The picker now displays Guest; a late callback still belongs to Host.
        drafts.update("Host's late words",person: first.id,project: project)
        #expect(drafts.text(for: second,project: project) == "Guest")
        #expect(drafts.text(for: first,project: project) == "Host's late words")
        drafts.acknowledge("Corrected host",person: first.id,project: project)
        #expect(drafts.text(for: first,project: project) == "Host's late words")
        drafts.update("Separate project's wording",person: first.id,project: otherProject)
        drafts.acknowledge("Host's late words",person: first.id,project: project)
        #expect(drafts.text(for: first,project: project) == first.name)
        #expect(drafts.text(for: first,project: otherProject) == "Separate project's wording")
    }
    @Test func selectModeNeverCreatesAnonymousProposalMarksOrPins() {
        let existing = UUID(), proposal = UUID()
        #expect(FrameMarkClickAction.resolve(existing: nil,proposal: proposal,selecting: true) == .select(nil))
        #expect(FrameMarkClickAction.resolve(existing: nil,proposal: nil,selecting: true) == .select(nil))
        #expect(FrameMarkClickAction.resolve(existing: existing,proposal: proposal,selecting: true) == .select(existing))
        #expect(FrameMarkClickAction.resolve(existing: existing,proposal: proposal,selecting: false) == .select(existing))
        #expect(FrameMarkClickAction.resolve(existing: nil,proposal: proposal,selecting: false) == .acceptPerson(proposal))
        #expect(FrameMarkClickAction.resolve(existing: nil,proposal: nil,selecting: false) == .newPin)
    }
    private func fixture() async throws -> (URL,Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-people-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic project people",root: root,engine: root,engineVersion: "synthetic")
        return (root,project)
    }
    @Test func sameNamesRemainDistinctAndEveryMentionChoiceStaysProjectLocal() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectPeopleRepository(project: project)
        let first = try await repo.create(name: "Alex"), second = try await repo.create(name: "Alex")
        let document = try await repo.load()
        #expect(first.id != second.id && document.people.count == 2)
        #expect(Set(document.mentionMatches("alex",exact: true).map(\.id)) == [first.id,second.id])
        try ProjectPersonReference(projectID: project.id,personID: first.id,nameSnapshot: first.name,confirmedByUser: true).validate(project: project.id)
        #expect(throws: (any Error).self) { try ProjectPersonReference(projectID: project.id,personID: first.id,nameSnapshot: first.name,confirmedByUser: false).validate(project: project.id) }
        #expect(throws: (any Error).self) { try ProjectPersonReference(projectID: project.id,personID: first.id,nameSnapshot: first.name,confirmedByUser: true).validate(project: UUID()) }
    }
    @Test func renamePreservesStableIDAndHistoricalReferenceWords() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectPeopleRepository(project: project), person = try await repo.create(name: "Host")
        let reference = ProjectPersonReference(projectID: project.id,personID: person.id,nameSnapshot: person.name,confirmedByUser: true)
        let renamed = try await repo.rename(person.id,name: "Presenter")
        #expect(renamed.people.first?.id == reference.personID && renamed.people.first?.name == "Presenter")
        #expect(reference.nameSnapshot == "Host" && renamed.people.first?.previousNames == ["Host"])
        try renamed.validateReference(reference,historical: true)
        #expect(throws: (any Error).self) { try renamed.validateReference(reference) }
        #expect(renamed.mentionMatches("host",exact: true).map(\.id) == [person.id])
        #expect(renamed.changes.map(\.kind) == [.create,.rename])
    }
    @Test func explicitMergeSplitAndArchiveRetainHistoryWithoutReassigningOldReferences() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectPeopleRepository(project: project), first = try await repo.create(name: "Host"), second = try await repo.create(name: "Presenter")
        let old = ProjectPersonReference(projectID: project.id,personID: first.id,nameSnapshot: "Host",confirmedByUser: true)
        let merged = try await repo.merge(first.id,into: second.id)
        try merged.validateReference(old,historical: true)
        #expect(throws: (any Error).self) { try merged.validateReference(old) }
        #expect(merged.canonicalID(first.id) == second.id && merged.mentionMatches("Host",exact: true).map(\.id) == [second.id])
        #expect(old.personID == first.id && old.nameSnapshot == "Host")
        let split = try await repo.create(name: "Guest",splitFrom: second.id)
        #expect(split.id != second.id && split.id != first.id)
        let archived = try await repo.archive(second.id,archived: true)
        #expect(archived.mentionMatches("Host").isEmpty && archived.people.count == 3)
        let restored = try await repo.archive(second.id,archived: false)
        #expect(restored.canonicalID(first.id) == second.id && restored.people.contains(where: { $0.id == split.id && $0.active }))
        var cycle = restored
        let target = try #require(cycle.people.firstIndex(where: { $0.id == second.id }))
        cycle.people[target].archived = true; cycle.people[target].mergedIntoID = first.id
        #expect(throws: (any Error).self) { try cycle.validate(project: project.id) }
    }
    @Test func separateActorsKeepBothNamesAndNeverRewriteTheProjectManifest() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try Data(contentsOf: project.folder.appendingPathComponent("clauto-project.json"))
        let first = ProjectPeopleRepository(project: project), second = ProjectPeopleRepository(project: project)
        async let a = first.create(name: "First person")
        async let b = second.create(name: "Second person")
        _ = try await (a,b)
        let document = try await first.load()
        #expect(Set(document.people.map(\.name)) == ["First person","Second person"] && document.revision == 2)
        #expect(try Data(contentsOf: project.folder.appendingPathComponent("clauto-project.json")) == manifest)
    }
    @Test func staleRootCannotReadOrChangeTheReplacementCatalog() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectPeopleRepository(project: project), original = try await repo.create(name: "Original person")
        let relative = ".clauto/people.json", before = try Data(contentsOf: project.folder.appendingPathComponent(relative)), backup = root.appendingPathComponent("Backup")
        try FileManager.default.copyItem(at: project.folder,to: backup)
        try FileManager.default.moveItem(at: project.folder,to: root.appendingPathComponent("Moved original")); try FileManager.default.moveItem(at: backup,to: project.folder)
        await #expect(throws: (any Error).self) { _ = try await repo.create(name: "Must stay unsaved") }
        await #expect(throws: (any Error).self) { _ = try await repo.load() }
        #expect(try Data(contentsOf: project.folder.appendingPathComponent(relative)) == before)
        let fresh = try await ProjectRepository().open(project.folder), current = try await ProjectPeopleRepository(project: fresh).load()
        #expect(current.people.map(\.id) == [original.id])
    }
    @Test func malformedNamesTamperedEnvelopesAndSymlinkCatalogsRefuseWithoutTouchingForeignBytes() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectPeopleRepository(project: project)
        for name in [" ","Two\nLines",String(repeating: "x",count: 161)] {
            await #expect(throws: (any Error).self) { _ = try await repo.create(name: name) }
        }
        _ = try await repo.create(name: "Local person")
        let path = project.folder.appendingPathComponent(".clauto/people.json"), original = try Data(contentsOf: path)
        var envelope = try #require(try JSONSerialization.jsonObject(with: original) as? [String:Any]); envelope["sha256"] = String(repeating: "0",count: 64)
        try JSONSerialization.data(withJSONObject: envelope).write(to: path)
        await #expect(throws: (any Error).self) { _ = try await repo.load() }
        let foreign = root.appendingPathComponent("Foreign sentinel"), sentinel = Data("Untouched synthetic sentinel".utf8)
        try sentinel.write(to: foreign); try FileManager.default.removeItem(at: path); try FileManager.default.createSymbolicLink(at: path,withDestinationURL: foreign)
        await #expect(throws: (any Error).self) { _ = try await repo.create(name: "Must not follow link") }
        #expect(try Data(contentsOf: foreign) == sentinel)
    }
    @Test func rosterMustReplayItsExactExplicitHistoryEvenWithAValidEnvelopeHash() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectPeopleRepository(project: project), person = try await repo.create(name: "Host")
        let original = try await repo.rename(person.id,name: "Presenter")
        try original.validate(project: project.id)
        var cases: [ProjectPeopleDocument] = []
        var changed = original; changed.people[0].name = "Invented label"; cases.append(changed)
        changed = original; changed.people[0].previousNames = ["Invented history"]; cases.append(changed)
        changed = original; changed.people[0].revision = 1; cases.append(changed)
        changed = original; changed.people.append(.init(id: UUID(),name: "Unrecorded person")); cases.append(changed)
        changed = original; changed.changes.removeFirst(); changed.revision -= 1; cases.append(changed)
        changed = original
        let last = try #require(changed.changes.last)
        changed.changes[1] = .init(id: last.id,revision: 2,kind: .rename,people: last.people,previousName: "Wrong prior label",name: last.name,created: last.created)
        cases.append(changed)
        changed = original
        let first = try #require(changed.changes.first)
        changed.changes[0] = .init(id: first.id,revision: 1,kind: .restore,people: first.people,previousName: nil,name: nil,created: first.created)
        cases.append(changed)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let path = project.folder.appendingPathComponent(".clauto/people.json")
        for value in cases {
            #expect(throws: (any Error).self) { try value.validate(project: project.id) }
            let payload = try encoder.encode(value)
            let envelope: [String:Any] = ["sha256":TranscriptSourceMap.sha(payload),"payload":payload.base64EncodedString()]
            let bytes = try JSONSerialization.data(withJSONObject: envelope)
            try bytes.write(to: path)
            await #expect(throws: (any Error).self) { _ = try await repo.load() }
            await #expect(throws: (any Error).self) { _ = try await repo.create(name: "Must remain unsaved") }
            #expect(try Data(contentsOf: path) == bytes)
        }
    }
    @Test func currentAssignmentsNeedAnExistingActiveIDAndExactConfirmedLabel() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectPeopleRepository(project: project), person = try await repo.create(name: "Guest")
        let document = try await repo.load()
        let correct = ProjectPersonReference(projectID: project.id,personID: person.id,nameSnapshot: "Guest",confirmedByUser: true)
        try document.validateReference(correct)
        for ref in [ProjectPersonReference(projectID: project.id,personID: UUID(),nameSnapshot: "Guest",confirmedByUser: true),ProjectPersonReference(projectID: project.id,personID: person.id,nameSnapshot: "Another name",confirmedByUser: true),ProjectPersonReference(projectID: UUID(),personID: person.id,nameSnapshot: "Guest",confirmedByUser: true),ProjectPersonReference(projectID: project.id,personID: person.id,nameSnapshot: "Guest",confirmedByUser: false)] {
            #expect(throws: (any Error).self) { try document.validateReference(ref) }
            #expect(throws: (any Error).self) { try document.validateReference(ref,historical: true) }
        }
        let archived = try await repo.archive(person.id,archived: true)
        try archived.validateReference(correct,historical: true)
        #expect(throws: (any Error).self) { try archived.validateReference(correct) }
        let path = project.folder.appendingPathComponent(".clauto/people.json"), beforeNoOp = try Data(contentsOf: path)
        let noOp = try await repo.archive(person.id,archived: true)
        #expect(noOp.people == archived.people && noOp.revision == archived.revision && noOp.changes.map(\.id) == archived.changes.map(\.id))
        #expect(try Data(contentsOf: path) == beforeNoOp)
        let restored = try await repo.archive(person.id,archived: false)
        let beforeRename = try Data(contentsOf: path)
        let unchanged = try await repo.rename(person.id,name: "Guest")
        #expect(unchanged.people == restored.people && unchanged.revision == restored.revision && unchanged.changes.map(\.id) == restored.changes.map(\.id))
        #expect(try Data(contentsOf: path) == beforeRename)
    }
    @MainActor @Test func explicitRegionAssociationSurvivesResizeUndoSavedRevisionAndLaterProfileCorrections() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let people = ProjectPeopleRepository(project: f.project), person = try await people.create(name: "Host"), document = try await people.load()
        let draft = FrameCommentDraft(request: frame.request,frame: frame)
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.3,height: 0.4),kind: .highlight)
        let markID = try #require(draft.selectedShapeID)
        try draft.updateRegion(markID,tag: "Host's hands",note: "Keep this mixing visible")
        let reference = ProjectPersonReference(projectID: f.project.id,personID: person.id,nameSnapshot: person.name,confirmedByUser: true)
        try draft.associate(reference,with: markID,in: document)
        draft.undo(); #expect(draft.history.shapes.first?.person == nil)
        draft.redo(); #expect(draft.history.shapes.first?.person == reference)
        try draft.resizeSelected(.init(x: 0.2,y: 0.2,width: 0.3,height: 0.4))
        #expect(draft.history.shapes.first?.person == reference)
        let repository = FrameCommentRepository(project: f.project)
        let first = try await repository.save(frame: frame,text: "",annotations: draft.history.shapes,id: draft.id)
        _ = try await people.rename(person.id,name: "Presenter")
        _ = try await people.archive(person.id,archived: true)
        let old = try await repository.read(first.id)
        #expect(old.0.annotations.first?.person == reference)
        var revised = old.0.annotations; revised[0].note = "Keep the earlier person link and update these words"
        let child = try await repository.save(frame: frame,text: "",annotations: revised,supersedes: first.id)
        #expect(child.annotations.first?.person == reference && child.supersedesID == first.id)
        #expect(child.request == first.request && child.framePNG_SHA256 == first.framePNG_SHA256 && child.reviewOnly && !child.appliedToVideo)
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == f.target.preview.sha256)
        // Completed history and its exact lost-acknowledgement recovery do not
        // depend on the current registry still being available.
        try FileManager.default.removeItem(at: f.project.folder.appendingPathComponent(".clauto/people.json"))
        #expect(try await repository.read(first.id).0.annotations.first?.person == reference)
        let retry = try await repository.save(frame: frame,text: "",annotations: old.0.annotations,id: first.id)
        #expect(retry.id == first.id)
    }
    @MainActor @Test func deletedRegionAndForgedPersonReferencesCannotBeAssignedOrSaved() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), people = ProjectPeopleRepository(project: f.project)
        let person = try await people.create(name: "Guest"), document = try await people.load()
        let draft = FrameCommentDraft(request: frame.request,frame: frame)
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.2,height: 0.3),kind: .highlight)
        let deleted = try #require(draft.selectedShapeID); try draft.removeSelected()
        try draft.add(.init(x: 0.5,y: 0.5,width: 0.2,height: 0.3),kind: .highlight)
        let reference = ProjectPersonReference(projectID: f.project.id,personID: person.id,nameSnapshot: person.name,confirmedByUser: true)
        try draft.associate(reference,with: deleted,in: document)
        #expect(draft.history.shapes.count == 1 && draft.history.shapes.first?.person == nil)
        let repository = FrameCommentRepository(project: f.project)
        for bad in [ProjectPersonReference(projectID: UUID(),personID: person.id,nameSnapshot: person.name,confirmedByUser: true),ProjectPersonReference(projectID: f.project.id,personID: UUID(),nameSnapshot: person.name,confirmedByUser: true),ProjectPersonReference(projectID: f.project.id,personID: person.id,nameSnapshot: "Invented name",confirmedByUser: true),ProjectPersonReference(projectID: f.project.id,personID: person.id,nameSnapshot: person.name,confirmedByUser: false)] {
            var shape = try #require(draft.history.shapes.first); shape.person = bad; shape.note = "Keep these exact draft words"
            await #expect(throws: (any Error).self) { _ = try await repository.save(frame: frame,text: "",annotations: [shape]) }
        }
        #expect(try await repository.list().isEmpty)
    }
    @Test func anonymousVisionGeometryFlipsOnlyTheImageYAxisAndRefusesInvalidBoxes() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let box = try #require(FramePersonProposal.fromVision(.init(x: 0.1,y: 0.2,width: 0.3,height: 0.4),confidence: 0.9,frame: frame))
        #expect(abs(box.bounds.x-0.1) < 1e-9 && abs(box.bounds.y-0.4) < 1e-9 && box.bounds.width == 0.3 && box.bounds.height == 0.4)
        #expect(box.requestID == frame.request.id && box.frameSHA256 == frame.pngSHA256)
        for rect in [CGRect(x: -0.1,y: 0,width: 0.3,height: 0.4),.init(x: 0,y: 0,width: -0.1,height: 0.4),.init(x: 0.9,y: 0.9,width: 0.4,height: 0.4),.init(x: Double.nan,y: 0,width: 0.3,height: 0.4),.init(x: 0,y: 0,width: 0.00001,height: 0.4)] {
            #expect(FramePersonProposal.fromVision(rect,confidence: 0.9,frame: frame) == nil)
        }
        for confidence in [0.49,1.1,Double.nan] { #expect(FramePersonProposal.fromVision(.init(x: 0,y: 0,width: 0.5,height: 0.5),confidence: confidence,frame: frame) == nil) }
    }
    @MainActor private func waitForDetection(_ controller: FrameCommentController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while (controller.preparing || controller.findingPeople) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!controller.preparing && !controller.findingPeople)
    }
    @MainActor @Test func anonymousBoxesBecomeNamedRegionsOnlyAfterSeparateExplicitChoices() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let repo = ProjectPeopleRepository(project: f.project), first = try await repo.create(name: "Alex"), second = try await repo.create(name: "Alex")
        let controller = FrameCommentController(project: f.project,capture: PeopleFrozenCapture(frame),peopleDetector: SyntheticPeopleDetector())
        try controller.begin(frame.request); try await waitForDetection(controller)
        let draft = try #require(controller.draft), proposal = try #require(controller.personProposals.first)
        #expect(draft.history.shapes.isEmpty && controller.comments.isEmpty)
        controller.acceptPersonProposal(proposal.id,draftID: UUID()); #expect(draft.history.shapes.isEmpty)
        controller.acceptPersonProposal(proposal.id,draftID: draft.id)
        let mark = try #require(draft.history.shapes.first)
        #expect(mark.person == nil && mark.bounds == proposal.bounds && controller.personProposals.isEmpty)
        await controller.assignPerson(second.id,to: mark.id,draftID: draft.id)
        #expect(draft.history.shapes.first?.person?.personID == second.id && second.id != first.id)
        await controller.assignPerson(nil,to: mark.id,draftID: draft.id)
        #expect(draft.history.shapes.first?.person == nil)
        draft.undo(); #expect(draft.history.shapes.first?.person?.personID == second.id)
        #expect(controller.cancel())
        let invalid = FrameCommentController(project: f.project,capture: PeopleFrozenCapture(frame),peopleDetector: SyntheticPeopleDetector(invalid: true))
        try invalid.begin(frame.request); try await waitForDetection(invalid)
        #expect(invalid.personProposals.isEmpty && invalid.peopleDetectionError != nil && invalid.draft?.history.shapes.isEmpty == true)
        #expect(invalid.cancel())
    }
    @MainActor @Test func lateAnonymousAnalysisCannotReopenACancelledFrameDraft() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project), gate = GatedPeopleDetector()
        let controller = FrameCommentController(project: f.project,capture: PeopleFrozenCapture(frame),peopleDetector: gate)
        try controller.begin(frame.request)
        let deadline = ContinuousClock.now + .seconds(5)
        while await !gate.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered && controller.findingPeople)
        #expect(controller.cancel() && controller.draft == nil && controller.personProposals.isEmpty)
        await gate.release()
        while await !gate.returned && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.returned)
        await Task.yield()
        #expect(controller.draft == nil && controller.personProposals.isEmpty && !controller.findingPeople && controller.peopleDetectionError == nil)
    }
}
