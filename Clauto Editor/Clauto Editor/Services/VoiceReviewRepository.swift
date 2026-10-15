import Foundation
import Darwin

/// Transactions reload the durable document under the project lock. There is no
/// await inside a disk transaction and no write to a saved version/current cut.
actor VoiceReviewRepository {
    let project: Project
    private let rootIdentity: RenderDirectoryIdentity
    private let directory: SourceRenderDirectory
    private let root: SourceRenderDirectory
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private struct Envelope: Codable { let sha256: String; let document: VoiceReviewDocument }

    init(project: Project) throws {
        self.project = project
        root = try SourceRenderDirectory.open(project.folder); rootIdentity = root.identity
        directory = try root.child("notes").child("voice-review", create: true)
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    private func locked<T>(_ change: (inout VoiceReviewDocument) throws -> T, save: Bool = true) throws -> T {
        let fd = openat(directory.descriptor, "ledger.lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkflowFailure.invalid("Voice review storage is unavailable.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw WorkflowFailure.invalid("Voice review storage could not be locked.") }
        defer { flock(fd, LOCK_UN) }
        try root.checkPath(); try directory.checkPath()
        guard root.identity == rootIdentity else { throw ProjectFailure.invalidProject }
        var document: VoiceReviewDocument
        var info = stat()
        if fstatat(directory.descriptor, "ledger.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            let bytes = try directory.read("ledger.json", limit: 16 * 1024 * 1024)
            try TranscriptJSONKeys.validate(bytes)
            let envelope = try decoder.decode(Envelope.self, from: bytes)
            guard TranscriptSourceMap.sha(try encoder.encode(envelope.document)) == envelope.sha256 else { throw WorkflowFailure.invalid("Voice review history is damaged. Keep its evidence and recover a verified copy.") }
            document = envelope.document
        } else {
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }
            document = VoiceReviewDocument(projectID: project.id)
        }
        try validate(document)
        let result = try change(&document)
        if save {
            document.revision = UUID(); document.sequence += 1
            try validate(document)
            let bytes = try encoder.encode(document)
            guard bytes.count <= 15 * 1024 * 1024 else { throw WorkflowFailure.invalid("The voice review ledger is full. Preserve this history before starting another review.") }
            let wrapped = try encoder.encode(Envelope(sha256: TranscriptSourceMap.sha(bytes), document: document))
            try root.checkPath(); try directory.checkPath()
            try directory.replacePointer(wrapped, name: "ledger.json")
        }
        if let snapshot = document as? T { return snapshot }
        return result
    }

    private func validate(_ document: VoiceReviewDocument) throws {
        try document.validateCardLineage()
        try document.validateSpeechSources()
        let typed = document.typedDrafts ?? [], submissions = document.typedSubmissions ?? []
        guard typed.count <= 1_000, Set(typed.map(\.versionID)).count == typed.count,
              Set(typed.map(\.id)).count == typed.count, Set(typed.map(\.submissionID)).count == typed.count,
              submissions.count <= 10_000, Set(submissions.map(\.noteID)).count == submissions.count,
              Set(submissions.map { $0.draft.submissionID }).count == submissions.count,
              typed.allSatisfy({ draft in !submissions.contains { $0.draft.submissionID == draft.submissionID } }) else { throw ProjectFailure.invalidProject }
        for draft in typed {
            try draft.validate(project: project.id)
            guard draft.target == nil || document.targets.contains(draft.target!) else { throw ProjectFailure.invalidProject }
        }
        for submission in submissions {
            try submission.draft.validate(project: project.id)
            guard let target = submission.draft.target, document.targets.contains(target),
                  document.notes.contains(where: { $0.id == submission.noteID }) else { throw ProjectFailure.invalidProject }
        }
        guard document.schemaVersion == 1, document.projectID == project.id, document.sequence >= 0,
              (document.cardOperations ?? []).count <= 10_000,
              Set((document.cardOperations ?? []).map(\.id)).count == (document.cardOperations ?? []).count,
              document.sessions.count <= 1_000, document.targets.count <= 1_000, document.notes.count <= 10_000,
              document.candidates.count <= 10_000,
              (document.drafts ?? []).count <= 10_000,
              Set((document.drafts ?? []).map(\.noteID)).count == (document.drafts ?? []).count,
              (document.drafts ?? []).allSatisfy({ draft in draft.text.count <= 20_000 && draft.start.count <= 100 && draft.end.count <= 100 && draft.baseRevision > 0 && document.notes.contains(where: { $0.id == draft.noteID }) }),
              document.candidates.allSatisfy({ !$0.appliedToCut && !$0.productionAuthorized }),
              Set(document.targets.map(\.id)).count == document.targets.count,
              Set(document.sessions.map(\.id)).count == document.sessions.count,
              Set(document.notes.map(\.id)).count == document.notes.count,
              Set(document.candidates.map(\.id)).count == document.candidates.count,
              document.targets.allSatisfy({ $0.projectID == project.id && $0.duration.isFinite && $0.duration > 0 }),
              document.notes.allSatisfy({ $0.text.count <= 20_000 && $0.transcript.count <= 20_000 && $0.history.count <= 512 && $0.revision > 0 }),
              document.sessions.allSatisfy({ $0.audio.count <= 20_000 && $0.playhead.count <= 20_000 && $0.events.count <= 20_000 }) else { throw ProjectFailure.invalidProject }
    }

    func load() throws -> VoiceReviewDocument { try locked({ $0 }, save: false) }

    func recover() throws -> VoiceReviewDocument {
        try locked { document in
            for i in document.sessions.indices where [.recording,.finishing,.retrying].contains(document.sessions[i].state) {
                let pid = document.sessions[i].ownerProcessID
                if kill(pid, 0) == -1 && errno == ESRCH {
                    document.sessions[i].state = .interrupted; document.sessions[i].failure = "Recording was interrupted. No microphone was restarted."
                }
            }
            for i in document.candidates.indices where document.candidates[i].state == .processing {
                if kill(document.candidates[i].ownerProcessID, 0) == -1 && errno == ESRCH {
                    document.candidates[i].state = .failed; document.candidates[i].detail = "Preparation was interrupted; retry the saved notes."
                }
            }
            for i in document.notes.indices where document.notes[i].state == .processing {
                if document.candidates.contains(where: { $0.state == .failed && $0.noteRevisions.contains(where: { $0.id == document.notes[i].id }) }) { document.notes[i].state = .failed }
            }
            if let lease = document.processingJobID, let owner = document.candidates.first(where: { $0.id == lease })?.ownerProcessID,
               kill(owner, 0) == -1 && errno == ESRCH { document.processingJobID = nil }
            document.refresh(); return document
        }
    }

    func register(_ target: VoiceReviewTarget) throws -> VoiceReviewTarget {
        try locked { document in
            guard target.projectID == project.id else { throw ProjectFailure.invalidProject }
            try VoiceReviewProvenance.check(target, project: project)
            if let old = document.targets.first(where: { $0.versionID == target.versionID && $0.versionMetadataSHA256 == target.versionMetadataSHA256 && $0.preview == target.preview && $0.timeline == target.timeline && $0.approvedPlanSHA256 == target.approvedPlanSHA256 && $0.approvedScriptSHA256 == target.approvedScriptSHA256 && $0.approvedBriefSHA256 == target.approvedBriefSHA256 && $0.duration == target.duration && $0.engineVersion == target.engineVersion }) { return old }
            guard !document.targets.contains(where: { $0.versionID == target.versionID }) else { throw WorkflowFailure.invalid("This saved version changed after its first voice review. Restore its verified files or save a new version before attaching feedback.") }
            document.targets.append(target); return target
        }
    }

    func begin(id: UUID, attempt: UUID, deviceUID: String, locale: String, now: Date = Date()) throws -> VoiceReviewDocument {
        try locked { document in
            if document.sessions.contains(where: { $0.id == id && $0.attemptID == attempt && $0.deviceUID == deviceUID && $0.locale == locale }) { return document }
            guard !document.sessions.contains(where: { [.recording,.finishing,.retrying].contains($0.state) }) else { throw WorkflowFailure.invalid("Another voice session owns this project. Stop it before starting a microphone.") }
            document.sessions.append(.init(id: id, attemptID: attempt, deviceUID: deviceUID, locale: locale,
                ownerProcessID: getpid(), created: now)); return document
        }
    }

    func observe(session id: UUID, host: Double, seconds: Double, rate: Double, target: UUID?, epoch: UUID, kind: VoiceTransportKind) throws -> VoiceReviewDocument {
        try locked { document in
            guard let i = document.sessions.firstIndex(where: { $0.id == id && [.recording,.finishing].contains($0.state) }) else { return document }
            if let target, let bound = document.targets.first(where: { $0.id == target }) {
                try VoiceReviewProvenance.check(bound.preview, project: project)
                try VoiceReviewProvenance.check(bound.timeline, project: project)
            }
            try document.sessions[i].observe(host: host, seconds: seconds, rate: rate, targetID: target, epoch: epoch, kind: kind)
            document.refresh(); return document
        }
    }

    func captured(session id: UUID, attempt: UUID, audioStart: Double, duration: Double, hostStart: Double) throws -> VoiceReviewDocument {
        try locked { document in
            guard let i = document.sessions.firstIndex(where: { $0.id == id && $0.attemptID == attempt && [.recording,.finishing].contains($0.state) }) else { return document }
            try document.sessions[i].captured(audioStart: audioStart, duration: duration, hostStart: hostStart)
            document.refresh(); return document
        }
    }

    func speech(_ result: VoiceSpeechResult, session: UUID, attempt: UUID, now: Date = Date()) throws -> VoiceReviewDocument {
        try locked { document in try document.speech(result, sessionID: session, attemptID: attempt, now: now); return document }
    }

    func end(session id: UUID, state: VoiceCaptureState, failure: String? = nil) throws -> VoiceReviewDocument {
        try locked { document in
            guard let i = document.sessions.firstIndex(where: { $0.id == id }) else { return document }
            document.sessions[i].state = state; document.sessions[i].failure = failure
            if state == .cancelled {
                for j in document.notes.indices where document.notes[j].sessionID == id && !document.notes[j].isFinal { document.notes[j].state = .cancelled; document.notes[j].revision += 1 }
            }
            document.refresh(); return document
        }
    }

    func discardDraft(_ id: UUID) throws -> VoiceReviewDocument {
        try locked { document in document.drafts?.removeAll { $0.noteID == id }; return document }
    }
    func saveDraft(_ draft: VoiceTranscriptDraft) throws -> VoiceReviewDocument {
        try locked { document in
            guard document.notes.contains(where: { $0.id == draft.noteID }), draft.text.count <= 20_000,
                  draft.start.count <= 100, draft.end.count <= 100, draft.baseRevision > 0 else { throw ProjectFailure.invalidProject }
            var drafts = document.drafts ?? []; drafts.removeAll { $0.noteID == draft.noteID }; drafts.append(draft)
            document.drafts = drafts; return document
        }
    }

    func edit(note id: UUID, expectedRevision: Int, text: String, intent: VoiceIntent, anchor: VoiceNoteAnchor?, action: VoiceRangeAction? = nil) throws -> VoiceReviewDocument {
        try locked { document in
            guard let i = document.notes.firstIndex(where: { $0.id == id && $0.revision == expectedRevision }), (document.notes[i].supersededBy ?? []).isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 20_000 else { throw WorkflowFailure.invalid("This note changed. Reload its latest transcript before saving your edit.") }
            if let anchor {
                guard let target = document.targets.first(where: { $0.id == anchor.targetID }), anchor.seconds.isFinite, anchor.seconds >= 0, anchor.seconds <= target.duration,
                      anchor.endSeconds == nil || (anchor.endSeconds!.isFinite && anchor.endSeconds! >= anchor.seconds && anchor.endSeconds! <= target.duration) else { throw WorkflowFailure.invalid("Choose a valid saved version and time range for this note.") }
            }
            document.drafts?.removeAll { $0.noteID == id }
            document.notes[i].revision += 1; document.notes[i].text = text; document.notes[i].intent = intent
            document.notes[i].action = action
            document.notes[i].manuallyEdited = true; document.notes[i].isFinal = true; document.notes[i].state = .ready
            if let anchor { document.notes[i].resolvedAnchor = anchor }
            document.notes[i].history.append(.init(date: Date(), source: anchor == nil ? "User transcript edit" : "User anchor resolution", text: text, revision: document.notes[i].revision))
            document.refresh(); return document
        }
    }

    func cancel(note id: UUID) throws -> VoiceReviewDocument {
        try locked { document in
            guard let i = document.notes.firstIndex(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }
            document.notes[i].state = .cancelled; document.notes[i].revision += 1
            document.notes[i].history.append(.init(date: Date(), source: "User cancelled processing", text: document.notes[i].text, revision: document.notes[i].revision))
            document.refresh(); return document
        }
    }

    func retry(note id: UUID) throws -> VoiceReviewDocument {
        try locked { document in
            guard let i = document.notes.firstIndex(where: { $0.id == id }), document.notes[i].isFinal, (document.notes[i].supersededBy ?? []).isEmpty else { throw WorkflowFailure.invalid("Finalize or edit the saved transcript before retrying preparation. Starting a microphone requires a separate Start action.") }
            document.notes[i].revision += 1; document.notes[i].state = .ready; document.refresh(); return document
        }
    }

    func restructureCards(_ request: VoiceCardRequest) throws -> VoiceReviewDocument {
        try locked { document in try document.restructureCards(request); return document }
    }

    func claim(now: Date = Date()) throws -> VoiceRevisionCandidate? {
        try locked { document in
            document.refresh()
            guard document.processingJobID == nil else { return nil }
            for target in document.targets {
                let eligible = document.notes.filter { $0.isFinal && $0.issues.isEmpty && $0.effectiveAnchor?.targetID == target.id && [.ready,.processing,.prepared,.failed].contains($0.state) }
                guard eligible.contains(where: { $0.state == .ready }) else { continue }
                try VoiceReviewProvenance.check(target, project: project)
                let refs = eligible.map { VoiceNoteRevision(id: $0.id, revision: $0.revision) }
                if document.candidates.contains(where: { $0.parent.id == target.id && $0.noteRevisions == refs && [.processing,.prepared].contains($0.state) }) { continue }
                for i in document.candidates.indices where document.candidates[i].parent.id == target.id && [.processing,.prepared].contains(document.candidates[i].state) { document.candidates[i].state = .superseded }
                let candidate = VoiceRevisionCandidate(id: UUID(), parent: target, noteRevisions: refs, ownerProcessID: getpid(), created: now, renderNotBefore: now.addingTimeInterval(2))
                document.candidates.append(candidate)
                document.processingJobID = candidate.id
                for i in document.notes.indices where refs.contains(where: { $0.id == document.notes[i].id }) { document.notes[i].state = .processing }
                return candidate
            }
            return nil
        }
    }

    func candidateInput(_ claim: VoiceRevisionCandidate) throws -> [VoiceCandidateDirective] {
        try locked({ document in
            try claim.noteRevisions.map { ref in
                guard let note = document.notes.first(where: { $0.id == ref.id && $0.revision == ref.revision && $0.issues.isEmpty && $0.state == .processing }),
                      let anchor = note.effectiveAnchor, anchor.targetID == claim.parent.id else { throw CancellationError() }
                return .init(noteID: note.id, revision: note.revision, intent: note.intent, anchor: anchor, text: note.text, action: note.action)
            }
        }, save: false)
    }

    func complete(_ claim: VoiceRevisionCandidate, directives: [VoiceCandidateDirective], failure: String? = nil) throws -> VoiceReviewDocument {
        try locked { document in
            document.refresh()
            guard document.processingJobID == claim.id else { return document }
            document.processingJobID = nil
            func releaseUnchangedNotes() {
                for i in document.notes.indices where document.notes[i].state == .processing && document.notes[i].issues.isEmpty && claim.noteRevisions.contains(where: { $0.id == document.notes[i].id && $0.revision == document.notes[i].revision }) { document.notes[i].state = .ready }
            }
            guard let c = document.candidates.firstIndex(where: { $0.id == claim.id && $0.state == .processing }) else { releaseUnchangedNotes(); return document }
            let latest = document.notes.filter { $0.isFinal && $0.issues.isEmpty && $0.effectiveAnchor?.targetID == claim.parent.id && [.ready,.processing,.prepared,.failed].contains($0.state) }.map { VoiceNoteRevision(id: $0.id, revision: $0.revision) }
            guard latest == claim.noteRevisions else { document.candidates[c].state = .superseded; releaseUnchangedNotes(); return document }
            if let failure { document.candidates[c].state = .failed; document.candidates[c].detail = failure }
            else {
                try VoiceReviewProvenance.check(claim.parent, project: project)
                let expected = try claim.noteRevisions.map { ref -> VoiceCandidateDirective in
                    guard let note = document.notes.first(where: { $0.id == ref.id && $0.revision == ref.revision }), let anchor = note.effectiveAnchor else { throw ProjectFailure.invalidProject }
                    return .init(noteID: note.id, revision: note.revision, intent: note.intent, anchor: anchor, text: note.text, action: note.action)
                }
                guard directives == expected else { throw WorkflowFailure.invalid("The candidate processor changed a finalized feedback instruction.") }
                let payload = VoiceCandidateInstructions(id: claim.id, parent: claim.parent, noteRevisions: claim.noteRevisions,
                    directives: directives, created: claim.created, productionAuthorized: false, appliedToCut: false)
                let bytes = try encoder.encode(payload), filename = claim.id.uuidString + ".json"
                let folder = try directory.child("candidates", create: true)
                try folder.checkPath(); try root.checkPath()
                try folder.writeNew(bytes, name: filename)
                document.candidates[c].instructionsRelativePath = "notes/voice-review/candidates/" + filename
                document.candidates[c].instructionsSHA256 = TranscriptSourceMap.sha(bytes)
                document.candidates[c].directives = directives; document.candidates[c].state = .prepared
                document.candidates[c].detail = "Separate candidate prepared. Rendering awaits source, editorial and production gates; no new cut exists."
            }
            for i in document.notes.indices where claim.noteRevisions.contains(where: { $0.id == document.notes[i].id && $0.revision == document.notes[i].revision }) { document.notes[i].state = failure == nil ? .prepared : .failed }
            return document
        }
    }

    /// Persist a debounced intent only. This is not permission to invoke a renderer.
    func requestRender(candidate id: UUID, now: Date = Date()) throws -> VoiceReviewDocument {
        try locked { document in
            document.refresh()
            guard let i = document.candidates.firstIndex(where: { $0.id == id && $0.state == .prepared }), now >= document.candidates[i].renderNotBefore else { return document }
            let parent = document.candidates[i].parent
            try VoiceReviewProvenance.check(parent, project: project)
            guard let path = document.candidates[i].instructionsRelativePath, let sha = document.candidates[i].instructionsSHA256,
                  try VoiceReviewProvenance.inspect(path, project: project).sha256 == sha else { throw WorkflowFailure.invalid("The separate candidate instructions changed. Prepare a new candidate before requesting a render.") }
            guard !document.notes.contains(where: { $0.isFinal && $0.state != .cancelled && !$0.issues.isEmpty && ($0.effectiveAnchor == nil || $0.effectiveAnchor?.targetID == parent.id) }) else {
                document.candidates[i].detail = "Waiting for unresolved feedback before any render intent can advance."
                return document
            }
            guard !document.candidates.contains(where: { $0.parent.id == parent.id && $0.created > document.candidates[i].created && [.processing,.prepared].contains($0.state) }) else { return document }
            document.candidates[i].renderRequested = true
            document.candidates[i].detail = "Render requested after debounce; blocked pending approved candidate application and all existing production gates."
            return document
        }
    }
}

