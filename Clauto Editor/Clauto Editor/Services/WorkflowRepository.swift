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
    var narrationCount: Int? = nil
    var durationBounds: VideoDurationBounds? = nil
    var exportResolution: ExportResolution? = nil
    var aspect: String? = nil
    var whisperModel: String? = nil
    var outputSettingsSchema: Int? = nil
    var creativeReferenceHashes: [String: String]? = nil
    var creativeReferenceSnapshotSHA256: String? = nil
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
    var savedSchemaChecked: Bool? = nil
    var briefHash: String? = nil
    var approvedScript: String? = nil
    var primaryOutputPrefix: String? = nil
    var durationBounds: VideoDurationBounds? = nil
    var exportResolution: ExportResolution? = nil
    var aspect: String? = nil
    func preferredArtifact(_ suffix: String) -> String? {
        if let prefix = primaryOutputPrefix, [".heard.txt", ".edl.json", ".preview.mp4", ".mp4"].contains(suffix) {
            return artifacts.contains(prefix + suffix) ? prefix + suffix : nil
        }
        return artifacts.first { $0.hasSuffix(suffix) }
    }
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

struct CutFeedback: Codable, Identifiable, Sendable {
    enum Attachment: String, Codable, Sendable { case verified, changedOrMissingVersion, invalidRange }
    var id = UUID()
    var projectID: UUID
    var versionID: UUID
    var versionNumber: Int
    var timelineSHA256: String
    var startSeconds: Double
    var endSeconds: Double?
    var text: String
    var created = Date()
    var resolved = false
    var resolvedAt: Date? = nil
    var attachment: Attachment? = nil
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
        let base = root.resolvingSymlinksInPath()
        var ancestor = base
        // Foundation may leave an absent leaf unresolved. Check each ancestor
        // so an escaped notes directory cannot hide behind a new filename.
        for component in path.split(separator: "/") {
            ancestor = ancestor.appendingPathComponent(String(component)).resolvingSymlinksInPath()
            guard ancestor.path.hasPrefix(base.path + "/") else { throw ProjectFailure.invalidProject }
        }
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
        try TranscriptProductionGate.requireLegacyPipelineAllowed(project: project)
        guard run.projectID == project.id, try projectFolder(for: run).resolvingSymlinksInPath().standardizedFileURL.path == project.folder.resolvingSymlinksInPath().standardizedFileURL.path else { throw ProjectFailure.invalidProject }
    }

    func settings(_ run: EditRun, project: Project, engine: URL) throws -> [String: String] {
        try validate(run, project: project)
        let settings = try decoder.decode([String: String].self, from: Data(contentsOf: safe("paths.json", in: run.folder)))
        try run.durationBounds?.validate()
        let frozenBounds = try settings["duration_bounds"].map { try decoder.decode(VideoDurationBounds.self, from: Data($0.utf8)) }
        guard frozenBounds == run.durationBounds else { throw WorkflowFailure.invalid("This run's duration limits changed. Start a new run with the intended limits.") }
        try validateOutputSettings(run, settings: settings)
        guard ((run.narrationCount ?? 1) > 1) == (settings["assembly"] != nil) else { throw ProjectFailure.invalidProject }
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
        if let assembly = settings["assembly"] {
            guard URL(fileURLWithPath: assembly).standardizedFileURL == (try safe("inputs/narration-order.json", in: run.folder)).standardizedFileURL else { throw ProjectFailure.invalidProject }
            let data = try Data(contentsOf: URL(fileURLWithPath: assembly))
            guard settings["assembly_sha256"] == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else {
                throw WorkflowFailure.invalid("The narration order changed. Start a new run with the intended clips.")
            }
            let spec = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard spec?["schema_version"] as? Int == 2, let sources = spec?["sources"] as? [[String: String]], sources.count >= 2,
                  Set(sources.compactMap { $0["source"] }).count == sources.count else { throw ProjectFailure.invalidProject }
            let intake = try safe("inputs/footage/a-cam", in: run.folder)
            let linked = try fm.contentsOfDirectory(at: intake, includingPropertiesForKeys: nil)
            guard sources.allSatisfy({ value in linked.contains { $0.resolvingSymlinksInPath().path == value["source"] && $0.deletingPathExtension().lastPathComponent == value["key"] } }),
                  sources.count == linked.count else { throw WorkflowFailure.invalid("The narration order changed. Start a new run with the intended clips.") }
        }
        let snapshotURL = try safe("inputs/creative-references/provenance.json", in: run.folder)
        if fm.fileExists(atPath: snapshotURL.path) {
            let data = try Data(contentsOf: snapshotURL)
            guard run.creativeReferenceSnapshotSHA256 == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined(),
                  settings["creative_reference_schema"] == "1" else { throw WorkflowFailure.invalid("This run's creative-reference snapshot changed or its identity was cleared.") }
            let frozen = try decoder.decode([CreativeReference].self, from: data)
            var hashes: [String: String] = [:]
            for reference in frozen { hashes[reference.role.rawValue] = reference.sha256 }
            guard hashes == (run.creativeReferenceHashes ?? [:]) else {
                throw WorkflowFailure.invalid("This run's creative-reference identities differ from its preserved snapshot.")
            }
        } else if run.creativeReferenceSnapshotSHA256 != nil || settings["creative_reference_schema"] != nil {
            throw WorkflowFailure.invalid("This run's creative-reference snapshot is missing.")
        }
        for key in ["style_guide", "taste_principles"] {
            guard settings[key + "_sha256"] == run.creativeReferenceHashes?[key],
                  (settings[key] != nil) == (run.creativeReferenceHashes?[key] != nil) else {
                throw WorkflowFailure.invalid("This run's creative-reference identities changed. Start a new run with the intended versions.")
            }
            if let path = settings[key] {
                let url = URL(fileURLWithPath: path)
                guard url.resolvingSymlinksInPath().path.hasPrefix((try safe("inputs/creative-references", in: run.folder)).resolvingSymlinksInPath().path + "/"),
                      settings[key + "_sha256"] == SHA256.hash(data: try Data(contentsOf: url)).map({ String(format: "%02x", $0) }).joined() else {
                    throw WorkflowFailure.invalid("This run's creative references changed. Start a new run with the intended reference versions.")
                }
            }
        }
        return settings
    }

    func prepare(project: Project, engine: URL, label: String, primaryID: UUID? = nil, narrationIDs: [UUID] = []) throws -> EditRun {
        try TranscriptProductionGate.requireLegacyPipelineAllowed(project: project)
        try project.manifest.durationBounds?.validate()
        let missing = project.manifest.files.filter { !fm.fileExists(atPath: project.folder.appendingPathComponent($0.relativePath).path) }
        guard missing.isEmpty else { throw ProjectFailure.missingFile(missing.map(\.name).joined(separator: ", ")) }
        let footage = project.manifest.files.filter { $0.group == .footage }
        let ordered = try narrationIDs.map { id -> ProjectFile in
            guard let file = footage.first(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }; return file
        }
        guard Set(narrationIDs).count == narrationIDs.count else { throw ProjectFailure.invalidProject }
        guard let primary = ordered.first ?? primaryID.flatMap({ id in footage.first { $0.id == id } }) ?? (footage.count == 1 ? footage.first : nil) else {
            throw WorkflowFailure.invalid("Choose and order the narration clips for this cut.")
        }
        let selected = ordered.isEmpty ? [primary] : ordered
        guard selected.allSatisfy({ !$0.name.lowercased().hasSuffix(".insv") }) else { throw ProjectFailure.unsupportedCamera }
        guard Set(selected.map { URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent.lowercased() }).count == selected.count else {
            throw WorkflowFailure.invalid("Narration clips need distinct names before transcription. Rename the project copies or choose clips with different names.")
        }
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
        let references = try ProjectRepositoryReferenceSnapshot.read(project)
        for key in ["style_guide", "taste_principles"] { paths.removeValue(forKey: key); paths.removeValue(forKey: key + "_sha256") }
        var referenceSnapshotSHA256: String?
        if !references.isEmpty {
            let referenceFolder = try safe("inputs/creative-references", in: folder)
            try fm.createDirectory(at: referenceFolder, withIntermediateDirectories: true)
            let snapshot = try encoder.encode(references.map(\.0))
            try snapshot.write(to: referenceFolder.appendingPathComponent("provenance.json"), options: .withoutOverwriting)
            referenceSnapshotSHA256 = SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined()
            paths["creative_reference_schema"] = "1"
            // Last attachment of a role wins for this new run; previous versions
            // remain retained in the project and previous run snapshots.
            for (reference, data) in references {
                let destination = referenceFolder.appendingPathComponent(reference.id.uuidString + "-" + reference.name)
                try data.write(to: destination, options: .withoutOverwriting)
                paths[reference.role.rawValue] = destination.path
                paths[reference.role.rawValue + "_sha256"] = reference.sha256
            }
        }
        let narration = inputs.appendingPathComponent("footage/a-cam")
        try fm.createDirectory(at: narration, withIntermediateDirectories: true)
        for file in selected {
            try fm.createSymbolicLink(at: narration.appendingPathComponent(file.name), withDestinationURL: project.folder.appendingPathComponent(file.relativePath).resolvingSymlinksInPath())
        }
        if selected.count > 1 {
            let spec: [String: Any] = ["schema_version": 2, "sources": selected.map {
                ["source": project.folder.appendingPathComponent($0.relativePath).resolvingSymlinksInPath().path,
                 "key": URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent]
            }]
            let order = inputs.appendingPathComponent("narration-order.json")
            let data = try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: order)
            paths["assembly"] = order.path
            paths["assembly_sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        paths["footage"] = inputs.appendingPathComponent("footage").path
        paths["script"] = inputs.appendingPathComponent("script").path
        paths["build"] = folder.path
        paths["cuts"] = project.folder.appendingPathComponent("cuts").path
        paths["duration_bounds"] = try project.manifest.durationBounds.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        paths["export_resolution"] = project.manifest.outputResolution.rawValue
        paths["aspect"] = project.manifest.aspect
        paths["whisper_model"] = project.manifest.whisperModel
        paths["output_settings_schema"] = "1"
        try encoder.encode(paths).write(to: folder.appendingPathComponent("paths.json"), options: .atomic)
        var run = EditRun(folder: folder, projectID: project.id, label: label)
        run.narrationCount = selected.count
        run.durationBounds = project.manifest.durationBounds
        run.exportResolution = project.manifest.outputResolution
        run.aspect = project.manifest.aspect
        run.whisperModel = project.manifest.whisperModel
        run.outputSettingsSchema = 1
        let referenceHashes = Dictionary(uniqueKeysWithValues: ["style_guide", "taste_principles"].compactMap { key in paths[key + "_sha256"].map { (key, $0) } })
        run.creativeReferenceHashes = referenceHashes.isEmpty ? nil : referenceHashes
        run.creativeReferenceSnapshotSHA256 = referenceSnapshotSHA256
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
        let settings = try decoder.decode([String: String].self, from: Data(contentsOf: safe("paths.json", in: run.folder)))
        let frozenBounds = try settings["duration_bounds"].map { try decoder.decode(VideoDurationBounds.self, from: Data($0.utf8)) }
        guard frozenBounds == run.durationBounds else { throw WorkflowFailure.invalid("This run's duration limits changed. Start a new run with the intended limits.") }
        try validateOutputSettings(run, settings: settings)
        guard run.state == .complete, run.projectID == project.id,
              let approval = run.approvedPlanHash, try plan(run).hash == approval else { throw WorkflowFailure.invalid("Review the current graphic plan before saving a finished cut.") }
        let exports = try safe("exports", in: run.folder)
        let timelines = try fm.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil).filter { $0.pathExtension == "fcpxml" }
        guard !timelines.isEmpty else { throw WorkflowFailure.invalid("The engine did not produce a timeline. The previous cut is still current.") }
        if let resolution = run.exportResolution, let aspect = run.aspect {
            let expected = resolution.dimensions(aspect: aspect)
            for timeline in timelines {
                let xml = try XMLDocument(contentsOf: safe(timeline.lastPathComponent, in: exports), options: .nodeLoadExternalEntitiesNever)
                let sequences = try xml.nodes(forXPath: "/fcpxml/library/event/project/sequence")
                guard sequences.count == 1, let sequence = sequences[0] as? XMLElement,
                      let format = sequence.attribute(forName: "format")?.stringValue,
                      let formats = try xml.nodes(forXPath: "/fcpxml/resources/format").compactMap({ $0 as? XMLElement }).first(where: { $0.attribute(forName: "id")?.stringValue == format }),
                      Int(formats.attribute(forName: "width")?.stringValue ?? "") == expected.width,
                      Int(formats.attribute(forName: "height")?.stringValue ?? "") == expected.height else {
                    throw WorkflowFailure.invalid("The finished timeline does not match this run's chosen export dimensions. The previous cut stays current.")
                }
            }
        }
        if let bounds = run.durationBounds {
            // Validate actual emitted bytes independently of runner success and the EDL.
            guard timelines.count == 1 else { throw WorkflowFailure.invalid("A single finished timeline is required to verify duration limits.") }
            let xml = try XMLDocument(contentsOf: safe(timelines[0].lastPathComponent, in: exports), options: .nodeLoadExternalEntitiesNever)
            try bounds.check(try timelineDuration(xml))
        }
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
        var savedSchemaChecked = true
        do {
            for section in ["exports", "roughcut", "plan", "inputs"] {
                let source = try safe(section, in: run.folder)
                guard fm.fileExists(atPath: source.path) else { continue }
                for case let file as URL in fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey])! {
                    guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                          ["fcpxml", "itt", "mp4", "pdf", "txt", "md", "docx", "json"].contains(file.pathExtension.lowercased()) else { continue }
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
                        let (saved, checkedSchema) = try serializedTimeline(xml)
                        if relative.hasPrefix("exports/"), let bounds = run.durationBounds {
                            try bounds.check(try timelineDuration(XMLDocument(data: saved, options: .nodeLoadExternalEntitiesNever)))
                        }
                        savedSchemaChecked = savedSchemaChecked && checkedSchema
                        try saved.write(to: target, options: .atomic)
                        let record = relative.replacingOccurrences(of: ".fcpxml", with: ".snapshot.json")
                        let hashes: [String: Any] = [
                            "source_sha256": SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined(),
                            "saved_sha256": SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined(),
                            "transformation": "Made local media references permanent; source validation is retained separately.",
                            "saved_schema": checkedSchema ? "Passed the installed Final Cut DTD" : "Unavailable",
                        ]
                        try JSONSerialization.data(withJSONObject: hashes, options: [.prettyPrinted, .sortedKeys]).write(to: safe(record, in: folder), options: .atomic)
                        artifacts.append(record)
                    } else { try fm.copyItem(at: file, to: target) }
                    artifacts.append(relative)
                }
            }
            let runSettings = try decoder.decode([String: String].self, from: Data(contentsOf: safe("paths.json", in: run.folder)))
            let assembled = (run.narrationCount ?? 1) > 1
            guard assembled == (runSettings["assembly"] != nil) else { throw ProjectFailure.invalidProject }
            if assembled {
                for suffix in [".edl.json", ".heard.txt", ".preview.mp4", ".roughcut.fcpxml"] {
                    guard artifacts.contains("roughcut/assembly/selected" + suffix) else {
                        throw WorkflowFailure.invalid("The assembled result is incomplete. The previous version stays current.")
                    }
                }
            }
            let readbacks = artifacts.filter { $0.hasSuffix(".heard.txt") }
            guard !readbacks.isEmpty, try readbacks.allSatisfy({ !(try String(contentsOf: safe($0, in: folder), encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw WorkflowFailure.invalid("Read-back is missing or empty. This cut remains unverified and the previous version stays current.")
            }
            let briefHash = SHA256.hash(data: try Data(contentsOf: safe("inputs/brief.md", in: run.folder))).map { String(format: "%02x", $0) }.joined()
            let planObject = try JSONSerialization.jsonObject(with: Data(try plan(run).text.utf8)) as? [String: Any]
            guard let script = planObject?["script"] as? String, script == URL(fileURLWithPath: script).lastPathComponent,
                  artifacts.contains("inputs/script/" + script) else { throw WorkflowFailure.invalid("The approved script is missing from the run snapshot.") }
            let prefix = assembled ? "roughcut/assembly/selected" : nil
            let version = CutVersion(number: number, label: run.label, engineVersion: project.manifest.engineVersion, runID: run.id, artifacts: artifacts, approvedPlanHash: approval, sourceSchemaChecked: schemaChecked, savedSchemaChecked: savedSchemaChecked, briefHash: briefHash, approvedScript: "inputs/script/" + script, primaryOutputPrefix: prefix, durationBounds: run.durationBounds, exportResolution: run.exportResolution, aspect: run.aspect)
            try encoder.encode(version).write(to: folder.appendingPathComponent("clauto-version.json"), options: .atomic)
            try encoder.encode(version.id).write(to: safe("cuts/current.json", in: project.folder), options: .atomic)
            return version
        } catch { try? fm.removeItem(at: folder); throw error }
    }

    private func serializedTimeline(_ xml: XMLDocument) throws -> (Data, Bool) {
        // Foundation infers standalone=yes and retains broken lexical DOCTYPE state
        // with nodePreserveAll. Rebuild the declaration before writing permanent URLs.
        xml.isStandalone = false
        let declaration = XMLDTD(); declaration.name = "fcpxml"; xml.dtd = declaration
        let saved = xml.xmlData
        let parsed = try XMLDocument(data: saved, options: .nodeLoadExternalEntitiesNever)
        guard parsed.rootElement()?.name == "fcpxml",
              let version = parsed.rootElement()?.attribute(forName: "version")?.stringValue,
              version.range(of: "^[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { throw ProjectFailure.invalidProject }
        let schema = URL(fileURLWithPath: "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv" + version.replacingOccurrences(of: ".", with: "_") + ".dtd")
        guard fm.fileExists(atPath: schema.path) else { return (saved, false) }
        let dtd = try XMLDTD(data: Data(contentsOf: schema), options: .nodeLoadExternalEntitiesNever)
        dtd.name = "fcpxml"; parsed.dtd = dtd
        do { try parsed.validate() }
        catch { throw WorkflowFailure.invalid("The saved timeline failed Final Cut's schema check. The previous cut is still current. " + error.localizedDescription) }
        return (saved, true)
    }

    private func timelineDuration(_ xml: XMLDocument) throws -> Double {
        let sequences = try xml.nodes(forXPath: "/fcpxml/library/event/project/sequence")
        guard sequences.count == 1, let sequence = sequences.first as? XMLElement,
              let text = sequence.attribute(forName: "duration")?.stringValue, text.hasSuffix("s") else {
            throw WorkflowFailure.invalid("A single finished sequence with a valid duration is required.")
        }
        let parts = text.dropLast().split(separator: "/", omittingEmptySubsequences: false)
        let value: Double
        if parts.count == 1, let n = Double(parts[0]) { value = n }
        else if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d.isFinite, d > 0 { value = n / d }
        else { throw WorkflowFailure.invalid("The finished sequence duration is unreadable.") }
        guard value.isFinite, value > 0 else { throw WorkflowFailure.invalid("The finished sequence duration is invalid.") }
        return value
    }

    private func validateOutputSettings(_ run: EditRun, settings: [String: String]) throws {
        guard settings["export_resolution"] == run.exportResolution?.rawValue,
              settings["aspect"] == run.aspect,
              settings["output_settings_schema"] == run.outputSettingsSchema.map({ String($0) }) else {
            throw WorkflowFailure.invalid("This run's output settings are missing or changed. Start a new run with the intended settings.")
        }
        if run.outputSettingsSchema != nil {
            guard run.outputSettingsSchema == 1, run.exportResolution != nil,
                  ["16:9", "9:16"].contains(run.aspect ?? ""),
                  settings["whisper_model"] == run.whisperModel,
                  ["small", "medium", "large-v3"].contains(run.whisperModel ?? "") else {
                throw WorkflowFailure.invalid("This run's frozen output settings are incomplete. Start a new run.")
            }
        } else {
            guard run.exportResolution == nil, run.aspect == nil,
                  ["small", "medium", "large-v3"].contains(settings["whisper_model"] ?? "") else {
                throw WorkflowFailure.invalid("This older run's model settings are unavailable. Start a new run.")
            }
        }
    }

    func messages(project: Project) throws -> [LocalMessage] {
        let file = try safe("notes/conversation.json", in: project.folder)
        return fm.fileExists(atPath: file.path) ? try decoder.decode([LocalMessage].self, from: Data(contentsOf: file)) : []
    }

    func handoffReport(_ requested: CutVersion, project: Project) throws -> HandoffReport {
        guard let version = try versions(project: project).first(where: { $0.id == requested.id }) else { throw ProjectFailure.invalidProject }
        let root = try safe("cuts/" + version.folderName, in: project.folder)
        func text(_ suffix: String) throws -> String? {
            guard let file = version.preferredArtifact(suffix) else { return nil }
            return try String(contentsOf: safe(file, in: root), encoding: .utf8)
        }
        var sections: [HandoffReport.Section] = []
        let script: String
        if let recorded = version.approvedScript { script = recorded }
        else {
            guard let plan = try text(".plan.json"), let object = try JSONSerialization.jsonObject(with: Data(plan.utf8)) as? [String: Any],
                  let name = object["script"] as? String, name == URL(fileURLWithPath: name).lastPathComponent else { throw ProjectFailure.invalidProject }
            script = "inputs/script/" + name
        }
        guard script.hasPrefix("inputs/script/"), version.artifacts.contains(script) else { throw ProjectFailure.invalidProject }
        let scriptURL = try safe(script, in: root)
        if ["md", "txt"].contains(scriptURL.pathExtension.lowercased()) {
            sections.append(.init(title: "Approved script", text: try String(contentsOf: scriptURL, encoding: .utf8)))
        } else if scriptURL.pathExtension.lowercased() == "docx", fm.fileExists(atPath: scriptURL.path) {
            sections.append(.init(title: "Approved script", text: "The original script is preserved with this version as a Word document. This PDF does not convert its comments."))
        } else { throw ProjectFailure.invalidProject }
        guard let readback = try text(".heard.txt") else { throw WorkflowFailure.invalid("Read-back is unavailable. Reconnect the version's drive and retry.") }
        sections.append(.init(title: "Rendered audio read-back", text: readback))
        if let edlFile = version.preferredArtifact(".edl.json") {
            struct EDL: Decodable {
                struct Span: Decodable { var start: Double; var end: Double; var reason: String?; var source: String?; var source_start: Double?; var source_end: Double? }
                struct Segment: Decodable { var source: String; var start: Double; var end: Double }
                var source: String; var fps: Double; var keeps: [Span]; var drops: [Span]
                var segments: [Segment]? = nil
            }
            let edl = try decoder.decode(EDL.self, from: Data(contentsOf: safe(edlFile, in: root)))
            guard edl.fps.isFinite, edl.fps > 0 else { throw ProjectFailure.invalidProject }
            guard let timelineFile = version.artifacts.first(where: { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }) else { throw ProjectFailure.invalidProject }
            let xml = try XMLDocument(contentsOf: safe(timelineFile, in: root), options: .nodeLoadExternalEntitiesNever)
            let clips = try xml.nodes(forXPath: "//sequence/spine/asset-clip").compactMap { $0 as? XMLElement }
            guard clips.count == edl.keeps.count else { throw WorkflowFailure.invalid("The saved timeline and cut points disagree. Rebuild the cut before exporting its shot list.") }
            guard edl.segments == nil || edl.segments?.count == clips.count else { throw ProjectFailure.invalidProject }
            func seconds(_ value: String?) throws -> Double {
                guard let value, value.hasSuffix("s") else { throw ProjectFailure.invalidProject }
                let parts = value.dropLast().split(separator: "/")
                if parts.count == 1, let n = Double(parts[0]), n.isFinite { return n }
                if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), n.isFinite, d.isFinite, d > 0 { return n / d }
                throw ProjectFailure.invalidProject
            }
            var timeline = 0.0
            var rows: [String] = []
            for (index, span) in edl.keeps.enumerated() {
                let clip = clips[index]
                let at = try seconds(clip.attribute(forName: "offset")?.stringValue)
                let start = try seconds(clip.attribute(forName: "start")?.stringValue)
                let duration = try seconds(clip.attribute(forName: "duration")?.stringValue)
                func snapped(_ value: Double) -> Double { (value * edl.fps).rounded() / edl.fps }
                let sourceStart = edl.segments?[index].start ?? span.start
                let sourceEnd = edl.segments?[index].end ?? span.end
                if let segment = edl.segments?[index] {
                    let assets = try xml.nodes(forXPath: "//resources/asset").compactMap { $0 as? XMLElement }
                    guard let asset = assets.first(where: { $0.attribute(forName: "id")?.stringValue == clip.attribute(forName: "ref")?.stringValue }),
                          let representation = asset.elements(forName: "media-rep").first,
                          let path = representation.attribute(forName: "src")?.stringValue.flatMap({ URL(string: $0) }), path.isFileURL,
                          path.resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: segment.source).resolvingSymlinksInPath().standardizedFileURL else {
                        throw WorkflowFailure.invalid("The shot list's source and saved timeline disagree.")
                    }
                }
                guard span.start.isFinite, span.end.isFinite, span.start >= 0, span.end > span.start,
                      sourceStart.isFinite, sourceEnd.isFinite, sourceStart >= 0, sourceEnd > sourceStart,
                      abs(sourceEnd - sourceStart - (span.end - span.start)) < 0.000001,
                      abs(at - snapped(timeline)) < 0.000001, abs(start - snapped(sourceStart)) < 0.000001,
                      abs(duration - snapped(span.end - span.start)) < 0.000001 else {
                    throw WorkflowFailure.invalid("The saved timeline and cut points changed. Rebuild the cut before exporting its shot list.")
                }
                timeline += span.end - span.start
                rows.append(String(format: "Shot %d | Timeline %.3fs | Source %.3f-%.3fs | Duration %.3fs", index + 1, at, start, start + duration, duration)
                    + "\n" + (edl.segments.map { URL(fileURLWithPath: $0[index].source).lastPathComponent + " | " } ?? "") + (span.reason ?? "Retained source footage"))
            }
            sections.append(.init(title: "Shot list", text: URL(fileURLWithPath: edl.source).lastPathComponent + String(format: " | %.6f fps\n\n", edl.fps) + rows.joined(separator: "\n\n")))
            if !edl.drops.isEmpty {
                sections.append(.init(title: "Removed spans and reasons", text: edl.drops.map {
                    ($0.source.map { URL(fileURLWithPath: $0).lastPathComponent + " | " } ?? "") +
                    String(format: "%.3f-%.3fs | ", $0.source_start ?? $0.start, $0.source_end ?? $0.end) + ($0.reason ?? "No reason recorded")
                }.joined(separator: "\n")))
            }
        } else { throw WorkflowFailure.invalid("The shot list is unavailable for this version.") }
        if let sheet = try text(".build-sheet.md") {
            let plain = sheet.components(separatedBy: "\n").compactMap { line -> String? in
                var line = line.trimmingCharacters(in: .whitespaces)
                if line == "---" { return nil }
                if line.hasPrefix("> ") { line = String(line.dropFirst(2)) }
                if line.hasPrefix("#") { line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
                return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            }.joined(separator: "\n")
            sections.append(.init(title: "Graphic and asset checklist", text: plain))
        }
        return HandoffReport(title: project.manifest.name + " - " + version.folderName,
            subtitle: version.label + " | Engine " + version.engineVersion + " | This report uses the saved version's inputs and read-back.", sections: sections)
    }
    func feedback(project: Project) throws -> [CutFeedback] {
        let file = try safe("notes/cut-feedback.json", in: project.folder)
        guard fm.fileExists(atPath: file.path) else { return [] }
        var entries = try decoder.decode([CutFeedback].self, from: Data(contentsOf: file))
        guard entries.allSatisfy({ $0.projectID == project.id }) else { throw ProjectFailure.invalidProject }
        var targets: [UUID: FeedbackTarget] = [:]
        for index in entries.indices {
            let entry = entries[index]
            if targets[entry.versionID] == nil { targets[entry.versionID] = try? feedbackTarget(entry.versionID, project: project) }
            guard let target = targets[entry.versionID], entry.timelineSHA256 == target.sha,
                  entry.versionNumber == target.version.number else { entries[index].attachment = .changedOrMissingVersion; continue }
            entries[index].attachment = validFeedbackRange(start: entry.startSeconds, end: entry.endSeconds, duration: target.duration) ? .verified : .invalidRange
        }
        return entries
    }

    func derivativeSource(_ requested: CutVersion, project: Project) throws -> SavedCutSource {
        let target = try feedbackTarget(requested.id, project: project)
        guard let timeline = target.version.artifacts.first(where: { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }) else { throw ProjectFailure.invalidProject }
        let folder = try safe("cuts/" + target.version.folderName, in: project.folder)
        let captions = try target.version.artifacts.first(where: { $0.hasPrefix("exports/") && $0.hasSuffix(".itt") }).map { try safe($0, in: folder) }
        return SavedCutSource(timeline: try safe(timeline, in: folder), captions: captions, timelineSHA256: target.sha, duration: target.duration, engineVersion: target.version.engineVersion)
    }

    func derivativeFolder(_ id: UUID, project: Project) throws -> URL {
        let root = try safe("build/derivatives", in: project.folder)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return try safe("build/derivatives/" + id.uuidString, in: project.folder)
    }

    func verifyDerivative(folder: URL, parentVersionID: UUID, parentHash: String, request: DerivativeRequest, project: Project) throws -> String {
        guard let id = UUID(uuidString: folder.lastPathComponent),
              folder.resolvingSymlinksInPath().path == (try derivativeFolder(id, project: project)).resolvingSymlinksInPath().path else { throw ProjectFailure.invalidProject }
        let recipeURL = try safe("derivative.json", in: folder)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: recipeURL)) as? [String: Any]
        let target = try feedbackTarget(parentVersionID, project: project)
        try request.validate(duration: target.duration)
        let range = object?["selected_range_seconds"] as? [Double]
        let framing = object?["framing"] as? [String: Any]
        let effectsObject = object?["audio_effects"]
        let actualEffects: LocalAudioEffects?
        if effectsObject == nil || effectsObject is NSNull { actualEffects = nil }
        else { actualEffects = try decoder.decode(LocalAudioEffects.self, from: JSONSerialization.data(withJSONObject: effectsObject!)) }
        guard object?["state"] as? String == "complete", object?["parent_sha256"] as? String == parentHash,
              target.sha == parentHash, range?.count == 2,
              abs(range![0] - DerivativeRequest.snapped(request.start)) < 1e-9,
              abs(range![1] - DerivativeRequest.snapped(request.end ?? target.duration)) < 1e-9,
              framing?["conform"] as? String == request.framing,
              framing?["position_percent_of_height"] as? [Double] == [request.x, request.y], actualEffects == request.effects,
              object?["aspect"] as? String == request.aspect, object?["resolution"] as? String == request.resolution.rawValue,
              object?["full_decode_passed"] as? Bool == true, let hashes = object?["output_sha256"] as? [String: String],
              hashes["review.mp4"] != nil, hashes["timeline.fcpxml"] != nil else {
            throw WorkflowFailure.invalid("The export receipt does not match this saved version and its selected output settings.")
        }
        for (leaf, hash) in hashes {
            guard URL(fileURLWithPath: leaf).lastPathComponent == leaf,
                  try DerivativeService.digest(safe(leaf, in: folder)) == hash else { throw WorkflowFailure.invalid("An exported file changed. Create a new verified export.") }
        }
        let sound = object?["sound_effect"] as? [String: Any]
        if let soundID = request.soundFileID {
            let manifest = try decoder.decode(ProjectManifest.self, from: Data(contentsOf: safe("clauto-project.json", in: project.folder)))
            guard manifest.id == project.id, let file = manifest.files.first(where: { $0.id == soundID && [.audio, .music].contains($0.group) }),
                  !file.relativePath.hasPrefix("/"), !file.relativePath.split(separator: "/").contains("..") else { throw ProjectFailure.invalidProject }
            let soundURL = project.folder.appendingPathComponent(file.relativePath)
            guard soundURL.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(project.folder.resolvingSymlinksInPath().path + "/") else { throw ProjectFailure.invalidProject }
            let path = soundURL.resolvingSymlinksInPath().path
            let sourceHashes = object?["source_sha256"] as? [String: String]
            guard sound?["source"] as? String == path, sound?["at"] as? Double == DerivativeRequest.snapped(request.soundAt),
                  sound?["gain_db"] as? Double == request.soundGainDB, sourceHashes?[path] == (try DerivativeService.digest(soundURL)) else {
                throw WorkflowFailure.invalid("The sound-effect export does not match the selected local sound and its timing.")
            }
        } else if sound != nil { throw WorkflowFailure.invalid("The export added an unexpected sound effect.") }
        return try DerivativeService.digest(recipeURL)
    }

    func saveDerivative(_ record: DerivedCut, project: Project) throws {
        guard record.projectID == project.id else { throw ProjectFailure.invalidProject }
        let folder = try derivativeFolder(record.id, project: project)
        guard try verifyDerivative(folder: folder, parentVersionID: record.parentVersionID, parentHash: record.parentTimelineSHA256, request: record.request, project: project) == record.recipeSHA256 else { throw ProjectFailure.invalidProject }
        try encoder.encode(record).write(to: safe("clauto-derivative.json", in: folder), options: .atomic)
    }

    func derivatives(project: Project) throws -> [DerivedCut] {
        let root = try safe("build/derivatives", in: project.folder)
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: safe("clauto-derivative.json", in: folder)),
                  let record = try? decoder.decode(DerivedCut.self, from: data), record.id.uuidString == folder.lastPathComponent,
                  record.projectID == project.id,
                  (try? verifyDerivative(folder: folder, parentVersionID: record.parentVersionID, parentHash: record.parentTimelineSHA256, request: record.request, project: project)) == record.recipeSHA256 else { return nil }
            return record
        }.sorted { $0.created > $1.created }
    }

    private struct FeedbackTarget { var version: CutVersion; var duration: Double; var sha: String }
    private func validFeedbackRange(start: Double, end: Double?, duration: Double) -> Bool {
        start.isFinite && start >= 0 && start <= duration && (end == nil || (end!.isFinite && end! >= start && end! <= duration))
    }
    private func feedbackTarget(_ id: UUID, project: Project) throws -> FeedbackTarget {
        guard let version = try versions(project: project).first(where: { $0.id == id }),
              let artifact = version.artifacts.first(where: { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }) else { throw ProjectFailure.invalidProject }
        let relative = "cuts/" + version.folderName + "/" + artifact
        let file = try safe(relative, in: project.folder)
        let data = try Data(contentsOf: file)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let receiptPath = String(relative.dropLast(".fcpxml".count)) + ".snapshot.json"
        let receipt = try decoder.decode([String: String].self, from: Data(contentsOf: safe(receiptPath, in: project.folder)))
        guard receipt["saved_sha256"] == sha else { throw WorkflowFailure.invalid("The saved timeline changed. Restore a verified version before attaching feedback.") }
        let xml = try XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever)
        guard let sequence = try xml.nodes(forXPath: "//sequence").first as? XMLElement,
              let value = sequence.attribute(forName: "duration")?.stringValue, value.hasSuffix("s") else { throw ProjectFailure.invalidProject }
        let parts = value.dropLast().split(separator: "/")
        let duration: Double
        if parts.count == 1, let n = Double(parts[0]) { duration = n }
        else if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 { duration = n / d }
        else { throw ProjectFailure.invalidProject }
        guard duration.isFinite, duration > 0 else { throw ProjectFailure.invalidProject }
        return FeedbackTarget(version: version, duration: duration, sha: sha)
    }

    func addFeedback(_ text: String, start: Double, end: Double? = nil,
                     version requested: CutVersion, project: Project) throws -> [CutFeedback] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000, start.isFinite, start >= 0,
              end == nil || (end!.isFinite && end! >= start) else { throw WorkflowFailure.invalid("Enter a comment and valid time range.") }
        let target = try feedbackTarget(requested.id, project: project), version = target.version
        guard validFeedbackRange(start: start, end: end, duration: target.duration) else {
            throw WorkflowFailure.invalid("The feedback time is outside this saved version.")
        }
        var entries = try feedback(project: project)
        entries.append(CutFeedback(projectID: project.id, versionID: version.id, versionNumber: version.number,
            timelineSHA256: target.sha, startSeconds: start, endSeconds: end, text: text, attachment: .verified))
        try encoder.encode(entries).write(to: safe("notes/cut-feedback.json", in: project.folder), options: .atomic)
        return entries
    }

    func resolveFeedback(_ id: UUID, resolved: Bool, project: Project) throws -> [CutFeedback] {
        var entries = try feedback(project: project)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }
        guard entries[index].attachment == .verified else { throw WorkflowFailure.invalid("This feedback's saved version or time range changed. Restore its verified cut before resolving it.") }
        entries[index].resolved = resolved; entries[index].resolvedAt = resolved ? Date() : nil
        try encoder.encode(entries).write(to: safe("notes/cut-feedback.json", in: project.folder), options: .atomic)
        return entries
    }

    func queue(_ text: String, project: Project) throws -> [LocalMessage] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowFailure.invalid("Write a change request first.") }
        var messages = try messages(project: project)
        messages.append(LocalMessage(text: text))
        try encoder.encode(messages).write(to: safe("notes/conversation.json", in: project.folder), options: .atomic)
        return messages
    }
}
