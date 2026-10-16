import Foundation
import Darwin

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

/// A receipt belongs to one observed directory, never a persistent promise that
/// a removable drive is still connected or writable on the next launch.
struct PreparedWorkspace: Sendable {
    var root: URL
    var identity: RenderDirectoryIdentity
}

actor WorkspacePreparation {
    func prepare(_ requested: URL) throws -> PreparedWorkspace {
        try Task.checkCancellation()
        guard requested.isFileURL, requested.path != "/" else { throw ProjectFailure.invalidProject }
        let selected = requested.standardizedFileURL
        guard selected.path != "/" else { throw ProjectFailure.invalidProject }
        try ProjectRepository.validateDrive(selected)
        // Resolve the closest existing ancestor first. Foundation can leave
        // system aliases unresolved when the complete selected path is missing.
        var ancestor = selected,missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            try Task.checkCancellation()
            guard ancestor.path != "/" else { throw ProjectFailure.invalidProject }
            missing.insert(ancestor.lastPathComponent,at: 0)
            ancestor.deleteLastPathComponent()
        }
        var folder = try SourceRenderDirectory.open(ancestor)
        let url = missing.reduce(folder.url) { $0.appendingPathComponent($1) }
        guard url.path != "/" else { throw ProjectFailure.invalidProject }
        try ProjectRepository.validateDrive(url)
        for component in missing {
            try Task.checkCancellation()
            try folder.checkPath()
            try ProjectRepository.validateDrive(url)
            // Mounted roots must already exist; no local mountpoint fallback.
            let next = folder.url.appendingPathComponent(component)
            let mountComponent = next.pathComponents.count <= 3 && next.pathComponents.dropFirst().first == "Volumes"
            folder = try folder.child(component,create: !mountComponent)
        }
        try folder.checkPath()
        try Task.checkCancellation()
        let name = ".clauto-setup-check-"+UUID().uuidString
        let fd = openat(folder.descriptor,name,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW,S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkflowFailure.invalid("This folder could not be prepared. Choose an available project folder, then retry.") }
        defer { Darwin.close(fd) }
        // Unlink while empty, before writing. Cleanup cannot delete a replaced
        // leaf or follow a renamed root; an unlink failure retains only an empty
        // uniquely named file and is never reported as successful preparation.
        guard unlinkat(folder.descriptor,name,0) == 0 else { throw WorkflowFailure.invalid("The folder could not finish its temporary write check. Retry when the drive is available.") }
        let bytes = Array("Clauto workspace".utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(fd,$0.baseAddress,bytes.count) }) == bytes.count,
              fsync(fd) == 0, lseek(fd,0,SEEK_SET) == 0 else { throw ProjectFailure.invalidProject }
        var readback = [UInt8](repeating: 0,count: bytes.count)
        guard Darwin.read(fd,&readback,readback.count) == bytes.count, readback == bytes else { throw ProjectFailure.invalidProject }
        try Task.checkCancellation()
        try folder.checkPath()
        return .init(root: url,identity: folder.identity)
    }
}