extension VoiceReviewRepository {
    private func checkedCandidate(_ id: UUID, document: VoiceReviewDocument) throws -> Int {
        guard let i = document.candidates.firstIndex(where: { $0.id == id && $0.state == .prepared }) else { throw WorkflowFailure.invalid("Prepare the latest finalized feedback before reviewing a candidate.") }
        let candidate = document.candidates[i]
        let notes = document.notes.filter { $0.state != .cancelled && ($0.effectiveAnchor?.targetID == candidate.parent.id || $0.effectiveAnchor == nil) }
        guard notes.allSatisfy({ $0.isFinal && $0.issues.isEmpty }),
              notes.map({ VoiceNoteRevision(id: $0.id,revision: $0.revision) }) == candidate.noteRevisions,
              let path = candidate.instructionsRelativePath, let sha = candidate.instructionsSHA256,
              try VoiceReviewProvenance.inspect(path,project: project).sha256 == sha else { throw WorkflowFailure.invalid("Feedback changed or remains unresolved. Prepare and approve the latest candidate.") }
        try VoiceReviewProvenance.check(candidate.parent,project: project)
        return i
    }
    func addTyped(text: String, action: VoiceRangeAction, anchor: VoiceNoteAnchor) throws -> VoiceReviewDocument {
        try locked { document in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 20_000,
                  let target = document.targets.first(where: { $0.id == anchor.targetID }),
                  anchor.seconds.isFinite, let end = anchor.endSeconds, end.isFinite,
                  anchor.seconds >= 0, end > anchor.seconds, end <= target.duration else { throw WorkflowFailure.invalid("Enter feedback and an explicit start/end inside the selected movie.") }
            try VoiceReviewProvenance.check(target,project: project)
            let id = UUID(), attempt = UUID()
            var session = VoiceReviewSession(id: id,attemptID: attempt,deviceUID: "typed-no-microphone",locale: "",ownerProcessID: getpid(),created: Date()); session.state = .stopped
            document.sessions.append(session)
            var note = VoiceReviewNote(id: UUID(),sessionID: id,segmentID: "typed-"+UUID().uuidString,audioStart: nil,audioEnd: nil,created: Date(),transcript: "",text: text,isFinal: true,intent: action == .protect ? .protect : .change)
            note.action = action; note.manuallyEdited = true; note.resolvedAnchor = anchor
            note.history.append(.init(date: Date(),source: "User typed feedback; no microphone",text: text,revision: note.revision))
            document.notes.append(note); document.refresh(); return document
        }
    }
    func saveTypedDraft(_ draft: VoiceTypedDraft, expected: VoiceTypedDraft?) throws -> VoiceReviewDocument {
        try locked { document in
            try draft.validate(project: project.id)
            // An old delayed autosave must not resurrect submitted words.
            if (document.typedSubmissions ?? []).contains(where: { $0.draft.id == draft.id && $0.draft.revision >= draft.revision }) { return document }
            try checkTypedDraftBase(draft,expected: expected,document: document)
            var values = document.typedDrafts ?? []; values.removeAll { $0.versionID == draft.versionID }; values.append(draft)
            document.typedDrafts = values; return document
        }
    }
    private func checkTypedDraftBase(_ draft: VoiceTypedDraft, expected: VoiceTypedDraft?, document: VoiceReviewDocument) throws {
        let stored = (document.typedDrafts ?? []).first { $0.versionID == draft.versionID }
        // A previous submission may have committed despite an uncertain response.
        let consumedBase = stored == nil && expected.map { base in
            (document.typedSubmissions ?? []).contains { $0.draft == base }
        } == true
        guard stored == expected || stored == draft || consumedBase,
              stored == nil || stored!.id == draft.id,
              stored == nil || stored!.revision <= draft.revision,
              stored?.revision != draft.revision || stored == draft else {
            throw WorkflowFailure.invalid("This draft changed in another window. Copy your text before reloading the saved draft.")
        }
    }
    func submitTypedDraft(_ draft: VoiceTypedDraft, expected: VoiceTypedDraft?) throws -> VoiceReviewDocument {
        try locked { document in
            if let receipt = (document.typedSubmissions ?? []).first(where: { $0.draft.submissionID == draft.submissionID }) {
                guard receipt.draft == draft else { throw WorkflowFailure.invalid("This feedback submission changed. Keep its original draft and retry it unchanged.") }
                return document
            }
            guard !(document.typedSubmissions ?? []).contains(where: { $0.draft.id == draft.id && $0.draft.revision >= draft.revision }) else {
                throw WorkflowFailure.invalid("This draft revision was already submitted. Edit a new draft before saving another note.")
            }
            try draft.validate(project: project.id)
            try checkTypedDraftBase(draft,expected: expected,document: document)
            guard let target = draft.target, document.targets.contains(target),
                  !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = Double(draft.start), let end = Double(draft.end), start.isFinite, end.isFinite,
                  start >= 0, end > start, end <= target.duration else {
                throw WorkflowFailure.invalid("Enter feedback and an explicit start/end inside the selected movie.")
            }
            try VoiceReviewProvenance.check(target,project: project)
            let sessionID = UUID(), noteID = UUID()
            var session = VoiceReviewSession(id: sessionID,attemptID: UUID(),deviceUID: "typed-no-microphone",locale: "",ownerProcessID: getpid(),created: Date()); session.state = .stopped
            var note = VoiceReviewNote(id: noteID,sessionID: sessionID,segmentID: "typed-"+draft.submissionID.uuidString,audioStart: nil,audioEnd: nil,created: Date(),transcript: "",text: draft.text,isFinal: true,intent: draft.action == .protect ? .protect:.change)
            note.action = draft.action; note.manuallyEdited = true; note.resolvedAnchor = .init(targetID: target.id,seconds: start,endSeconds: end)
            note.history.append(.init(date: Date(),source: "User typed feedback; no microphone",text: draft.text,revision: note.revision))
            document.sessions.append(session); document.notes.append(note)
            var submissions = document.typedSubmissions ?? []; submissions.append(.init(draft: draft,noteID: noteID)); document.typedSubmissions = submissions
            document.typedDrafts?.removeAll { $0.id == draft.id }; document.refresh(); return document
        }
    }
    func prepareEditPlan(_ id: UUID) throws -> VoiceReviewDocument {
        try locked { document in
            document.refresh(); let i = try checkedCandidate(id,document: document)
            if document.candidates[i].editPlan != nil { return document }
            let plan = try VoiceCandidateEditPlan.compile(document.candidates[i]), bytes = try encoder.encode(plan)
            let folder = try directory.child("edit-plans",create: true), name = plan.id.uuidString+".json"
            try folder.writeNew(bytes,name: name)
            document.candidates[i].editPlan = plan
            document.candidates[i].editPlanRelativePath = "notes/voice-review/edit-plans/"+name
            document.candidates[i].editPlanSHA256 = TranscriptSourceMap.sha(bytes)
            document.candidates[i].detail = plan.issues.isEmpty ? "Review exact frame ranges, then explicitly approve this watched-movie candidate. No movie has rendered." : plan.issues.joined(separator: "\n")
            return document
        }
    }
    func approveEditPlan(_ id: UUID, expectedSHA: String) throws -> VoiceReviewDocument {
        try locked { document in
            document.refresh(); let i = try checkedCandidate(id,document: document)
            guard let plan = document.candidates[i].editPlan, let path = document.candidates[i].editPlanRelativePath,
                  let sha = document.candidates[i].editPlanSHA256, sha == expectedSHA, plan.issues.isEmpty,
                  try VoiceReviewProvenance.inspect(path,project: project).sha256 == sha,
                  TranscriptSourceMap.sha(try encoder.encode(plan)) == sha else { throw WorkflowFailure.invalid("Resolve and review the exact candidate plan before approval.") }
            let approval = VoiceCandidateEditApproval(id: UUID(),planID: plan.id,planSHA256: sha,created: Date(),scope: VoiceCandidateEditPlan.mode,productionAuthorized: false)
            let bytes = try encoder.encode(approval), name = approval.id.uuidString+".json"
            try directory.child("edit-approvals",create: true).writeNew(bytes,name: name)
            document.candidates[i].editApproval = approval
            document.candidates[i].editApprovalRelativePath = "notes/voice-review/edit-approvals/"+name
            document.candidates[i].editApprovalSHA256 = TranscriptSourceMap.sha(bytes)
            document.candidates[i].detail = "Exact review-movie cuts approved. Original editable camera/graphics timeline remains separate; production approval is unchanged."
            return document
        }
    }
    func approvedEditSnapshot(_ id: UUID) throws -> VoiceApprovedEditSnapshot {
        try locked({ document in
            document.refresh(); let i = try checkedCandidate(id,document: document), candidate = document.candidates[i]
            guard let plan = candidate.editPlan, let planSHA = candidate.editPlanSHA256,
                  let path = candidate.editPlanRelativePath, let approval = candidate.editApproval,
                  let approvalSHA = candidate.editApprovalSHA256, let approvalPath = candidate.editApprovalRelativePath,
                  plan.issues.isEmpty, approval.planID == plan.id, approval.planSHA256 == planSHA,
                  approval.scope == VoiceCandidateEditPlan.mode, !approval.productionAuthorized,
                  try VoiceReviewProvenance.inspect(path,project: project).sha256 == planSHA,
                  try VoiceReviewProvenance.inspect(approvalPath,project: project).sha256 == approvalSHA,
                  TranscriptSourceMap.sha(try encoder.encode(plan)) == planSHA,
                  TranscriptSourceMap.sha(try encoder.encode(approval)) == approvalSHA else { throw WorkflowFailure.invalid("This candidate needs a current explicit frame-plan approval before rendering.") }
            return .init(candidate: candidate,plan: plan,planSHA256: planSHA,approval: approval,approvalSHA256: approvalSHA)
        },save: false)
    }
    func verifiedPreview(_ id: UUID) async throws -> URL {
        let pair: (VoiceReviewTarget, VoiceCandidatePreview) = try locked({ document in
            guard let candidate = document.candidates.first(where: { $0.id == id }), let record = candidate.renderedPreview,
                  !record.productionAuthorized, !record.appliedToWatchedVersion,
                  record.planSHA256 == candidate.editPlanSHA256 else { throw WorkflowFailure.invalid("This candidate has no verified rendered preview.") }
            return (candidate.parent,record)
        },save: false)
        let project = self.project
        let check = Task.detached { () throws -> URL in
            let (parent,record) = pair
            try VoiceReviewProvenance.check(parent,project: project)
            let folder = try SourceRenderDirectory.open(project.folder).child("build").child("voice-candidates").child(record.id.uuidString)
            guard folder.identity == record.folderIdentity, let completion = record.completionSHA256, TranscriptSourceMap.sha(try folder.read("completion.json")) == completion else { throw ProjectFailure.invalidProject }
            for (name,sha) in record.artifactsSHA256 { guard try folder.voiceHash(name) == sha else { throw WorkflowFailure.invalid("A rendered candidate changed. Render a fresh candidate before playback.") } }
            let bytes = try folder.read("render-proof.json")
            guard TranscriptSourceMap.sha(bytes) == record.proofSHA256 else { throw ProjectFailure.invalidProject }
            let proof = try JSONDecoder().decode(VoiceMasterProof.self,from: bytes)
            guard try folder.voiceHash("input.json") == proof.inputSHA256 else { throw ProjectFailure.invalidProject }
            return folder.url.appendingPathComponent("review.mov")
        }
        return try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
    }
    func commitPreview(_ snapshot: VoiceApprovedEditSnapshot, final: SourceRenderDirectory, output: SourceRenderDirectory,
                       id: UUID, proof: VoiceMasterProof, proofSHA: String, receipts: [VoiceArtifact]) throws -> VoiceReviewDocument {
        try locked { document in
            document.refresh(); let i = try checkedCandidate(snapshot.candidate.id,document: document)
            guard document.candidates[i].editPlanSHA256 == snapshot.planSHA256,
                  document.candidates[i].editApproval?.id == snapshot.approval.id,
                  document.candidates[i].editApprovalSHA256 == snapshot.approvalSHA256,
                  proof.planSHA256 == snapshot.planSHA256, proof.approvalSHA256 == snapshot.approvalSHA256,
                  !proof.productionAuthorized, !proof.appliedToWatchedVersion,
                  final.url == output.url.appendingPathComponent(id.uuidString), Set(receipts.map(\.relativePath)) == Set(VoiceMasterByteContract.files),
                  receipts.first(where: { $0.relativePath == "candidate-plan.json" })?.sha256 == snapshot.planSHA256,
                  receipts.first(where: { $0.relativePath == "candidate-approval.json" })?.sha256 == snapshot.approvalSHA256,
                  receipts.first(where: { $0.relativePath == "parent.fcpxml" })?.sha256 == snapshot.plan.parent.timeline.sha256,
                  receipts.first(where: { $0.relativePath == "input.json" })?.sha256 == proof.inputSHA256,
                  receipts.first(where: { $0.relativePath == "render-proof.json" })?.sha256 == proofSHA,
                  let planPath = document.candidates[i].editPlanRelativePath, let approvalPath = document.candidates[i].editApprovalRelativePath,
                  try VoiceReviewProvenance.inspect(planPath,project: project).sha256 == snapshot.planSHA256,
                  try VoiceReviewProvenance.inspect(approvalPath,project: project).sha256 == snapshot.approvalSHA256 else { throw WorkflowFailure.invalid("The candidate feedback, frame plan or approval changed during rendering. Output remains separate evidence.") }
            try root.checkPath(); try output.checkPath(); try final.checkPath(); try Task.checkCancellation()
            for receipt in receipts { try final.voiceCheck(receipt) }
            var record = VoiceCandidatePreview(id: id,relativeFolder: "build/voice-candidates/"+id.uuidString,planSHA256: snapshot.planSHA256,approvalID: snapshot.approval.id,proofSHA256: proofSHA,folderIdentity: final.identity,artifactsSHA256: proof.artifactsSHA256,frames: proof.frames,audioSamplesPerChannel: proof.audioSamplesPerChannel,productionAuthorized: false,appliedToWatchedVersion: false)
            let completion = try encoder.encode(record)
            try final.writeNew(completion,name: "completion.json"); record.completionSHA256 = TranscriptSourceMap.sha(completion)
            try root.checkPath(); try output.checkPath(); try final.checkPath(); try Task.checkCancellation()
            for receipt in receipts { try final.voiceCheck(receipt) }
            try VoiceReviewProvenance.check(snapshot.plan.parent,project: project)
            document.candidates[i].renderedPreview = record
            document.candidates[i].detail = "Rendered review candidate verified against exact watched-master frame ranges and decoded pixels/PCM. The watched version and original native timeline are unchanged."
            return document
        }
    }

}

