import Foundation
import Observation

@MainActor @Observable final class FrameCommentDraft: Identifiable {
    let id = UUID()
    let request: FrameCommentRequest
    let supersedesID: UUID?
    var text: String
    var history: FrameAnnotationHistory
    var selectedShapeID: UUID?
    var tool = FrameAnnotationKind.ellipse
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
    func removeSelected() throws { if let selectedShapeID { try history.remove(selectedShapeID); self.selectedShapeID = nil } }
    func undo() { history.undo(); selectedShapeID = nil }
    func redo() { history.redo(); selectedShapeID = nil }
    var canSave: Bool { frame != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 16_384 }
}
@MainActor @Observable final class FrameCommentController: Identifiable {
    nonisolated let id: UUID
    let project: Project
    let repository: FrameCommentRepository
    private(set) var comments: [SavedFrameComment] = []
    private(set) var draft: FrameCommentDraft?
    private(set) var preparing = false
    private(set) var saving = false
    var error: String?
    @ObservationIgnored private let capture: any ReviewFrameCapturing
    @ObservationIgnored private var preparation: Task<Void,Never>?
    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var draftEpoch = UUID()
    @ObservationIgnored private var saveTask: Task<Bool,Never>?
    @ObservationIgnored var releaseLease: (() -> Void)?
    init(project: Project, capture: any ReviewFrameCapturing = ReviewFrameCaptureService()) {
        id = project.id; self.project = project; self.capture = capture; repository = .init(project: project)
    }
    var hasPendingWork: Bool { draft != nil || preparing || saveTask != nil }
    func load() async { do { comments = try await repository.list() } catch { self.error = error.localizedDescription } }
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
            } catch { if draftEpoch == epoch { self.error = error.localizedDescription } }
        }
    }
    @discardableResult func save() async -> Bool {
        if let saveTask { return await saveTask.value }
        guard let draft, let frame = draft.frame, draft.canSave else { error = "Add a written comment before saving. A circle alone is not an editing instruction."; return false }
        let text = draft.text, annotations = draft.history.shapes
        saving = true
        let task = Task { () -> Bool in
            defer { saving = false; saveTask = nil }
            do {
                let record = try await repository.save(frame: frame,text: text,annotations: annotations,supersedes: draft.supersedesID,id: draft.id)
                // A committed save stays acknowledged even if a subsequent
                // directory refresh fails. Never retry an already saved draft.
                comments.removeAll { $0.id == record.supersedesID }; comments.append(record)
                if self.draft?.id == draft.id, draft.text == text, draft.history.shapes == annotations { self.draft = nil; releaseLease?(); releaseLease = nil }
                else { error = "An earlier draft was saved; newer edits are still open." }
                return true
            } catch { self.error = error.localizedDescription; return false }
        }
        saveTask = task; return await task.value
    }
    @discardableResult func cancel() -> Bool {
        guard !saving else { error = "Wait for the save to finish before closing this frame comment."; return false }
        let requestID = draft?.request.id
        draftEpoch = UUID(); preparation?.cancel(); draft = nil; preparing = false; error = nil
        if let requestID { Task { await capture.cancel(requestID) } }
        releaseLease?(); releaseLease = nil; return true
    }
    func flushForExit() async -> Bool {
        if let saveTask { _ = await saveTask.value }
        return draft == nil && !preparing && !saving
    }
}
