import Foundation

/// Account operations belong to the existing Claude client. Clauto never reads
/// tokens, accepts API keys, or copies credentials into the project.
struct ClaudeAccountService: Sendable {
    enum Status: Equatable, Sendable { case ready, signedOut, differentAccountMethod }
    let contract: ClaudeClientContract
    let runner: any CommandRunning
    func status() async throws -> Status {
        try verifyClient()
        let result = try await runner.run(command(["auth","status","--json"],timeout: .seconds(15)),onLine: nil)
        if result.cancelled { throw CancellationError() }
        try verifyClient()
        // The official client documents exit 1 for signed out. Unknown errors
        // never count as a connected account, and their raw output is not UI.
        if result.exitCode == 1 { return .signedOut }
        guard result.succeeded, result.output.utf8.count <= 65_536 else { throw ClaudeClientFailure.accountCheck }
        let method: String
        do {
            let bytes = Data(result.output.utf8); try TranscriptJSONKeys.validate(bytes)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String:Any],
                  let value = object["authMethod"] as? String else { throw ClaudeClientFailure.accountCheck }
            method = value
        } catch { throw ClaudeClientFailure.accountCheck }
        switch method {
        case "claude.ai": return .ready
        case "none": return .signedOut
        default: return .differentAccountMethod
        }
    }
    /// Called only by the app's Sign In button. The client opens its own browser
    /// flow and stores the existing account in its own credential store.
    func signIn() async throws {
        try verifyClient()
        let result = try await runner.run(command(["auth","login","--claudeai"],timeout: .seconds(300)),onLine: nil)
        if result.cancelled { throw CancellationError() }
        try verifyClient()
        guard result.succeeded else { throw ClaudeClientFailure.signInRequired }
        guard try await status() == .ready else { throw ClaudeClientFailure.signInRequired }
    }
    private func verifyClient() throws {
        guard try ClaudeClientContract.digest(contract.executable) == contract.executableSHA256 else { throw ClaudeClientFailure.changed }
    }
    private func command(_ arguments: [String],timeout: Duration) -> ProcessCommand {
        .init(executable: contract.executable,arguments: arguments,
              environment: ClaudeClientContract.environment(contract.executable),timeout: timeout)
    }
}
