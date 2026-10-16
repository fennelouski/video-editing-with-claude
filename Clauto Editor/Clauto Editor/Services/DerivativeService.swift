import Foundation
import CryptoKit

struct LocalAudioEffects: Codable, Equatable, Sendable {
    var gainDB = 0.0
    var highpassHZ: Double? = nil
    var lowpassHZ: Double? = nil
    var compressor = false
    var echoDelayMS: Double? = nil
    var echoDecay = 0.3
    enum CodingKeys: String, CodingKey {
        case gainDB = "gain_db", highpassHZ = "highpass_hz", lowpassHZ = "lowpass_hz", compressor
        case echoDelayMS = "echo_delay_ms", echoDecay = "echo_decay"
    }
    func validate() throws {
        guard gainDB.isFinite, (-60...18).contains(gainDB), echoDecay.isFinite, (0...0.85).contains(echoDecay),
              highpassHZ == nil || (highpassHZ!.isFinite && (20...2000).contains(highpassHZ!)),
              lowpassHZ == nil || (lowpassHZ!.isFinite && (2000...22000).contains(lowpassHZ!)),
              echoDelayMS == nil || (echoDelayMS!.isFinite && (1...500).contains(echoDelayMS!)) else {
            throw WorkflowFailure.invalid("Audio settings are outside their supported ranges.")
        }
    }
}

struct DerivativeRequest: Codable, Equatable, Sendable {
    var aspect = "9:16"
    var resolution: ExportResolution = .fullHD
    var start = 0.0
    var end: Double? = nil
    var framing = "fit"
    var x = 0.0
    var y = 0.0
    var effects: LocalAudioEffects? = nil
    var graphic: GraphicCutSelection? = nil
    var soundFileID: UUID? = nil
    var soundAt = 0.0
    var soundGainDB = -12.0
    enum CodingKeys: String, CodingKey { case aspect, resolution, start, end, framing, x, y, effects, graphic, soundFileID, soundAt, soundGainDB }
    static func snapped(_ seconds: Double) -> Double {
        // Match config.frames(): multiply by the precomputed floating-point FPS.
        (seconds * (24000.0 / 1001.0)).rounded(.toNearestOrEven) * 1001.0 / 24000.0
    }
    func validate(duration: Double) throws {
        guard ["16:9", "9:16"].contains(aspect), ["fit", "fill"].contains(framing),
              start.isFinite, start >= 0, start < duration,
              end == nil || (end!.isFinite && end! > start && end! <= duration),
              x.isFinite, y.isFinite, abs(x) <= 100, abs(y) <= 100 else {
            throw WorkflowFailure.invalid("Choose a time range inside this saved cut and framing positions within −100…100 percent.")
        }
        try effects?.validate()
        try graphic?.validate(cutDuration: Self.snapped(end ?? duration)-Self.snapped(start))
        if soundFileID != nil {
            guard soundAt.isFinite, soundAt >= 0, soundAt < (end ?? duration) - start,
                  soundGainDB.isFinite, (-60...12).contains(soundGainDB) else { throw WorkflowFailure.invalid("Choose a sound time inside the export and a gain of −60…12dB.") }
        }
    }
}

extension DerivativeRequest {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try values.decode(String.self, forKey: .aspect)
        resolution = try values.decode(ExportResolution.self, forKey: .resolution)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decodeIfPresent(Double.self, forKey: .end)
        framing = try values.decode(String.self, forKey: .framing)
        x = try values.decode(Double.self, forKey: .x); y = try values.decode(Double.self, forKey: .y)
        effects = try values.decodeIfPresent(LocalAudioEffects.self, forKey: .effects)
        graphic = try values.decodeIfPresent(GraphicCutSelection.self,forKey: .graphic)
        soundFileID = try values.decodeIfPresent(UUID.self, forKey: .soundFileID)
        soundAt = try values.decodeIfPresent(Double.self, forKey: .soundAt) ?? 0
        soundGainDB = try values.decodeIfPresent(Double.self, forKey: .soundGainDB) ?? -12
    }
}

struct SavedCutSource: Sendable {
    var timeline: URL
    var captions: URL?
    var timelineSHA256: String
    var duration: Double
    var engineVersion: String
}

