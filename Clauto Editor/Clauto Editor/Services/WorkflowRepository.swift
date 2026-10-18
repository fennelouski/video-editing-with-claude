import Foundation
import CryptoKit
import AVFoundation
import Darwin

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
    var scriptInputSHA256: String? = nil
    var scriptInputName: String? = nil
    var scriptSelectionReceiptSHA256: String? = nil
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
    var scriptInputSHA256: String? = nil
    var scriptSelectionReceiptSHA256: String? = nil
    var localEditOrigin: SavedVersionOrigin? = nil
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

/// Saving a verified local export inherits its parent's approved inputs. It is
/// not a new editorial, scientific or production approval.
struct SavedVersionOrigin: Codable, Equatable, Sendable {
    var derivativeID: UUID
    var parentVersionID: UUID
    var parentTimelineSHA256: String
    var recipeSHA256: String
    var parentMetadataSHA256: String
    var receiptSHA256: String
}

struct SavedVersionPromotionReceipt: Codable, Sendable {
    var schemaVersion = 1
    var projectID: UUID
    var versionID: UUID
    var versionNumber: Int
    var derivativeID: UUID
    var parentVersionID: UUID
    var parentMetadataSHA256: String
    var projectManifestSHA256: String
    var parentTimelineSHA256: String
    var recipeSHA256: String
    var savedTimelineSHA256: String
    var savedPreviewSHA256: String
    var savedOutputSHA256: [String: String]
    var newEditorialApproval = false
    var newFactApproval = false
    var productionAuthorized = false
}

struct SavedCutPointer: Equatable, Sendable {
    let id: UUID?
    let signature: SourceFileSignature?
}

enum SavedCutStorage {
    /// The caller holds the common project lease and uniquely reserved this
    /// version folder. Stage/fsync first, then publish the complete record by
    /// descriptor-relative rename. A crash leaves no partially written final
    /// metadata. This is owned-slot coordination, not a generic no-replace API.
    static func publishMetadata(_ bytes: Data, to folder: SourceRenderDirectory, lease: ProjectMutationLease,
                                validatePublication: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws {
        try lease.root.checkPath(); try folder.checkPath()
        guard !(try CreativeAssetFiles.exists("clauto-version.json", in: folder)) else { throw ProjectFailure.invalidProject }
        let pending = ".clauto-version-pending-"+UUID().uuidString
        try folder.writeNew(bytes, name: pending)
        try validatePublication(); try Task.checkCancellation()
        try lease.root.checkPath(); try folder.checkPath()
        guard !(try CreativeAssetFiles.exists("clauto-version.json", in: folder)),
              renameat(folder.descriptor,pending,folder.descriptor,"clauto-version.json")==0 else { throw ProjectFailure.invalidProject }
        _ = fsync(folder.descriptor)
    }
    static func currentState(_ root: SourceRenderDirectory) throws -> SavedCutPointer {
        let cuts = try root.child("cuts")
        guard try CreativeAssetFiles.exists("current.json", in: cuts) else { return .init(id: nil, signature: nil) }
        func signature() throws -> SourceFileSignature {
            var value = stat()
            guard fstatat(cuts.descriptor,"current.json",&value,AT_SYMLINK_NOFOLLOW)==0,
                  value.st_mode&S_IFMT==S_IFREG,value.st_size>=0 else { throw ProjectFailure.invalidProject }
            return .init(device: value.st_dev,inode: value.st_ino,size: value.st_size,
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec),modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec),changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
        }
        let before = try signature()
        let id = try JSONDecoder().decode(UUID.self, from: cuts.read("current.json", limit: 1024))
        guard try signature() == before else { throw ProjectFailure.invalidProject }
        return .init(id: id, signature: before)
    }
    static func currentID(_ root: SourceRenderDirectory) throws -> UUID? {
        try currentState(root).id
    }

