import Foundation
import CryptoKit

struct EditRun: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case prepared, running, needsReview, needsAssets, failed, cancelled, complete }
    var id = UUID()
    var folder: URL
    var projectID: UUID
    var label: String
    var state: State = .prepared
    var events: [StageEventRecord] = []
    var approvedPlanHash: String? = nil
    var failure: String? = nil
    var created = Date()
    var ownerProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
}

struct StageEventRecord: Codable, Identifiable, Sendable {
    var stage: Int
    var state: String
    var detail: String
    var id: Int { stage }
}

struct MissingPiece: Codable, Identifiable, Sendable {
    var ref: String
    var kind: String
    var key: String
    var status: String
    var notes: [String]
    var id: String { ref }
}

struct CutVersion: Codable, Identifiable, Sendable {
    var id = UUID()
    var number: Int
    var label: String
    var created = Date()
    var engineVersion: String
    var runID: UUID
    var artifacts: [String]
    var approvedPlanHash: String
    var sourceSchemaChecked: Bool? = nil
    var briefHash: String? = nil
    var folderName: String { String(format: "v%03d", number) }
    func briefChanged(_ project: Project) -> Bool {
        guard let briefHash else { return false }
        return briefHash != SHA256.hash(data: Data(project.brief.markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct LocalMessage: Codable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var created = Date()
    var state = "Saved locally; awaiting an authorized Claude session"
}

enum WorkflowFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { text } else { nil } }
}

actor WorkflowRepository {
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; value.dateEncodingStrategy = .iso8601; return value
    }()
    private let decoder: JSONDecoder = { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }()

