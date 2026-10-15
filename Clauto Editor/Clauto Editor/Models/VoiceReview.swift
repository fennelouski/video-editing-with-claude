import Foundation

struct VoiceArtifact: Codable, Equatable, Sendable {
    let relativePath: String
    let sha256: String
    let signature: SourceFileSignature
}

/// A note binds this saved edit and its approved inputs, never the current cut.
struct VoiceReviewTarget: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectID: UUID
    let versionID: UUID
    let versionNumber: Int
    let versionMetadataSHA256: String
    let timeline: VoiceArtifact
    let preview: VoiceArtifact
    let approvedPlanSHA256: String
    let approvedPlanPath: String
    let approvedScriptSHA256: String
    let approvedScriptPath: String
    let approvedBriefSHA256: String
    let engineVersion: String
    let duration: Double
}

enum VoiceCaptureState: String, Codable, Sendable { case recording, finishing, stopped, cancelled, interrupted, retrying }
enum VoiceNoteState: String, Codable, Sendable { case provisional, ready, needsResolution, processing, prepared, cancelled, failed }
enum VoiceIntent: String, Codable, CaseIterable, Sendable {
    case protect, change, unclear
    static func infer(_ text: String) -> Self {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.range(of: #"^(i\s+)?(really\s+)?(like|love|keep|protect)\b|^don.t change\b"#, options: .regularExpression) != nil { return .protect }
        if lower.range(of: #"^(i\s+)?(don.t like|dislike|hate|remove|cut|change)\b"#, options: .regularExpression) != nil { return .change }
        return .unclear
    }
}
enum VoiceTransportKind: String, Codable, Sendable {
    case sample, play, pause, seekRequested, seekCompleted, versionChanged, unavailable
}
struct VoiceTransportEvent: Codable, Identifiable, Sendable {
    var id = UUID()
    let hostTime: Double
    let kind: VoiceTransportKind
    let targetID: UUID?
    let seconds: Double
}
struct VoicePlayheadSpan: Codable, Sendable {
    let hostStart: Double
    var confirmedThrough: Double
    let seconds: Double
    let rate: Double
    let targetID: UUID?
    let epoch: UUID
    func time(at host: Double) -> Double { seconds + (host - hostStart) * rate }
}
struct VoiceAudioSpan: Codable, Sendable {
    let audioStart: Double
    var duration: Double
    let hostStart: Double
    var audioEnd: Double { audioStart + duration }
    var hostEnd: Double { hostStart + duration }
}
struct VoiceReviewSession: Codable, Identifiable, Sendable {
    let id: UUID
    var attemptID: UUID
    let deviceUID: String
    let locale: String
    let ownerProcessID: Int32
    var state: VoiceCaptureState = .recording
    let created: Date
    var audio: [VoiceAudioSpan] = []
    var playhead: [VoicePlayheadSpan] = []
    var events: [VoiceTransportEvent] = []
    var failure: String?
    var backupRelativePath: String?
    var backupSHA256: String?

    mutating func observe(host: Double, seconds: Double, rate: Double, targetID: UUID?, epoch: UUID, kind: VoiceTransportKind) throws {
        guard host.isFinite, seconds.isFinite, seconds >= 0, [0,1].contains(rate) else { throw ProjectFailure.invalidProject }
        if kind != .sample && !events.contains(where: { $0.hostTime == host && $0.kind == kind && $0.targetID == targetID && $0.seconds == seconds }) { events.append(.init(hostTime: host, kind: kind, targetID: targetID, seconds: seconds)) }
        if let last = playhead.last, host >= last.confirmedThrough {
            if kind == .sample, last.targetID == targetID, last.epoch == epoch, last.rate == rate,
                abs(last.time(at: host) - seconds) <= 0.025 {
                playhead[playhead.count-1].confirmedThrough = host; return
            }
            if kind == .sample {
                // Do not bridge an unobserved jump/stall with invented playback.
                events.append(.init(hostTime: host, kind: .unavailable, targetID: targetID, seconds: seconds))
            } else if last.targetID == targetID && abs(last.time(at: host)-seconds) <= 0.025 {
                playhead[playhead.count-1].confirmedThrough = host
            }
        }
        playhead.append(.init(hostStart: host, confirmedThrough: host, seconds: seconds, rate: rate, targetID: targetID, epoch: epoch))
        playhead.sort { $0.hostStart < $1.hostStart }
    }

    mutating func captured(audioStart: Double, duration: Double, hostStart: Double) throws {
        guard audioStart.isFinite, duration.isFinite, hostStart.isFinite, audioStart >= 0, duration > 0, hostStart > 0 else { throw WorkflowFailure.invalid("The microphone clock is unavailable; resolve affected feedback before processing.") }
        if audio.contains(where: { $0.audioStart <= audioStart && $0.audioEnd >= audioStart+duration && abs(($0.hostStart+audioStart-$0.audioStart)-hostStart) < 0.000002 }) { return }
        if let last = audio.last, abs(last.audioEnd-audioStart) < 0.000002, abs(last.hostEnd-hostStart) < 0.002 {
            audio[audio.count-1].duration += duration
        } else {
            guard !audio.contains(where: { audioStart < $0.audioEnd-0.000002 && audioStart+duration > $0.audioStart+0.000002 }) else { throw WorkflowFailure.invalid("Overlapping microphone clock packets cannot anchor feedback.") }
            audio.append(.init(audioStart: audioStart, duration: duration, hostStart: hostStart)); audio.sort { $0.audioStart < $1.audioStart }
        }
    }

    func hostRange(start: Double, end: Double) -> (Double, Double)? {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              let first = audio.first(where: { start >= $0.audioStart-0.000002 && start < $0.audioEnd }),
              let last = audio.last(where: { end > $0.audioStart && end <= $0.audioEnd+0.000002 }) else { return nil }
        let covered = audio.filter { $0.audioEnd > start && $0.audioStart < end }
        for (a,b) in zip(covered, covered.dropFirst()) where abs(a.audioEnd-b.audioStart) > 0.000002 || abs(a.hostEnd-b.hostStart) > 0.002 { return nil }
        return (first.hostStart + start-first.audioStart, last.hostStart + end-last.audioStart)
    }

    func coversPlayback(start: Double, end: Double, target: UUID, epoch: UUID) -> Bool {
        var cursor = start
        for span in playhead where span.targetID == target && span.epoch == epoch && span.confirmedThrough > cursor && span.hostStart < end {
            guard span.hostStart <= cursor+0.002 else { return false }
            cursor = max(cursor, span.confirmedThrough)
            if cursor >= end { return true }
        }
        return false
    }
}

struct VoiceNoteAnchor: Codable, Equatable, Sendable {
    let targetID: UUID
    let seconds: Double
    var endSeconds: Double?
}
struct VoiceNoteHistory: Codable, Identifiable, Sendable {
    var id = UUID()
    let date: Date
    let source: String
    let text: String
    let revision: Int
}
struct VoiceReviewNote: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let segmentID: String
    let audioStart: Double?
    var audioEnd: Double?
    let created: Date
    var transcript: String
    var text: String
    var isFinal: Bool
    var revision = 1
    var action: VoiceRangeAction?
    var manuallyEdited = false
    var intent: VoiceIntent
    /// Set once from captured onset; a user resolution is kept separately.
    var onset: VoiceNoteAnchor?
    var resolvedAnchor: VoiceNoteAnchor?
    var state: VoiceNoteState = .provisional
    var issues: [String] = []
    var history: [VoiceNoteHistory] = []
    var effectiveAnchor: VoiceNoteAnchor? { resolvedAnchor ?? onset }
}

/// Unsubmitted edits survive view replacement and restart without becoming instructions.
struct VoiceTranscriptDraft: Codable, Equatable, Sendable {
    let noteID: UUID
    var text: String
    var intent: VoiceIntent
    var targetID: UUID?
    var start: String
    var end: String
    var baseRevision: Int
    var action: VoiceRangeAction? = nil
}

struct VoiceNoteRevision: Codable, Equatable, Sendable { let id: UUID; let revision: Int }
struct VoiceCandidateDirective: Codable, Equatable, Sendable {
    let noteID: UUID
    let revision: Int
    let intent: VoiceIntent
    let anchor: VoiceNoteAnchor
    let text: String
    var action: VoiceRangeAction? = nil
}
struct VoiceRevisionCandidate: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case processing, prepared, needsResolution, cancelled, failed, superseded }
    let id: UUID
    let parent: VoiceReviewTarget
    let noteRevisions: [VoiceNoteRevision]
    let ownerProcessID: Int32
    let created: Date
    var state: State = .processing
    var directives: [VoiceCandidateDirective] = []
    var detail: String = "Preparing separate candidate instructions locally"
    var renderNotBefore: Date
    var renderRequested = false
    var instructionsRelativePath: String?
    var instructionsSHA256: String?
    var editPlan: VoiceCandidateEditPlan?
    var editPlanRelativePath: String?
    var editPlanSHA256: String?
    var editApproval: VoiceCandidateEditApproval?
    var editApprovalRelativePath: String?
    var editApprovalSHA256: String?
    var renderedPreview: VoiceCandidatePreview?
    var appliedToCut = false
    var productionAuthorized = false
}

