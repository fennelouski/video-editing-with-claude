import Foundation
import Observation

@MainActor @Observable final class ScriptWorkspaceController {
    let project: Project
    private(set) var session: ScriptWorkspaceSession?
    private(set) var busy = false
    private(set) var failure: String?
    private(set) var assemblyFailure: String?
    private(set) var exportedURL: URL?
    private(set) var assemblies: [ScriptAssemblyReview] = []
    private(set) var writerSubmission: ScriptWriterSubmission?
    private(set) var generating = false
    @ObservationIgnored private let writer: any ScriptWriting
    @ObservationIgnored private var writerTask: Task<Void,Never>?
    var requestedAssemblyID: UUID?
    var requestedVersionID: UUID?
    @ObservationIgnored private let repository: ScriptWorkspaceRepository
    init(project: Project, repository: ScriptWorkspaceRepository = ScriptWorkspaceRepository(),writer: any ScriptWriting = ConnectedScriptWriter()) {
        self.project = project; self.repository = repository;self.writer = writer
    }
    func prepareWriter(title: String,model: String) async {
        guard !busy,let session else { return }
        do {
            guard let fresh = try await repository.load(project: project),fresh.state.revisionID == session.state.revisionID else { throw WorkflowFailure.invalid("Reload the changed source workspace before sending a script request.") }
            writerSubmission = try .init(session: fresh,title: title,model: model);failure = nil
        } catch { writerSubmission = nil;failure = error.localizedDescription }
    }
    func discardWriter() { if !busy { writerSubmission = nil } }
    func generateScript() {
        guard !busy,let submission = writerSubmission else { return }
        busy = true;generating = true
        writerTask = Task { [self] in
            defer { busy = false;generating = false;writerTask = nil;writerSubmission = nil }
            do {
                let response = try await writer.write(submission)
                try Task.checkCancellation()
                session = try await repository.saveWriterResponse(project: project,submission: submission,response: response)
                failure = nil;await refreshAssemblies()
            } catch { failure = error is CancellationError ? "Script request cancelled. No generated version or timeline was applied.":error.localizedDescription }
        }
    }
    func cancelWriter() async { writerTask?.cancel();await writer.cancel();await writerTask?.value }
    func flushForExit() async -> Bool {
        if generating { await cancelWriter() }
        return !busy
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { session = try await repository.load(project: project); failure = nil; exportedURL = nil; await refreshAssemblies() }
        catch { failure = error.localizedDescription; assemblies = [] }
    }
    @discardableResult func perform(_ action: ScriptWorkspaceAction) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do {
            session = try await repository.update(project: project, expectedRevision: session?.state.revisionID, action: action)
            await refreshAssemblies()
            failure = nil; exportedURL = nil; return true
        } catch { failure = error.localizedDescription; return false }
    }
    func exportWriterPacket() async {
        guard !busy, let session else { return }; busy = true; defer { busy = false }
        do { exportedURL = try await repository.exportWriterPacket(project: project, expectedRevision: session.state.revisionID); failure = nil }
        catch { failure = error.localizedDescription }
    }
    func assemble(_ version: UUID) async {
        guard !busy, let session else { return }; busy = true; defer { busy = false }
        do { exportedURL = try await repository.assemble(project: project, expectedRevision: session.state.revisionID, versionID: version); failure = nil; await refreshAssemblies() }
        catch { failure = error.localizedDescription }
    }
    private func refreshAssemblies() async {
        do { assemblies = try await repository.assemblies(project: project); assemblyFailure = nil }
        catch { assemblies = []; assemblyFailure = error.localizedDescription }
    }
}

/// One EditorStore owns this registry for all of its project workspaces. A copied
/// project with the same UUID cannot retarget another root's controller.
@MainActor final class ScriptWorkspaceRegistry {
    private struct Key: Hashable { let id: UUID; let path: String; let device: Int32?; let inode: UInt64? }
    private var controllers: [Key: ScriptWorkspaceController] = [:]
    var hasPendingWork: Bool { controllers.values.contains { $0.busy } }
    func flushForExit() async -> Bool {
        var saved = true
        for controller in controllers.values { if !(await controller.flushForExit()) { saved = false } }
        return saved
    }
    func remove(projectID: UUID) throws {
        guard !controllers.contains(where: { $0.key.id == projectID && $0.value.busy }) else { throw WorkflowFailure.invalid("Finish the active script operation before changing its project location.") }
        controllers = controllers.filter { $0.key.id != projectID }
    }
    func controller(for project: Project) -> ScriptWorkspaceController {
        let key = Key(id: project.id, path: project.folder.resolvingSymlinksInPath().standardizedFileURL.path,
            device: project.folderIdentity?.device, inode: project.folderIdentity?.inode)
        if let existing = controllers[key] { return existing }
        let next = ScriptWorkspaceController(project: project); controllers[key] = next; return next
    }
}