    /// Reserve a distinct name briefly under the common lease. Missing version
    /// metadata denotes incomplete retained work, not an accepted saved version.
    static func reserve(_ project: Project) throws -> (Int, SourceRenderDirectory) {
        let lease = try ProjectMutationLease.acquire(project)
        defer { withExtendedLifetime(lease) {} }
        let cuts = try lease.root.child("cuts", create: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: cuts.url.path)
        let numbers = names.compactMap { name -> Int? in
            guard name.range(of: "^v[0-9]+$", options: .regularExpression) != nil else { return nil }
            return Int(name.dropFirst())
        }
        let last = numbers.max() ?? 0
        guard last >= 0, last < 999_999 else { throw ProjectFailure.invalidProject }
        let number = last + 1
        let folder = try cuts.child(String(format: "v%03d", number), create: true, exclusive: true)
        try lease.root.checkPath(); try cuts.checkPath()
        return (number, folder)
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
        _ = try ProjectMutationLease.checkedRoot(project)
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
        try validateScriptInput(run,project: project,settings: settings)
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

    private func validateScriptInput(_ run: EditRun,project: Project,settings: [String:String]) throws {
        guard let path = settings["approved_script"], path.hasPrefix("/"),
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix((try safe("inputs/script",in: run.folder)).resolvingSymlinksInPath().path+"/"),
              fm.fileExists(atPath: path) else { throw WorkflowFailure.invalid("The saved script is unavailable. Choose a script and start a new run.") }
        var scriptBytes: Data?
        if let expected = run.scriptInputSHA256 {
            guard let name = run.scriptInputName, name == URL(fileURLWithPath: name).lastPathComponent,
                  name != ".", name != "..",
                  URL(fileURLWithPath: path).standardizedFileURL == (try safe("inputs/script/"+name,in: run.folder)).standardizedFileURL,
                  settings["script_input_sha256"] == expected else { throw ProjectFailure.invalidProject }
            let bytes: Data
            do { bytes = try SourceRenderDirectory.open(run.folder).child("inputs").child("script").read(name,limit: ProjectScriptSelectionStore.limit) }
            catch is CancellationError { throw CancellationError() }
            catch { throw WorkflowFailure.invalid("This run's saved script is unavailable or changed. Start a new run with the intended script.") }
            guard TranscriptSourceMap.sha(bytes) == expected else {
                throw WorkflowFailure.invalid("This run's saved script changed. Start a new run with the intended script.")
            }
            scriptBytes = bytes
        } else if settings["script_input_sha256"] != nil || run.scriptInputName != nil { throw ProjectFailure.invalidProject }
        let selectionURL = try safe("inputs/script-selection.json",in: run.folder)
        if run.scriptSelectionReceiptSHA256 != nil || settings["script_selection_sha256"] != nil || fm.fileExists(atPath: selectionURL.path) {
            let data = try SourceRenderDirectory.open(run.folder).child("inputs").read("script-selection.json",limit: 64*1024)
            try TranscriptJSONKeys.validate(data)
            let selected = try decoder.decode(ProjectScriptReceipt.self,from: data)
            guard let expected = run.scriptSelectionReceiptSHA256, settings["script_selection_sha256"] == expected,
                  TranscriptSourceMap.sha(data) == expected, selected.schemaVersion == 1, selected.projectID == project.id,
                  selected.purpose == ProjectScriptSelectionStore.purpose, selected.sha256 == run.scriptInputSHA256,
                  selected.byteCount == scriptBytes?.count, selected.filename == run.scriptInputName else {
                throw WorkflowFailure.invalid("This run's script selection changed. Start a new run with the intended script.")
            }
        }
    }

    func prepare(project: Project, engine: URL, label: String, primaryID: UUID? = nil, narrationIDs: [UUID] = []) throws -> EditRun {
        _ = try ProjectMutationLease.checkedRoot(project)
        guard project.manifest.importedReviewOnly != true else { throw WorkflowFailure.invalid("This imported movie project supports feedback and separate review previews. Its original camera/graphics timeline remains reference evidence; a new production cut is not authorized here.") }
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
        let selectedScript: URL
        var scriptSelectionSHA: String?
        if let snapshot = try ProjectScriptSelectionStore.read(project: project) {
            let target = inputs.appendingPathComponent("script")
            try fm.createDirectory(at: target,withIntermediateDirectories: false)
            selectedScript = target.appendingPathComponent(snapshot.receipt.filename)
            try snapshot.bytes.write(to: selectedScript,options: .withoutOverwriting)
            try snapshot.receiptBytes.write(to: inputs.appendingPathComponent("script-selection.json"),options: .withoutOverwriting)
            scriptSelectionSHA = snapshot.reference.receiptSHA256
        } else {
            let scripts = try fm.contentsOfDirectory(at: URL(fileURLWithPath: paths["script"]!), includingPropertiesForKeys: nil)
                .filter { ["md", "txt", "docx"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("~$") }
            guard let legacy = scripts.first(where: { $0.lastPathComponent == "script.md" }) ?? (scripts.count == 1 ? scripts.first : nil) else {
                throw WorkflowFailure.invalid("Choose a script in Files, or use the script in Brief, before making this cut.")
            }
            let bytes = try SourceRenderDirectory.open(project.folder).child("script").read(legacy.lastPathComponent,limit: ProjectScriptSelectionStore.limit)
            let target = inputs.appendingPathComponent("script")
            try fm.createDirectory(at: target,withIntermediateDirectories: false)
            selectedScript = target.appendingPathComponent(legacy.lastPathComponent)
            try bytes.write(to: selectedScript,options: .withoutOverwriting)
        }
        paths["approved_script"] = try safe("inputs/script/" + selectedScript.lastPathComponent, in: folder).path
        let scriptSHA = TranscriptSourceMap.sha(try SourceRenderDirectory.open(folder).child("inputs").child("script").read(selectedScript.lastPathComponent,limit: ProjectScriptSelectionStore.limit))
        paths["script_input_sha256"] = scriptSHA; paths["script_selection_sha256"] = scriptSelectionSHA
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
        run.scriptInputSHA256 = scriptSHA; run.scriptSelectionReceiptSHA256 = scriptSelectionSHA
        run.scriptInputName = selectedScript.lastPathComponent
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
        let physical = try ProjectMutationLease.checkedRoot(project)
        let cuts = try physical.child("cuts")
        let root = cuts.url
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: "^v[0-9]+$", options: .regularExpression) != nil }
            .compactMap { folder -> CutVersion? in
                _ = try safe(folder.lastPathComponent, in: root)
                let owned = try cuts.child(folder.lastPathComponent)
                guard try CreativeAssetFiles.exists("clauto-version.json", in: owned) else { return nil }
                let version = try decoder.decode(CutVersion.self, from: owned.read("clauto-version.json", limit: 1024*1024))
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
        let lease = try ProjectMutationLease.acquire(project)
        defer { withExtendedLifetime(lease) {} }
        let cuts = try lease.root.child("cuts")
        guard try versions(project: project).contains(where: { $0.id == version.id }) else { throw ProjectFailure.invalidProject }
        try lease.root.checkPath(); try cuts.checkPath()
        try cuts.replacePointer(encoder.encode(version.id), name: "current.json")
    }

    func snapshot(_ run: EditRun, project: Project,
                  reserveVersion: @Sendable (Project) throws -> (Int, SourceRenderDirectory) = { try SavedCutStorage.reserve($0) }) throws -> CutVersion {
        try validate(run, project: project)
        let originalRoot = try ProjectMutationLease.checkedRoot(project)
        let originalCuts = try originalRoot.child("cuts")
        let originalCurrent = try SavedCutStorage.currentState(originalRoot)
        let settings = try decoder.decode([String: String].self, from: Data(contentsOf: safe("paths.json", in: run.folder)))
        try validateScriptInput(run,project: project,settings: settings)
        let frozenBounds = try settings["duration_bounds"].map { try decoder.decode(VideoDurationBounds.self, from: Data($0.utf8)) }
        guard frozenBounds == run.durationBounds else { throw WorkflowFailure.invalid("This run's duration limits changed. Start a new run with the intended limits.") }
        try validateOutputSettings(run, settings: settings)
        guard run.state == .complete, run.projectID == project.id,
              let approval = run.approvedPlanHash, try plan(run).hash == approval else { throw WorkflowFailure.invalid("Review the current graphic plan before saving a finished cut.") }
        let exports = try safe("exports", in: run.folder)
        let timelines = try fm.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil).filter { $0.pathExtension == "fcpxml" }
        guard !timelines.isEmpty else { throw WorkflowFailure.invalid("The engine did not produce a timeline. The previous cut is still current.") }
        let sourceExports = try SourceRenderDirectory.open(exports)
        var validatedXML = [String:Data](), validatedReports = [String:Data]()
        for timeline in timelines {
            validatedXML[timeline.lastPathComponent] = try sourceExports.read(timeline.lastPathComponent,limit: 16*1024*1024)
        }
        if let resolution = run.exportResolution, let aspect = run.aspect {
            let expected = resolution.dimensions(aspect: aspect)
            for timeline in timelines {
                let xml = try XMLDocument(data: validatedXML[timeline.lastPathComponent]!, options: .nodeLoadExternalEntitiesNever)
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
            let xml = try XMLDocument(data: validatedXML[timelines[0].lastPathComponent]!, options: .nodeLoadExternalEntitiesNever)
            try bounds.check(try timelineDuration(xml))
        }
        struct Validation: Decodable { var timeline: String; var sha256: String; var problems: [String]; var schemaChecked: Bool }
        var schemaChecked = true
        for timeline in timelines {
            let reportName = timeline.deletingPathExtension().lastPathComponent + ".validation.json"
            let reportBytes = try sourceExports.read(reportName,limit: 8*1024*1024)
            validatedReports[reportName] = reportBytes
            let report = try decoder.decode(Validation.self, from: reportBytes)
            let hash = TranscriptSourceMap.sha(validatedXML[timeline.lastPathComponent]!)
            guard report.timeline == timeline.lastPathComponent, report.sha256 == hash, report.problems.isEmpty else {
                throw WorkflowFailure.invalid("The timeline's validation evidence is missing or changed. Re-run rendering before saving a version.")
            }
            schemaChecked = schemaChecked && report.schemaChecked
        }
        let (number, reserved) = try reserveVersion(project)
        try reserved.checkPath()
        var artifacts: [String] = []
        var savedSchemaChecked = true
        do {
            let runSource = try SourceRenderDirectory.open(run.folder)
            let resolvedRun = run.folder.resolvingSymlinksInPath()
            func location(_ relative: String, in base: SourceRenderDirectory, create: Bool = false) throws -> (SourceRenderDirectory, String) {
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw ProjectFailure.invalidProject }
                let parts = relative.split(separator: "/").map(String.init)
                guard let leaf = parts.last else { throw ProjectFailure.invalidProject }
                var parent = base
                for part in parts.dropLast() { parent = try parent.child(part, create: create) }
                return (parent, leaf)
            }
            var mediaHashes = [String:String]()
            var copiedHashes = [String:String]()
            var materializedXML = Set<String>(), materializedReports = Set<String>()
            func copySection(_ source: SourceRenderDirectory, prefix: String) throws {
                try runSource.checkPath(); try reserved.checkPath(); try source.checkPath()
                for name in try fm.contentsOfDirectory(atPath: source.url.path).sorted() {
                    try Task.checkCancellation()
                    var info = stat()
                    guard fstatat(source.descriptor,name,&info,AT_SYMLINK_NOFOLLOW)==0 else { throw ProjectFailure.invalidProject }
                    if info.st_mode&S_IFMT==S_IFDIR {
                        try copySection(source.child(name), prefix: prefix+"/"+name); continue
                    }
                    guard info.st_mode&S_IFMT==S_IFREG,
                          ["fcpxml", "itt", "mp4", "pdf", "txt", "md", "docx", "json"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { continue }
                    var relative = prefix+"/"+name
                    if relative.hasSuffix(".validation.json") { relative = String(relative.dropLast(".validation.json".count))+".source-validation.json" }
                    let (target, leaf) = try location(relative, in: reserved, create: true)
                    if name.hasSuffix(".fcpxml") {
                        let sourceBytes = try source.read(name, limit: 16*1024*1024)
                        if prefix == "exports" || prefix.hasPrefix("exports/") {
                            guard prefix == "exports", validatedXML[name] == sourceBytes else { throw WorkflowFailure.invalid("The validated source timeline changed while saving. The previous cut stays current.") }
                        }
                        let xml = try XMLDocument(data: sourceBytes, options: [.nodePreserveAll,.nodeLoadExternalEntitiesNever])
                        for case let node as XMLElement in try xml.nodes(forXPath: "//media-rep[@src] | //asset[@src]") {
                            guard let src = node.attribute(forName: "src"), let value = src.stringValue,
                                  let media = URL(string: value), media.isFileURL else { throw ProjectFailure.invalidProject }
                            let resolved = media.resolvingSymlinksInPath()
                            guard fm.fileExists(atPath: resolved.path) else { throw ProjectFailure.missingFile(resolved.lastPathComponent) }
                            if resolved.path.hasPrefix(resolvedRun.path+"/") {
                                let generated = String(resolved.path.dropFirst(resolvedRun.path.count+1))
                                let (input, inputLeaf) = try location(generated, in: runSource)
                                let mediaName = SHA256.hash(data: Data(resolved.path.utf8)).prefix(8).map { String(format: "%02x",$0) }.joined()+"-"+resolved.lastPathComponent
                                let permanent = try reserved.child("media", create: true)
                                if mediaHashes[mediaName] == nil {
                                    mediaHashes[mediaName] = try input.voiceHash(inputLeaf, limit: GraphicArtifactFiles.movieLimit, copyTo: permanent, destinationName: mediaName)
                                    copiedHashes["media/"+mediaName] = mediaHashes[mediaName]
                                }
                                src.stringValue = permanent.url.appendingPathComponent(mediaName).absoluteString
                            } else { src.stringValue = resolved.absoluteString }
                        }
                        let (saved, checkedSchema) = try serializedTimeline(xml)
                        if relative.hasPrefix("exports/"), let bounds = run.durationBounds {
                            try bounds.check(try timelineDuration(XMLDocument(data: saved, options: .nodeLoadExternalEntitiesNever)))
                        }
                        savedSchemaChecked = savedSchemaChecked && checkedSchema
                        try target.writeNew(saved, name: leaf)
                        if prefix == "exports" { materializedXML.insert(name) }
                        copiedHashes[relative] = TranscriptSourceMap.sha(saved)
                        let record = relative.replacingOccurrences(of: ".fcpxml",with: ".snapshot.json")
                        let hashes: [String:Any] = ["source_sha256":TranscriptSourceMap.sha(sourceBytes),"saved_sha256":TranscriptSourceMap.sha(saved),
                            "transformation":"Made local media references permanent; source validation is retained separately.",
                            "saved_schema":checkedSchema ? "Passed the installed Final Cut DTD":"Unavailable"]
                        let (recordFolder, recordLeaf) = try location(record,in: reserved,create: true)
                        let recordBytes = try JSONSerialization.data(withJSONObject: hashes,options: [.prettyPrinted,.sortedKeys])
                        try recordFolder.writeNew(recordBytes,name: recordLeaf)
                        copiedHashes[record] = TranscriptSourceMap.sha(recordBytes)
                        artifacts.append(record)
                    } else if prefix == "exports", let expected = validatedReports[name] {
                        let bytes = try source.read(name,limit: 8*1024*1024)
                        guard bytes == expected else { throw ProjectFailure.invalidProject }
                        try target.writeNew(bytes,name: leaf)
                        materializedReports.insert(name)
                        copiedHashes[relative] = TranscriptSourceMap.sha(bytes)
                    } else { copiedHashes[relative] = try source.voiceHash(name,limit: GraphicArtifactFiles.movieLimit,copyTo: target,destinationName: leaf) }
                    artifacts.append(relative)
                }
            }
            for section in ["exports","roughcut","plan","inputs"] {
                if try CreativeAssetFiles.exists(section,in: runSource) { try copySection(runSource.child(section),prefix: section) }
            }
            guard materializedXML == Set(validatedXML.keys), materializedReports == Set(validatedReports.keys) else {
                throw WorkflowFailure.invalid("A validated timeline or its report disappeared while saving. The previous cut stays current.")
            }
            let runSettings = try decoder.decode([String: String].self, from: runSource.read("paths.json",limit: 8*1024*1024))
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
            guard !readbacks.isEmpty, try readbacks.allSatisfy({ path in
                let (directory, name) = try location(path,in: reserved)
                guard let text = String(data: try directory.read(name,limit: 16*1024*1024),encoding: .utf8) else { throw ProjectFailure.invalidProject }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw WorkflowFailure.invalid("Read-back is missing or empty. This cut remains unverified and the previous version stays current.")
            }
            let briefHash = TranscriptSourceMap.sha(try reserved.child("inputs").read("brief.md",limit: 16*1024*1024))
            let planPaths = artifacts.filter { $0.hasPrefix("plan/") && $0.hasSuffix(".plan.json") }
            guard planPaths.count == 1 else { throw ProjectFailure.invalidProject }
            let (planFolder, planLeaf) = try location(planPaths[0],in: reserved)
            let savedPlan = try planFolder.read(planLeaf,limit: 16*1024*1024)
            guard TranscriptSourceMap.sha(savedPlan)==approval else { throw ProjectFailure.invalidProject }
            let planObject = try JSONSerialization.jsonObject(with: savedPlan) as? [String:Any]
            guard let script = planObject?["script"] as? String, script == URL(fileURLWithPath: script).lastPathComponent,
                  artifacts.contains("inputs/script/" + script) else { throw WorkflowFailure.invalid("The approved script is missing from the run snapshot.") }
            if let sha = run.scriptInputSHA256 {
                guard script == run.scriptInputName,
                      TranscriptSourceMap.sha(try reserved.child("inputs").child("script").read(script,limit: ProjectScriptSelectionStore.limit)) == sha else { throw WorkflowFailure.invalid("The saved version's script differs from its selected run input.") }
                if let receiptSHA = run.scriptSelectionReceiptSHA256 {
                    guard TranscriptSourceMap.sha(try reserved.child("inputs").read("script-selection.json",limit: 64*1024)) == receiptSHA else { throw ProjectFailure.invalidProject }
                }
                try validateScriptInput(run,project: project,settings: settings)
            }
            let prefix = assembled ? "roughcut/assembly/selected" : nil
            let version = CutVersion(number: number, label: run.label, engineVersion: project.manifest.engineVersion, runID: run.id, artifacts: artifacts, approvedPlanHash: approval, sourceSchemaChecked: schemaChecked, savedSchemaChecked: savedSchemaChecked, briefHash: briefHash, approvedScript: "inputs/script/" + script, primaryOutputPrefix: prefix, durationBounds: run.durationBounds, exportResolution: run.exportResolution, aspect: run.aspect,scriptInputSHA256: run.scriptInputSHA256,scriptSelectionReceiptSHA256: run.scriptSelectionReceiptSHA256)
            // Hash outside the common lease, then retain file identities for the
            // short publication check. Completed bytes cannot drift unnoticed.
            var copiedSignatures = [String:SourceFileSignature]()
            for (path, hash) in copiedHashes {
                let (directory, name) = try location(path,in: reserved)
                let before = try Self.derivativeSignature(name,in: directory)
                guard try directory.voiceHash(name,limit: GraphicArtifactFiles.movieLimit)==hash,
                      try Self.derivativeSignature(name,in: directory)==before else { throw ProjectFailure.invalidProject }
                copiedSignatures[path] = before
            }
            let lease = try ProjectMutationLease.acquire(project)
            defer { withExtendedLifetime(lease) {} }
            guard lease.root.identity == originalRoot.identity,
                  try SavedCutStorage.currentState(lease.root) == originalCurrent else {
                throw WorkflowFailure.invalid("The current version changed while saving. Your earlier versions are preserved; review the current cut before saving again.")
            }
            try reserved.checkPath(); try originalCuts.checkPath()
            for (path, signature) in copiedSignatures {
                let (directory, name) = try location(path,in: reserved)
                guard try Self.derivativeSignature(name,in: directory)==signature else { throw ProjectFailure.invalidProject }
            }
            try SavedCutStorage.publishMetadata(encoder.encode(version), to: reserved, lease: lease)
            try originalCuts.replacePointer(encoder.encode(version.id), name: "current.json")
            return version
        } catch { throw error } // Retain incomplete owned work; never delete by a mutable pathname.
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
        if version.localEditOrigin != nil {
            let bound = try feedbackTarget(version.id, project: project)
            let receipt = try promotionReceipt(version, project: project)
            let directory = try ProjectMutationLease.checkedRoot(project).child("cuts").child(version.folderName).child("exports")
            for (name, hash) in receipt.savedOutputSHA256 {
                guard try directory.voiceHash(name, limit: GraphicArtifactFiles.movieLimit) == hash else { throw ProjectFailure.invalidProject }
            }
            let xml = try XMLDocument(data: directory.read("timeline.fcpxml", limit: 16*1024*1024), options: .nodeLoadExternalEntitiesNever)
            let assets = try xml.nodes(forXPath: "/fcpxml/resources/asset").compactMap { $0 as? XMLElement }
            let clips = try xml.nodes(forXPath: "/fcpxml/library/event/project/sequence/spine//asset-clip").compactMap { $0 as? XMLElement }
            let rows = clips.enumerated().map { index, clip in
                let asset = assets.first { $0.attribute(forName: "id")?.stringValue == clip.attribute(forName: "ref")?.stringValue }
                let source = asset?.elements(forName: "media-rep").first?.attribute(forName: "src")?.stringValue.flatMap(URL.init(string:))
                return "Layer \(index+1) | \(source?.lastPathComponent ?? "Saved media") | Timeline \(clip.attribute(forName: "offset")?.stringValue ?? "inherited") | Source \(clip.attribute(forName: "start")?.stringValue ?? "0s") | Duration \(clip.attribute(forName: "duration")?.stringValue ?? "inherited")"
            }
            sections.append(.init(title: "Local update and review status", text: "Saved from parent version ID \(receipt.parentVersionID.uuidString). The approved script above is inherited reference material. This local export was fully decoded and its output hashes verified, but its edited audio has not been transcribed again. No new editorial, scientific or production approval is recorded. Review the saved movie before sharing."))
            sections.append(.init(title: "Saved timeline layers", text: rows.joined(separator: "\n") + String(format: "\n\nSaved duration %.3f seconds. Times retain the editable timeline's rational-second notation; connected-layer offsets are relative to their parent clip.", bound.duration)))
            return HandoffReport(title: project.manifest.name + " - " + version.folderName,
                subtitle: version.label + " | Local update with inherited approved inputs", sections: sections)
        }
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
        let root = try ProjectMutationLease.checkedRoot(project)
        let target = try feedbackTarget(requested.id, project: project)
        guard let timeline = target.version.artifacts.first(where: { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }) else { throw ProjectFailure.invalidProject }
        let folder = try safe("cuts/" + target.version.folderName, in: project.folder)
        let captions = try target.version.artifacts.first(where: { $0.hasPrefix("exports/") && $0.hasSuffix(".itt") }).map { try safe($0, in: folder) }
        try root.checkPath()
        return SavedCutSource(timeline: try safe(timeline, in: folder), captions: captions, timelineSHA256: target.sha, duration: target.duration, engineVersion: target.version.engineVersion)
    }

    func derivativeFolder(_ id: UUID, project: Project) throws -> URL {
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        let parent = try lease.root.child("build",create: true).child("derivatives",create: true)
        try lease.root.checkPath();try parent.checkPath()
        return parent.url.appendingPathComponent(id.uuidString)
    }

    private struct DerivativeVerification: Sendable {
        let root: SourceRenderDirectory
        let output: SourceRenderDirectory
        let signatures: [String:SourceFileSignature]
        let recipeSHA256: String
        func check() throws {
            try Task.checkCancellation();try root.checkPath();try output.checkPath()
            for (name,signature) in signatures {
                guard try WorkflowRepository.derivativeSignature(name,in: output)==signature else {
                    throw WorkflowFailure.invalid("An export changed before publication. Its parent is preserved; create another export.")
                }
            }
            try root.checkPath();try output.checkPath()
        }
    }
    private nonisolated static func derivativeSignature(_ name: String,in directory: SourceRenderDirectory) throws -> SourceFileSignature {
        guard CreativeAssetFiles.validLeaf(name) else { throw ProjectFailure.invalidProject }
        var value = stat()
        guard fstatat(directory.descriptor,name,&value,AT_SYMLINK_NOFOLLOW)==0,value.st_mode&S_IFMT==S_IFREG,value.st_size>=0 else { throw ProjectFailure.invalidProject }
        return .init(device: value.st_dev,inode: value.st_ino,size: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec),changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
    func verifyDerivative(folder: URL, parentVersionID: UUID, parentHash: String, request: DerivativeRequest, project: Project) throws -> String {
        let root = try ProjectMutationLease.checkedRoot(project)
        return try inspectDerivative(folder: folder,parentVersionID: parentVersionID,parentHash: parentHash,request: request,project: project,root: root).recipeSHA256
    }
    private func inspectDerivative(folder: URL,parentVersionID: UUID,parentHash: String,request: DerivativeRequest,project: Project,root: SourceRenderDirectory) throws -> DerivativeVerification {
        guard let id = UUID(uuidString: folder.lastPathComponent) else { throw ProjectFailure.invalidProject }
        let owned = try root.child("build").child("derivatives").child(id.uuidString)
        // URL equality also compares directory hints. The caller captured this
        // URL before the worker created the directory; compare path spelling,
        // while the checked root/child descriptors pin physical identity.
        guard folder.standardizedFileURL.path==owned.url.standardizedFileURL.path else { throw ProjectFailure.invalidProject }
        var signatures = ["derivative.json":try Self.derivativeSignature("derivative.json",in: owned)]
        let recipeBytes = try owned.read("derivative.json",limit: 8*1024*1024)
        try TranscriptJSONKeys.validate(recipeBytes)
        let object = try JSONSerialization.jsonObject(with: recipeBytes) as? [String: Any]
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
              hashes.count<=100,hashes["review.mp4"] != nil, hashes["timeline.fcpxml"] != nil else {
            throw WorkflowFailure.invalid("The export receipt does not match this saved version and its selected output settings.")
        }
        for (leaf, hash) in hashes {
            let before = try Self.derivativeSignature(leaf,in: owned)
            guard CutoutSourceInfo.validHash(hash),before.size<=GraphicArtifactFiles.movieLimit,
                  try owned.voiceHash(leaf,limit: GraphicArtifactFiles.movieLimit)==hash,
                  try Self.derivativeSignature(leaf,in: owned)==before else { throw WorkflowFailure.invalid("An exported file changed. Create a new verified export.") }
            signatures[leaf] = before
        }
        let composed = object?["generated_graphic"]
        if let graphic = request.graphic {
            guard let metadata = composed as? [String:Any],hashes["graphic-revision.json"]==graphic.manifestSHA256,
                  hashes["graphic-scene.json"] != nil else { throw WorkflowFailure.invalid("The selected graphic is missing from this export receipt.") }
            try graphic.verifyMetadata(metadata,revisionBytes: owned.read("graphic-revision.json",limit: 65536),
                sceneBytes: owned.read("graphic-scene.json",limit: 1024*1024),project: project)
        } else if composed != nil && !(composed is NSNull) { throw WorkflowFailure.invalid("This export contains an unexpected generated graphic.") }
        let sound = object?["sound_effect"] as? [String: Any]
        if let soundID = request.soundFileID {
            let manifest = try decoder.decode(ProjectManifest.self, from: root.read("clauto-project.json",limit: 8*1024*1024))
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
        let verification = DerivativeVerification(root: root,output: owned,signatures: signatures,recipeSHA256: TranscriptSourceMap.sha(recipeBytes))
        try verification.check();return verification
    }

    func saveDerivative(_ record: DerivedCut, project: Project) throws {
        guard record.projectID == project.id else { throw ProjectFailure.invalidProject }
        let root = try ProjectMutationLease.checkedRoot(project)
        let folder = root.url.appendingPathComponent("build/derivatives/"+record.id.uuidString)
        // Stream hashes outside the common project lease; feedback/draft writers
        // must remain available during large movie reads. Recheck every physical
        // artifact signature under the short publication lease.
        let verified = try inspectDerivative(folder: folder,parentVersionID: record.parentVersionID,parentHash: record.parentTimelineSHA256,request: record.request,project: project,root: root)
        guard verified.recipeSHA256==record.recipeSHA256 else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
        guard lease.root.identity==root.identity else { throw ProjectFailure.invalidProject }
        try verified.check();try lease.root.checkPath()
        let bytes = try encoder.encode(record)
        if try CreativeAssetFiles.exists("clauto-derivative.json",in: verified.output) {
            guard try verified.output.read("clauto-derivative.json",limit: 65536)==bytes else { throw ProjectFailure.invalidProject }
        } else { try verified.output.writeNew(bytes,name: "clauto-derivative.json") }
        try lease.root.checkPath();try verified.output.checkPath()
    }

    /// Copies an already verified export into immutable main-version history.
    /// It never rerenders, grants approval, deletes build evidence or overwrites
    /// an earlier version. A concurrent current-version change refuses publication.
    func saveDerivativeAsVersion(_ requested: DerivedCut, label: String, expectedCurrent: UUID?,
                                 project original: Project,
                                 fileExecutor: GraphicBlockingExecutor = GraphicArtifactFiles.executor) async throws -> CutVersion {
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 240,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              requested.projectID == original.id else { throw WorkflowFailure.invalid("Give this version a short name.") }
        let root = try ProjectMutationLease.checkedRoot(original)
        var pinned = original; pinned.folder = root.url; pinned.folderIdentity = root.identity
        let project = pinned
        let originalCuts = try root.child("cuts")
        let manifestBytes = try root.read("clauto-project.json", limit: 8*1024*1024)
        try TranscriptJSONKeys.validate(manifestBytes)
        let manifest = try decoder.decode(ProjectManifest.self, from: manifestBytes)
        guard manifest.id == project.id else { throw ProjectFailure.invalidProject }
        let versions = try versions(project: project)
        if let existing = versions.first(where: { $0.localEditOrigin?.derivativeID == requested.id }) {
            guard existing.localEditOrigin?.recipeSHA256 == requested.recipeSHA256,
                  existing.localEditOrigin?.parentVersionID == requested.parentVersionID else { throw ProjectFailure.invalidProject }
            let receipt = try promotionReceipt(existing, project: project)
            let exports = try root.child("cuts").child(existing.folderName).child("exports")
            for (name, sha) in receipt.savedOutputSHA256 {
                guard try exports.voiceHash(name, limit: GraphicArtifactFiles.movieLimit) == sha else { throw ProjectFailure.invalidProject }
            }
            return existing // Retry acknowledges its version without changing a newer current cut.
        }
        let currentPointer = try SavedCutStorage.currentState(root)
        guard currentPointer.id == expectedCurrent,
              let parent = versions.first(where: { $0.id == requested.parentVersionID }),
              let scriptPath = parent.approvedScript, scriptPath.hasPrefix("inputs/script/"),
              parent.artifacts.contains(scriptPath), let briefSHA = parent.briefHash else {
            throw WorkflowFailure.invalid("The current version changed or its saved inputs are unavailable. Review the current cut before saving again.")
        }
        let source = try root.child("build").child("derivatives").child(requested.id.uuidString)
        let recordBytes = try source.read("clauto-derivative.json", limit: 65536)
        try TranscriptJSONKeys.validate(recordBytes)
        let stored = try decoder.decode(DerivedCut.self, from: recordBytes)
        guard stored.id == requested.id, stored.projectID == project.id,
              stored.parentVersionID == requested.parentVersionID,
              stored.parentTimelineSHA256 == requested.parentTimelineSHA256,
              stored.request == requested.request, stored.recipeSHA256 == requested.recipeSHA256 else { throw ProjectFailure.invalidProject }
        let verified = try inspectDerivative(folder: source.url, parentVersionID: stored.parentVersionID,
            parentHash: stored.parentTimelineSHA256, request: stored.request, project: project, root: root)
        guard verified.recipeSHA256 == stored.recipeSHA256 else { throw ProjectFailure.invalidProject }
        let recipe = try source.read("derivative.json", limit: 8*1024*1024)
        guard TranscriptSourceMap.sha(recipe) == stored.recipeSHA256 else { throw ProjectFailure.invalidProject }
        guard let object = try JSONSerialization.jsonObject(with: recipe) as? [String: Any],
              let hashes = object["output_sha256"] as? [String: String], hashes.count <= 100 else { throw ProjectFailure.invalidProject }
        // A separate short/portrait export is allowed, but moving it into main
        // version history must not erase the parent's frozen duration gate.
        let constraints = [parent.durationBounds, manifest.durationBounds].compactMap { $0 }
        for bounds in constraints { try bounds.validate() }
        let limits = VideoDurationBounds(minimum: constraints.compactMap(\.minimum).max(), maximum: constraints.compactMap(\.maximum).min())
        try limits.validate()
        let durationBounds = limits.enabled ? limits : nil
        let actualDuration = try timelineDuration(XMLDocument(data: source.read("timeline.fcpxml", limit: 16*1024*1024), options: .nodeLoadExternalEntitiesNever))
        try durationBounds?.check(actualDuration)
        let copiedBytes = verified.signatures.values.reduce(Int64(0)) { $0 + $1.size }
        guard copiedBytes <= GraphicArtifactFiles.movieLimit else {
            throw WorkflowFailure.invalid("This export is too large to save as one version. Choose a shorter or smaller export.")
        }
        let parentRoot = try root.child("cuts").child(parent.folderName)
        let parentMetadata = try parentRoot.read("clauto-version.json", limit: 1024*1024)
        let plans = parent.artifacts.filter { $0.hasPrefix("plan/") && $0.hasSuffix(".plan.json") }
        guard plans.count == 1 else { throw ProjectFailure.invalidProject }
        let planName = String(plans[0].dropFirst("plan/".count))
        let scriptName = String(scriptPath.dropFirst("inputs/script/".count))
        let parentFiles = [
            "plan/" + planName: try parentRoot.child("plan").read(planName, limit: 16*1024*1024),
            "inputs/brief.md": try parentRoot.child("inputs").read("brief.md", limit: 16*1024*1024),
            scriptPath: try parentRoot.child("inputs").child("script").read(scriptName, limit: ProjectScriptSelectionStore.limit)
        ]
        guard TranscriptSourceMap.sha(parentFiles["plan/" + planName]!) == parent.approvedPlanHash,
              TranscriptSourceMap.sha(parentFiles["inputs/brief.md"]!) == briefSHA,
              parent.scriptInputSHA256 == nil || parent.scriptInputSHA256 == TranscriptSourceMap.sha(parentFiles[scriptPath]!) else {
            throw WorkflowFailure.invalid("The parent's approved inputs changed. Restore their verified version before saving.")
        }
        return try await fileExecutor.perform { job in
            try job.checkCancellation(); try verified.check()
            let (number, destination) = try SavedCutStorage.reserve(project)
            let exports = try destination.child("exports", create: true)
            let inputs = try destination.child("inputs", create: true)
            _ = try inputs.child("script", create: true)
            _ = try destination.child("plan", create: true)
            var savedHashes = [String: String]()
            var signatures = [String: SourceFileSignature]()
            for (name, sha) in hashes.sorted(by: { $0.key < $1.key }) {
                try job.checkCancellation()
                guard CreativeAssetFiles.validLeaf(name),
                      try source.voiceHash(name, limit: GraphicArtifactFiles.movieLimit, copyTo: exports) == sha else { throw ProjectFailure.invalidProject }
                let before = try Self.derivativeSignature(name, in: exports)
                guard try exports.voiceHash(name, limit: GraphicArtifactFiles.movieLimit) == sha,
                      try Self.derivativeSignature(name, in: exports) == before else { throw ProjectFailure.invalidProject }
                savedHashes[name] = sha
                signatures[name] = before
            }
            try exports.writeNew(recipe, name: "derivative.json")
            savedHashes["derivative.json"] = TranscriptSourceMap.sha(recipe)
            signatures["derivative.json"] = try Self.derivativeSignature("derivative.json", in: exports)
            let xml = try XMLDocument(data: exports.read("timeline.fcpxml", limit: 16*1024*1024), options: .nodeLoadExternalEntitiesNever)
            for node in try xml.nodes(forXPath: "/fcpxml/resources/asset/media-rep") {
                guard let representation = node as? XMLElement,
                      let value = representation.attribute(forName: "src")?.stringValue,
                      let url = URL(string: value), url.isFileURL else { throw ProjectFailure.invalidProject }
                if url.deletingLastPathComponent().standardizedFileURL.path == source.url.standardizedFileURL.path {
                    guard hashes[url.lastPathComponent] != nil else { throw ProjectFailure.invalidProject }
                    representation.attribute(forName: "src")?.stringValue = exports.url.appendingPathComponent(url.lastPathComponent).absoluteString
                }
            }
            xml.isStandalone = false
            let declaration = XMLDTD(); declaration.name = "fcpxml"; xml.dtd = declaration
            let savedXML = xml.xmlData(options: .nodePrettyPrint)
            _ = try XMLDocument(data: savedXML, options: .nodeLoadExternalEntitiesNever)
            try exports.replacePointer(savedXML, name: "timeline.fcpxml")
            savedHashes["timeline.fcpxml"] = TranscriptSourceMap.sha(savedXML)
            signatures["timeline.fcpxml"] = try Self.derivativeSignature("timeline.fcpxml", in: exports)
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "source_sha256": hashes["timeline.fcpxml"]!,
                "saved_sha256": savedHashes["timeline.fcpxml"]!,
                "transformation": "Copied verified local-export assets into permanent saved-version storage."
            ], options: [.sortedKeys])
            try exports.writeNew(snapshot, name: "timeline.snapshot.json")
            savedHashes["timeline.snapshot.json"] = TranscriptSourceMap.sha(snapshot)
            signatures["timeline.snapshot.json"] = try Self.derivativeSignature("timeline.snapshot.json", in: exports)
            for (path, bytes) in parentFiles {
                let parts = path.split(separator: "/").map(String.init)
                var folder = destination
                for part in parts.dropLast() { folder = try folder.child(part, create: true) }
                try folder.writeNew(bytes, name: parts.last!)
            }
            try inputs.writeNew(parentMetadata, name: "parent-version.json")
            try inputs.writeNew(manifestBytes, name: "project-settings.json")
            try inputs.writeNew(recordBytes, name: "derived-source.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            var artifacts = savedHashes.keys.sorted().map { "exports/" + $0 } + parentFiles.keys.sorted()
            artifacts += ["inputs/parent-version.json", "inputs/project-settings.json", "inputs/derived-source.json", "inputs/local-edit-lineage.json"]
            var version = CutVersion(number: number, label: title, engineVersion: parent.engineVersion, runID: stored.id,
                artifacts: artifacts, approvedPlanHash: parent.approvedPlanHash,
                sourceSchemaChecked: nil, savedSchemaChecked: false, briefHash: parent.briefHash,
                approvedScript: scriptPath, durationBounds: durationBounds, exportResolution: stored.request.resolution, aspect: stored.request.aspect,
                scriptInputSHA256: TranscriptSourceMap.sha(parentFiles[scriptPath]!))
            let receipt = SavedVersionPromotionReceipt(projectID: project.id, versionID: version.id, versionNumber: number,
                derivativeID: stored.id, parentVersionID: parent.id, parentMetadataSHA256: TranscriptSourceMap.sha(parentMetadata),
                projectManifestSHA256: TranscriptSourceMap.sha(manifestBytes),
                parentTimelineSHA256: stored.parentTimelineSHA256, recipeSHA256: stored.recipeSHA256,
                savedTimelineSHA256: savedHashes["timeline.fcpxml"]!, savedPreviewSHA256: savedHashes["review.mp4"]!,
                savedOutputSHA256: savedHashes)
            let receiptBytes = try encoder.encode(receipt)
            try inputs.writeNew(receiptBytes, name: "local-edit-lineage.json")
            version.localEditOrigin = .init(derivativeID: stored.id, parentVersionID: parent.id,
                parentTimelineSHA256: stored.parentTimelineSHA256, recipeSHA256: stored.recipeSHA256,
                parentMetadataSHA256: TranscriptSourceMap.sha(parentMetadata), receiptSHA256: TranscriptSourceMap.sha(receiptBytes))
            try job.checkCancellation()
            let lease = try ProjectMutationLease.acquire(project)
            defer { withExtendedLifetime(lease) {} }
            guard lease.root.identity == root.identity,
                  try SavedCutStorage.currentState(lease.root) == currentPointer else {
                throw WorkflowFailure.invalid("The current version changed while saving. Your export and earlier versions are preserved; review the current cut before trying again.")
            }
            guard try lease.root.read("clauto-project.json", limit: 8*1024*1024) == manifestBytes else {
                throw WorkflowFailure.invalid("Project settings changed while saving. The export is preserved; review its duration settings before retrying.")
            }
            try verified.check(); try destination.checkPath()
            guard try parentRoot.read("clauto-version.json", limit: 1024*1024) == parentMetadata else { throw ProjectFailure.invalidProject }
            for (path, bytes) in parentFiles {
                let parts = path.split(separator: "/").map(String.init)
                var folder = parentRoot
                for part in parts.dropLast() { folder = try folder.child(part) }
                guard try folder.read(parts.last!, limit: 16*1024*1024) == bytes else { throw ProjectFailure.invalidProject }
                var copied = destination
                for part in parts.dropLast() { copied = try copied.child(part) }
                guard try copied.read(parts.last!, limit: 16*1024*1024) == bytes else { throw ProjectFailure.invalidProject }
            }
            guard try inputs.read("parent-version.json", limit: 1024*1024) == parentMetadata,
                  try inputs.read("project-settings.json", limit: 8*1024*1024) == manifestBytes,
                  try inputs.read("derived-source.json", limit: 65536) == recordBytes,
                  try inputs.read("local-edit-lineage.json", limit: 65536) == receiptBytes else { throw ProjectFailure.invalidProject }
            for (name, signature) in signatures {
                guard try Self.derivativeSignature(name, in: exports) == signature else { throw ProjectFailure.invalidProject }
            }
            try job.checkCancellation()
            try originalCuts.checkPath()
            try SavedCutStorage.publishMetadata(encoder.encode(version), to: destination, lease: lease)
            try originalCuts.replacePointer(encoder.encode(version.id), name: "current.json")
            return version
        }
    }

    private func promotionReceipt(_ version: CutVersion, project: Project) throws -> SavedVersionPromotionReceipt {
        guard let origin = version.localEditOrigin else { throw ProjectFailure.invalidProject }
        let folder = try ProjectMutationLease.checkedRoot(project).child("cuts").child(version.folderName)
        let bytes = try folder.child("inputs").read("local-edit-lineage.json", limit: 65536)
        guard TranscriptSourceMap.sha(bytes) == origin.receiptSHA256 else { throw ProjectFailure.invalidProject }
        try TranscriptJSONKeys.validate(bytes)
        let receipt = try decoder.decode(SavedVersionPromotionReceipt.self, from: bytes)
        guard receipt.schemaVersion == 1, receipt.projectID == project.id, receipt.versionID == version.id,
              receipt.versionNumber == version.number, receipt.derivativeID == origin.derivativeID,
              receipt.parentVersionID == origin.parentVersionID, receipt.parentMetadataSHA256 == origin.parentMetadataSHA256,
              receipt.parentTimelineSHA256 == origin.parentTimelineSHA256, receipt.recipeSHA256 == origin.recipeSHA256,
              !receipt.newEditorialApproval, !receipt.newFactApproval, !receipt.productionAuthorized,
              receipt.savedOutputSHA256["timeline.fcpxml"] == receipt.savedTimelineSHA256,
              receipt.savedOutputSHA256["review.mp4"] == receipt.savedPreviewSHA256 else { throw ProjectFailure.invalidProject }
        let parentBytes = try folder.child("inputs").read("parent-version.json", limit: 1024*1024)
        guard TranscriptSourceMap.sha(parentBytes) == receipt.parentMetadataSHA256 else { throw ProjectFailure.invalidProject }
        let parent = try decoder.decode(CutVersion.self, from: parentBytes)
        let settings = try folder.child("inputs").read("project-settings.json", limit: 8*1024*1024)
        guard TranscriptSourceMap.sha(settings) == receipt.projectManifestSHA256 else { throw ProjectFailure.invalidProject }
        let manifest = try decoder.decode(ProjectManifest.self, from: settings)
        guard manifest.id == project.id else { throw ProjectFailure.invalidProject }
        let constraints = [parent.durationBounds, manifest.durationBounds].compactMap { $0 }
        let limits = VideoDurationBounds(minimum: constraints.compactMap(\.minimum).max(), maximum: constraints.compactMap(\.maximum).min())
        try limits.validate()
        guard version.durationBounds == (limits.enabled ? limits : nil) else { throw ProjectFailure.invalidProject }
        let plans = version.artifacts.filter { $0.hasPrefix("plan/") && $0.hasSuffix(".plan.json") }
        guard parent.id == origin.parentVersionID, parent.approvedPlanHash == version.approvedPlanHash,
              parent.briefHash == version.briefHash, parent.approvedScript == version.approvedScript,
              plans.count == 1, let script = version.approvedScript, script.hasPrefix("inputs/script/"),
              version.artifacts.contains(script), let scriptHash = version.scriptInputSHA256,
              receipt.savedOutputSHA256.count <= 102,
              receipt.savedOutputSHA256.allSatisfy({ CreativeAssetFiles.validLeaf($0.key) && CutoutSourceInfo.validHash($0.value) }),
              TranscriptSourceMap.sha(try folder.child("plan").read(String(plans[0].dropFirst(5)), limit: 16*1024*1024)) == version.approvedPlanHash,
              TranscriptSourceMap.sha(try folder.child("inputs").read("brief.md", limit: 16*1024*1024)) == version.briefHash,
              TranscriptSourceMap.sha(try folder.child("inputs").child("script").read(String(script.dropFirst("inputs/script/".count)), limit: ProjectScriptSelectionStore.limit)) == scriptHash else { throw ProjectFailure.invalidProject }
        return receipt
    }

    func derivatives(project: Project) throws -> [DerivedCut] {
        let physical = try ProjectMutationLease.checkedRoot(project)
        defer { withExtendedLifetime(physical) {} }
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
    func voiceReviewTarget(_ requested: CutVersion, project: Project,
                           durationLoader: @Sendable (URL) async throws -> Double = { try await AVURLAsset(url: $0).load(.duration).seconds }) async throws -> VoiceReviewTarget {
        let base = "cuts/" + requested.folderName + "/"
        // Pin before decoding the version or awaiting AVFoundation. Revalidate the
        // complete input set afterward so no mixed snapshot can be registered.
        let metadata = try VoiceReviewProvenance.inspect(base + "clauto-version.json", project: project)
        let bound = try feedbackTarget(requested.id, project: project), version = bound.version
        guard requested.number == version.number,
              let preview = version.preferredArtifact(".preview.mp4") ?? version.preferredArtifact(".mp4"),
              let timeline = version.artifacts.first(where: { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") }),
              let script = version.approvedScript else { throw WorkflowFailure.invalid("Choose a saved version with a preview, approved inputs and verified timeline before voice review.") }
        let plans = version.artifacts.filter { $0.hasPrefix("plan/") && $0.hasSuffix(".plan.json") }
        guard plans.count == 1 else { throw WorkflowFailure.invalid("The saved edit's approved plan is unavailable.") }
        let plan = try VoiceReviewProvenance.inspect(base + plans[0], project: project)
        guard plan.sha256 == version.approvedPlanHash else { throw WorkflowFailure.invalid("The saved edit's approved plan changed.") }
        let xml = try VoiceReviewProvenance.inspect(base + timeline, project: project)
        guard xml.sha256 == bound.sha else { throw ProjectFailure.invalidProject }
        let brief = try VoiceReviewProvenance.inspect(base + "inputs/brief.md", project: project)
        guard brief.sha256 == version.briefHash else { throw WorkflowFailure.invalid("The saved edit's approved brief changed.") }
        let approvedScript = try VoiceReviewProvenance.inspect(base + script, project: project)
        let movie = try VoiceReviewProvenance.inspect(base + preview, project: project)
        let previewDuration = try await durationLoader(VoiceReviewProvenance.url(movie.relativePath, project: project))
        guard previewDuration.isFinite, abs(previewDuration - bound.duration) <= 1.0 / 24.0 else { throw WorkflowFailure.invalid("The saved preview duration does not match its verified timeline. Restore a matching preview before voice review.") }
        for artifact in [metadata, plan, xml, brief, approvedScript, movie] { try VoiceReviewProvenance.check(artifact, project: project) }
        if version.localEditOrigin != nil {
            let receipt = try promotionReceipt(version, project: project)
            guard receipt.savedTimelineSHA256 == xml.sha256, receipt.savedPreviewSHA256 == movie.sha256 else { throw ProjectFailure.invalidProject }
        }
        return VoiceReviewTarget(id: UUID(), projectID: project.id, versionID: version.id, versionNumber: version.number,
            versionMetadataSHA256: metadata.sha256,
            timeline: xml, preview: movie,
            approvedPlanSHA256: version.approvedPlanHash, approvedPlanPath: base + plans[0], approvedScriptSHA256: approvedScript.sha256, approvedScriptPath: base + script,
            approvedBriefSHA256: brief.sha256, engineVersion: version.engineVersion, duration: bound.duration)
    }
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
        if version.localEditOrigin != nil {
            guard try promotionReceipt(version, project: project).savedTimelineSHA256 == sha else { throw ProjectFailure.invalidProject }
        }
        let xml = try XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever)
        let projectSequences = try xml.nodes(forXPath: "/fcpxml/library/event/project/sequence")
        guard projectSequences.count == 1, let sequence = projectSequences.first as? XMLElement,
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
