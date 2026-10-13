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
    private var activePID: pid_t?
    private var activeRun: UUID?
    private var wasCancelled = false
    private var cancellationTask: Task<Void, Never>?

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
        guard activePID == nil else { throw ProcessFailure.busy }
        let output = Pipe(), errorPipe = Pipe()
        let pid = try Self.spawn(command, output: output, error: errorPipe)
        let runID = UUID()
        activePID = pid; activeRun = runID; wasCancelled = false
        try? output.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        let outTask = Task { await Self.drain(output.fileHandleForReading, isError: false, onLine: onLine) }
        let errTask = Task { await Self.drain(errorPipe.fileHandleForReading, isError: true, onLine: onLine) }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: command.timeout)
            if !Task.isCancelled { await self?.cancel(runID: runID) }
        }
        defer { timeoutTask.cancel(); activePID = nil; activeRun = nil }
        return await withTaskCancellationHandler {
            let code: Int32 = await withCheckedContinuation { continuation in
                // waitpid is blocking; keep it off the cooperative Swift executor.
                DispatchQueue.global(qos: .userInitiated).async {
                    var info = siginfo_t()
                    var result: Int32
                    // Keep the exited group leader unreaped during cancellation escalation:
                    // its reserved PID prevents a signal from reaching a reused group ID.
                    repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
                    let code: Int32 = result == -1 ? -1 : (info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status)
                    continuation.resume(returning: code)
                }
            }
            let out = await outTask.value
            let err = await errTask.value
            if let cancellationTask { await cancellationTask.value }
            var reapedStatus: Int32 = 0
            while waitpid(pid, &reapedStatus, 0) == -1 && errno == EINTR { }
            cancellationTask = nil
            return ProcessResult(exitCode: code, output: out, error: err, cancelled: wasCancelled)
        } onCancel: { Task { await self.cancel(runID: runID) } }
    }

    func cancel() { if let runID = activeRun { cancel(runID: runID) } }

    private func cancel(runID: UUID) {
        guard activeRun == runID, let pid = activePID else { return }
        guard cancellationTask == nil else { return }
        wasCancelled = true
        // posix_spawn assigns a new process group before exec. The group contains only
        // this run, including ffmpeg/model descendants; it never contains the GUI.
        kill(-pid, SIGINT)
        cancellationTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard activeRun == runID else { return }
            kill(-pid, SIGTERM)
            try? await Task.sleep(for: .seconds(2))
            guard activeRun == runID else { return }
            kill(-pid, SIGKILL)
        }
    }

    private nonisolated static func spawn(_ command: ProcessCommand, output: Pipe, error: Pipe) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, error.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        if let directory = command.directory {
            let code = posix_spawn_file_actions_addchdir(&actions, directory.path)
            if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        var signals = sigset_t(); sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        sigaddset(&signals, SIGINT); sigaddset(&signals, SIGTERM); sigaddset(&signals, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let arguments = [command.executable.path] + command.arguments
        let environment = Self.environment(overrides: command.environment).map { "\($0.key)=\($0.value)" }
        guard !(arguments + environment).contains(where: { $0.utf8.contains(0) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, command.executable.path, &actions, &attributes, &argv, &envp)
        if code != 0 {
            try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? error.fileHandleForReading.close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return pid
    }

    private nonisolated static func drain(_ handle: FileHandle, isError: Bool,
                                         onLine: (@Sendable (ProcessLine) async -> Void)?) async -> String {
        defer { try? handle.close() }
        var captured = Data(), pending = Data()
        while true {
            let chunk: Data = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: handle.availableData) }
            }
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
