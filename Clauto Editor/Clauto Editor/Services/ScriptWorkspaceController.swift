import Foundation
import Observation

@MainActor @Observable final class ScriptWorkspaceController {
    let project: Project
    private(set) var session: ScriptWorkspaceSession?
    private(set) var busy = false
    private(set) var failure: String?
    private(set) var exportedURL: URL?
    @ObservationIgnored private let repository: ScriptWorkspaceRepository
    init(project: Project, repository: ScriptWorkspaceRepository = ScriptWorkspaceRepository()) {
        self.project = project; self.repository = repository
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { session = try await repository.load(project: project); failure = nil; exportedURL = nil }
        catch { failure = error.localizedDescription }
    }
    @discardableResult func perform(_ action: ScriptWorkspaceAction) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do {
            session = try await repository.update(project: project, expectedRevision: session?.state.revisionID, action: action)
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
        do { exportedURL = try await repository.assemble(project: project, expectedRevision: session.state.revisionID, versionID: version); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
