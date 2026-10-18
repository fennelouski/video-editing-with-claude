import Foundation
import CoreGraphics
import Observation

struct FrameCommentSaveAttempt: Equatable, Sendable {
    let id: UUID
    let supersedesID: UUID?
    let text: String
    let annotations: [FrameEllipse]
}

@MainActor @Observable final class FrameCommentDraft: Identifiable {
    let id = UUID()
    let request: FrameCommentRequest
    private(set) var supersedesID: UUID?
    private(set) var pendingSave: FrameCommentSaveAttempt?
    private var nextSaveID: UUID?
    var text: String
    var history: FrameAnnotationHistory
    private var noteEditRevisions: [UUID:Int] = [:]
    private var historyEditRevision = 0
    func dictationEditIdentity(_ region: UUID) -> [Int] { [historyEditRevision,noteEditRevisions[region] ?? 0] }
    var selectedShapeID: UUID?
    var tool = FrameAnnotationKind.ellipse
    var selecting = false
    private(set) var frame: FrozenReviewFrame?
    init(request: FrameCommentRequest, text: String = "", shapes: [FrameEllipse] = [], supersedes: UUID? = nil, frame: FrozenReviewFrame? = nil) {
        self.request = request; self.text = text; history = .init(shapes: shapes); supersedesID = supersedes; self.frame = frame
    }
    func receive(_ frame: FrozenReviewFrame) throws {
        guard frame.request == request else { throw ProjectFailure.invalidProject }; self.frame = frame
    }
    func add(_ bounds: NormalizedVideoRect, kind: FrameAnnotationKind) throws {
        guard let frame else { throw ProjectFailure.invalidProject }
        let shape = FrameEllipse(id: UUID(),kind: kind,bounds: bounds)
        try shape.validate(width: frame.width,height: frame.height); try history.add(shape); selectedShapeID = shape.id
    }
    func addStroke(_ points: [CGPoint],video: CGRect) throws {
        guard let frame, let shape = VideoAnnotationGeometry.stroke(points,video: video,image: .init(width: frame.width,height: frame.height)) else { throw WorkflowFailure.invalid("Draw inside the captured video.") }
        try history.add(shape); selectedShapeID = shape.id
    }
    func updateSelected(tag: String,note: String) throws {
        guard let selectedShapeID else { return }
        try updateRegion(selectedShapeID,tag: tag,note: note)
    }
    func updateRegion(_ id: UUID,tag: String,note: String,dictated: Bool = false) throws {
        guard frame != nil, let index = history.shapes.firstIndex(where: { $0.id == id }) else { return }
        let previousNote = history.shapes[index].note ?? ""
        var shapes = history.shapes
        shapes[index].mentions = FramePersonMention.rebased(shapes[index].mentions,from: shapes[index].note ?? "",to: note)
        shapes[index].tag = tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil:tag
        shapes[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil:note
        // Retain all draft wording, including over-limit input. Save validates;
        // a field edit must never silently truncate or replace the user's words.
        try history.replace(shapes)
        if !dictated, !previousNote.utf8.elementsEqual(note.utf8) { noteEditRevisions[id,default: 0] += 1 }
    }
    func resizeSelected(_ bounds: NormalizedVideoRect) throws {
        guard let frame, let selectedShapeID, let old = history.shapes.first(where: { $0.id == selectedShapeID }) else { return }
        let points = old.points?.map { NormalizedVideoPoint(x: bounds.x+($0.x-old.bounds.x)/old.bounds.width*bounds.width,y: bounds.y+($0.y-old.bounds.y)/old.bounds.height*bounds.height) }
        let next = FrameEllipse(id: old.id,kind: old.kind,bounds: bounds,points: points,tag: old.tag,note: old.note,person: old.person,mentions: old.mentions,dictationSessionIDs: old.dictationSessionIDs)
        try next.validate(width: frame.width,height: frame.height)
        try history.replace(history.shapes.map { $0.id == old.id ? next:$0 })
    }
    func removeSelected() throws { if let selectedShapeID { try history.remove(selectedShapeID); noteEditRevisions[selectedShapeID,default: 0] += 1; self.selectedShapeID = nil } }
    func associate(_ reference: ProjectPersonReference?,with region: UUID,in people: ProjectPeopleDocument) throws {
        guard frame != nil, people.projectID == request.target.projectID else { throw ProjectFailure.invalidProject }
        guard let index = history.shapes.firstIndex(where: { $0.id == region }) else { return }
        if let reference { try people.validateReference(reference) }
        var next = history.shapes; next[index].person = reference; try history.replace(next)
    }
    func insertMention(_ reference: ProjectPersonReference,query: FramePersonMentionQuery,region: UUID,in people: ProjectPeopleDocument) throws {
        guard let frame, people.projectID == request.target.projectID else { throw ProjectFailure.invalidProject }
        try people.validateReference(reference)
        guard people.mentionMatches(query.query).contains(where: { $0.id == reference.personID }) else { throw ProjectFailure.invalidProject }
        guard let index = history.shapes.firstIndex(where: { $0.id == region }),
              history.shapes[index].note?.utf8.elementsEqual(query.note.utf8) == true, FramePersonMentionQuery.trailing(in: query.note) == query,
              let start = Range(NSRange(location: query.utf16Start,length: query.note.utf16.count-query.utf16Start),in: query.note) else {
            throw WorkflowFailure.invalid("This note changed. Choose the person again for its current words.")
        }
        var next = history.shapes
        let text = String(query.note[..<start.lowerBound])+"@"+reference.nameSnapshot+" "
        var mentions = FramePersonMention.rebased(next[index].mentions,from: query.note,to: text) ?? []
        mentions.removeAll { $0.utf16Start == query.utf16Start }
        mentions.append(.init(id: UUID(),person: reference,utf16Start: query.utf16Start,utf16Length: ("@"+reference.nameSnapshot).utf16.count,noteSHA256: FramePersonMention.hash(text)))
        next[index].note = text; next[index].mentions = mentions.sorted { $0.utf16Start < $1.utf16Start }
        try next[index].validate(width: frame.width,height: frame.height); try history.replace(next)
        noteEditRevisions[region,default: 0] += 1
    }
    func removeMention(_ id: UUID,region: UUID) throws {
        guard let index = history.shapes.firstIndex(where: { $0.id == region }) else { return }
        var next = history.shapes; let kept = next[index].mentions?.filter { $0.id != id } ?? []
        next[index].mentions = kept.isEmpty ? nil:kept; try history.replace(next)
    }
    func undo() { if history.canUndo { history.undo(); historyEditRevision += 1 }; selectedShapeID = nil }
    func redo() { if history.canRedo { history.redo(); historyEditRevision += 1 }; selectedShapeID = nil }
    func linkDictation(_ session: UUID,to region: UUID) throws {
        guard let index = history.shapes.firstIndex(where: { $0.id == region }) else { return }
        var next = history.shapes, ids = next[index].dictationSessionIDs ?? []
        if !ids.contains(session) { ids.append(session) }
        guard ids.count <= 64 else { throw WorkflowFailure.invalid("This region has reached its saved dictation limit. Add another region for more feedback.") }
        next[index].dictationSessionIDs = ids; try history.replace(next)
    }
    var validationIssue: String? {
        guard let frame else { return "Wait for the captured frame." }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !history.shapes.isEmpty else { return "Draw or add a note." }
        guard text.utf8.count <= 16_384 else { return "Keep the frame note within 16384 UTF-8 bytes. Your draft remains open." }
        do { for shape in history.shapes { try shape.validate(width: frame.width,height: frame.height) }; return nil }
        catch { return error.localizedDescription }
    }
    var canSave: Bool { validationIssue == nil }
    var canAttemptSave: Bool { pendingSave != nil || canSave }
    func beginSave() throws -> FrameCommentSaveAttempt {
        if let pendingSave { return pendingSave }
        guard canSave else { throw WorkflowFailure.invalid(validationIssue ?? "Add a note before saving.") }
        let snapshot = FrameCommentSaveAttempt(id: nextSaveID ?? id,supersedesID: supersedesID,text: text,annotations: history.shapes)
        pendingSave = snapshot; return snapshot
    }
    func acknowledgeSaved(_ snapshot: FrameCommentSaveAttempt) throws {
        guard pendingSave == snapshot else { throw ProjectFailure.invalidProject }
        // Retries retain an exact payload/ID until acknowledged. Any newer
        // wording then gets its own revision rather than reusing a consumed ID.
        pendingSave = nil; supersedesID = snapshot.id; nextSaveID = UUID()
    }
}
@MainActor @Observable final class FrameCommentController: Identifiable {
    nonisolated let id: UUID
    let project: Project
    let repository: FrameCommentRepository
    let dictation: RegionDictationController?
    private(set) var comments: [SavedFrameComment] = []
    private(set) var draft: FrameCommentDraft?
    private(set) var preparing = false
    private(set) var saving = false
    private(set) var people: ProjectPeopleDocument?
    private(set) var peopleBusy = false
    var peopleError: String?
    private(set) var personProposals: [FramePersonProposal] = []
    private(set) var findingPeople = false
    private(set) var peopleDetectionError: String?
    var error: String?
    @ObservationIgnored private let capture: any ReviewFrameCapturing
    @ObservationIgnored private let saveCheckpoint: @Sendable () async throws -> Void
    @ObservationIgnored private let peopleDetector: (any ReviewPeopleDetecting)?
    @ObservationIgnored private var detection: Task<Void,Never>?
    @ObservationIgnored private var detectionID: UUID?
    @ObservationIgnored private var preparation: Task<Void,Never>?
    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var draftEpoch = UUID()
    @ObservationIgnored private var saveTask: Task<Bool,Never>?
    @ObservationIgnored var releaseLease: (() -> Void)?
    init(project: Project, capture: any ReviewFrameCapturing = ReviewFrameCaptureService(), peopleDetector: (any ReviewPeopleDetecting)? = nil, dictation: RegionDictationController? = nil, saveCheckpoint: @escaping @Sendable () async throws -> Void = {}) {
        id = project.id; self.project = project; self.dictation = dictation; self.capture = capture; self.peopleDetector = peopleDetector; self.saveCheckpoint = saveCheckpoint; repository = .init(project: project)
    }
    var hasPendingWork: Bool { draft != nil || preparing || saveTask != nil || peopleBusy || dictation?.hasPendingWork == true }
    func load() async {
        do { comments = try await repository.list() } catch { self.error = error.localizedDescription }
        await refreshPeople(); await dictation?.load()
    }
    func refreshPeople() async {
        guard !peopleBusy else { return }
        peopleBusy = true; defer { peopleBusy = false }
        do { people = try await ProjectPeopleRepository(project: project).load(); peopleError = nil }
        catch { people = nil; peopleError = error.localizedDescription }
    }
    func assignPerson(_ id: UUID?,to region: UUID,draftID: UUID) async {
        guard !peopleBusy, !saving, draft?.id == draftID else { return }
        peopleBusy = true; defer { peopleBusy = false }
        do {
            let current = try await ProjectPeopleRepository(project: project).load(); people = current
            guard !saving, let draft, draft.id == draftID, draft.history.shapes.contains(where: { $0.id == region }) else { return }
            let reference: ProjectPersonReference?
            if let id {
                guard let person = current.people.first(where: { $0.id == id && $0.active }) else { throw WorkflowFailure.invalid("This person's name changed. Choose an available person again.") }
                reference = .init(projectID: project.id,personID: id,nameSnapshot: person.name,confirmedByUser: true)
            } else { reference = nil }
            try draft.associate(reference,with: region,in: current); peopleError = nil
        } catch { peopleError = error.localizedDescription }
    }
    func mentionPerson(_ id: UUID,query: FramePersonMentionQuery,region: UUID,draftID: UUID) async {
        guard !peopleBusy, !saving, draft?.id == draftID else { return }
        peopleBusy = true; defer { peopleBusy = false }
        do {
            let current = try await ProjectPeopleRepository(project: project).load(); people = current
            guard !saving, let draft, draft.id == draftID else { return }
            guard current.mentionMatches(query.query).contains(where: { $0.id == id }),
                  let person = current.people.first(where: { $0.id == id && $0.active }) else {
                throw WorkflowFailure.invalid("This person's name changed. Choose a current person again.")
            }
            let reference = ProjectPersonReference(projectID: project.id,personID: id,nameSnapshot: person.name,confirmedByUser: true)
            try draft.insertMention(reference,query: query,region: region,in: current); peopleError = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func createPerson(name: String) async -> Bool {
        await changePeople { repo in _ = try await repo.create(name: name) }
    }
    func renamePerson(_ id: UUID,name: String) async -> Bool {
        await changePeople { repo in _ = try await repo.rename(id,name: name) }
    }
    func archivePerson(_ id: UUID,archived: Bool) async {
        _ = await changePeople { repo in _ = try await repo.archive(id,archived: archived) }
    }
    func mergePerson(_ source: UUID,into destination: UUID) async {
        _ = await changePeople { repo in _ = try await repo.merge(source,into: destination) }
    }
    private func stopPeopleDetection() {
        detectionID = nil; detection?.cancel(); detection = nil
        findingPeople = false; personProposals = []; peopleDetectionError = nil
    }
    private func findPeople(in frame: FrozenReviewFrame,draftID: UUID) {
        stopPeopleDetection()
        guard let peopleDetector else { return }
        let generation = UUID(); detectionID = generation; findingPeople = true
        detection = Task {
            defer { if detectionID == generation { findingPeople = false; detection = nil } }
            do {
                let result = try await peopleDetector.detect(frame)
                try Task.checkCancellation()
                guard detectionID == generation, draft?.id == draftID, draft?.frame?.pngSHA256 == frame.pngSHA256 else { return }
                guard result.count <= 32, Set(result.map(\.id)).count == result.count else { throw ProjectFailure.invalidProject }
                for proposal in result { try proposal.validate(frame: frame) }
                personProposals = result
            } catch {
                if detectionID == generation, draft?.id == draftID { peopleDetectionError = error.localizedDescription }
            }
        }
    }
    func retryPeopleDetection() {
        guard !saving, let draft, let frame = draft.frame else { return }
        findPeople(in: frame,draftID: draft.id)
    }
    func acceptPersonProposal(_ id: UUID,draftID: UUID) {
        guard !saving, let draft, draft.id == draftID, let frame = draft.frame,
              let proposal = personProposals.first(where: { $0.id == id }) else { return }
        do {
            try proposal.validate(frame: frame); try draft.add(proposal.bounds,kind: .highlight)
            personProposals.removeAll { $0.id == id }; peopleDetectionError = nil
        } catch { peopleDetectionError = error.localizedDescription }
    }
    private func changePeople(_ operation: (ProjectPeopleRepository) async throws -> Void) async -> Bool {
        guard !peopleBusy, !saving else { return false }
        peopleBusy = true; defer { peopleBusy = false }
        do {
            let repo = ProjectPeopleRepository(project: project)
            try await operation(repo); people = try await repo.load(); peopleError = nil; return true
        } catch { peopleError = error.localizedDescription; return false }
    }
    func begin(_ request: FrameCommentRequest) throws {
        guard draft == nil, !preparing, !saving, request.target.projectID == project.id else { throw WorkflowFailure.invalid("Finish or cancel the open frame comment first.") }
        let next = FrameCommentDraft(request: request); draft = next; error = nil; preparing = true
        let previous = preparation, generation = UUID(); preparationID = generation
        preparation = Task {
            defer { if preparationID == generation { preparing = false; preparation = nil; preparationID = nil } }
            do {
                await previous?.value
                try Task.checkCancellation()
                let frozen = try await capture.capture(request,project: project)
                try Task.checkCancellation()
                guard draft?.id == next.id else { return }; try next.receive(frozen)
                findPeople(in: frozen,draftID: next.id)
            } catch { if draft?.id == next.id { self.error = error.localizedDescription } }
        }
    }
    func beginEdit(_ record: SavedFrameComment) throws {
        guard draft == nil, preparation == nil, !preparing, !saving else { throw WorkflowFailure.invalid("Finish or cancel the open frame comment first.") }
        let epoch = draftEpoch, generation = UUID()
        preparing = true; error = nil; preparationID = generation
        preparation = Task {
            defer { if preparationID == generation { preparing = false; preparation = nil; preparationID = nil } }
            do {
                let (saved,frame) = try await repository.read(record.id)
                try Task.checkCancellation()
                guard draft == nil, draftEpoch == epoch else { return }
                draft = .init(request: saved.request,text: saved.text,shapes: saved.annotations,supersedes: saved.id,frame: frame)
                if let draft { findPeople(in: frame,draftID: draft.id) }
            } catch { if draftEpoch == epoch { self.error = error.localizedDescription } }
        }
    }
    func dictateRegion(_ id: UUID) {
        guard !saving, let dictation, !dictation.hasPendingWork, let draft, let frame = draft.frame,
              let region = draft.history.shapes.first(where: { $0.id == id }), (region.dictationSessionIDs?.count ?? 0) < 64 else { return }
        let userEditIdentity = draft.dictationEditIdentity(id)
        var projection = RegionDictationProjection(draftID: draft.id,regionID: id,base: region.note ?? "",applied: region.note ?? "")
        dictation.start(frame: frame,region: region,draftID: draft.id) { [weak self] record in
            guard let self, let current = self.draft, current.id == projection.draftID else { return }
            do {
                if current.dictationEditIdentity(id) != userEditIdentity { projection.conflicted = true }
                let shape = current.history.shapes.first { $0.id == projection.regionID }
                // The durable anchor can be linked without any spoken words.
                // A user-removed region is never recreated by late results.
                if !projection.conflicted, let shape { try current.linkDictation(record.id,to: shape.id) }
                if let next = projection.next(transcript: record.transcript,current: shape?.note ?? (shape == nil ? nil:"")), let shape {
                    try current.updateRegion(shape.id,tag: shape.tag ?? "",note: next,dictated: true)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func closeDictationAndCancel() async -> Bool {
        guard !saving else { return false }
        if let dictation, !(await dictation.finish()) { error = dictation.error; return false }
        return cancel()
    }
    func beginRecoverDictation(_ id: UUID) throws {
        guard draft == nil, !preparing, !saving, let dictation else { throw ProjectFailure.invalidProject }
        let epoch = draftEpoch, generation = UUID(); preparing = true; preparationID = generation
        preparation = Task {
            defer { if preparationID == generation { preparing = false; preparation = nil; preparationID = nil } }
            do {
                let (record,frame) = try await dictation.repository.read(id)
                try Task.checkCancellation()
                guard draft == nil, draftEpoch == epoch else { return }
                var shape = record.region
                let base = shape.note ?? "", spoken = record.transcript
                shape.note = base+(base.isEmpty || spoken.isEmpty ? "":" ")+spoken
                shape.mentions = FramePersonMention.rebased(shape.mentions,from: base,to: shape.note ?? "")
                shape.dictationSessionIDs = Array(Set((shape.dictationSessionIDs ?? [])+[record.id])).sorted { $0.uuidString < $1.uuidString }
                draft = .init(request: record.request,shapes: [shape],frame: frame)
                draft?.selectedShapeID = shape.id; error = nil
            } catch { if draftEpoch == epoch { self.error = error.localizedDescription } }
        }
    }
    var canSaveFrameComment: Bool {
        !saving && !preparing && !peopleBusy && draft?.frame != nil && (draft?.canAttemptSave == true || dictation?.active == true)
    }
    @discardableResult func save() async -> Bool {
        if let saveTask { return await saveTask.value }
        guard !peopleBusy else { error = "Wait for the person update to finish before saving this frame comment."; return false }
        guard let draft, let frame = draft.frame, draft.canAttemptSave || dictation?.active == true else { error = "Draw or add a note."; return false }
        saving = true; error = nil
        let task = Task { () -> Bool in
            defer { saving = false; saveTask = nil }
            do {
                if let dictation, !(await dictation.finish()) { error = dictation.error; return false }
                // Finish an uncertain earlier attempt exactly before saving
                // newer words as its child. Two passes bound continuous edits.
                for pass in 0..<2 {
                    let snapshot = try draft.beginSave()
                    try await saveCheckpoint()
                    let record = try await repository.save(frame: frame,text: snapshot.text,annotations: snapshot.annotations,supersedes: snapshot.supersedesID,id: snapshot.id)
                    try draft.acknowledgeSaved(snapshot)
                    comments.removeAll { $0.id == record.id || $0.id == record.supersedesID }; comments.append(record)
                    guard self.draft?.id == draft.id else { return true }
                    if draft.text == snapshot.text, draft.history.shapes == snapshot.annotations {
                        self.draft = nil; stopPeopleDetection(); releaseLease?(); releaseLease = nil; return true
                    }
                    if pass == 1 || !draft.canSave { break }
                }
                error = "An earlier revision was saved; newer edits remain open and can be saved."
                return true
            } catch { self.error = error.localizedDescription; return false }
        }
        saveTask = task; return await task.value
    }
    @discardableResult func cancel() -> Bool {
        guard !saving, dictation?.hasPendingWork != true else { error = "Wait for the dictated words to finish saving before closing this frame comment."; return false }
        let requestID = draft?.request.id
        draftEpoch = UUID(); preparation?.cancel(); stopPeopleDetection(); draft = nil; preparing = false; error = nil
        if let requestID { Task { await capture.cancel(requestID) } }
        releaseLease?(); releaseLease = nil; return true
    }
    func flushForExit() async -> Bool {
        if let saveTask { _ = await saveTask.value }
        if let dictation, !(await dictation.finish()) { return false }
        return draft == nil && !preparing && !saving && !peopleBusy
    }
}
