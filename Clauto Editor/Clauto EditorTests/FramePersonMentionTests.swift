import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct FramePersonMentionTests {
    private func mention(_ text: String,name: String = "Alex",start: Int = 0,project: UUID = UUID(),person: UUID = UUID()) -> FramePersonMention {
        .init(id: UUID(),person: .init(projectID: project,personID: person,nameSnapshot: name,confirmedByUser: true),utf16Start: start,utf16Length: ("@"+name).utf16.count,noteSHA256: FramePersonMention.hash(text))
    }
    @Test func trailingQueriesKeepExactUnicodeWordsAndRefuseEmailsControlsAndOversizeInput() throws {
        let value = try #require(FramePersonMentionQuery.trailing(in: "🥖 Ask @Zoë Å"))
        #expect(value.query == "Zoë Å" && value.utf16Start == "🥖 Ask ".utf16.count)
        #expect(FramePersonMentionQuery.trailing(in: "@")?.query == "")
        for text in ["email@example.com","@@Alex","@Alex\n","@Alex\t",String(repeating: "a",count: 4096)+" @A","@"+String(repeating: "a",count: 161)] {
            #expect(FramePersonMentionQuery.trailing(in: text) == nil)
        }
    }
    @Test func editsShiftOnlyUnchangedTokensAndNeverKeepIntersectingOrAmbiguousMatches() throws {
        let text = "Keep @Alex visible", token = mention(text,start: 5)
        try token.validate(note: text)
        let before = try #require(FramePersonMention.rebased([token],from: text,to: "🥖 "+text)?.first)
        #expect(before.person == token.person && before.id == token.id && before.utf16Start == 8)
        try before.validate(note: "🥖 "+text)
        let after = try #require(FramePersonMention.rebased([token],from: text,to: text+" please")?.first)
        #expect(after.utf16Start == 5 && after.noteSHA256 != token.noteSHA256)
        try after.validate(note: text+" please")
        #expect(FramePersonMention.rebased([token],from: text,to: "Keep @Alec visible") == nil)
        #expect(FramePersonMention.rebased([token],from: text,to: "Keep visible") == nil)
        let repeated = "@Alex @Alex", first = mention(repeated)
        #expect(FramePersonMention.rebased([first],from: repeated,to: "@Alex") == nil)
        let second = mention(repeated,start: 6)
        #expect(FramePersonMention.rebased([second],from: repeated,to: "@Alex") == nil)
        let accented = "@Zoë", unicode = mention(accented,name: "Zoë")
        let decomposed = "@Zoe\u{308}"
        #expect(throws: (any Error).self) { try unicode.validate(note: decomposed) }
        #expect(FramePersonMention.rebased([unicode],from: accented,to: decomposed) == nil)
    }
    @Test func alteredHashesRangesWordsAndOverlappingTokensRefuse() throws {
        let text = "@Alex", token = mention(text)
        var altered = token; altered.noteSHA256 = String(repeating: "0",count: 64)
        #expect(throws: (any Error).self) { try altered.validate(note: text) }
        altered = token; altered.utf16Start = Int.max
        #expect(throws: (any Error).self) { try altered.validate(note: text) }
        #expect(throws: (any Error).self) { try token.validate(note: "@Alec") }
        let duplicate = mention(text)
        let region = FrameEllipse(id: UUID(),kind: .highlight,bounds: .init(x: 0,y: 0,width: 0.5,height: 0.5),note: text,mentions: [token,duplicate])
        #expect(throws: (any Error).self) { try region.validate(width: 100,height: 100) }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let plain = FrameEllipse(id: UUID(),kind: .ellipse,bounds: region.bounds,note: "Plain old note")
        let bytes = try encoder.encode(plain)
        #expect(!(String(decoding: bytes,as: UTF8.self).contains("mentions")))
        #expect(try decoder.decode(FrameEllipse.self,from: bytes) == plain)
    }
    @Test func editingOneMentionPreservesTheOtherPersonsExactIDAndUpdatedHash() throws {
        let old = "@Alex and @Zoë", first = mention(old), second = mention(old,name: "Zoë",start: "@Alex and ".utf16.count)
        let changed = "@Alec and @Zoë"
        let next = try #require(FramePersonMention.rebased([first,second],from: old,to: changed))
        #expect(next.count == 1 && next.first?.id == second.id && next.first?.person == second.person)
        try next[0].validate(note: changed)
        let moved = "🥖 "+changed
        let shifted = try #require(FramePersonMention.rebased(next,from: changed,to: moved)?.first)
        #expect(shifted.utf16Start == second.utf16Start+3 && shifted.person.personID == second.person.personID)
        try shifted.validate(note: moved)
    }
    @Test func expandingOrEmbeddingANameDropsItsEarlierIdentityEvenWithARehashedNote() throws {
        let old = "@Alex ", token = mention(old)
        for changed in ["@Alexandra ","x@Alex ","(@Alex ","@Alex, ","@Alex\u{301} ","@Alex-Guest "] {
            #expect(FramePersonMention.rebased([token],from: old,to: changed) == nil)
            var forged = token; forged.noteSHA256 = FramePersonMention.hash(changed)
            if let at = changed.range(of: "@Alex") { forged.utf16Start = changed[..<at.lowerBound].utf16.count }
            #expect(throws: (any Error).self) { try forged.validate(note: changed) }
        }
        for changed in [old+"stays", "Keep "+old, "\n"+old, old+"\n"] {
            let retained = try #require(FramePersonMention.rebased([token],from: old,to: changed)?.first)
            #expect(retained.id == token.id && retained.person == token.person)
            try retained.validate(note: changed)
        }
        #expect(FramePersonMention.rebased([token],from: old,to: "\n"+old+"\n") == nil)
    }
    @Test func everyUTF16OffsetMustBeAWholeCharacterBoundaryBeforeValidationCanIndex() throws {
        for prefix in ["🥖 ","👩‍🍳 ","🇳🇱 ","✋🏽 ","e\u{301} ","👨‍👩‍👧‍👦 "] {
            let note = prefix+"@Alex ", valid = mention(note,start: prefix.utf16.count)
            try valid.validate(note: note)
            for start in 0...note.utf16.count {
                for length in 0...(note.utf16.count-start) {
                    let candidate = FramePersonMention(id: UUID(),person: valid.person,utf16Start: start,utf16Length: length,noteSHA256: valid.noteSHA256)
                    if start == valid.utf16Start && length == valid.utf16Length { try candidate.validate(note: note) }
                    else { #expect(throws: (any Error).self) { try candidate.validate(note: note) } }
                }
            }
        }
        let note = "🥖 @Alex ", broken = FramePersonMention(id: UUID(),person: mention(note).person,utf16Start: 1,utf16Length: 5,noteSHA256: FramePersonMention.hash(note))
        #expect(throws: (any Error).self) { try broken.validate(note: note) }
        let old = "@Alex ", token = mention(old)
        let oversized = old+String(repeating: "x",count: 4097)
        #expect(FramePersonMention.rebased([token],from: old,to: oversized) == nil)
        #expect(throws: (any Error).self) { try token.validate(note: oversized) }
    }
    @MainActor @Test func duplicateNameChoicePinsTheOriginalRegionAndSurvivesUndoResizeAndProfileRename() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let repo = ProjectPeopleRepository(project: f.project), first = try await repo.create(name: "Alex"), second = try await repo.create(name: "Alex")
        let people = try await repo.load(), draft = FrameCommentDraft(request: frame.request,frame: frame)
        #expect(Set(people.mentionMatches("Al").map(\.id)) == [first.id,second.id])
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.2,height: 0.3),kind: .highlight)
        let original = try #require(draft.selectedShapeID)
        try draft.updateRegion(original,tag: "Hands",note: "🥖 Keep @Al")
        let query = try #require(FramePersonMentionQuery.trailing(in: "🥖 Keep @Al"))
        try draft.add(.init(x: 0.5,y: 0.5,width: 0.2,height: 0.3),kind: .ellipse)
        let other = try #require(draft.selectedShapeID)
        let reference = ProjectPersonReference(projectID: f.project.id,personID: second.id,nameSnapshot: "Alex",confirmedByUser: true)
        try draft.insertMention(reference,query: query,region: original,in: people)
        #expect(draft.selectedShapeID == other && draft.history.shapes.last?.mentions == nil)
        let marked = try #require(draft.history.shapes.first)
        #expect(marked.note == "🥖 Keep @Alex " && marked.mentions?.first?.person.personID == second.id)
        #expect(marked.person == nil) // Mentioning a person does not identify pixels.
        draft.undo(); #expect(draft.history.shapes.first?.note == "🥖 Keep @Al" && draft.history.shapes.first?.mentions == nil)
        draft.redo(); #expect(draft.history.shapes.first?.mentions == marked.mentions)
        draft.selectedShapeID = original; try draft.resizeSelected(.init(x: 0.2,y: 0.2,width: 0.2,height: 0.3))
        #expect(draft.history.shapes.first?.mentions == marked.mentions)
        let store = FrameCommentRepository(project: f.project), saved = try await store.save(frame: frame,text: "",annotations: draft.history.shapes,id: draft.id)
        _ = try await repo.rename(second.id,name: "Presenter")
        #expect(try await store.read(saved.id).0.annotations.first?.mentions == marked.mentions)
        try FileManager.default.removeItem(at: f.project.folder.appendingPathComponent(".clauto/people.json"))
        let retry = try await store.save(frame: frame,text: "",annotations: saved.annotations,id: saved.id)
        #expect(retry.id == saved.id && retry.request == saved.request && retry.annotations == saved.annotations)
    }
    @MainActor @Test func staleQueriesDeletedRegionsAndForeignChoicesLeaveEveryDraftWordIntact() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let repo = ProjectPeopleRepository(project: f.project), person = try await repo.create(name: "Alex"), people = try await repo.load()
        let draft = FrameCommentDraft(request: frame.request,frame: frame)
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.3,height: 0.3),kind: .ellipse)
        let region = try #require(draft.selectedShapeID), ref = ProjectPersonReference(projectID: f.project.id,personID: person.id,nameSnapshot: "Alex",confirmedByUser: true)
        try draft.updateRegion(region,tag: "",note: "Keep @Al")
        let query = try #require(FramePersonMentionQuery.trailing(in: "Keep @Al"))
        try draft.updateRegion(region,tag: "",note: "Keep @Al and these newer words")
        let snapshot = draft.history.shapes
        #expect(throws: (any Error).self) { try draft.insertMention(ref,query: query,region: region,in: people) }
        #expect(draft.history.shapes == snapshot)
        try draft.removeSelected()
        #expect(throws: (any Error).self) { try draft.insertMention(ref,query: query,region: region,in: people) }
        #expect(draft.history.shapes.isEmpty)
        try draft.add(.init(x: 0.1,y: 0.1,width: 0.3,height: 0.3),kind: .ellipse)
        let next = try #require(draft.selectedShapeID); try draft.updateRegion(next,tag: "",note: query.note)
        let forged = ProjectPersonReference(projectID: UUID(),personID: person.id,nameSnapshot: "Alex",confirmedByUser: true)
        #expect(throws: (any Error).self) { try draft.insertMention(forged,query: query,region: next,in: people) }
        #expect(draft.history.shapes.first?.note == query.note && draft.history.shapes.first?.mentions == nil)
    }
    @Test func validTextHashesCannotInventRosterReferencesOrAuthorizeVideoChanges() async throws {
        let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
        let frame = try await ReviewFrameCaptureService().capture(f.request(),project: f.project)
        let store = FrameCommentRepository(project: f.project)
        let region = FrameEllipse(id: UUID(),kind: .highlight,bounds: .init(x: 0.1,y: 0.1,width: 0.3,height: 0.3),note: "@Alex",mentions: [mention("@Alex",project: f.project.id)])
        await #expect(throws: (any Error).self) { _ = try await store.save(frame: frame,text: "",annotations: [region]) }
        #expect(try await store.list().isEmpty)
        #expect(try VoiceReviewProvenance.inspect(f.target.preview.relativePath,project: f.project).sha256 == f.target.preview.sha256)
    }
}
