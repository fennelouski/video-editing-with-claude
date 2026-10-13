import Foundation
import Darwin

struct ProcessCommand: Sendable {
    var executable: URL
    var arguments: [String] = []
    var directory: URL? = nil
    var environment: [String: String] = [:]
    var timeout: Duration = .seconds(60)
}

struct ProcessLine: Sendable {
    var text: String
    var isError: Bool
}

struct ProcessResult: Sendable {
    var exitCode: Int32
    var output: String
    var error: String
    var cancelled: Bool
    var succeeded: Bool { exitCode == 0 && !cancelled }
}

enum ProcessFailure: LocalizedError {
    case busy
    var errorDescription: String? { "A check is already running. Stop it or wait for it to finish." }
}

protocol CommandRunning: Sendable {
    func run(_ command: ProcessCommand, onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult
    func cancel() async
}

actor ProcessRunner: CommandRunning {
    private var active: Process?
    private var wasCancelled = false

    nonisolated static func environment(overrides: [String: String] = [:]) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Finder launches don't inherit a login shell. Never rely on an inherited PATH.
        result["PATH"] = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                          "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        result["PYTHONUNBUFFERED"] = "1"
        result["PYTHONDONTWRITEBYTECODE"] = "1"
        result["HF_HUB_DISABLE_TELEMETRY"] = "1"
        result["PYANNOTE_METRICS_ENABLED"] = "0"
        return result.merging(overrides) { _, new in new }
    }

    nonisolated static func executable(_ name: String, environment: [String: String] = environment()) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func run(_ command: ProcessCommand, onLine: (@Sendable (ProcessLine) async -> Void)? = nil) async throws -> ProcessResult {
        try Task.checkCancellation()
        guard active == nil else { throw ProcessFailure.busy }
        let process = Process()
        let output = Pipe(), errorPipe = Pipe()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        process.environment = Self.environment(overrides: command.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorPipe
        active = process
        wasCancelled = false
        // Drain both pipes concurrently: waiting for exit first deadlocks on a full pipe.
        let outTask = Task.detached { await Self.drain(output.fileHandleForReading, isError: false, onLine: onLine) }
        let errTask = Task.detached { await Self.drain(errorPipe.fileHandleForReading, isError: true, onLine: onLine) }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: command.timeout)
            if !Task.isCancelled { await self?.cancel() }
        }
        defer { timeoutTask.cancel(); active = nil }
        let code: Int32
        do {
            code = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus) }
                    do {
                        try process.run()
                        try? output.fileHandleForWriting.close()
                        try? errorPipe.fileHandleForWriting.close()
                    } catch {
                        try? output.fileHandleForWriting.close()
                        try? errorPipe.fileHandleForWriting.close()
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: { Task { await self.cancel() } }
        } catch {
            _ = await outTask.value
            _ = await errTask.value
            throw error
        }
        let out = await outTask.value
        let err = await errTask.value
        return ProcessResult(exitCode: code, output: out, error: err, cancelled: wasCancelled)
    }

    func cancel() {
        guard let process = active, process.isRunning else { return }
        wasCancelled = true
        process.interrupt()
        Task {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private nonisolated static func drain(_ handle: FileHandle, isError: Bool,
                                         onLine: (@Sendable (ProcessLine) async -> Void)?) async -> String {
        defer { try? handle.close() }
        var captured = Data(), pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            captured.append(chunk)
            if captured.count > 262_144 { captured.removeFirst(captured.count - 262_144) }
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                await onLine?(ProcessLine(text: line, isError: isError))
            }
            // A tool emitting a giant unterminated line must not grow memory without limit.
            if pending.count > 262_144 { pending.removeFirst(pending.count - 262_144) }
        }
        if !pending.isEmpty { await onLine?(ProcessLine(text: String(decoding: pending, as: UTF8.self), isError: isError)) }
        return String(decoding: captured, as: UTF8.self)
    }
}
