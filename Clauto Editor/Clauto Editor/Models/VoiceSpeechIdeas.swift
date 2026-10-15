import Foundation

/// Provider evidence is on the analyzer's converted audio clock. A run may
/// contain several words; no timestamp is interpolated inside it.
struct VoiceSpeechRun: Codable, Equatable, Sendable {
    let utf16Start: Int
    let utf16Length: Int
    let audioStart: Double?
    let audioEnd: Double?
}
struct VoiceSpeechSource: Codable, Sendable {
    let segmentID: String
    let text: String
    let audioStart: Double?
    let audioEnd: Double?
    let runs: [VoiceSpeechRun]?
    var pending: Bool
    var cardIDs: [UUID]?
}

extension VoiceReviewDocument {

    func validateSpeechSources() throws {
        for note in notes {
            if let source = note.speechSource {
                guard note.speechSourceID == nil, source.segmentID == note.segmentID,
                      source.text == note.transcript, source.text.count <= 20_000,
                      (source.runs ?? []).count <= 4_096,
                      (!source.pending || note.isFinal), (source.cardIDs ?? []).count <= 64,
                      Set(source.cardIDs ?? []).count == (source.cardIDs ?? []).count else { throw ProjectFailure.invalidProject }
                if let ids = source.cardIDs {
                    guard !source.pending, ids.first == note.id else { throw ProjectFailure.invalidProject }
                    for id in ids.dropFirst() {
                        guard notes.contains(where: { $0.id == id && $0.speechSourceID == note.id && $0.transcript == source.text }) else { throw ProjectFailure.invalidProject }
                    }
                }
            }
            if let root = note.speechSourceID {
                guard root != note.id, let source = notes.first(where: { $0.id == root })?.speechSource,
                      source.cardIDs?.contains(note.id) == true else { throw ProjectFailure.invalidProject }
            }
        }
    }