struct VoiceCandidateInstructions: Codable, Sendable {
    let id: UUID
    let parent: VoiceReviewTarget
    let noteRevisions: [VoiceNoteRevision]
    let directives: [VoiceCandidateDirective]
    let created: Date
    let productionAuthorized: Bool
    let appliedToCut: Bool
}

struct VoiceSpeechResult: Sendable {
    let segmentID: String
    let text: String
    let isFinal: Bool
    let audioStart: Double?
    let audioEnd: Double?
}

struct VoiceReviewDocument: Codable, Sendable {
    var schemaVersion = 1
    let projectID: UUID
    var revision = UUID()
    var sequence = 0
    var targets: [VoiceReviewTarget] = []
    var sessions: [VoiceReviewSession] = []
    var notes: [VoiceReviewNote] = []
    var candidates: [VoiceRevisionCandidate] = []
    var processingJobID: UUID?
    var drafts: [VoiceTranscriptDraft]? // Optional for ledgers created before draft retention.

    mutating func speech(_ result: VoiceSpeechResult, sessionID: UUID, attemptID: UUID, now: Date) throws {
        guard let session = sessions.first(where: { $0.id == sessionID && $0.attemptID == attemptID }),
              [.recording,.finishing,.retrying].contains(session.state) else { return }
        guard !result.segmentID.isEmpty, result.segmentID.count < 256, result.text.count <= 20_000 else { throw ProjectFailure.invalidProject }
        if let i = notes.firstIndex(where: { $0.sessionID == sessionID && $0.segmentID == result.segmentID }) {
            guard notes[i].state != .cancelled else { return }
            if notes[i].isFinal || notes[i].manuallyEdited {
                if result.text != notes[i].transcript { notes[i].history.append(.init(date: now, source: "Late ASR ignored", text: result.text, revision: notes[i].revision)) }
                return
            }
            guard notes[i].audioStart == result.audioStart else { throw WorkflowFailure.invalid("A recognition segment changed its original speech onset.") }
            if notes[i].text == result.text && notes[i].isFinal == result.isFinal && notes[i].audioEnd == result.audioEnd { return }
            notes[i].revision += 1; notes[i].transcript = result.text; notes[i].text = result.text
            notes[i].audioEnd = result.audioEnd; notes[i].isFinal = result.isFinal; notes[i].intent = .infer(result.text)
            notes[i].history.append(.init(date: now, source: result.isFinal ? "Final ASR" : "Partial ASR", text: result.text, revision: notes[i].revision))
        } else {
            guard notes.count < 10_000 else { throw WorkflowFailure.invalid("This voice review has reached its note limit. Start a new review project before recording more.") }
            var note = VoiceReviewNote(id: UUID(), sessionID: sessionID, segmentID: result.segmentID, audioStart: result.audioStart,
                audioEnd: result.audioEnd, created: now, transcript: result.text, text: result.text, isFinal: result.isFinal, intent: .infer(result.text))
            note.history.append(.init(date: now, source: result.isFinal ? "Final ASR" : "Partial ASR", text: result.text, revision: 1)); notes.append(note)
        }
        refresh()
    }

