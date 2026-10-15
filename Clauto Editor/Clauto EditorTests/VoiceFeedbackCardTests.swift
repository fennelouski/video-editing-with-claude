import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

/// Core tests never enumerate hardware or request system speech assets.
actor SyntheticVoiceReviewProvider: VoiceReviewDictating {
    func access(locale: String) async -> VoiceReviewAccess { .init(microphone: .authorized,speech: .authorized,installedModel: true,locale: locale) }
    func devices() async -> [VoiceInputDevice] { [] }
    func requestMicrophonePermission() async -> Bool { Issue.record("Unexpected microphone request in a synthetic core test"); return false }
    func requestSpeechPermission() async -> Bool { Issue.record("Unexpected speech request in a synthetic core test"); return false }
    func start(session: UUID,deviceUID: String,locale: String) async throws -> AsyncStream<VoiceDictationEvent> { throw WorkflowFailure.invalid("Synthetic core test cannot start a microphone") }
    func stop(session: UUID,cancel: Bool) async {}
}

struct VoiceFeedbackCardTests {
    private func speechFixture(_ f: FrameReviewFixture) async throws -> (VoiceReviewRepository,UUID,UUID) {
        let repo = try VoiceReviewRepository(project: f.project)
        _ = try await repo.register(f.target)
        let id = UUID(), attempt = UUID(), epoch = UUID()
        _ = try await repo.begin(id: id,attempt: attempt,deviceUID: "synthetic",locale: "en-US")
        _ = try await repo.captured(session: id,attempt: attempt,audioStart: 0,duration: 1.5,hostStart: 100)
        _ = try await repo.observe(session: id,host: 100,seconds: 0,rate: 1,target: f.target.id,epoch: epoch,kind: .play)
        _ = try await repo.observe(session: id,host: 101.5,seconds: 1.5,rate: 1,target: f.target.id,epoch: epoch,kind: .sample)
        return (repo,id,attempt)
    }
    @Test func mergeIsIdempotentRetainsParentsAndLateASRNeverResurrectsThem() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (repo,id,attempt) = try await speechFixture(f)
        _ = try await repo.speech(.init(segmentID: "a",text: "Keep first",isFinal: true,audioStart: 0.1,audioEnd: 0.3),session: id,attempt: attempt)
        let before = try await repo.speech(.init(segmentID: "b",text: "Keep second",isFinal: true,audioStart: 0.6,audioEnd: 0.8),session: id,attempt: attempt)
        let pointer = f.project.folder.appendingPathComponent("cuts/current.json"), sentinel = Data("Untouched watched version".utf8)
        try sentinel.write(to: pointer)
        let request = VoiceCardRequest(id: UUID(),kind: .merge,parents: before.orderedVisibleNotes.map { .init(id: $0.id,revision: $0.revision) })
        let after = try await repo.restructureCards(request)
        #expect(after.notes.count == 3 && after.orderedVisibleNotes.count == 1)
        let child = try #require(after.orderedVisibleNotes.first)
        #expect(child.text == "Keep first\nKeep second" && child.action == nil && child.state == .needsResolution)
        #expect(child.lineage?.parentAnchors == before.notes.compactMap(\.effectiveAnchor))
        #expect(after.notes.prefix(2).allSatisfy { $0.state == .cancelled && $0.supersededBy == request.childIDs })
        let retry = try await repo.restructureCards(request); #expect(retry.notes.count == 3 && retry.cardOperations?.count == 1)
        let late = try await repo.speech(.init(segmentID: "a",text: "Keep first revised late",isFinal: true,audioStart: 0.1,audioEnd: 0.4),session: id,attempt: attempt)
        #expect(late.notes.count == 3 && late.notes[0].history.last?.text == "Keep first revised late")
        #expect(late.orderedVisibleNotes.first?.text == child.text)
        await #expect(throws: (any Error).self) { _ = try await repo.retry(note: before.notes[0].id) }
        await #expect(throws: (any Error).self) { _ = try await repo.edit(note: before.notes[0].id,expectedRevision: after.notes[0].revision,text: "Resurrect",intent: .protect,anchor: nil) }
        #expect(try await repo.claim() == nil)
        #expect(try Data(contentsOf: pointer) == sentinel)
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == f.target.preview.sha256)
    }
    @Test func splitPreservesUnicodeAndRequiresSeparateExplicitTimingAndActions() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (repo,id,attempt) = try await speechFixture(f)
        let text = "Keep café 🎥. Remove fade."
        let before = try await repo.speech(.init(segmentID: "single",text: text,isFinal: true,audioStart: 0.1,audioEnd: 0.8),session: id,attempt: attempt)
        let parent = try #require(before.notes.first), ref = VoiceNoteRevision(id: parent.id,revision: parent.revision)
        let request = VoiceCardRequest(id: UUID(),kind: .split,parents: [ref],splitUTF16: "Keep café 🎥.".utf16.count)
        for offset in [1,"Keep café ".utf16.count+1] {
            var unchanged = before
            #expect(throws: (any Error).self) { try unchanged.restructureCards(.init(id: UUID(),kind: .split,parents: [ref],splitUTF16: offset)) }
            #expect(unchanged.notes.count == before.notes.count)
        }
        let result = try await repo.restructureCards(request)
        #expect(result.orderedVisibleNotes.map(\.text) == ["Keep café 🎥.","Remove fade."])
        #expect(result.orderedVisibleNotes.allSatisfy { $0.audioStart == nil && $0.action == nil && $0.state == .needsResolution && $0.transcript == text })
        #expect(result.notes.first?.onset == parent.onset)
        await #expect(throws: (any Error).self) { _ = try await repo.restructureCards(.init(id: UUID(),kind: .split,parents: [ref],splitUTF16: 1)) }
        let child = result.orderedVisibleNotes[0]
        let edited = try await repo.edit(note: child.id,expectedRevision: child.revision,text: child.text,intent: .protect,anchor: .init(targetID: f.target.id,seconds: 0.1,endSeconds: 0.3),action: .protect)
        #expect(edited.notes.first { $0.id == child.id }?.state == .needsResolution) // Other split card still has an unresolved overlapping anchor.
        let second = result.orderedVisibleNotes[1]
        let resolved = try await repo.edit(note: second.id,expectedRevision: second.revision,text: second.text,intent: .change,anchor: .init(targetID: f.target.id,seconds: 0.5,endSeconds: 0.8),action: .remove)
        #expect(resolved.orderedVisibleNotes.allSatisfy { $0.issues.isEmpty })
        #expect(resolved.notes.first { $0.id == child.id }?.lineage?.operation == request)
    }
    @Test func staleRequestsCrossVersionAndUnsavedEditsRefuseAtomically() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = try VoiceReviewRepository(project: f.project); _ = try await repo.register(f.target)
        _ = try await repo.addTyped(text: "Keep first",action: .protect,anchor: .init(targetID: f.target.id,seconds: 0.1,endSeconds: 0.3))
        let original = try await repo.addTyped(text: "Keep second",action: .protect,anchor: .init(targetID: f.target.id,seconds: 0.5,endSeconds: 0.7))
        let refs = original.notes.map { VoiceNoteRevision(id: $0.id,revision: $0.revision) }
        _ = try await repo.saveDraft(.init(noteID: refs[0].id,text: "Unsaved change",intent: .protect,targetID: f.target.id,start: "0.1",end: "0.3",baseRevision: refs[0].revision))
        await #expect(throws: (any Error).self) { _ = try await repo.restructureCards(.init(id: UUID(),kind: .merge,parents: refs)) }
        let unchanged = try await repo.load(); #expect(unchanged.notes.count == original.notes.count && unchanged.cardOperations == nil)
        _ = try await repo.discardDraft(refs[0].id)
        _ = try await repo.edit(note: refs[0].id,expectedRevision: refs[0].revision,text: "Keep updated",intent: .protect,anchor: nil)
        await #expect(throws: (any Error).self) { _ = try await repo.restructureCards(.init(id: UUID(),kind: .merge,parents: refs)) }
        #expect(try await repo.load().notes.count == 2)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.target)) as? [String:Any])
        object["id"] = UUID().uuidString; object["versionID"] = UUID().uuidString; object["versionNumber"] = 2
        // A second synthetic saved-version folder, with real matching provenance.
        let cuts = f.project.folder.appendingPathComponent("cuts")
        try FileManager.default.copyItem(at: cuts.appendingPathComponent("v001"),to: cuts.appendingPathComponent("v002"))
        let other = try JSONDecoder().decode(VoiceReviewTarget.self,from: JSONSerialization.data(withJSONObject: object))
        _ = try await repo.register(other)
        let mixed = try await repo.addTyped(text: "Keep other version",action: .protect,anchor: .init(targetID: other.id,seconds: 0.9,endSeconds: 1.1))
        let cross = mixed.orderedVisibleNotes.suffix(2).map { VoiceNoteRevision(id: $0.id,revision: $0.revision) }
        await #expect(throws: (any Error).self) { _ = try await repo.restructureCards(.init(id: UUID(),kind: .merge,parents: cross)) }
        #expect(try await repo.load().notes.count == 3)
    }
    @Test func spokenOrderingIgnoresCompletionOrderAndEarlierNeedsResolution() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (repo,id,attempt) = try await speechFixture(f)
        _ = try await repo.speech(.init(segmentID: "late",text: "Keep second",isFinal: true,audioStart: 1.1,audioEnd: 1.3),session: id,attempt: attempt,now: Date(timeIntervalSince1970: 1))
        let result = try await repo.speech(.init(segmentID: "early",text: "Remove earlier section",isFinal: true,audioStart: 0.1,audioEnd: 0.3),session: id,attempt: attempt,now: Date(timeIntervalSince1970: 0))
        #expect(result.orderedVisibleNotes.map(\.segmentID) == ["early","late"])
        let note = result.orderedVisibleNotes[0]; #expect(note.state == .needsResolution && abs((note.onset?.seconds ?? -1)-0.1) < 0.000001)
        let resolved = try await repo.edit(note: note.id,expectedRevision: note.revision,text: note.text,intent: .change,anchor: .init(targetID: f.target.id,seconds: 0.8,endSeconds: 1),action: .remove)
        let saved = try #require(resolved.notes.first { $0.id == note.id })
        #expect(saved.onset == note.onset && saved.resolvedAnchor?.seconds == 0.8 && saved.issues.isEmpty)
    }
    @Test func legacyCardsAndNestedSplitsKeepCaptureOrder() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let (repo,id,attempt) = try await speechFixture(f)
        _ = try await repo.speech(.init(segmentID: "first",text: "Keep one. Keep two. Keep three.",isFinal: true,audioStart: 0.1,audioEnd: 0.8),session: id,attempt: attempt)
        var legacy = try await repo.speech(.init(segmentID: "later",text: "Keep later shot",isFinal: true,audioStart: 1.1,audioEnd: 1.3),session: id,attempt: attempt)
        for index in legacy.notes.indices { legacy.notes[index].captureOrdinal = nil }
        let parent = legacy.notes[0]
        try legacy.restructureCards(.init(id: UUID(),kind: .split,parents: [.init(id: parent.id,revision: parent.revision)],splitUTF16: "Keep one. Keep two.".utf16.count))
        #expect(legacy.orderedVisibleNotes.map(\.text) == ["Keep one. Keep two.","Keep three.","Keep later shot"])
        let first = legacy.orderedVisibleNotes[0]
        try legacy.restructureCards(.init(id: UUID(),kind: .split,parents: [.init(id: first.id,revision: first.revision)],splitUTF16: "Keep one.".utf16.count))
        #expect(legacy.orderedVisibleNotes.map(\.text) == ["Keep one.","Keep two.","Keep three.","Keep later shot"])
        let pair = legacy.orderedVisibleNotes.prefix(2).map { VoiceNoteRevision(id: $0.id,revision: $0.revision) }
        try legacy.restructureCards(.init(id: UUID(),kind: .merge,parents: pair))
        #expect(legacy.orderedVisibleNotes.map(\.text) == ["Keep one.\nKeep two.","Keep three.","Keep later shot"])
        try legacy.validateCardLineage()
        let encoder = JSONEncoder(), reopened = try JSONDecoder().decode(VoiceReviewDocument.self,from: encoder.encode(legacy))
        #expect(reopened.orderedVisibleNotes.map(\.id) == legacy.orderedVisibleNotes.map(\.id))
        try reopened.validateCardLineage()
    }

    @Test func restructuringInvalidatesPreparedAndInFlightCandidatesAndRetainsLateDraft() async throws {
        for prepared in [false,true] {
            let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
            let repo = try VoiceReviewRepository(project: f.project); _ = try await repo.register(f.target)
            _ = try await repo.addTyped(text: "Keep first",action: .protect,anchor: .init(targetID: f.target.id,seconds: 0.1,endSeconds: 0.3))
            _ = try await repo.addTyped(text: "Keep second",action: .protect,anchor: .init(targetID: f.target.id,seconds: 0.5,endSeconds: 0.7))
            let claim = try #require(try await repo.claim()), input = try await repo.candidateInput(claim)
            if prepared { _ = try await repo.complete(claim,directives: input) }
            let before = try await repo.load(), parent = before.notes[0]
            let request = VoiceCardRequest(id: UUID(),kind: .merge,parents: before.notes.map { .init(id: $0.id,revision: $0.revision) })
            let merged = try await repo.restructureCards(request)
            #expect(merged.candidates.first?.state == .superseded)
            _ = try await repo.complete(claim,directives: input)
            await #expect(throws: (any Error).self) { _ = try await repo.candidateInput(claim) }
            await #expect(throws: (any Error).self) { _ = try await repo.prepareEditPlan(claim.id) }
            // A delayed draft write is evidence only; it must survive reopening.
            let draft = VoiceTranscriptDraft(noteID: parent.id,text: "Late unsaved words",intent: .protect,targetID: f.target.id,start: "0.1",end: "0.3",baseRevision: parent.revision)
            _ = try await repo.saveDraft(draft)
            let reopened = try await VoiceReviewRepository(project: f.project).load()
            #expect(reopened.drafts?.first == draft && reopened.notes[0].state == .cancelled)
            #expect(reopened.orderedVisibleNotes.count == 1 && reopened.orderedVisibleNotes[0].state == .needsResolution)
            #expect(try await repo.claim() == nil)
        }
    }

    @MainActor @Test func immediateStructureThenQuitWaitsForDurableOperationAndDraftRecovery() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = try VoiceReviewRepository(project: f.project); _ = try await repo.register(f.target)
        _ = try await repo.addTyped(text: "Keep one. Keep two.",action: .protect,anchor: .init(targetID: f.target.id,seconds: 0.1,endSeconds: 0.3))
        let controller = try VoiceReviewController(project: f.project,provider: SyntheticVoiceReviewProvider(), steeringIdleInterval: 0); await controller.load()
        let parent = try #require(controller.document.notes.first)
        let request = VoiceCardRequest(id: UUID(),kind: .split,parents: [.init(id: parent.id,revision: parent.revision)],splitUTF16: "Keep one.".utf16.count)
        controller.restructureCards(request)
        #expect(controller.hasPendingWork)
        #expect(await controller.flushForExit())
        let reopened = try await VoiceReviewRepository(project: f.project).load()
        #expect(reopened.cardOperations == [request] && reopened.orderedVisibleNotes.count == 2)
        let draft = VoiceTranscriptDraft(noteID: parent.id,text: "Recover my late draft",intent: .protect,targetID: f.target.id,start: "0.1",end: "0.3",baseRevision: parent.revision)
        _ = try await repo.saveDraft(draft)
        let restored = try VoiceReviewController(project: f.project,provider: SyntheticVoiceReviewProvider(), steeringIdleInterval: 0); await restored.load()
        #expect(restored.visibleCards.contains { $0.id == parent.id } && restored.drafts[parent.id] == draft)
        restored.discardDraft(parent.id)
        #expect(await restored.flushForExit())
        #expect(!restored.visibleCards.contains { $0.id == parent.id })
    }

    @Test func committed611LedgerEnvelopeKeepsItsOriginalChecksum() throws {
        // Generated by the committed 6111011 encoder, not by the new model.
        let bytes = Data(#"{"document":{"candidates":[],"notes":[{"audioEnd":0.3,"audioStart":0.1,"created":2000,"history":[{"date":2000,"id":"EAA7F824-55F3-45C7-94E1-94E02A30854D","revision":1,"source":"Final ASR","text":"Keep original legacy words"}],"id":"B86A43EA-85A4-4D8A-BF32-CB37FB41900E","intent":"protect","isFinal":true,"issues":[],"manuallyEdited":false,"revision":1,"segmentID":"legacy","sessionID":"506EB6FD-A08B-4AC6-9515-DE13DE53C003","state":"provisional","text":"Keep original legacy words","transcript":"Keep original legacy words"}],"projectID":"C29FB5C7-4D3D-4ED2-9906-05223CE53256","revision":"C5058909-6500-436A-BAAC-955C3E135591","schemaVersion":1,"sequence":0,"sessions":[{"attemptID":"7548D38F-057E-475F-BB23-C777D79ADB33","audio":[],"created":1000,"deviceUID":"synthetic-legacy","events":[],"id":"506EB6FD-A08B-4AC6-9515-DE13DE53C003","locale":"en-US","ownerProcessID":0,"playhead":[],"state":"stopped"}],"targets":[]},"sha256":"52291b552d1149e08019a702941848c91fa36cb4f76f5de3db8213f0562be9f9"}"#.utf8)
        struct Envelope: Decodable { let sha256: String; let document: VoiceReviewDocument }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self,from: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        #expect(TranscriptSourceMap.sha(try encoder.encode(envelope.document)) == envelope.sha256)
        #expect(envelope.document.notes.first?.transcript == "Keep original legacy words")
        #expect(envelope.document.cardOperations == nil && envelope.document.notes.first?.capturePath == nil)
        try envelope.document.validateCardLineage()
    }

}