struct DerivedCut: Codable, Identifiable, Sendable {
    var id: UUID
    var projectID: UUID
    var parentVersionID: UUID
    var parentTimelineSHA256: String
    var request: DerivativeRequest
    var recipeSHA256: String
    var created = Date()
}

struct DerivativeService: Sendable {
    var runner: any CommandRunning
    var disk: WorkflowRepository
    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func export(_ request: DerivativeRequest, version: CutVersion, project: Project, engine: URL,
                onLine: @escaping @Sendable (ProcessLine) async -> Void) async throws -> DerivedCut {
        // Keep this open handle's physical root through all asynchronous work.
        // Portable older callers may omit identity; bind it before the first await.
        let root = try ProjectMutationLease.checkedRoot(project)
        var pinned = project;pinned.folderIdentity = root.identity
        let project = pinned
        let source = try await disk.derivativeSource(version, project: project)
        let engineVersion = try String(contentsOf: engine.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard engineVersion == source.engineVersion else { throw WorkflowFailure.invalid("This saved cut requires its original engine version before exporting.") }
        try request.validate(duration: source.duration)
        let id = UUID(), folder = try await disk.derivativeFolder(id, project: project)
        var arguments = ["timeline_derivatives.py", source.timeline.path, folder.path,
                         "--aspect", request.aspect, "--resolution", request.resolution.rawValue,
                         "--start", String(request.start), "--framing", request.framing,
                         "--x", String(request.x), "--y", String(request.y)]
        if let end = request.end { arguments += ["--end", String(end)] }
        if let captions = source.captions { arguments += ["--captions", captions.path] }
        if let effects = request.effects { arguments += ["--audio-effects", String(decoding: try JSONEncoder().encode(effects), as: UTF8.self)] }
        if let soundID = request.soundFileID {
            let canonical = try await ProjectRepository().open(project.folder)
            guard canonical.id == project.id, let file = canonical.manifest.files.first(where: { $0.id == soundID && [.audio, .music].contains($0.group) }) else { throw ProjectFailure.invalidProject }
            let sound = project.folder.appendingPathComponent(file.relativePath).resolvingSymlinksInPath()
            try ProjectRepository.validateDrive(sound)
            arguments += ["--sound", sound.path, "--sound-at", String(request.soundAt), "--sound-gain-db", String(request.soundGainDB)]
        }
        if let graphic = request.graphic {
            guard graphic.projectID==project.id else { throw ProjectFailure.invalidProject }
            let exported = try await GraphicStudioRepository().exportRevision(project,sceneID: graphic.sceneID,revisionID: graphic.revisionID)
            try graphic.validateSource(exported.revision,project: project.id)
            let manifest = project.folder.appendingPathComponent(graphic.relativeManifestPath)
            let expected = graphic.manifestSHA256
            try await GraphicArtifactFiles.executor.perform { job in
                try job.checkCancellation();let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
                let folder = try lease.root.child("assets").child("generated-scenes").child(graphic.sceneID.uuidString).child("revisions").child(graphic.revisionID.uuidString)
                guard TranscriptSourceMap.sha(try folder.read("revision.json",limit: 65536))==expected else { throw CutoutFailure.changedSource }
                try lease.validate(project)
            }
            arguments += ["--graphic-revision",manifest.path,"--graphic-selection",String(decoding: try JSONEncoder().encode(graphic),as: UTF8.self)]
        }
        try Task.checkCancellation();try root.checkPath()
        let result = try await runner.run(ProcessCommand(executable: engine.appendingPathComponent("run"), arguments: arguments,
            directory: engine, environment: ["CLAUTO_OFFLINE": "1"], timeout: .seconds(86_400)), onLine: onLine)
        try Task.checkCancellation();try root.checkPath()
        guard result.succeeded else { throw WorkflowFailure.invalid(result.cancelled ? "Export stopped. The saved parent cut is unchanged." : "The local export stopped. " + String(result.output.suffix(1800))) }
        let recipe = try await disk.verifyDerivative(folder: folder, parentVersionID: version.id, parentHash: source.timelineSHA256, request: request, project: project)
        let record = DerivedCut(id: id, projectID: project.id, parentVersionID: version.id, parentTimelineSHA256: source.timelineSHA256,
                                request: request, recipeSHA256: recipe)
        try await disk.saveDerivative(record, project: project)
        return record
    }
}