    mutating func refresh() {
        for i in notes.indices where notes[i].state != .cancelled {
            var issues: [String] = []
            if notes[i].resolvedAnchor == nil {
                if let session = sessions.first(where: { $0.id == notes[i].sessionID }),
                   let start = notes[i].audioStart, let end = notes[i].audioEnd,
                   let (hostStart,hostEnd) = session.hostRange(start: start, end: end),
                   let frame = session.playhead.last(where: { $0.hostStart <= hostStart && $0.confirmedThrough >= hostStart }),
                   let targetID = frame.targetID, let target = targets.first(where: { $0.id == targetID }),
                   frame.time(at: hostStart) >= 0, frame.time(at: hostStart) <= target.duration {
                    let anchor = VoiceNoteAnchor(targetID: targetID, seconds: frame.time(at: hostStart))
                    if let onset = notes[i].onset {
                        if onset.targetID != anchor.targetID || abs(onset.seconds-anchor.seconds) > 0.025 { issues.append("Speech-onset mapping changed; resolve the original anchor.") }
                    } else { notes[i].onset = anchor }
                    if session.events.contains(where: { $0.hostTime > hostStart+0.000001 && $0.hostTime < hostEnd-0.000001 }) {
                        issues.append("Speech crossed a seek, pause or version boundary. Choose its exact target and time.")
                    }
                    if !session.coversPlayback(start: hostStart, end: hostEnd, target: targetID, epoch: frame.epoch) {
                        issues.append("Continuous playback clock coverage is missing or changed during speech.")
                    }
                } else { issues.append("Speech timing or playback clock coverage is missing. Choose the target and time.") }
            }
            if notes[i].intent == .unclear { issues.append("Clarify whether this protects a moment or requests a change.") }
            if notes[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("The transcript is empty.") }
            notes[i].issues = issues
            if !notes[i].isFinal {
                if let session = sessions.first(where: { $0.id == notes[i].sessionID }), [.stopped,.interrupted].contains(session.state) {
                    notes[i].issues.append("Capture ended before a final transcript. Edit this saved text or explicitly start a new recording."); notes[i].state = .needsResolution
                } else { notes[i].state = .provisional }
            }
            else if !issues.isEmpty { notes[i].state = .needsResolution }
            else if [.provisional,.needsResolution].contains(notes[i].state) { notes[i].state = .ready }
        }
        // A protect/change overlap always needs visible resolution; no last-writer win.
        for i in notes.indices where notes[i].isFinal && notes[i].state != .cancelled {
            guard let a = notes[i].effectiveAnchor else { continue }
            for j in notes.indices where j > i && notes[j].isFinal && notes[j].state != .cancelled {
                guard let b = notes[j].effectiveAnchor, a.targetID == b.targetID,
                    notes[i].intent != .unclear, notes[j].intent != .unclear, notes[i].intent != notes[j].intent,
                    max(a.seconds,b.seconds) < min(a.endSeconds ?? a.seconds+0.25,b.endSeconds ?? b.seconds+0.25) else { continue }
                let message = "Conflicting protect/change feedback overlaps. Edit its range, intent or cancel one note."
                notes[i].issues.append(message); notes[j].issues.append(message)
                notes[i].state = .needsResolution; notes[j].state = .needsResolution
            }
        }
        for i in candidates.indices where [.processing,.prepared].contains(candidates[i].state) {
            if candidates[i].noteRevisions.contains(where: { ref in !notes.contains(where: { $0.id == ref.id && $0.revision == ref.revision && $0.issues.isEmpty && $0.state != .cancelled }) }) {
                candidates[i].state = .superseded; candidates[i].detail = "Feedback changed; this candidate is retained in history."
            }
        }
    }
}
