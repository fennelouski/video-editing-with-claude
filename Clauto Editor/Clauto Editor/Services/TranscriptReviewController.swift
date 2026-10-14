import Foundation
import Observation

/// One captured project owns each controller; delayed edits never use sidebar selection.
@MainActor @Observable final class TranscriptReviewController {
    let project: Project
    var session: TranscriptReviewSession?
    private(set) var loading = false
    private(set) var operationDescription = "Opening review…"
    var saving = false
    var dirty = false
    var failure: String?
    var exportedURL: URL?
    var recoveredDraftURL: URL?
    @ObservationIgnored private let repository: TranscriptReviewRepository
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    var generationForDisplay: Int { generation }

    init(project: Project, repository: TranscriptReviewRepository = TranscriptReviewRepository()) {
        self.project = project; self.repository = repository
    }

    func load() async {
        guard !loading, !saving, !dirty else { return }
        operationDescription = "Opening review…"
        loading = true; defer { finishOperation() }
        do { session = try await repository.load(project: project); failure = nil }
        catch { failure = error.localizedDescription }
    }

    func importCatalog(_ url: URL) async {
        guard !loading, !saving, !dirty else { return }
        operationDescription = "Checking transcript sources…"
        loading = true; defer { finishOperation() }
        do { session = try await repository.importCatalog(url, project: project); failure = nil }
        catch { failure = error.localizedDescription }
    }

    func change(_ rowID: String, _ edit: (inout TranscriptRowDecision) -> Void) {
        guard var draft = session, !loading, var decision = draft.state.decisions[rowID] else { return }
        edit(&decision)
        guard decision != draft.state.decisions[rowID] else { return }
        draft.state.decisions[rowID] = decision; changed(draft)
    }

    func move(_ rowID: String, to position: Int) {
        guard var draft = session, !loading else { return }
        do {
            try draft.state.move(rowID, to: position)
            if draft.state.rowOrder != session?.state.rowOrder { changed(draft) }
        } catch { failure = error.localizedDescription }
    }

    private func changed(_ draft: TranscriptReviewSession) {
        session = draft; generation += 1; dirty = true; failure = nil; exportedURL = nil
        scheduleSave()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            // Coalesce typing, then serialize all later edits through this one loop.
            try? await Task.sleep(for: .milliseconds(250))
            await persistPending()
            saveTask = nil
        }
    }

    private func persistPending() async {
        saving = true; defer { saving = false }
        while dirty, let draft = session {
            let submitted = generation
            do {
                let saved = try await repository.save(draft, expectedRevision: draft.state.revisionID, project: project)
                if generation == submitted { session = saved; dirty = false }
                else if var newer = session {
                    // Keep keystrokes arriving during I/O, but advance their disk base.
                    newer.state.revisionID = saved.state.revisionID
                    newer.state.revisionNumber = saved.state.revisionNumber
                    newer.state.saved = saved.state.saved
                    newer.state.undoTargetRevisionID = saved.state.undoTargetRevisionID
                    newer.state.undoTargetSHA256 = saved.state.undoTargetSHA256
                    session = newer
                }
                failure = nil
            } catch { failure = error.localizedDescription; return }
        }
    }

    @discardableResult func flush() async -> Bool {
        if dirty && saveTask == nil { scheduleSave() }
        if let task = saveTask { await task.value }
        return !dirty && failure == nil
    }

    func undo() async {
        guard !loading else { return }
        operationDescription = "Restoring the previous review choices…"
        loading = true; defer { finishOperation() }
        guard await flush(), let current = session else { return }
        do {
            session = try await repository.undo(expectedRevision: current.state.revisionID, project: project)
            failure = nil; exportedURL = nil
        } catch { failure = error.localizedDescription }
    }

    func exportSelections() async {
        guard !loading else { return }
        operationDescription = "Exporting review selections…"
        loading = true; defer { finishOperation() }
        guard await flush(), let current = session else { return }
        do { exportedURL = try await repository.export(expectedRevision: current.state.revisionID, project: project); failure = nil }
        catch { failure = error.localizedDescription }
    }

    func saveDraftAndReload() async {
        guard !loading else { return }
        operationDescription = "Preserving the pending draft and reloading…"
        loading = true; defer { finishOperation() }
        if let task = saveTask { await task.value }
        guard let draft = session else { return }
        do {
            let backup = try await repository.saveDraftCopy(draft, project: project)
            let latest = try await repository.load(project: project)
            recoveredDraftURL = backup; session = latest; dirty = false; failure = nil
        } catch { failure = error.localizedDescription }
    }

    func waitForPendingOperation() async {
        guard loading else { return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func finishOperation() {
        loading = false
        let waiters = operationWaiters; operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor enum TranscriptReviewExit {
    /// Retry pending writes and drain edits arriving during I/O. A read/import
    /// error with no unsaved choices does not trap the user in the application.
    static func flush(_ controllers: [TranscriptReviewController]) async -> Bool {
        while true {
            let pending = controllers.filter { $0.dirty || $0.saving || $0.loading }
            if pending.isEmpty { return true }
            for controller in pending {
                await controller.waitForPendingOperation()
                if controller.dirty || controller.saving {
                    guard await controller.flush() else { return false }
                }
            }
        }
    }
}