    private func safe(_ path: String, in root: URL) throws -> URL {
        try ProjectRepository.validateDrive(root)
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ProjectFailure.invalidProject }
        let url = root.appendingPathComponent(path)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw ProjectFailure.invalidProject }
        return url
    }

    private func projectFolder(for run: EditRun) throws -> URL {
        guard UUID(uuidString: run.folder.lastPathComponent) != nil,
              run.folder.deletingLastPathComponent().lastPathComponent == "runs",
              run.folder.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "build" else { throw ProjectFailure.invalidProject }
        let project = run.folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let canonical = try safe("build/runs/" + run.folder.lastPathComponent, in: project)
        guard canonical.resolvingSymlinksInPath().standardizedFileURL.path == run.folder.resolvingSymlinksInPath().standardizedFileURL.path,
              try decoder.decode(ProjectManifest.self, from: Data(contentsOf: project.appendingPathComponent("clauto-project.json"))).id == run.projectID else { throw ProjectFailure.invalidProject }
        return project
    }

    func validate(_ run: EditRun, project: Project) throws {
        guard run.projectID == project.id, try projectFolder(for: run).resolvingSymlinksInPath().standardizedFileURL.path == project.folder.resolvingSymlinksInPath().standardizedFileURL.path else { throw ProjectFailure.invalidProject }
    }

    func settings(_ run: EditRun, project: Project, engine: URL) throws -> [String: String] {
        try validate(run, project: project)
        let settings = try decoder.decode([String: String].self, from: Data(contentsOf: safe("paths.json", in: run.folder)))
        let expected = ["footage": try safe("inputs/footage", in: run.folder), "script": try safe("inputs/script", in: run.folder),
                        "assets": try safe("assets", in: project.folder), "build": run.folder, "cuts": try safe("cuts", in: project.folder),
                        "templates": engine.appendingPathComponent("templates")]
        for (key, folder) in expected {
            guard let path = settings[key], path.hasPrefix("/"), URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw WorkflowFailure.invalid("This run's \(key) folder changed. Start a new run using the project's original folder settings.")
            }
            try ProjectRepository.validateDrive(folder)
        }
        let version = try String(contentsOf: engine.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == project.manifest.engineVersion else { throw WorkflowFailure.invalid("This run requires its original engine version.") }
        if let cache = settings["model_cache"] {
            guard cache.hasPrefix("/"), !project.folder.path.hasPrefix("/Volumes/Videos/") || URL(fileURLWithPath: cache).resolvingSymlinksInPath().path.hasPrefix("/Volumes/Videos/Food Videos/Katie YouTube/") else { throw ProjectFailure.invalidProject }
            try ProjectRepository.validateDrive(URL(fileURLWithPath: cache))
        } else { throw WorkflowFailure.invalid("Choose a model cache before running.") }
        guard let script = settings["approved_script"], script.hasPrefix("/"),
              URL(fileURLWithPath: script).resolvingSymlinksInPath().path.hasPrefix((try safe("inputs/script", in: run.folder)).resolvingSymlinksInPath().path + "/"),
              fm.fileExists(atPath: script) else { throw WorkflowFailure.invalid("The saved script is unavailable. Approve a script and start a new run.") }
        return settings
    }

    func prepare(project: Project, engine: URL, label: String, primaryID: UUID? = nil) throws -> EditRun {
        let missing = project.manifest.files.filter { !fm.fileExists(atPath: project.folder.appendingPathComponent($0.relativePath).path) }
        guard missing.isEmpty else { throw ProjectFailure.missingFile(missing.map(\.name).joined(separator: ", ")) }
        let footage = project.manifest.files.filter { $0.group == .footage }
        guard let primary = primaryID.flatMap({ id in footage.first { $0.id == id } }) ?? (footage.count == 1 ? footage.first : nil) else {
            throw WorkflowFailure.invalid("Choose the narration clip for this cut. The current engine finishes one narration source per run; other footage remains available in the project.")
        }
        guard !primary.name.lowercased().hasSuffix(".insv") else { throw ProjectFailure.unsupportedCamera }
        let engineVersion = try String(contentsOf: engine.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.manifest.engineVersion == engineVersion else { throw WorkflowFailure.invalid("This project uses a different engine version. Choose its original engine before running.") }
        var paths = try decoder.decode([String: String].self, from: Data(contentsOf: project.folder.appendingPathComponent("paths.json")))
        for key in ["footage", "assets", "script", "templates"] {
            guard let value = paths[key], value.hasPrefix("/"), fm.fileExists(atPath: value) else { throw WorkflowFailure.invalid("The \(key) folder is unavailable. Choose it in project settings and retry.") }
        }
        for key in ["assets", "build", "cuts", "script"] {
            guard let path = paths[key], URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == (try safe(key, in: project.folder)).resolvingSymlinksInPath().standardizedFileURL.path else {
                throw WorkflowFailure.invalid("The \(key) folder must belong to this project. Reopen the project with its original folder settings.")
            }
        }
        if project.folder.path.hasPrefix("/Volumes/Videos/") {
            guard let cache = paths["model_cache"], cache.hasPrefix("/Volumes/Videos/Food Videos/Katie YouTube/") else {
                throw WorkflowFailure.invalid("Choose a model cache on the Videos NAS before running.")
            }
        }
        let folder = try safe("build/runs/\(UUID().uuidString)", in: project.folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: folder) } }
        let inputs = folder.appendingPathComponent("inputs")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: paths["script"]!), to: inputs.appendingPathComponent("script"))
        let scripts = try fm.contentsOfDirectory(at: inputs.appendingPathComponent("script"), includingPropertiesForKeys: nil)
            .filter { ["md", "txt", "docx"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("~$") }
        guard let selectedScript = scripts.first(where: { $0.lastPathComponent == "script.md" }) ?? (scripts.count == 1 ? scripts.first : nil) else {
            throw WorkflowFailure.invalid("Choose one script for this cut, or use the Brief's approved script. Multiple documents cannot be selected by filename order.")
        }
        paths["approved_script"] = try safe("inputs/script/" + selectedScript.lastPathComponent, in: folder).path
        try fm.copyItem(at: project.folder.appendingPathComponent("brief.md"), to: inputs.appendingPathComponent("brief.md"))
        let narration = inputs.appendingPathComponent("footage/a-cam")
        try fm.createDirectory(at: narration, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: narration.appendingPathComponent(primary.name), withDestinationURL: project.folder.appendingPathComponent(primary.relativePath).resolvingSymlinksInPath())
        paths["footage"] = inputs.appendingPathComponent("footage").path
        paths["script"] = inputs.appendingPathComponent("script").path
        paths["build"] = folder.path
        paths["cuts"] = project.folder.appendingPathComponent("cuts").path
        try encoder.encode(paths).write(to: folder.appendingPathComponent("paths.json"), options: .atomic)
        let run = EditRun(folder: folder, projectID: project.id, label: label)
        try save(run)
        prepared = true
        return run
    }

    func save(_ run: EditRun) throws {
        _ = try projectFolder(for: run)
        try encoder.encode(run).write(to: safe("clauto-run.json", in: run.folder), options: .atomic)
    }

    func recentRun(project: Project) throws -> EditRun? {
        let root = try safe("build/runs", in: project.folder)
        guard fm.fileExists(atPath: root.path) else { return nil }
        let runs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder -> EditRun? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("clauto-run.json")) else { return nil }
            guard let decoded = try? decoder.decode(EditRun.self, from: data), decoded.folder.resolvingSymlinksInPath().standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
            guard (try? validate(decoded, project: project)) != nil else { return nil }
            return decoded
        }.filter { $0.projectID == project.id }
        return runs.max { $0.created < $1.created }
    }

    func plan(_ run: EditRun) throws -> (text: String, hash: String, issues: [String]) {
        _ = try projectFolder(for: run)
        let root = try safe("plan", in: run.folder)
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".plan.json") }
        guard files.count == 1 else { throw WorkflowFailure.invalid("A single graphic plan is required. Resolve the plan step and retry.") }
        let data = try Data(contentsOf: safe(files[0].lastPathComponent, in: root))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cues = object["cues"] as? [[String: Any]], let problems = object["issues"] as? [String],
              let unresolved = object["unresolved"] as? [String] else { throw WorkflowFailure.invalid("The graphic plan is unreadable. Rebuild the plan before approving it.") }
        let issues = problems + unresolved.map { "Unresolved cue: \($0)" } + cues.compactMap { $0["unresolved"] as? String }.filter { !$0.isEmpty }
        return (String(decoding: data, as: UTF8.self), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), issues)
    }

    func missing(_ run: EditRun) throws -> [MissingPiece] {
        _ = try projectFolder(for: run)
        let folder = try safe("plan", in: run.folder)
        guard let file = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasSuffix(".assets.json") }) else { return [] }
        struct Sheet: Decodable { var resolutions: [MissingPiece] }
        return try decoder.decode(Sheet.self, from: Data(contentsOf: safe(file.lastPathComponent, in: folder))).resolutions.filter { $0.status != "ok" }
    }

    func satisfy(_ piece: MissingPiece, urls: [URL], run: EditRun) throws {
        let project = try projectFolder(for: run)
        let folders = ["cutout": "cutouts", "texture": "textures", "foley": "foley", "music": "music", "broll": "broll", "macro": "macro"]
        guard let subfolder = folders[piece.kind], !piece.key.isEmpty,
              piece.key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else { throw ProjectFailure.invalidProject }
        let paths = try decoder.decode([String: String].self, from: Data(contentsOf: safe("paths.json", in: run.folder)))
        let base = ["broll", "macro"].contains(piece.kind) ? try safe("inputs/footage", in: run.folder) : try safe("assets", in: project)
        guard paths[["broll", "macro"].contains(piece.kind) ? "footage" : "assets"].map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }) == base.resolvingSymlinksInPath().standardizedFileURL.path else { throw ProjectFailure.invalidProject }
        let destination = try safe(subfolder, in: base)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for source in urls {
            guard fm.fileExists(atPath: source.path), (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw ProjectFailure.missingFile(source.lastPathComponent) }
            var version = 1
            var target: URL
            repeat {
                target = destination.appendingPathComponent("\(piece.key)_v\(String(format: "%02d", version))_a.\(source.pathExtension.lowercased())")
                version += 1
            } while fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            try fm.createSymbolicLink(at: target, withDestinationURL: source.resolvingSymlinksInPath())
        }
        // The engine rechecks format, alpha, resolution and variants. A drop is not a green tick.
    }

    func appendLog(_ line: ProcessLine, run: EditRun) throws {
        _ = try projectFolder(for: run)
        let url = try safe("run.log", in: run.folder)
        if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data((line.text + "\n").utf8))
    }

    func logTail(_ run: EditRun) throws -> String {
        _ = try projectFolder(for: run)
        let handle = try FileHandle(forReadingFrom: safe("run.log", in: run.folder)); defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length > 262_144 ? length - 262_144 : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }

    func versions(project: Project) throws -> [CutVersion] {
        let root = try safe("cuts", in: project.folder)
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: "^v[0-9]+$", options: .regularExpression) != nil }
            .map { folder in
                _ = try safe(folder.lastPathComponent, in: root)
                let version = try decoder.decode(CutVersion.self, from: Data(contentsOf: folder.appendingPathComponent("clauto-version.json")))
                guard version.number > 0, version.folderName == folder.lastPathComponent else { throw ProjectFailure.invalidProject }
                for artifact in version.artifacts { _ = try safe(artifact, in: folder) }
                return version
            }
            .sorted { $0.number < $1.number }
    }

    func current(project: Project) throws -> CutVersion? {
        let pointer = try safe("cuts/current.json", in: project.folder)
        guard fm.fileExists(atPath: pointer.path) else { return nil }
        let id = try decoder.decode(UUID.self, from: Data(contentsOf: pointer))
        guard let version = try versions(project: project).first(where: { $0.id == id }) else {
            throw WorkflowFailure.invalid("The current version record is missing. Choose an available version to restore.")
        }
        return version
    }

    func restore(_ version: CutVersion, project: Project) throws {
        guard try versions(project: project).contains(where: { $0.id == version.id }) else { throw ProjectFailure.invalidProject }
        try encoder.encode(version.id).write(to: safe("cuts/current.json", in: project.folder), options: .atomic)
    }

    func snapshot(_ run: EditRun, project: Project) throws -> CutVersion {
        try validate(run, project: project)
        guard run.state == .complete, run.projectID == project.id,
              let approval = run.approvedPlanHash, try plan(run).hash == approval else { throw WorkflowFailure.invalid("Review the current graphic plan before saving a finished cut.") }
        let exports = try safe("exports", in: run.folder)
        let timelines = try fm.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil).filter { $0.pathExtension == "fcpxml" }
        guard !timelines.isEmpty else { throw WorkflowFailure.invalid("The engine did not produce a timeline. The previous cut is still current.") }
        struct Validation: Decodable { var timeline: String; var sha256: String; var problems: [String]; var schemaChecked: Bool }
        var schemaChecked = true
        for timeline in timelines {
            let checked = try safe(timeline.lastPathComponent, in: exports)
            let report = try decoder.decode(Validation.self, from: Data(contentsOf: safe(timeline.deletingPathExtension().lastPathComponent + ".validation.json", in: exports)))
            let hash = SHA256.hash(data: try Data(contentsOf: checked)).map { String(format: "%02x", $0) }.joined()
            guard report.timeline == timeline.lastPathComponent, report.sha256 == hash, report.problems.isEmpty else {
                throw WorkflowFailure.invalid("The timeline's validation evidence is missing or changed. Re-run rendering before saving a version.")
            }
            schemaChecked = schemaChecked && report.schemaChecked
        }
        let number = (try versions(project: project).map(\.number).max() ?? 0) + 1
        let folder = try safe(String(format: "cuts/v%03d", number), in: project.folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var artifacts: [String] = []
        do {
            for section in ["exports", "roughcut", "plan", "inputs"] {
                let source = try safe(section, in: run.folder)
                guard fm.fileExists(atPath: source.path) else { continue }
                for case let file as URL in fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey])! {
                    guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                          ["fcpxml", "itt", "mp4", "pdf", "txt", "md", "docx", "json"].contains(file.pathExtension) else { continue }
                    let resolvedFile = file.resolvingSymlinksInPath()
                    let resolvedRun = run.folder.resolvingSymlinksInPath()
                    guard resolvedFile.path.hasPrefix(resolvedRun.path + "/") else { continue }
                    var relative = String(resolvedFile.path.dropFirst(resolvedRun.path.count + 1))
                    // This receipt validates the engine's source XML. URI rewriting below
                    // creates different bytes, so keep its role explicit in the version.
                    if relative.hasSuffix(".validation.json") { relative = String(relative.dropLast(".validation.json".count)) + ".source-validation.json" }
                    let target = try safe(relative, in: folder)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if file.pathExtension == "fcpxml" {
                        let xml = try XMLDocument(contentsOf: file, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
                        for case let node as XMLElement in try xml.nodes(forXPath: "//media-rep[@src] | //asset[@src]") {
                            guard let src = node.attribute(forName: "src"), let value = src.stringValue,
                                  let media = URL(string: value), media.isFileURL else { throw ProjectFailure.invalidProject }
                            let resolved = media.resolvingSymlinksInPath()
                            guard fm.fileExists(atPath: resolved.path) else { throw ProjectFailure.missingFile(resolved.lastPathComponent) }
                            if resolved.path.hasPrefix(resolvedRun.path + "/") {
                                let name = "media/\(SHA256.hash(data: Data(resolved.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined())-\(resolved.lastPathComponent)"
                                let copied = try safe(name, in: folder)
                                try fm.createDirectory(at: copied.deletingLastPathComponent(), withIntermediateDirectories: true)
                                if !fm.fileExists(atPath: copied.path) { try fm.copyItem(at: resolved, to: copied) }
                                src.stringValue = copied.absoluteString
                            } else { src.stringValue = resolved.absoluteString }
                        }
                        let saved = xml.xmlData
                        try saved.write(to: target, options: .atomic)
                        let record = relative.replacingOccurrences(of: ".fcpxml", with: ".snapshot.json")
                        let hashes: [String: Any] = [
                            "source_sha256": SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined(),
                            "saved_sha256": SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined(),
                            "transformation": "Made local media references permanent; source validation is retained separately.",
                        ]
                        try JSONSerialization.data(withJSONObject: hashes, options: [.prettyPrinted, .sortedKeys]).write(to: safe(record, in: folder), options: .atomic)
                        artifacts.append(record)
                    } else { try fm.copyItem(at: file, to: target) }
                    artifacts.append(relative)
                }
            }
            guard artifacts.contains(where: { $0.hasSuffix(".heard.txt") }) else { throw WorkflowFailure.invalid("Read-back is missing. This cut remains unverified and the previous version stays current.") }
            let briefHash = SHA256.hash(data: try Data(contentsOf: safe("inputs/brief.md", in: run.folder))).map { String(format: "%02x", $0) }.joined()
            let version = CutVersion(number: number, label: run.label, engineVersion: project.manifest.engineVersion, runID: run.id, artifacts: artifacts, approvedPlanHash: approval, sourceSchemaChecked: schemaChecked, briefHash: briefHash)
            try encoder.encode(version).write(to: folder.appendingPathComponent("clauto-version.json"), options: .atomic)
            try encoder.encode(version.id).write(to: safe("cuts/current.json", in: project.folder), options: .atomic)
            return version
        } catch { try? fm.removeItem(at: folder); throw error }
    }

    func messages(project: Project) throws -> [LocalMessage] {
        let file = try safe("notes/conversation.json", in: project.folder)
        return fm.fileExists(atPath: file.path) ? try decoder.decode([LocalMessage].self, from: Data(contentsOf: file)) : []
    }
    func queue(_ text: String, project: Project) throws -> [LocalMessage] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowFailure.invalid("Write a change request first.") }
        var messages = try messages(project: project)
        messages.append(LocalMessage(text: text))
        try encoder.encode(messages).write(to: safe("notes/conversation.json", in: project.folder), options: .atomic)
        return messages
    }
}
