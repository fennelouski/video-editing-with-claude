import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct VoiceSpeechIdeaTests {
    private func fixture(clock: Bool = true) async throws -> (FrameReviewFixture,VoiceReviewRepository,UUID,UUID) {
        let f = try await FrameReviewFixture.make(), repo = try VoiceReviewRepository(project: f.project)
        _ = try await repo.register(f.target)
        let id = UUID(), attempt = UUID(), epoch = UUID()
        _ = try await repo.begin(id: id,attempt: attempt,deviceUID: "synthetic",locale: "en-US")
        _ = try await repo.observe(session: id,host: 100,seconds: 0.4,rate: 0,target: f.target.id,epoch: epoch,kind: .pause)
        _ = try await repo.observe(session: id,host: 105,seconds: 0.4,rate: 0,target: f.target.id,epoch: epoch,kind: .sample)
        if clock { _ = try await repo.captured(session: id,attempt: attempt,audioStart: 0,duration: 5,hostStart: 100) }
        return (f,repo,id,attempt)
    }
    private func result(_ pieces: [String],times: [(Double,Double)],final: Bool = true) -> VoiceSpeechResult {
        var offset = 0
        let runs = zip(pieces,times).map { text,time -> VoiceSpeechRun in
            defer { offset += text.utf16.count }
            return .init(utf16Start: offset,utf16Length: text.utf16.count,audioStart: time.0,audioEnd: time.1)
        }
        return .init(segmentID: "utterance",text: pieces.joined(),isFinal: final,audioStart: times.first!.0,audioEnd: times.last!.1,runs: runs)
    }
    @Test func finalCardsFollowReportedSilenceWithOriginalWordsAndNoDuplicateRetry() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let event = result(["Keep café 🎥. ","Keep the second detail."],times: [(0.2,0.6),(2,2.4)])
        var partial = event; partial = .init(segmentID: event.segmentID,text: event.text,isFinal: false,audioStart: event.audioStart,audioEnd: event.audioEnd,runs: event.runs)
        let provisional = try await repo.speech(partial,session: id,attempt: attempt)
        #expect(provisional.notes.count == 1 && provisional.notes[0].state == .provisional)
        #expect(try await repo.claim() == nil)
        let final = try await repo.speech(event,session: id,attempt: attempt)
        #expect(final.orderedVisibleNotes.map(\.text) == ["Keep café 🎥.","Keep the second detail."])
        #expect(final.notes.allSatisfy { $0.isFinal && $0.transcript == event.text && $0.issues.isEmpty && $0.action == nil })
        #expect(final.notes.map(\.audioStart) == [0.2,2] && final.notes.map(\.audioEnd) == [0.6,2.4])
        #expect(final.notes[0].speechSource?.runs == event.runs && final.notes[1].speechSourceID == final.notes[0].id)
        let retry = try await repo.speech(event,session: id,attempt: attempt)
        #expect(retry.notes.map(\.id) == final.notes.map(\.id))
        let reopened = try await VoiceReviewRepository(project: f.project).load()
        #expect(reopened.notes[0].speechSource?.text == event.text)
        #expect(reopened.notes[0].speechSource?.cardIDs == final.notes.map(\.id))
    }
    @Test func delayedClockGroupsFinalOnlyAfterCoverageAndNeverAfterManualEdit() async throws {
        for edited in [false,true] {
            let (f,repo,id,attempt) = try await fixture(clock: false); defer { try? FileManager.default.removeItem(at: f.root) }
            let event = result(["Keep first. ","Keep second."],times: [(0.2,0.6),(2,2.4)])
            let waiting = try await repo.speech(event,session: id,attempt: attempt), note = try #require(waiting.notes.first)
            #expect(waiting.notes.count == 1 && note.state == .needsResolution && note.speechSource?.pending == true)
            if edited { _ = try await repo.edit(note: note.id,expectedRevision: note.revision,text: "Keep my explicit edit",intent: .protect,anchor: .init(targetID: f.target.id,seconds: 0.1,endSeconds: 0.3),action: .protect) }
            let final = try await repo.captured(session: id,attempt: attempt,audioStart: 0,duration: 5,hostStart: 100)
            if edited { #expect(final.notes.count == 1 && final.notes[0].text == "Keep my explicit edit" && final.notes[0].speechSource?.pending == false) }
            else { #expect(final.notes.count == 2 && final.notes[0].revision > note.revision && final.notes.allSatisfy { $0.issues.isEmpty }) }
        }
    }
    @Test func topicCueUsesRealRunBoundaryAndDoesNotInventAnInteriorWordTime() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let event = result(["Keep first. ","Next ","point: keep detail."],times: [(0.2,0.6),(0.7,0.8),(0.8,1.2)])
        let cards = try await repo.speech(event,session: id,attempt: attempt)
        #expect(cards.notes.map(\.text) == ["Keep first.","Next point: keep detail."])
        #expect(cards.notes[1].audioStart == 0.7 && cards.notes[1].state == .needsResolution) // Meaning is explicit, not guessed from the cue.
        let single = result(["Keep first. Next point: keep detail."],times: [(0.2,1.2)])
        var raw = VoiceReviewDocument(projectID: f.project.id); raw.sessions = cards.sessions; raw.targets = cards.targets
        try raw.speech(single,sessionID: id,attemptID: attempt,now: Date())
        #expect(raw.notes.count == 1 && raw.notes[0].audioStart == 0.2)
    }
    @Test func seekBetweenRunsSplitsButSeekInsideRunRequiresResolution() async throws {
        for split in [false,true] {
            let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
            let repo = try VoiceReviewRepository(project: f.project); _ = try await repo.register(f.target)
            let id = UUID(), attempt = UUID(), a = UUID(), b = UUID(), c = UUID()
            _ = try await repo.begin(id: id,attempt: attempt,deviceUID: "synthetic",locale: "en-US")
            _ = try await repo.captured(session: id,attempt: attempt,audioStart: 0,duration: 5,hostStart: 100)
            _ = try await repo.observe(session: id,host: 100,seconds: 0.2,rate: 0,target: f.target.id,epoch: a,kind: .pause)
            _ = try await repo.observe(session: id,host: 100.7,seconds: 0.2,rate: 0,target: f.target.id,epoch: a,kind: .sample)
            _ = try await repo.observe(session: id,host: 100.8,seconds: 0.2,rate: 0,target: nil,epoch: b,kind: .seekRequested)
            _ = try await repo.observe(session: id,host: 101,seconds: 0.8,rate: 0,target: f.target.id,epoch: c,kind: .seekCompleted)
            _ = try await repo.observe(session: id,host: 105,seconds: 0.8,rate: 0,target: f.target.id,epoch: c,kind: .sample)
            let event = split ? result(["Keep first. ","Keep second."],times: [(0.2,0.6),(1.1,1.4)]) : result(["Keep first and second."],times: [(0.2,1.4)])
            let cards = try await repo.speech(event,session: id,attempt: attempt)
            if split {
                #expect(cards.notes.count == 2 && cards.notes.allSatisfy { $0.issues.isEmpty })
                #expect(cards.notes.map { $0.onset?.seconds } == [0.2,0.8])
            } else { #expect(cards.notes.count == 1 && cards.notes[0].state == .needsResolution) }
        }
    }
    @Test func incompleteOverlappingAndUnicodeBrokenRunsKeepRawTextUnresolved() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let event = result(["Keep 🎥. ","Keep second."],times: [(0.2,0.6),(2,2.4)])
        let cases: [[VoiceSpeechRun]] = [[],Array(event.runs!.prefix(1)),
            [.init(utf16Start: 0,utf16Length: 6,audioStart: 0.2,audioEnd: 0.6),.init(utf16Start: 6,utf16Length: event.text.utf16.count-6,audioStart: 2,audioEnd: 2.4)],
            [.init(utf16Start: 0,utf16Length: event.text.utf16.count,audioStart: .nan,audioEnd: 2.4)],
            [.init(utf16Start: 0,utf16Length: 9,audioStart: 0.2,audioEnd: 2.1),.init(utf16Start: 9,utf16Length: event.text.utf16.count-9,audioStart: 2,audioEnd: 2.4)]]
        for runs in cases {
            var doc = VoiceReviewDocument(projectID: f.project.id); let baseline = try await repo.load(); doc.sessions = baseline.sessions; doc.targets = baseline.targets
            var bad = event; bad.runs = runs
            try doc.speech(bad,sessionID: id,attemptID: attempt,now: Date())
            #expect(doc.notes.count == 1 && doc.notes[0].text == event.text && doc.notes[0].state == .needsResolution)
            #expect(doc.notes[0].speechTimingIssue != nil)
            _ = try JSONEncoder().encode(doc) // Nonfinite provider metadata cannot discard the words.
        }
    }
    @Test func lateASRAfterManualStructureNeverCreatesNewIdeaSiblings() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let event = result(["Keep first. ","Keep second."],times: [(0.2,0.6),(2,2.4)])
        let before = try await repo.speech(event,session: id,attempt: attempt)
        let merged = try await repo.restructureCards(.init(id: UUID(),kind: .merge,parents: before.notes.map { .init(id: $0.id,revision: $0.revision) }))
        #expect(merged.orderedVisibleNotes.first?.transcript == event.text)
        let late = try await repo.speech(result(["Keep first revised. ","Keep second revised."],times: [(0.2,0.6),(2,2.4)]),session: id,attempt: attempt)
        #expect(late.notes.count == merged.notes.count && late.orderedVisibleNotes.map(\.id) == merged.orderedVisibleNotes.map(\.id))
        #expect(late.notes[0].history.last?.text == "Keep first revised. Keep second revised.")
    }
    @Test func missingCapturedPacketsNeverMasqueradeAsSilence() async throws {
        let (f,repo,id,attempt) = try await fixture(clock: false); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await repo.captured(session: id,attempt: attempt,audioStart: 0,duration: 1,hostStart: 100)
        _ = try await repo.captured(session: id,attempt: attempt,audioStart: 2,duration: 1,hostStart: 102)
        let event = result(["Keep first. ","Keep second."],times: [(0.2,0.6),(2,2.4)])
        let waiting = try await repo.speech(event,session: id,attempt: attempt)
        #expect(waiting.notes.count == 1 && waiting.notes[0].text == event.text && waiting.notes[0].state == .needsResolution)
        #expect(try await repo.claim() == nil)
    }

    @Test func shiftedFirstRunNeverReanchorsAnExistingPartialAndWrongAttemptIsIgnored() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = VoiceSpeechResult(segmentID: "utterance",text: "Keep original",isFinal: false,audioStart: 0.1,audioEnd: 0.8)
        let before = try await repo.speech(original,session: id,attempt: attempt)
        let shifted = VoiceSpeechResult(segmentID: "utterance",text: "Keep original",isFinal: true,audioStart: 0.1,audioEnd: 0.8,runs: [.init(utf16Start: 0,utf16Length: "Keep original".utf16.count,audioStart: 0.3,audioEnd: 0.8)])
        let ignored = try await repo.speech(result(["Keep foreign. ","Keep wrong attempt."],times: [(0.2,0.6),(2,2.4)]),session: id,attempt: UUID())
        #expect(ignored.notes.count == before.notes.count && ignored.notes[0].text == before.notes[0].text && !ignored.notes[0].isFinal)
        let after = try await repo.speech(shifted,session: id,attempt: attempt)
        #expect(after.notes.count == 1 && after.notes[0].onset == before.notes[0].onset && after.notes[0].state == .needsResolution)
        #expect(after.notes[0].speechTimingIssue != nil && after.notes[0].speechSource?.runs == shifted.runs)
    }

    @Test func stoppedSessionAndWrongAttemptLeaveExistingCardEvidenceUnchanged() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let event = result(["Keep original. ","Keep second."],times: [(0.2,0.6),(2,2.4)],final: false)
        _ = try await repo.speech(event,session: id,attempt: attempt)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(try await repo.load().notes)
        for final in [false,true] {
            let late = result(["Keep foreign. ","Keep foreign second."],times: [(0.2,0.6),(2,2.4)],final: final)
            _ = try await repo.speech(late,session: id,attempt: UUID())
            #expect(try encoder.encode(try await repo.load().notes) == original)
        }
        let stopped = try await repo.end(session: id,state: .stopped), stoppedBytes = try encoder.encode(stopped.notes)
        for final in [false,true] {
            let late = result(["Keep original. ","Keep second."],times: [(0.2,0.6),(2,2.4)],final: final)
            _ = try await repo.speech(late,session: id,attempt: attempt)
            #expect(try encoder.encode(try await repo.load().notes) == stoppedBytes)
        }
        #expect(try await VoiceReviewRepository(project: f.project).load().notes.count == 1)
    }

    @Test func validFinalClearsOldTimingErrorAndHistoryLimitRetainsFinalWords() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var partial = result(["Keep first. ","Keep second."],times: [(0.2,0.6),(2,2.4)],final: false)
        partial.runs = Array(repeating: .init(utf16Start: 0,utf16Length: 1,audioStart: 0.2,audioEnd: 0.3),count: 4_097)
        let bad = try await repo.speech(partial,session: id,attempt: attempt)
        #expect(bad.notes[0].speechTimingIssue != nil)
        let event = result(["Keep first. ","Keep second."],times: [(0.2,0.6),(2,2.4)])
        let final = try await repo.speech(event,session: id,attempt: attempt)
        #expect(final.notes.count == 2 && final.notes.allSatisfy { $0.speechTimingIssue == nil && $0.issues.isEmpty })
        var full = bad
        let entry = try #require(full.notes[0].history.first)
        full.notes[0].history = (0..<511).map { _ in .init(date: entry.date,source: entry.source,text: entry.text,revision: 1) }
        try full.speech(event,sessionID: id,attemptID: attempt,now: Date())
        #expect(full.notes.count == 1 && full.notes[0].isFinal && full.notes[0].text == event.text && full.notes[0].history.count == 512)
        #expect(full.notes[0].speechTimingIssue?.contains("history limit") == true && full.notes[0].state == .needsResolution)
    }
    @Test func bothLateAudioAndLateTransportWaitBeforeChoosingInterRunBoundary() async throws {
        for audioFirst in [false,true] {
            let f = try await FrameReviewFixture.make(); defer { try? FileManager.default.removeItem(at: f.root) }
            let repo = try VoiceReviewRepository(project: f.project); _ = try await repo.register(f.target)
            let id = UUID(), attempt = UUID(), a = UUID(), b = UUID(), c = UUID()
            _ = try await repo.begin(id: id,attempt: attempt,deviceUID: "synthetic",locale: "en-US")
            _ = try await repo.observe(session: id,host: 100,seconds: 0.2,rate: 0,target: f.target.id,epoch: a,kind: .pause)
            let event = result(["Keep first. ","Keep second."],times: [(0.2,0.6),(1.1,1.4)])
            let waiting = try await repo.speech(event,session: id,attempt: attempt)
            #expect(waiting.notes.count == 1 && waiting.notes[0].speechSource?.pending == true)
            if audioFirst { _ = try await repo.captured(session: id,attempt: attempt,audioStart: 0,duration: 5,hostStart: 100) }
            _ = try await repo.observe(session: id,host: 100.7,seconds: 0.2,rate: 0,target: f.target.id,epoch: a,kind: .sample)
            _ = try await repo.observe(session: id,host: 100.8,seconds: 0.2,rate: 0,target: nil,epoch: b,kind: .seekRequested)
            _ = try await repo.observe(session: id,host: 101,seconds: 0.8,rate: 0,target: f.target.id,epoch: c,kind: .seekCompleted)
            _ = try await repo.observe(session: id,host: 105,seconds: 0.8,rate: 0,target: f.target.id,epoch: c,kind: .sample)
            if !audioFirst { _ = try await repo.captured(session: id,attempt: attempt,audioStart: 0,duration: 5,hostStart: 100) }
            let final = try await repo.load()
            #expect(final.notes.count == 2 && final.notes.allSatisfy { $0.issues.isEmpty })
            #expect(final.notes.map { $0.onset?.seconds } == [0.2,0.8])
        }
    }

    @Test func changedMissingAndNonfiniteFinalHeadersRetainWordsAndOriginalOnset() async throws {
        for start: Double? in [0.3,nil,.nan] {
            let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let partial = VoiceSpeechResult(segmentID: "utterance",text: "Keep partial",isFinal: false,audioStart: 0.2,audioEnd: 0.8)
            let before = try await repo.speech(partial,session: id,attempt: attempt)
            let final = VoiceSpeechResult(segmentID: "utterance",text: "Keep all final original words",isFinal: true,audioStart: start,audioEnd: 0.8,runs: [.init(utf16Start: 0,utf16Length: "Keep all final original words".utf16.count,audioStart: 0.3,audioEnd: 0.8)])
            let after = try await repo.speech(final,session: id,attempt: attempt)
            #expect(after.notes.count == 1 && after.notes[0].isFinal && after.notes[0].text == final.text)
            #expect(after.notes[0].audioStart == 0.2 && after.notes[0].onset == before.notes[0].onset && after.notes[0].state == .needsResolution)
            #expect(after.notes[0].speechSource?.text == final.text && after.notes[0].speechTimingIssue?.contains("original speech onset") == true)
            #expect(try await VoiceReviewRepository(project: f.project).load().notes[0].text == final.text)
        }
    }

    @Test func mergeKeepsIdenticalWordsFromSeparateUtterancesAsSeparateEvidence() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await repo.speech(.init(segmentID: "one",text: "Keep the same words",isFinal: true,audioStart: 0.2,audioEnd: 0.6),session: id,attempt: attempt)
        let before = try await repo.speech(.init(segmentID: "two",text: "Keep the same words",isFinal: true,audioStart: 2,audioEnd: 2.4),session: id,attempt: attempt)
        let merged = try await repo.restructureCards(.init(id: UUID(),kind: .merge,parents: before.notes.map { .init(id: $0.id,revision: $0.revision) }))
        #expect(merged.orderedVisibleNotes.first?.transcript == "Keep the same words\nKeep the same words")
    }

    @Test func silenceThresholdDoesNotDependOnFloatingPointSubtractionOrigin() async throws {
        let (f,repo,id,attempt) = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let baseline = try await repo.load()
        for times in [[(0.1,0.2),(1.4,1.6)],[(0.2,0.6),(1.8,2.1)],[(2.0,2.2),(3.4,3.6)]] {
            var doc = baseline
            try doc.speech(result(["Keep one. ","Keep two."],times: times),sessionID: id,attemptID: attempt,now: Date())
            #expect(doc.notes.count == 2)
        }
        var below = baseline
        try below.speech(result(["Keep one. ","Keep two."],times: [(0.1,0.2),(1.39999,1.6)]),sessionID: id,attemptID: attempt,now: Date())
        #expect(below.notes.count == 1)
    }

}