    mutating func speech(_ result: VoiceSpeechResult,sessionID: UUID,attemptID: UUID,now: Date) throws {
        guard sessions.contains(where: { $0.id == sessionID && $0.attemptID == attemptID && [.recording,.finishing,.retrying].contains($0.state) }) else { return }
        // A late result cannot create siblings after any explicit edit/retirement.
        if let note = notes.first(where: { $0.sessionID == sessionID && $0.segmentID == result.segmentID }),
           note.isFinal || note.manuallyEdited || note.state == .cancelled {
            try storeSpeech(result,sessionID: sessionID,attemptID: attemptID,now: now); return
        }
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0:nil } }
        let safeRuns = result.runs.flatMap { runs -> [VoiceSpeechRun]? in
            guard runs.count <= 4_096 else { return nil }
            return runs.map { .init(utf16Start: $0.utf16Start,utf16Length: $0.utf16Length,audioStart: finite($0.audioStart),audioEnd: finite($0.audioEnd)) }
        }
        let safe = VoiceSpeechResult(segmentID: result.segmentID,text: result.text,isFinal: result.isFinal,
            audioStart: finite(result.audioStart),audioEnd: finite(result.audioEnd))
        let old = notes.first(where: { $0.sessionID == sessionID && $0.segmentID == result.segmentID })
        let headerChanged = old.map { $0.audioStart != safe.audioStart } ?? false
        let capturedStart = old.map(\.audioStart) ?? safe.audioStart
        let admitted = VoiceSpeechResult(segmentID: safe.segmentID,text: safe.text,isFinal: safe.isFinal,audioStart: capturedStart,audioEnd: safe.audioEnd)
        try storeSpeech(admitted,sessionID: sessionID,attemptID: attemptID,now: now,refreshNow: false)
        guard let index = notes.firstIndex(where: { $0.sessionID == sessionID && $0.segmentID == result.segmentID }) else { return }
        notes[index].speechTimingIssue = nil
        notes[index].speechSource = .init(segmentID: result.segmentID,text: result.text,audioStart: safe.audioStart,audioEnd: safe.audioEnd,runs: safeRuns,pending: result.isFinal && result.runs != nil)
        if headerChanged {
            notes[index].speechTimingIssue = "Recognition changed its original speech onset. Final words and the original anchor are retained; confirm the exact range."
            notes[index].speechSource?.pending = false
        } else if result.runs != nil && safeRuns == nil {
            notes[index].speechTimingIssue = "Speech timing exceeded its safe limit. Original words are retained; confirm the exact range."
            notes[index].speechSource?.pending = false
        }
        refresh()
    }

    /// Revisited when either audio-clock or transport packets arrive after ASR.
    /// Work is staged in memory; failure preserves the complete original card.
    mutating func resolveSpeechIdeas() {
        let ids = notes.filter { $0.speechSource?.pending == true }.map(\.id)
        for id in ids {
            guard let index = notes.firstIndex(where: { $0.id == id }), let source = notes[index].speechSource else { continue }
            if notes[index].manuallyEdited || notes[index].state == .cancelled {
                notes[index].speechSource?.pending = false; continue
            }
            do {
                let runs = try Self.checkedRuns(source)
                guard let capturedStart = notes[index].audioStart, let originalStart = source.audioStart,
                      abs(capturedStart-originalStart) <= 0.000002 else { throw ProjectFailure.invalidProject }
                guard let session = sessions.first(where: { $0.id == notes[index].sessionID }),
                      let start = source.audioStart, let end = source.audioEnd,
                      let host = session.hostRange(start: start,end: end),
                      session.playhead.contains(where: { $0.confirmedThrough >= host.1-0.000001 }) else { continue }
                let groups = Self.ideaGroups(runs,source: source,session: session)
                var copy = self
                try copy.applyIdeas(groups,to: id,source: source)
                self = copy
            } catch {
                notes[index].speechSource?.pending = false
                notes[index].speechTimingIssue = (error as? WorkflowFailure)?.localizedDescription ?? "Word timing is incomplete or inconsistent. Original words are retained; confirm the exact range."
            }
        }
    }
    private static func checkedRuns(_ source: VoiceSpeechSource) throws -> [VoiceSpeechRun] {
        guard let start = source.audioStart, let end = source.audioEnd, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= 86_400, let runs = source.runs, !runs.isEmpty, runs.count <= 4_096 else { throw ProjectFailure.invalidProject }
        var cursor = 0, audio = start
        let text = source.text
        for run in runs {
            guard run.utf16Start == cursor, run.utf16Length > 0, run.utf16Length <= text.utf16.count-cursor,
                  let a = run.audioStart, let b = run.audioEnd, a.isFinite, b.isFinite,
                  a >= audio-0.000002, b > a, a >= start-0.000002, b <= end+0.000002 else { throw ProjectFailure.invalidProject }
            let lower = String.Index(utf16Offset: cursor,in: text), upper = String.Index(utf16Offset: cursor+run.utf16Length,in: text)
            guard (lower == text.endIndex || text.indices.contains(lower)), (upper == text.endIndex || text.indices.contains(upper)),
                  lower.utf16Offset(in: text) == cursor, upper.utf16Offset(in: text) == cursor+run.utf16Length else { throw ProjectFailure.invalidProject }
            cursor += run.utf16Length; audio = b
        }
        guard cursor == text.utf16.count, let first = runs.first?.audioStart,
              abs(first-start) <= 0.000002 else { throw ProjectFailure.invalidProject }
        return runs
    }
    private static func runText(_ run: VoiceSpeechRun,in text: String) -> String {
        let a = String.Index(utf16Offset: run.utf16Start,in: text), b = String.Index(utf16Offset: run.utf16Start+run.utf16Length,in: text)
        return String(text[a..<b])
    }
    private static func ideaGroups(_ runs: [VoiceSpeechRun],source: VoiceSpeechSource,session: VoiceReviewSession) -> [[VoiceSpeechRun]] {
        var groups: [[VoiceSpeechRun]] = [[]]
        for (position,run) in runs.enumerated() {
            if let previous = groups.last?.last, let end = previous.audioEnd, let start = run.audioStart {
                let gap = start-end
                // Continuous captured-clock coverage establishes an actual gap.
                let host = gap > 0 ? session.hostRange(start: end,end: start):nil
                let leftHost = session.hostRange(start: previous.audioStart!,end: end)?.1
                let rightHost = session.hostRange(start: start,end: run.audioEnd!)?.0
                let boundary = leftHost.flatMap { a in rightHost.map { b in session.events.contains { $0.hostTime >= a-0.000001 && $0.hostTime <= b+0.000001 } } } ?? false
                let left = runText(previous,in: source.text).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = runs[position...].prefix(8).map { runText($0,in: source.text) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                let cue = right.range(of: #"^(another point|next point|separately|moving on)\b"#,options: [.regularExpression,.caseInsensitive]) != nil
                let topic = cue && left.last.map { ".!?".contains($0) } == true
                if (gap >= 1.2-0.000000001 && host != nil) || boundary || topic { groups.append([]) }
            }
            groups[groups.count-1].append(run)
        }
        return groups
    }
    private mutating func applyIdeas(_ groups: [[VoiceSpeechRun]],to id: UUID,source: VoiceSpeechSource) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }), !groups.isEmpty else { throw ProjectFailure.invalidProject }
        guard groups.count <= 64, notes.count+groups.count-1 <= 10_000, notes[index].history.count < 512 else {
            throw WorkflowFailure.invalid("Idea grouping reached this review's card/history limit. Final original words are retained; confirm the exact range.")
        }
        let original = notes[index], sessionID = original.sessionID
        var ids: [UUID] = []
        for (part,runs) in groups.enumerated() {
            guard let first = runs.first, let last = runs.last else { throw ProjectFailure.invalidProject }
            let text = runs.map { Self.runText($0,in: source.text) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ProjectFailure.invalidProject }
            let cardIndex: Int
            if part == 0 {
                cardIndex = index
                if notes[index].text != text || notes[index].audioEnd != last.audioEnd { notes[index].revision += 1 }
                notes[index].text = text; notes[index].audioEnd = last.audioEnd; notes[index].intent = .infer(text)
            } else {
                let identity = sessionID.uuidString+":"+source.segmentID+":"+String(first.utf16Start)
                let segment = "idea-"+TranscriptSourceMap.sha(Data(identity.utf8))
                guard !notes.contains(where: { $0.sessionID == sessionID && $0.segmentID == segment }) else { throw ProjectFailure.invalidProject }
                var child = VoiceReviewNote(id: UUID(),sessionID: sessionID,segmentID: segment,audioStart: first.audioStart,audioEnd: last.audioEnd,created: original.created,transcript: source.text,text: text,isFinal: true,intent: .infer(text))
                child.captureOrdinal = captureOrder(child,fallback: notes.count); child.speechSourceID = id
                notes.append(child); cardIndex = notes.count-1
            }
            notes[cardIndex].transcript = source.text
            notes[cardIndex].history.append(.init(date: original.created,source: "Final idea card from reported audio runs; original utterance retained",text: text,revision: notes[cardIndex].revision))
            ids.append(notes[cardIndex].id)
        }
        notes[index].speechSource?.pending = false; notes[index].speechSource?.cardIDs = ids
    }
}
