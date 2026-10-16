import Foundation

protocol ConversationLocalEditExecuting: Sendable {
    func execute(_ request: ConversationLocalEditRequest,project: Project,engine: URL,
                 onLine: @escaping @Sendable (ProcessLine) async -> Void) async throws -> DerivedCut
    func cancel() async
}

/// One fresh instance per attempt. Cancellation cannot target a later manual or
/// automatic export. Only local scripts see media; the provider gets no file tools.
actor ConversationLocalEditWorker: ConversationLocalEditExecuting {
    private let runner: any CommandRunning
    private var started = false
    init(runner: any CommandRunning = ProcessRunner()) { self.runner = runner }
    func cancel() async { await runner.cancel() }
    func execute(_ request: ConversationLocalEditRequest,project: Project,engine: URL,
                 onLine: @escaping @Sendable (ProcessLine) async -> Void) async throws -> DerivedCut {
        guard !started else { throw ProcessFailure.busy };started = true
        try request.validate(project: project.id);try Task.checkCancellation()
        let root = try ProjectMutationLease.checkedRoot(project)
        var bound = project;bound.folderIdentity = root.identity
        let repository = WorkflowRepository()
        guard let version = try await repository.versions(project: bound).first(where: { $0.id==request.target.versionID }),
              version.number==request.target.versionNumber,version.engineVersion==request.target.engineVersion else {
            throw WorkflowFailure.invalid("The local command's saved version is unavailable. Its feedback remains attached to that version.")
        }
        let source = try await repository.derivativeSource(version,project: bound)
        guard source.timelineSHA256==request.target.timelineSHA256,
              abs(source.duration-request.target.duration)<=1e-9,source.engineVersion==request.target.engineVersion else {
            throw WorkflowFailure.invalid("The local command's saved inputs changed. Its feedback will not be moved to another cut.")
        }
        try Task.checkCancellation();try root.checkPath()
        return try await DerivativeService(runner: runner,disk: repository)
            .export(request.output,version: version,project: bound,engine: engine,onLine: onLine)
    }
}
