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
    var requestedAssemblyID: UUID?
    var requestedVersionID: UUID?
    @ObservationIgnored private let repository: ScriptWorkspaceRepository
    init(project: Project, repository: ScriptWorkspaceRepository = ScriptWorkspaceRepository()) {
        self.project = project; self.repository = repository
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
