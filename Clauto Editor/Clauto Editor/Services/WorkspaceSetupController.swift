import Foundation
import Observation

/// One owned operation, one configuration epoch. Changing folders invalidates
/// results immediately, but cannot release the physical slot before its task joins.
@MainActor @Observable final class WorkspaceSetupController {
    private(set) var checks: [SetupCheck] = []
    private(set) var busy = false
    private(set) var stopping = false
    private(set) var pausedForExit = false
    private(set) var error: String?
    private(set) var prepared: PreparedWorkspace?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var operation: Task<Void,Never>?
    @ObservationIgnored private let service: SetupService
    @ObservationIgnored private let workspace: WorkspacePreparation
    init(service: SetupService = .init(runner: ProcessRunner()),workspace: WorkspacePreparation = .init()) {
        self.service = service;self.workspace = workspace
    }
    func invalidate() {
        revision = UUID(); checks = []; prepared = nil;error = nil;stopping = busy
        operation?.cancel()
    }
    func run(engine: URL,projects: URL,prepare: Bool) async {
        guard !busy, !pausedForExit else { return }
        let owner = revision
        busy = true;error = nil; checks = []
        let previous = prepared
        let task = Task<Void,Never> { [self] in
            do {
                let receipt: PreparedWorkspace?
                if prepare { receipt = try await workspace.prepare(projects) } else { receipt = previous }
                try Task.checkCancellation()
                guard revision == owner else { return }
                let result = try await service.check(engine: engine,projectsRoot: projects,prepared: receipt)
                try Task.checkCancellation()
                guard revision == owner else { return }
                prepared = receipt; checks = result
            } catch is CancellationError { }
            catch { if revision == owner { self.error = "Workspace preparation could not finish. Your existing files are unchanged. Retry, or choose another project folder." } }
        }
        operation = task
        await task.value
        operation = nil;busy = false;stopping = false
    }
    func pauseForExit() async { pausedForExit = true; await stopAndWait() }
    func resumeAfterCancelledExit() { pausedForExit = false }
    func stopAndWait() async {
        invalidate()
        if let operation { await operation.value }
        // run() owns releasing busy and the task reference, so a new request
        // cannot overlap with a delayed outer completion.
    }
}
