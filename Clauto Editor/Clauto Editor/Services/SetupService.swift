import Foundation

struct SetupCheck: Identifiable, Sendable {
    enum State: String, Sendable { case ready = "Ready", needsAttention = "Needs attention", notChecked = "Not checked" }
    var id: String
    var title: String
    var state: State
    var detail: String
}

struct EnginePreflight: Decodable, Sendable {
    var ready: Bool
    var problems: [String]
    var engine_version: String
}

struct StageEvent: Decodable, Identifiable, Sendable {
    enum State: String, Decodable, Sendable { case start, done, fail }
    var stage: Int
    var state: State
    var detail: String
    var id: Int { stage }
}

struct SetupService: Sendable {
    var runner: any CommandRunning

    func check(engine: URL, projectsRoot: URL) async -> [SetupCheck] {
        var checks: [SetupCheck] = []
        for (name, title, arguments) in [("brew", "Homebrew", ["--version"]), ("ffmpeg", "Video tools", ["-version"]),
                                          ("git", "Git", ["--version"]), ("python3.11", "Python 3.11", ["--version"]),
                                          ("claude", "Claude Code", ["--version"])] {
            guard let executable = name == "claude" ? ClaudeClientContract.locate():ProcessRunner.executable(name) else {
                checks.append(SetupCheck(id: name, title: title, state: .needsAttention, detail: "\(title) is missing. Installation is a later setup milestone.")); continue
            }
            do {
                let result = try await runner.run(ProcessCommand(executable: executable, arguments: arguments, timeout: .seconds(15)), onLine: nil)
                checks.append(SetupCheck(id: name, title: title, state: result.succeeded ? .ready : .needsAttention,
                                         detail: result.succeeded ? (result.output + result.error).components(separatedBy: "\n").first ?? "Available" : "The check failed. Retry after checking the tool installation."))
            } catch { checks.append(SetupCheck(id: name, title: title, state: .needsAttention, detail: error.localizedDescription)) }
        }
        let engineExists = FileManager.default.fileExists(atPath: engine.appendingPathComponent("run").path)
        let venvExists = FileManager.default.isExecutableFile(atPath: engine.appendingPathComponent(".venv/bin/python").path)
        checks.append(SetupCheck(id: "engine", title: "Editing engine", state: engineExists && venvExists ? .ready : .needsAttention,
                                 detail: engineExists && venvExists ? "Engine and Python environment found. Release pinning is pending." : "Choose an engine folder with its Python environment installed."))
        do {
            try ProjectRepository.validateDrive(projectsRoot)
            checks.append(SetupCheck(id: "folders", title: "Project drive", state: .ready, detail: projectsRoot.path))
        } catch { checks.append(SetupCheck(id: "folders", title: "Project drive", state: .needsAttention, detail: error.localizedDescription)) }
        checks.append(SetupCheck(id: "signin", title: "Claude sign-in", state: .notChecked, detail: "Send a message in your project to connect. Sign-in is guided there; this check does not contact your account."))
        checks.append(SetupCheck(id: "model", title: "Speech model", state: .notChecked, detail: "Voice feedback and region dictation guide local speech setup when you start. Pipeline transcription uses the project's separately installed model."))
        return checks
    }
}