protocol VoiceCandidateProcessing: Sendable {
    func prepare(_ candidate: VoiceRevisionCandidate, directives: [VoiceCandidateDirective]) async throws -> [VoiceCandidateDirective]
}
struct LocalVoiceCandidateProcessor: VoiceCandidateProcessing {
    func prepare(_ candidate: VoiceRevisionCandidate, directives: [VoiceCandidateDirective]) async throws -> [VoiceCandidateDirective] {
        try Task.checkCancellation()
        // Deterministic local instructions, not remote interpretation or production approval.
        return directives
    }
}
actor VoiceCandidateWorker {
    let repository: VoiceReviewRepository
    let processor: any VoiceCandidateProcessing
    private var running = false
    private var abandonedClaim: VoiceRevisionCandidate?
    init(repository: VoiceReviewRepository, processor: any VoiceCandidateProcessing = LocalVoiceCandidateProcessor()) { self.repository = repository; self.processor = processor }
    func drain() async throws {
        guard !running else { return }; running = true; defer { running = false }
        if let abandonedClaim {
            _ = try await repository.complete(abandonedClaim, directives: [], failure: "Prior local preparation stopped before its cleanup could be saved.")
            self.abandonedClaim = nil
        }
        while let claim = try await repository.claim() {
            abandonedClaim = claim
            do {
                let input = try await repository.candidateInput(claim)
                let output = try await processor.prepare(claim, directives: input)
                try Task.checkCancellation()
                _ = try await repository.complete(claim, directives: output)
            } catch {
                let detail = Task.isCancelled ? "Local preparation cancelled; saved feedback remains available for retry." : error.localizedDescription
                // An unstructured cleanup task intentionally does not inherit the
                // cancelled worker's state. It releases only this exact job lease.
                _ = try await Task { [repository] in try await repository.complete(claim, directives: [], failure: detail) }.value
                abandonedClaim = nil
                if Task.isCancelled { throw CancellationError() }
            }
            abandonedClaim = nil
        }
    }
}