/// A separate actor keeps synchronous drive and input checks off MainActor,
/// including builds using NonisolatedNonsendingByDefault. Filesystem calls may
/// still be uninterruptible; the UI owner retains its slot until they return.
actor SetupService {
    let runner: any CommandRunning
    let locate: @Sendable (String) -> URL?
    init(runner: any CommandRunning,locate: @escaping @Sendable (String) -> URL? = { ProcessRunner.executable($0) }) {
        self.runner = runner;self.locate = locate
    }

    /// Uses only local, noninteractive probes. No installer, account command,
    /// model load, engine stage, shell or user project is run by this check.
    func check(engine: URL, projectsRoot: URL, prepared: PreparedWorkspace? = nil) async throws -> [SetupCheck] {
        try Task.checkCancellation()
        var checks = [SetupCheck(id: "review",title: "Review and drawing",state: .ready,
            detail: "Movie review, frame notes and local creative tools are included. Choose or prepare a project folder to save your work.")]
        do {
            try ProjectRepository.validateDrive(projectsRoot)
            let folder = try SourceRenderDirectory.open(projectsRoot)
            let verified = prepared?.identity == folder.identity && prepared?.root.path == folder.url.path
            checks.append(.init(id: "folders",title: "Project folder",state: verified ? .ready : .notChecked,
                detail: verified ? "Prepared with a temporary write and readback check. Originals and existing projects were preserved." : "Use Prepare workspace to check saving in this folder. Existing files will stay in place."))
        } catch { checks.append(.init(id: "folders",title: "Project folder",state: .needsAttention,
            detail: "Use Prepare workspace to create the selected folder, or choose an available drive and retry.")) }
        let files = FileManager.default
        let python = engine.appendingPathComponent(".venv/bin/python")
        let observedEngine = try? SourceRenderDirectory.open(engine)
        let observedInputs = Self.signatures(engine)
        let versionBytes = try? observedEngine?.read("ENGINE_VERSION",limit: 1024)
        let fontVersionReady = versionBytes.flatMap { String(data: $0,encoding: .utf8) }.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let enginePresent = observedEngine != nil
        var probe: EngineSetupProbe?
        if enginePresent, files.isExecutableFile(atPath: engine.appendingPathComponent("run").path), files.isExecutableFile(atPath: python.path) {
            do {
            let result = try await runner.run(.init(executable: python,arguments: ["-I","-B","-c",Self.pythonProbe,engine.path],directory: engine,
                environment: ["HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1","HF_HUB_DISABLE_TELEMETRY":"1"],timeout: .seconds(20)),onLine: nil)
            try Task.checkCancellation()
            if result.cancelled { throw CancellationError() }
            if result.succeeded, result.output.utf8.count <= 16_384 {
                let data = Data(result.output.utf8)
                try TranscriptJSONKeys.validate(data)
                probe = try JSONDecoder().decode(EngineSetupProbe.self,from: data)
            }
            } catch is CancellationError { throw CancellationError() }
              catch { probe = nil }
        }
        let pythonReady = probe.map { $0.version.count == 3 && $0.version[0] == 3 && $0.version[1] >= 12 } ?? false
        let exportReady = pythonReady && Self.exportScripts.allSatisfy { probe?.syntax[$0] == true && observedInputs[$0] != "unavailable" }
        checks.append(.init(id: "engine",title: "Local editing engine",state: exportReady ? .ready : .needsAttention,
            detail: exportReady ? "The selected engine's Python 3.12 or newer can parse its export tools." : "Choose an installed editing engine to enable exports. Clauto could not verify this engine's Python and export scripts. Review and drawing remain available."))
        var videoReady = exportReady
        for name in ["ffmpeg","ffprobe"] {
            try Task.checkCancellation()
            guard let executable = locate(name) else { videoReady = false; continue }
            do {
            let result = try await runner.run(.init(executable: executable,arguments: ["-version"],timeout: .seconds(10)),onLine: nil)
            try Task.checkCancellation()
            if result.cancelled { throw CancellationError() }
            videoReady = videoReady && result.succeeded && result.output.hasPrefix(name+" version ")
            } catch is CancellationError { throw CancellationError() }
              catch { videoReady = false }
        }
        checks.append(.init(id: "exports",title: "Saved-cut exports",state: videoReady ? .ready : .needsAttention,
            detail: videoReady ? "The selected Python export tools and both video tools respond. A real export still checks its own inputs." : "Local exports need a verified engine and both video tools. Retry after local tools are available; reviewing movies does not require them."))
        let fontReady = pythonReady && fontVersionReady
            && Self.fontScripts.allSatisfy { probe?.syntax[$0] == true && observedInputs[$0] != "unavailable" }
            && Self.fontModules.allSatisfy { probe?.modules[$0] == true }
        checks.append(.init(id: "fonts",title: "Custom font builds",state: fontReady ? .ready : .needsAttention,
            detail: fontReady ? "The selected engine can load its local image and font libraries." : "Font drawing is available. Building a font needs the selected engine's image and font libraries."))
        checks.append(.init(id: "transcription",title: "Footage transcription",state: .notChecked,
            detail: "Pipeline transcription and its cached model are checked when preparing a project. This workspace check does not load or download a model."))
        checks.append(.init(id: "signin",title: "Conversation account",state: .notChecked,
            detail: "Conversation connects in the project when you choose to send. Workspace preparation does not check or change your account."))
        checks.append(.init(id: "model",title: "Local voice feedback",state: .notChecked,
            detail: "Speech recognition is included. Starting voice feedback guides microphone, speech access and local model preparation inside Clauto."))
        try Task.checkCancellation()
        let currentInputs = Self.signatures(engine)
        let rootChanged = observedEngine == nil || (try? SourceRenderDirectory.open(engine).identity) != observedEngine?.identity
        let changed = Set(observedInputs.keys.filter { observedInputs[$0] != currentInputs[$0] })
        let commonChanged = !changed.isDisjoint(with: ["run",".venv/bin/python"])
        for index in checks.indices {
            let id = checks[index].id
            let exportChanged = !changed.isDisjoint(with: Self.exportScripts)
            if rootChanged || commonChanged || (id == "fonts" ? !changed.isDisjoint(with: Self.fontScripts+["ENGINE_VERSION"]) : exportChanged) {
                if ["engine","exports","fonts"].contains(id) {
                    checks[index].state = .needsAttention
                    checks[index].detail = "The selected engine or its tools changed during the check. Retry with the current folder."
                }
            }
        }
        if let prepared, (try? SourceRenderDirectory.open(projectsRoot).identity) != prepared.identity {
            if let index = checks.firstIndex(where: { $0.id == "folders" }) {
                checks[index].state = .needsAttention
                checks[index].detail = "The project folder changed or disconnected during its check. Prepare the current folder again."
            }
        }
        return checks
    }

    private struct EngineSetupProbe: Decodable {
        var version: [Int]
        var syntax: [String:Bool]
        var modules: [String:Bool]
    }
    static let exportScripts = ["scripts/timeline_derivatives.py","scripts/config.py","scripts/fcpxml.py","scripts/duration_bounds.py","scripts/graphic_scene_cue.py","scripts/offline_run.py","scripts/cli.py"]
    static let fontScript = "scripts/tools/custom_font_studio.py"
    static let fontScripts = [fontScript,"scripts/tools/trace.py"]
    static let fontModules = ["PIL.Image","PIL.ImageOps","numpy","fontTools.fontBuilder","fontTools.ttLib","fontTools.ttLib.tables._g_l_y_f","fontTools.ttLib.tables.ttProgram","fontTools.varLib.instancer","brotli"]
    private static func signatures(_ engine: URL) -> [String:String] {
        var result: [String:String] = [:]
        for name in ["run",".venv/bin/python","ENGINE_VERSION"]+exportScripts+fontScripts {
            let file = engine.appendingPathComponent(name).resolvingSymlinksInPath()
            do {
                let digest: String
                if name == ".venv/bin/python" {
                    // Standard venv interpreters are intentionally symlinked.
                    digest = try ClaudeClientContract.digest(file)
                } else {
                    var directory = try SourceRenderDirectory.open(engine)
                    let components = name.split(separator: "/").map(String.init)
                    for component in components.dropLast() { directory = try directory.child(component) }
                    // Match the font worker's regular-file, size and no-follow
                    // contract; a followed helper symlink cannot count as ready.
                    digest = TranscriptSourceMap.sha(try directory.read(components.last!,limit: name == "ENGINE_VERSION" ? 1024 : 1024*1024))
                    try directory.checkPath()
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                result[name] = [file.path,digest,String(describing: attributes[.systemFileNumber]),String(describing: attributes[.systemNumber]),String(describing: attributes[.posixPermissions])].joined(separator: "|")
            } catch { result[name] = "unavailable" }
        }
        return result
    }
    static let pythonProbe = #"""
import ast, importlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
scripts = ["scripts/timeline_derivatives.py", "scripts/config.py", "scripts/fcpxml.py", "scripts/duration_bounds.py", "scripts/graphic_scene_cue.py", "scripts/offline_run.py", "scripts/cli.py", "scripts/tools/custom_font_studio.py", "scripts/tools/trace.py"]
syntax = {}
for name in scripts:
    try:
        with (root / name).open("rb") as handle:
            source = handle.read(1024 * 1024 + 1)
        if len(source) > 1024 * 1024:
            raise ValueError("script limit")
        ast.parse(source, filename=name)
        syntax[name] = True
    except Exception:
        syntax[name] = False
modules = {}
for name in ["PIL.Image", "PIL.ImageOps", "numpy", "fontTools.fontBuilder", "fontTools.ttLib", "fontTools.ttLib.tables._g_l_y_f", "fontTools.ttLib.tables.ttProgram", "fontTools.varLib.instancer", "brotli"]:
    try:
        importlib.import_module(name)
        modules[name] = True
    except Exception:
        modules[name] = False
print(json.dumps({"version": list(sys.version_info[:3]), "syntax": syntax, "modules": modules}, sort_keys=True))
"""#
}
