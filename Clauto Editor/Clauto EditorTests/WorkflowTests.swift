import Foundation
import Testing
import Darwin
import CryptoKit
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor FixtureRunner: CommandRunning {
    var commands: [ProcessCommand] = []
    var failStage: Int?
    var malformed: Bool
    var failDetail: String
    init(failStage: Int? = nil, malformed: Bool = false, failDetail: String = "Missing fixture") { self.failStage = failStage; self.malformed = malformed; self.failDetail = failDetail }
    func cancel() {}
    func run(_ command: ProcessCommand, onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        commands.append(command)
        let start = Int(command.arguments[command.arguments.firstIndex(of: "--from")! + 1])!
        let stop = Int(command.arguments[command.arguments.firstIndex(of: "--to")! + 1])!
        for stage in start...stop {
            await onLine?(ProcessLine(text: "{\"stage\":\(stage),\"state\":\"start\",\"detail\":\"Synthetic fixture\"}", isError: false))
            if stage == failStage {
                let detail = String(decoding: try JSONEncoder().encode(failDetail), as: UTF8.self)
                await onLine?(ProcessLine(text: "{\"stage\":\(stage),\"state\":\"fail\",\"detail\":\(detail)}", isError: false))
                return ProcessResult(exitCode: 3, output: "", error: "", cancelled: false)
            }
            await onLine?(ProcessLine(text: malformed ? "unrecognized response" : "{\"stage\":\(stage),\"state\":\"done\",\"detail\":\"Synthetic fixture\"}", isError: false))
        }
        return ProcessResult(exitCode: 0, output: "", error: "", cancelled: false)
    }
}

private actor DerivativeProtocolRunner: CommandRunning {
    var mode: String
    let rootToReplace: URL?
    init(_ mode: String,rootToReplace: URL? = nil) { self.mode = mode;self.rootToReplace = rootToReplace }
    func cancel() {}
    func run(_ command: ProcessCommand, onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        let parent = URL(fileURLWithPath: command.arguments[1]), folder = URL(fileURLWithPath: command.arguments[2])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if mode != "missing" {
            // Protocol fixture only. Actual codec/alpha/audio acceptance is covered by
            // Python integration tests and the opt-in real native-service test below.
            try Data("synthetic-protocol-output".utf8).write(to: folder.appendingPathComponent("review.mp4"))
            try FileManager.default.copyItem(at: parent, to: folder.appendingPathComponent("timeline.fcpxml"))
            let range = [0.0, (0.5 * 24000 / 1001).rounded(.toNearestOrEven) * 1001 / 24000]
            var recipe: [String: Any] = ["state": "complete", "parent_sha256": try DerivativeService.digest(parent),
                "aspect": "9:16", "resolution": "720p", "full_decode_passed": true,
                "selected_range_seconds": mode == "wrongRange" ? [0.0, 0.8] : range,
                "framing": ["conform": "fit", "position_percent_of_height": [0.0, 0.0]], "audio_effects": NSNull(),
                "output_sha256": ["review.mp4": try DerivativeService.digest(folder.appendingPathComponent("review.mp4")),
                                  "timeline.fcpxml": try DerivativeService.digest(folder.appendingPathComponent("timeline.fcpxml"))]]
            if let index = command.arguments.firstIndex(of: "--sound") {
                let sound = URL(fileURLWithPath: command.arguments[index + 1])
                let at = Double(command.arguments[command.arguments.firstIndex(of: "--sound-at")! + 1])!
                let gain = Double(command.arguments[command.arguments.firstIndex(of: "--sound-gain-db")! + 1])!
                recipe["source_sha256"] = [sound.path: mode == "badSoundHash" ? "wrong" : try DerivativeService.digest(sound)]
                recipe["sound_effect"] = ["source": mode == "badSoundIdentity" ? sound.path + ".different" : sound.path,
                    "at": mode == "badSoundTime" ? DerivativeRequest.snapped(at) + 0.1 : DerivativeRequest.snapped(at), "gain_db": gain]
            }
            try JSONSerialization.data(withJSONObject: recipe).write(to: folder.appendingPathComponent("derivative.json"))
        }
        if let rootToReplace {
            let preserved = rootToReplace.appendingPathExtension("original")
            try FileManager.default.moveItem(at: rootToReplace,to: preserved)
            try FileManager.default.copyItem(at: preserved,to: rootToReplace)
        }
        return ProcessResult(exitCode: 0, output: "Synthetic protocol fixture", error: "", cancelled: false)
    }
}

struct WorkflowTests {
    private func fixture(legacyScriptName: String? = nil) async throws -> (URL, URL, Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-workflow-\(UUID())")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"), withIntermediateDirectories: true)
        try "0.1.0-dev".write(to: engine.appendingPathComponent("ENGINE_VERSION"), atomically: true, encoding: .utf8)
        let repo = ProjectRepository()
        var project = try await repo.create(name: "Synthetic", root: root.appendingPathComponent("projects"), engine: engine, engineVersion: "0.1.0-dev")
        let clip = root.appendingPathComponent("clip.MOV")
        try Data("synthetic-original".utf8).write(to: clip)
        project = try await repo.add([clip], to: project)
        if let legacyScriptName {
            try "Hello. [[NOTE: fixture]]".write(to: project.folder.appendingPathComponent("script/"+legacyScriptName),atomically: true,encoding: .utf8)
        } else { project = try await repo.approveScript("Hello. [[NOTE: fixture]]", project: project) }
        return (root, engine, project)
    }

    private func plan(_ run: EditRun) throws {
        let folder = run.folder.appendingPathComponent("plan")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"script":"script.md","cues":[],"issues":[],"unresolved":[]}"#.utf8).write(to: folder.appendingPathComponent("video.plan.json"))
    }

    private func outputs(_ run: EditRun, project: Project, withReadback: Bool = true) throws {
        let fm = FileManager.default
        for key in ["exports", "roughcut", "graphics"] { try fm.createDirectory(at: run.folder.appendingPathComponent(key), withIntermediateDirectories: true) }
        let graphic = run.folder.appendingPathComponent("graphics/cue.mov")
        try Data("synthetic-generated-layer".utf8).write(to: graphic)
        let source = URL(fileURLWithPath: project.manifest.files[0].originalPath)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.13"><resources>
        <format id="r1" frameDuration="1001/24000s" width="1920" height="1080"/>
        <asset id="r2" name="Original" start="0s" duration="24000/24000s" hasVideo="1" format="r1"><media-rep kind="original-media" src="\(source.absoluteString)"/></asset>
        <asset id="r3" name="Generated layer" start="0s" duration="24000/24000s" hasVideo="1" format="r1"><media-rep kind="original-media" src="\(graphic.absoluteString)"/></asset>
        </resources><library><event name="Synthetic"><project name="Fixture"><sequence format="r1" duration="24000/24000s" tcStart="0s" tcFormat="NDF"><spine><asset-clip ref="r2" offset="0s" start="0s" duration="24000/24000s"/></spine></sequence></project></event></library></fcpxml>
        """
        try xml.write(to: run.folder.appendingPathComponent("exports/video.fcpxml"), atomically: true, encoding: .utf8)
        let evidence: [String: Any] = ["timeline": "video.fcpxml", "sha256": SHA256.hash(data: Data(xml.utf8)).map { String(format: "%02x", $0) }.joined(), "problems": [], "schemaChecked": false]
        try JSONSerialization.data(withJSONObject: evidence).write(to: run.folder.appendingPathComponent("exports/video.validation.json"))
        if withReadback { try "Synthetic read-back.".write(to: run.folder.appendingPathComponent("roughcut/clip.heard.txt"), atomically: true, encoding: .utf8) }
    }

    @Test func derivativeProtocolRequiresReceiptAndExactSelectedVersionRange() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Parent")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        let parent = try await disk.snapshot(run, project: project)
        let request = DerivativeRequest(resolution: .hd, end: 0.5)
        for mode in ["missing", "wrongRange"] {
            await #expect(throws: (any Error).self) {
                try await DerivativeService(runner: DerivativeProtocolRunner(mode), disk: disk).export(request, version: parent, project: project, engine: engine, onLine: { _ in })
            }
        }
        #expect(try await disk.derivatives(project: project).isEmpty)
        let result = try await DerivativeService(runner: DerivativeProtocolRunner("complete"), disk: disk).export(request, version: parent, project: project, engine: engine, onLine: { _ in })
        #expect(try await WorkflowRepository().derivatives(project: project).first?.id == result.id)
        #expect(result.parentVersionID == parent.id && result.request == request)
        #expect(try await disk.current(project: project)?.id == parent.id)
        let folder = try await disk.derivativeFolder(result.id, project: project)
        for directoryHint in [false,true] {
            let equivalent = URL(fileURLWithPath: folder.path,isDirectory: directoryHint)
            let hash = try await disk.verifyDerivative(folder: equivalent,parentVersionID: parent.id,parentHash: result.parentTimelineSHA256,request: request,project: project)
            #expect(hash==result.recipeSHA256)
        }
        try Data("changed".utf8).write(to: folder.appendingPathComponent("review.mp4"))
        #expect(try await disk.derivatives(project: project).isEmpty)
    }

    @Test(arguments: [false,true]) func derivativeCannotAdmitAnIdenticalReplacementRootAfterItsWorkerReturns(legacyUnpinnedHandle: Bool) async throws {
        let (root,engine,original) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository();var run = try await disk.prepare(project: original,engine: engine,label: "Physical root protocol fixture")
        try plan(run);try outputs(run,project: original)
        run.state = .complete;run.approvedPlanHash = try await disk.plan(run).hash
        let parent = try await disk.snapshot(run,project: original)
        var project = original;if legacyUnpinnedHandle { project.folderIdentity = nil }
        let oldCurrent = try Data(contentsOf: original.folder.appendingPathComponent("cuts/current.json"))
        await #expect(throws: (any Error).self) {
            _ = try await DerivativeService(runner: DerivativeProtocolRunner("complete",rootToReplace: original.folder),disk: disk)
                .export(DerivativeRequest(resolution: .hd,end: 0.5),version: parent,project: project,engine: engine,onLine: { _ in })
        }
        let physicalOriginal = original.folder.appendingPathExtension("original")
        for folder in [physicalOriginal,original.folder] {
            #expect(try Data(contentsOf: folder.appendingPathComponent("cuts/current.json"))==oldCurrent)
            let children = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("build/derivatives"),includingPropertiesForKeys: nil)
            #expect(children.count==1)
            for child in children { #expect(!FileManager.default.fileExists(atPath: child.appendingPathComponent("clauto-derivative.json").path)) }
        }
        await #expect(throws: (any Error).self) { _ = try await disk.derivativeFolder(UUID(),project: original) }
        await #expect(throws: (any Error).self) { _ = try await disk.derivatives(project: original) }
        let reopened = try await ProjectRepository().open(original.folder)
        #expect(try await disk.derivatives(project: reopened).isEmpty)
    }

    @Test func derivativeSoundIdentityTimingAndHashMustMatchTheChosenLocalFile() async throws {
        let (root, engine, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let sound = root.appendingPathComponent("synthetic-effect.wav")
        let bytes = Data("protocol-only synthetic sound identity".utf8); try bytes.write(to: sound)
        let project = try await ProjectRepository().add([sound], to: original, group: .audio)
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Sound parent")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        let parent = try await disk.snapshot(run, project: project)
        let file = try #require(project.manifest.files.first { $0.group == .audio })
        let request = DerivativeRequest(resolution: .hd, end: 0.5, soundFileID: file.id, soundAt: 0.0625625)
        for mode in ["badSoundIdentity", "badSoundTime", "badSoundHash"] {
            await #expect(throws: WorkflowFailure.self) {
                try await DerivativeService(runner: DerivativeProtocolRunner(mode), disk: disk).export(request, version: parent, project: project, engine: engine, onLine: { _ in })
            }
        }
        #expect(try await disk.derivatives(project: project).isEmpty)
        let accepted = try await DerivativeService(runner: DerivativeProtocolRunner("sound"), disk: disk).export(request, version: parent, project: project, engine: engine, onLine: { _ in })
        #expect(try await disk.derivatives(project: project).first?.id == accepted.id)
        #expect(try Data(contentsOf: sound) == bytes)
        #expect(try await disk.current(project: project)?.id == parent.id)
    }

    @Test func derivativeParametersRejectInvalidTimesAndEffects() throws {
        #expect(DerivativeRequest.snapped(0.0625625) == 2002.0 / 24000.0)
        for request in [DerivativeRequest(start: -.infinity), DerivativeRequest(end: 3), DerivativeRequest(x: 101),
                        DerivativeRequest(effects: LocalAudioEffects(gainDB: .nan))] {
            #expect(throws: WorkflowFailure.self) { try request.validate(duration: 2) }
        }
        let legacy = try JSONDecoder().decode(DerivativeRequest.self, from: Data(#"{"aspect":"9:16","resolution":"720p","start":0,"framing":"fit","x":0,"y":0}"#.utf8))
        #expect(legacy.soundFileID == nil && legacy.soundAt == 0 && legacy.soundGainDB == -12)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_DERIVATIVE_ACCEPTANCE_PROJECT"] != nil))
    func actualNativeSelectedVersionDerivativeAcceptance() async throws {
        let projectURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAUTO_DERIVATIVE_ACCEPTANCE_PROJECT"]))
        let engine = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAUTO_ACCEPTANCE_ENGINE"]))
        let project = try await ProjectRepository().open(projectURL), disk = WorkflowRepository()
        let parent = try #require(try await disk.current(project: project))
        let request = DerivativeRequest(resolution: .hd, start: 0.0625625, end: 0.75, effects: LocalAudioEffects(gainDB: -3, highpassHZ: 80, compressor: true))
        let result = try await DerivativeService(runner: ProcessRunner(), disk: disk).export(request, version: parent, project: project, engine: engine, onLine: { _ in })
        #expect(result.parentVersionID == parent.id)
        #expect(try await disk.current(project: project)?.id == parent.id)
        #expect(try await WorkflowRepository().derivatives(project: project).contains { $0.id == result.id })
        print("NATIVE_DERIVATIVE_ACCEPTANCE_FOLDER=" + project.folder.appendingPathComponent("build/derivatives/" + result.id.uuidString).path)
    }

    @Test func outputPreferencesPersistFreezeAndRefuseMismatchedTimeline() async throws {
        let (root, engine, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository(), disk = WorkflowRepository(), runner = FixtureRunner()
        let project = try await repo.exportResolution(.ultraHD, project: original)
        #expect(try await repo.open(project.folder).manifest.outputResolution == .ultraHD)
        var run = try await disk.prepare(project: project, engine: engine, label: "4K")
        let changed = try await repo.preferences(aspect: "9:16", model: "small", project: project)
        _ = try await repo.exportResolution(.hd, project: changed)
        let finished = try await PipelineService(runner: runner, disk: disk).execute(run, project: changed, engine: engine, start: 1, stop: 3, onEvent: { _ in })
        #expect(finished.state == .needsReview)
        let command = try #require(await runner.commands.first)
        #expect(command.arguments[command.arguments.firstIndex(of: "--resolution")! + 1] == "2160p")
        #expect(command.arguments[command.arguments.firstIndex(of: "--aspect")! + 1] == "16:9")
        #expect(command.environment["CLAUTO_WHISPER_MODEL"] == "large-v3")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        // The fixture emits 1920x1080: success receipts cannot disguise the wrong canvas.
        await #expect(throws: WorkflowFailure.self) { try await disk.snapshot(run, project: project) }
        #expect(try await disk.current(project: project) == nil)
        var missing = run
        missing.exportResolution = nil; missing.aspect = nil; missing.whisperModel = nil; missing.outputSettingsSchema = nil
        await #expect(throws: WorkflowFailure.self) { try await disk.settings(missing, project: project, engine: engine) }
        await #expect(throws: WorkflowFailure.self) { try await disk.snapshot(missing, project: project) }
        var settings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: run.folder.appendingPathComponent("paths.json")))
        settings["export_resolution"] = "720p"
        try JSONEncoder().encode(settings).write(to: run.folder.appendingPathComponent("paths.json"))
        await #expect(throws: WorkflowFailure.self) { try await disk.settings(run, project: project, engine: engine) }
    }

    @Test func durationLimitsPersistFreezeAndRejectTampering() async throws {
        let (root, engine, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository(), disk = WorkflowRepository(), runner = FixtureRunner()
        let bounds = VideoDurationBounds(minimum: 0.5, maximum: 2)
        let project = try await repo.durationBounds(bounds, project: original)
        #expect(try await repo.open(project.folder).manifest.durationBounds == bounds)
        let run = try await disk.prepare(project: project, engine: engine, label: "Bounded")
        let changed = try await repo.durationBounds(VideoDurationBounds(maximum: 0.8), project: project)
        #expect(run.durationBounds == bounds)
        let done = try await PipelineService(runner: runner, disk: disk).execute(run, project: changed, engine: engine, start: 1, stop: 3, onEvent: { _ in })
        #expect(done.state == .needsReview)
        let command = try #require(await runner.commands.first)
        #expect(command.arguments.contains("--min-duration") && command.arguments.contains("--max-duration"))
        #expect(command.arguments[command.arguments.firstIndex(of: "--max-duration")! + 1] == "2.0")
        var settings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: run.folder.appendingPathComponent("paths.json")))
        settings["duration_bounds"] = #"{"maximum":20}"#
        try JSONEncoder().encode(settings).write(to: run.folder.appendingPathComponent("paths.json"))
        await #expect(throws: WorkflowFailure.self) { try await disk.settings(run, project: changed, engine: engine) }
        for invalid in [VideoDurationBounds(minimum: 0), VideoDurationBounds(maximum: .infinity), VideoDurationBounds(minimum: 2, maximum: 1)] {
            await #expect(throws: WorkflowFailure.self) { try await repo.durationBounds(invalid, project: original) }
        }
    }

    @Test func actualTimelineBoundsGatePreservesThePreviousCut() async throws {
        let (root, engine, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository(), repo = ProjectRepository()
        var first = try await disk.prepare(project: original, engine: engine, label: "Previous")
        try plan(first); try outputs(first, project: original)
        first.state = .complete; first.approvedPlanHash = try await disk.plan(first).hash
        let previous = try await disk.snapshot(first, project: original)
        for bounds in [VideoDurationBounds(maximum: 0.9), VideoDurationBounds(minimum: 1.1)] {
            let project = try await repo.durationBounds(bounds, project: original)
            var run = try await disk.prepare(project: project, engine: engine, label: "Impossible")
            try plan(run); try outputs(run, project: project)
            run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
            await #expect(throws: WorkflowFailure.self) { try await disk.snapshot(run, project: project) }
            #expect(try await disk.current(project: project)?.id == previous.id)
            #expect(try await disk.versions(project: project).count == 1)
        }
        let project = try await repo.durationBounds(VideoDurationBounds(minimum: 1, maximum: 1), project: original)
        var run = try await disk.prepare(project: project, engine: engine, label: "Exact")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        let accepted = try await disk.snapshot(run, project: project)
        #expect(accepted.durationBounds == project.manifest.durationBounds && accepted.number == 2)
    }

    @Test func resumedDurationFailureShowsTheEditorialProblem() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Review")
        try plan(run); run.approvedPlanHash = try await disk.plan(run).hash; run.state = .needsReview
        let message = "Duration review required: retained narration is above the maximum. Review whole takes or sentences."
        let runner = FixtureRunner(failStage: 4, failDetail: message)
        let failed = try await PipelineService(runner: runner, disk: disk).execute(run, project: project, engine: engine, start: 4, stop: 5, onEvent: { _ in })
        #expect(failed.state == .failed && failed.failure == message)
    }

    @Test func oldManifestsRunsAndVersionsLoadWithoutDurationLimits() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await ProjectRepository().open(project.folder).manifest.durationBounds == nil)
        let disk = WorkflowRepository()
        let run = try await disk.prepare(project: project, engine: engine, label: "Legacy")
        #expect(try await disk.recentRun(project: project)?.durationBounds == nil)
        #expect(try await disk.settings(run, project: project, engine: engine)["duration_bounds"] == nil)
    }

    @Test func timedFeedbackStaysWithItsVersionAndPreservesCuts() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var versions: [CutVersion] = []
        for label in ["First", "Second"] {
            var run = try await disk.prepare(project: project, engine: engine, label: label)
            try plan(run); try outputs(run, project: project)
            run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
            versions.append(try await disk.snapshot(run, project: project))
        }
        let timeline = project.folder.appendingPathComponent("cuts/" + versions[0].folderName + "/exports/video.fcpxml")
        let original = try Data(contentsOf: timeline)
        let entries = try await disk.addFeedback("Shorten this pause", start: 0.25, end: 0.75, version: versions[0], project: project)
        let entry = try #require(entries.first)
        #expect(entry.versionID == versions[0].id && entry.versionNumber == 1)
        #expect(entry.timelineSHA256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        #expect(entry.startSeconds == 0.25 && entry.endSeconds == 0.75)
        #expect(try await WorkflowRepository().feedback(project: project).first?.text == "Shorten this pause")
        #expect(try await disk.feedback(project: project).allSatisfy { $0.versionID != versions[1].id })
        let resolved = try await disk.resolveFeedback(entry.id, resolved: true, project: project)
        #expect(resolved[0].resolved && resolved[0].resolvedAt != nil)
        #expect(try await disk.resolveFeedback(entry.id, resolved: false, project: project)[0].resolvedAt == nil)
        #expect(try Data(contentsOf: timeline) == original)
        #expect(try await disk.current(project: project)?.id == versions[1].id)
    }

    @Test func changedTimelineAndForgedLoadedRangesDisableFeedback() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Feedback provenance")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        let version = try await disk.snapshot(run, project: project)
        var entries = try await disk.addFeedback("Synthetic", start: 0.2, end: 0.8, version: version, project: project)
        #expect(entries[0].attachment == .verified)
        let timeline = project.folder.appendingPathComponent("cuts/" + version.folderName + "/exports/video.fcpxml")
        let original = try Data(contentsOf: timeline)
        try Data((String(decoding: original, as: UTF8.self) + "\n").utf8).write(to: timeline)
        #expect(try await disk.feedback(project: project)[0].attachment == .changedOrMissingVersion)
        await #expect(throws: WorkflowFailure.self) { try await disk.addFeedback("Edited timeline", start: 0, version: version, project: project) }
        await #expect(throws: WorkflowFailure.self) { try await disk.resolveFeedback(entries[0].id, resolved: true, project: project) }
        try original.write(to: timeline)
        entries[0].endSeconds = 20; entries[0].attachment = .verified
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: project.folder.appendingPathComponent("notes/cut-feedback.json"))
        #expect(try await disk.feedback(project: project)[0].attachment == .invalidRange)
        await #expect(throws: WorkflowFailure.self) { try await disk.resolveFeedback(entries[0].id, resolved: true, project: project) }
        #expect(try Data(contentsOf: timeline) == original)
    }

    @Test func invalidFeedbackTimesIdentityAndEscapedNotesAreRefused() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Feedback")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        let version = try await disk.snapshot(run, project: project)
        for start in [-0.1, 1.1, Double.nan, Double.infinity] {
            await #expect(throws: WorkflowFailure.self) { try await disk.addFeedback("Synthetic", start: start, version: version, project: project) }
        }
        await #expect(throws: WorkflowFailure.self) { try await disk.addFeedback(" ", start: 0, version: version, project: project) }
        await #expect(throws: WorkflowFailure.self) { try await disk.addFeedback("Synthetic", start: 0.7, end: 0.2, version: version, project: project) }
        var unknown = version; unknown.id = UUID()
        await #expect(throws: ProjectFailure.self) { try await disk.addFeedback("Wrong version", start: 0, version: unknown, project: project) }
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let notes = project.folder.appendingPathComponent("notes")
        try FileManager.default.removeItem(at: notes); try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: outside)
        await #expect(throws: ProjectFailure.self) { try await disk.addFeedback("Escaped note", start: 0, version: version, project: project) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func stagedPipelineRequiresReviewAndKeepsNetworkOffline() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository(), runner = FixtureRunner()
        let service = PipelineService(runner: runner, disk: disk)
        var run = try await disk.prepare(project: project, engine: engine, label: "First draft")
        run = try await service.execute(run, project: project, engine: engine, start: 1, stop: 3, onEvent: { _ in })
        #expect(run.state == .needsReview)
        await #expect(throws: ProjectFailure.self) { try await service.execute(run, project: project, engine: engine, start: 1, stop: 5, onEvent: { _ in }) }
        try plan(run)
        await #expect(throws: WorkflowFailure.self) { try await service.execute(run, project: project, engine: engine, start: 4, stop: 5, onEvent: { _ in }) }
        run.approvedPlanHash = try await disk.plan(run).hash
        run = try await service.execute(run, project: project, engine: engine, start: 4, stop: 5, onEvent: { _ in })
        #expect(run.state == .complete)
        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.environment["HF_HUB_OFFLINE"] == "1" && $0.environment["TRANSFORMERS_OFFLINE"] == "1" })
        #expect(commands.allSatisfy { !$0.arguments.contains("--no-verify") && !$0.arguments.contains("--allow-missing") })
        #expect(commands[1].arguments.contains("4"))
    }

    @Test func failureAndMalformedProgressNeverProduceCompletedRun() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Fixture")
        run.state = .needsReview
        try plan(run); run.approvedPlanHash = try await disk.plan(run).hash
        let missing = try await PipelineService(runner: FixtureRunner(failStage: 4), disk: disk).execute(run, project: project, engine: engine, start: 4, stop: 5, onEvent: { _ in })
        #expect(missing.state == .needsAssets)
        let fresh = try await disk.prepare(project: project, engine: engine, label: "Malformed")
        let malformed = try await PipelineService(runner: FixtureRunner(malformed: true), disk: disk).execute(fresh, project: project, engine: engine, start: 1, stop: 3, onEvent: { _ in })
        #expect(malformed.state == .failed)
        #expect(try await disk.current(project: project) == nil)
    }

    @Test func fiveVersionsPreserveMediaAndRestoreWithoutOverwriting() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var cuts: [CutVersion] = []
        for i in 1...5 {
            var run = try await disk.prepare(project: project, engine: engine, label: "Revision \(i)")
            try plan(run); try outputs(run, project: project)
            run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
            cuts.append(try await disk.snapshot(run, project: project))
        }
        #expect(try await disk.versions(project: project).map(\.number) == [1, 2, 3, 4, 5])
        let first = cuts[0], folder = project.folder.appendingPathComponent("cuts/" + first.folderName)
        #expect(!first.briefChanged(project))
        var changed = project; changed.brief.about = "A revised brief"
        #expect(first.briefChanged(changed))
        let xmlFile = folder.appendingPathComponent("exports/video.fcpxml")
        let originalXML = try Data(contentsOf: xmlFile)
        #expect(!String(decoding: originalXML, as: UTF8.self).contains("standalone=\"yes\""))
        #expect(String(decoding: originalXML, as: UTF8.self).contains("<!DOCTYPE fcpxml>"))
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("exports/video.snapshot.json"))) as? [String: String])
        #expect(record["saved_sha256"] == SHA256.hash(data: originalXML).map { String(format: "%02x", $0) }.joined())
        #expect(record["source_sha256"] != record["saved_sha256"])
        #expect(first.artifacts.contains("exports/video.source-validation.json"))
        try await disk.restore(first, project: project)
        #expect(try await disk.current(project: project)?.id == first.id)
        #expect(try Data(contentsOf: xmlFile) == originalXML)
        // Clearing engine scratch must not break generated media referenced by saved versions.
        try FileManager.default.removeItem(at: project.folder.appendingPathComponent("build/runs"))
        let xml = try XMLDocument(data: originalXML)
        for case let element as XMLElement in try xml.nodes(forXPath: "//media-rep") {
            let url = try #require(URL(string: element.attribute(forName: "src")!.stringValue!))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: project.manifest.files[0].originalPath)) == Data("synthetic-original".utf8))
    }

    @Test func failedSnapshotLeavesPreviousCutAndNoPartialVersion() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Unverified")
        try plan(run); try outputs(run, project: project, withReadback: false)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        await #expect(throws: WorkflowFailure.self) { try await disk.snapshot(run, project: project) }
        #expect(try await disk.versions(project: project).isEmpty)
        #expect(try await disk.current(project: project) == nil)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_13.dtd"),
                   "Requires the locally installed Final Cut schema"))
    func savedTimelineSchemaFailureLeavesPreviousCutCurrent() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Valid")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        let previous = try await disk.snapshot(run, project: project)
        #expect(previous.savedSchemaChecked == true)
        let path = run.folder.appendingPathComponent("exports/video.fcpxml")
        let malformed = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "<spine>", with: "<spine unsupported=\"yes\">")
        try malformed.write(to: path, atomically: true, encoding: .utf8)
        // A forged valid source receipt must not bypass validation of the saved bytes.
        let evidence: [String: Any] = ["timeline": "video.fcpxml", "sha256": SHA256.hash(data: Data(malformed.utf8)).map { String(format: "%02x", $0) }.joined(), "problems": [], "schemaChecked": true]
        try JSONSerialization.data(withJSONObject: evidence).write(to: run.folder.appendingPathComponent("exports/video.validation.json"))
        await #expect(throws: WorkflowFailure.self) { try await disk.snapshot(run, project: project) }
        #expect(try await disk.current(project: project)?.id == previous.id)
        #expect(try await disk.versions(project: project).count == 1)
    }

    @Test func planEditsInvalidateApprovalAndMessagesSurviveReopen() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Changed")
        run.state = .needsReview
        try plan(run); run.approvedPlanHash = try await disk.plan(run).hash
        try Data(#"{"cues":[{"text":"a changed fact"}],"issues":[],"unresolved":[]}"#.utf8).write(to: run.folder.appendingPathComponent("plan/video.plan.json"))
        await #expect(throws: WorkflowFailure.self) {
            try await PipelineService(runner: FixtureRunner(), disk: disk).execute(run, project: project, engine: engine, start: 4, stop: 5, onEvent: { _ in })
        }
        _ = try await disk.queue("Make the intro shorter.", project: project)
        #expect(try await WorkflowRepository().messages(project: project).first?.text == "Make the intro shorter.")
    }

    @Test func referencesFromAssetLibraryNeverWriteBackToLibrary() async throws {
        let (root, _, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        for (folder, name) in [("fonts", "HerMarker.ttf"), ("textures", "paper-grain.png")] {
            try FileManager.default.createDirectory(at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data("synthetic resource".utf8).write(to: library.appendingPathComponent(folder + "/" + name))
        }
        let updated = try await ProjectRepository().useFolder(library, key: "assets", project: project)
        #expect(updated.manifest.files.contains { $0.relativePath == "assets/textures/paper-grain.png" })
        #expect(try Data(contentsOf: library.appendingPathComponent("fonts/HerMarker.ttf")) == Data("synthetic resource".utf8))
        let settings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: project.folder.appendingPathComponent("paths.json")))
        #expect(settings["assets"] == project.folder.appendingPathComponent("assets").path)
    }

    @Test func redirectedDescendantIsKilledBeforeCancelledRunReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-pid")
        let child = "import os,signal,sys,time; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1]+'.pending','w').write(str(os.getpid())); os.replace(sys.argv[1]+'.pending',sys.argv[1]); time.sleep(30)"
        let script = "import subprocess,sys,time,os; p=subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(30)"
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, child, marker.path], timeout: .seconds(1)))
        #expect(result.cancelled)
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func taskCancellationAfterParentExitKillsPipeHoldingChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-task-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-pid")
        let child = "import os,signal,sys,time; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1]+'.pending','w').write(str(os.getpid())); os.replace(sys.argv[1]+'.pending',sys.argv[1]); time.sleep(30)"
        let parent = "import subprocess,sys; subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]])"
        let runner = ProcessRunner()
        let task = Task { try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", parent, child, marker.path], timeout: .seconds(10))) }
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        defer { kill(pid, SIGKILL) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func timelineEditsInvalidateSavedValidationEvidence() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Modified")
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        try "<fcpxml/>".write(to: run.folder.appendingPathComponent("exports/video.fcpxml"), atomically: true, encoding: .utf8)
        await #expect(throws: WorkflowFailure.self) { try await disk.snapshot(run, project: project) }
        #expect(try await disk.versions(project: project).isEmpty)
    }

    @Test func staleRemovalAndScriptHeadingsRoundTrip() async throws {
        let (root, _, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository()
        let audio = root.appendingPathComponent("recording.wav"); try Data("original".utf8).write(to: audio)
        let added = try await repo.add([audio], to: project)
        let old = try #require(added.manifest.files.first { $0.group == .audio })
        let assigned = try await repo.assign(.music, to: old, project: added)
        let music = try #require(assigned.manifest.files.first { $0.id == old.id })
        _ = try await repo.remove(old, from: added)
        #expect(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent(music.relativePath).path))
        var brief = Brief(); brief.script = "## Music\nA heading in narration.\n\\## About\n    indented code"
        #expect(Brief(markdown: brief.markdown) == brief)
    }

    @Test func tamperedWritablePathsAndEscapedRunFoldersAreRefused() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository(), fm = FileManager.default
        let manifest = project.folder.appendingPathComponent("paths.json")
        let data = try Data(contentsOf: manifest)
        var paths = try JSONDecoder().decode([String: String].self, from: data)
        let library = root.appendingPathComponent("shared-library")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        paths["assets"] = library.path
        try JSONEncoder().encode(paths).write(to: manifest)
        await #expect(throws: WorkflowFailure.self) { try await disk.prepare(project: project, engine: engine, label: "Invalid") }
        try data.write(to: manifest)
        let run = try await disk.prepare(project: project, engine: engine, label: "Valid")
        paths = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: run.folder.appendingPathComponent("paths.json")))
        paths["assets"] = library.path
        try JSONEncoder().encode(paths).write(to: run.folder.appendingPathComponent("paths.json"))
        let source = root.appendingPathComponent("asset.png"); try Data("original".utf8).write(to: source)
        await #expect(throws: ProjectFailure.self) { try await disk.satisfy(MissingPiece(ref: "texture:x", kind: "texture", key: "x", status: "missing", notes: []), urls: [source], run: run) }
        #expect(try fm.contentsOfDirectory(atPath: library.path).isEmpty)
        let planFolder = run.folder.appendingPathComponent("plan")
        try fm.createSymbolicLink(at: planFolder, withDestinationURL: library)
        await #expect(throws: ProjectFailure.self) { try await disk.plan(run) }
        let outside = root.appendingPathComponent("outside"); try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.removeItem(at: run.folder)
        try fm.createSymbolicLink(at: run.folder, withDestinationURL: outside)
        await #expect(throws: ProjectFailure.self) { try await disk.validate(run, project: project) }
    }

    @Test func malformedPlanAndDanglingCurrentPointerAreVisibleErrors() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository(), run = try await disk.prepare(project: project, engine: engine, label: "Invalid plan")
        try plan(run)
        try Data("[]".utf8).write(to: run.folder.appendingPathComponent("plan/video.plan.json"))
        await #expect(throws: WorkflowFailure.self) { try await disk.plan(run) }
        try JSONEncoder().encode(UUID()).write(to: project.folder.appendingPathComponent("cuts/current.json"))
        await #expect(throws: WorkflowFailure.self) { try await disk.current(project: project) }
    }

    @Test func runSettingsAreRecheckedBeforeExecutionAndReopenUsesPathAliases() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository(), runner = FixtureRunner()
        let run = try await disk.prepare(project: project, engine: engine, label: "Recorded")
        #expect(try await disk.recentRun(project: project)?.id == run.id)
        let pathsFile = run.folder.appendingPathComponent("paths.json")
        let data = try Data(contentsOf: pathsFile)
        var settings = try JSONDecoder().decode([String: String].self, from: data)
        settings["build"] = root.appendingPathComponent("outside").path
        try JSONEncoder().encode(settings).write(to: pathsFile)
        await #expect(throws: WorkflowFailure.self) { try await PipelineService(runner: runner, disk: disk).execute(run, project: project, engine: engine, start: 1, stop: 3, onEvent: { _ in }) }
        try Data("not json".utf8).write(to: pathsFile)
        await #expect(throws: DecodingError.self) { try await PipelineService(runner: runner, disk: disk).execute(run, project: project, engine: engine, start: 1, stop: 3, onEvent: { _ in }) }
        #expect(try await disk.recentRun(project: project)?.state == .prepared)
        #expect(await runner.commands.isEmpty)
    }

    @Test func actualEngineProcessStopsAtAssetGateWithoutRendering() async throws {
        let fm = FileManager.default
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard fm.isExecutableFile(atPath: engine.appendingPathComponent(".venv/bin/python").path) else { return }
        let root = fm.temporaryDirectory.appendingPathComponent("clauto-engine-gate-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let repo = ProjectRepository(), disk = WorkflowRepository()
        let version = try String(contentsOf: engine.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var project = try await repo.create(name: "Synthetic engine gate", root: root, engine: engine, engineVersion: version)
        let clip = root.appendingPathComponent("synthetic.MOV"); try Data("never transcribed by this stage4 fixture".utf8).write(to: clip)
        project = try await repo.add([clip], to: project)
        try await repo.approveScript("Synthetic asset-gate fixture.", project: project)
        try fm.createDirectory(at: project.folder.appendingPathComponent("assets/fonts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.folder.appendingPathComponent("assets/textures"), withIntermediateDirectories: true)
        try Data("preflight existence fixture, never rendered".utf8).write(to: project.folder.appendingPathComponent("assets/fonts/test.ttf"))
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII="))
        try png.write(to: project.folder.appendingPathComponent("assets/textures/paper-grain.png"))
        var run = try await disk.prepare(project: project, engine: engine, label: "Asset gate")
        try plan(run); run.state = .needsReview; run.approvedPlanHash = try await disk.plan(run).hash
        let result = try await PipelineService(runner: ProcessRunner(), disk: disk).execute(run, project: project, engine: engine, start: 4, stop: 5, onEvent: { _ in })
        #expect(result.state == .needsAssets)
        #expect(result.events.filter { $0.state == "fail" }.map(\.stage) == [4])
        #expect(!result.events.contains { $0.stage == 5 })
        #expect(try await disk.missing(result).contains { $0.key == "kraft" && $0.status == "missing" })
        #expect(try await disk.current(project: project) == nil)
    }

    @Test func approvedScriptWinsOverAnOlderAlphabeticalDraft() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try "An obsolete draft".write(to: project.folder.appendingPathComponent("script/000-old.txt"), atomically: true, encoding: .utf8)
        let disk = WorkflowRepository(), runner = FixtureRunner()
        let run = try await disk.prepare(project: project, engine: engine, label: "Approved script")
        _ = try await PipelineService(runner: runner, disk: disk).execute(run, project: project, engine: engine, start: 1, stop: 3, onEvent: { _ in })
        let command = try #require(await runner.commands.first)
        let argument = try #require(command.arguments.firstIndex(of: "--script"))
        #expect(command.arguments[argument + 1].hasSuffix("/inputs/script/script.md"))
        #expect(try String(contentsOf: URL(fileURLWithPath: command.arguments[argument + 1]), encoding: .utf8) == "Hello. [[NOTE: fixture]]")
    }

    @Test func uppercaseApprovedScriptSurvivesVersionSnapshot() async throws {
        let (root, engine, project) = try await fixture(legacyScriptName: "APPROVED.MD"); defer { try? FileManager.default.removeItem(at: root) }
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Uppercase")
        try plan(run); try outputs(run, project: project)
        try Data(#"{"script":"APPROVED.MD","cues":[],"issues":[],"unresolved":[]}"#.utf8).write(to: run.folder.appendingPathComponent("plan/video.plan.json"))
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        let version = try await disk.snapshot(run, project: project)
        #expect(version.approvedScript == "inputs/script/APPROVED.MD")
        #expect(version.artifacts.contains("inputs/script/APPROVED.MD"))
    }

    @Test func narrationOrderIsExplicitAndFrozenAcrossStages() async throws {
        let (root, engine, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("second.MOV"); try Data("second synthetic original".utf8).write(to: second)
        let project = try await ProjectRepository().add([second], to: original)
        let ids = project.manifest.files.filter { $0.group == .footage }.map(\.id).reversed()
        let disk = WorkflowRepository()
        let run = try await disk.prepare(project: project, engine: engine, label: "Ordered", narrationIDs: Array(ids))
        let settings = try await disk.settings(run, project: project, engine: engine)
        let path = try #require(settings["assembly"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let sources = try #require(object["sources"] as? [[String: String]])
        #expect(sources[0]["source"] == second.path)
        let changed: [String: Any] = ["schema_version": 2, "sources": Array(sources.reversed())]
        try JSONSerialization.data(withJSONObject: changed).write(to: URL(fileURLWithPath: path))
        await #expect(throws: WorkflowFailure.self) { try await disk.settings(run, project: project, engine: engine) }
        await #expect(throws: ProjectFailure.self) { try await disk.prepare(project: project, engine: engine, label: "Duplicate", narrationIDs: [ids.first!, ids.first!]) }
        #expect(try Data(contentsOf: second) == Data("second synthetic original".utf8))
    }

    @Test func copiedNarrationUsesIntakeKeysAndCannotLoseAssemblyEvidence() async throws {
        let (root, engine, original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("second.MOV"); try Data("copied synthetic original".utf8).write(to: second)
        let project = try await ProjectRepository().add([second], to: original, copy: true)
        let ids = project.manifest.files.filter { $0.group == .footage }.map(\.id)
        let disk = WorkflowRepository()
        var run = try await disk.prepare(project: project, engine: engine, label: "Copied", narrationIDs: ids)
        let settings = try await disk.settings(run, project: project, engine: engine)
        let assemblyPath = try #require(settings["assembly"])
        let spec = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: assemblyPath))) as? [String: Any])
        let sources = try #require(spec["sources"] as? [[String: String]])
        #expect(sources[1]["key"] == "second")
        #expect(sources[1]["source"] != second.path)
        try plan(run); try outputs(run, project: project)
        run.state = .complete; run.approvedPlanHash = try await disk.plan(run).hash
        await #expect(throws: WorkflowFailure.self) { try await disk.snapshot(run, project: project) }
        var version = CutVersion(number: 1, label: "Incomplete", engineVersion: "test", runID: run.id, artifacts: ["roughcut/source.heard.txt"], approvedPlanHash: "test")
        version.primaryOutputPrefix = "roughcut/assembly/selected"
        #expect(version.preferredArtifact(".heard.txt") == nil)
        #expect(try await disk.current(project: project) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_SYNTHETIC_ACCEPTANCE_ROOT"] != nil,
                   "Requires explicitly prepared synthetic inputs and cached speech models"))
    func fullCachedSpeechToVersionAcceptance() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAUTO_SYNTHETIC_ACCEPTANCE_ROOT"]))
        struct Input: Decodable { var synthetic: Bool; var approved_script: String; var source: String; var sources: [String]?; var asset_library: String }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        #expect(input.synthetic)
        guard input.synthetic else { return }
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repo = ProjectRepository(), disk = WorkflowRepository()
        var project = try await repo.create(name: "Synthetic acceptance only", root: root.appendingPathComponent("projects"), engine: engine, engineVersion: "0.1.0-dev")
        let sourceURLs = (input.sources ?? [input.source]).map { URL(fileURLWithPath: $0) }
        project = try await repo.add(sourceURLs, to: project)
        project = try await repo.useFolder(URL(fileURLWithPath: input.asset_library), key: "assets", project: project)
        project = try await repo.useFolder(URL(fileURLWithPath: "/Volumes/Videos/Food Videos/Katie YouTube/Models"), key: "model_cache", project: project)
        try await repo.approveScript(input.approved_script, project: project)
        let sourceHash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: input.source)))
        let sourceHashes = try sourceURLs.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let service = PipelineService(runner: ProcessRunner(), disk: disk)
        let narrationIDs = try sourceURLs.map { url in try #require(project.manifest.files.first { $0.originalPath == url.path }?.id) }
        var run = try await disk.prepare(project: project, engine: engine, label: "Synthetic cached-model acceptance", narrationIDs: narrationIDs)
        run = try await service.execute(run, project: project, engine: engine, start: 1, stop: 3, onEvent: { _ in })
        #expect(run.state == .needsReview, Comment(rawValue: run.failure ?? ""))
        guard run.state == .needsReview else { return }
        let plan = try await disk.plan(run)
        #expect(plan.issues.isEmpty)
        guard plan.issues.isEmpty else { return }
        run.approvedPlanHash = plan.hash // Only the developer-authored synthetic plan is approved in this test.
        run = try await service.execute(run, project: project, engine: engine, start: 4, stop: 5, onEvent: { _ in })
        #expect(run.state == .complete, Comment(rawValue: run.failure ?? ""))
        guard run.state == .complete else { return }
        let version = try await disk.snapshot(run, project: project)
        #expect(version.artifacts.contains { $0.hasSuffix(".fcpxml") })
        #expect(version.artifacts.contains { $0.hasSuffix(".heard.txt") })
        #expect(version.artifacts.contains { $0.hasSuffix(".itt") })
        #expect(try await disk.current(project: project)?.id == version.id)
        #expect(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: input.source))) == sourceHash)
        for (index, source) in sourceURLs.enumerated() { #expect(SHA256.hash(data: try Data(contentsOf: source)) == sourceHashes[index]) }
        let versionRoot = project.folder.appendingPathComponent("cuts/" + version.folderName)
        let savedTimelines = version.artifacts.filter { $0.hasSuffix(".fcpxml") }.map { versionRoot.appendingPathComponent($0).path }
        let validation = try await ProcessRunner().run(ProcessCommand(executable: engine.appendingPathComponent("run"),
            arguments: ["-c", "import sys; sys.path.insert(0, 'scripts'); import fcpxml as F; from pathlib import Path; assert F.FCP_DTD.exists(); problems = {p: F.validate(Path(p)) for p in sys.argv[1:]}; print(problems); assert problems and all(not v for v in problems.values())"] + savedTimelines,
            directory: engine, environment: ["CLAUTO_OFFLINE": "1"], timeout: .seconds(60)))
        try #require(validation.succeeded, Comment(rawValue: validation.output + validation.error))
        try #require(version.savedSchemaChecked == true)
        if sourceURLs.count > 1 {
            #expect(version.primaryOutputPrefix == "roughcut/assembly/selected")
            let xml = try XMLDocument(contentsOf: versionRoot.appendingPathComponent(try #require(version.artifacts.first { $0.hasPrefix("exports/") && $0.hasSuffix(".fcpxml") })))
            let storyline = try xml.nodes(forXPath: "//sequence/spine/asset-clip").compactMap { $0 as? XMLElement }
            #expect(Set(storyline.compactMap { $0.attribute(forName: "ref")?.stringValue }).count == sourceURLs.count)
            #expect(try await disk.handoffReport(version, project: project).sections.contains { $0.title == "Shot list" && $0.text.contains(sourceURLs[1].lastPathComponent) })
        }
        let report: [String: Any] = ["synthetic_only": true, "project": project.folder.path,
            "run": run.folder.path, "version": version.number, "schema_checked": version.sourceSchemaChecked ?? false,
            "saved_schema_checked": version.savedSchemaChecked ?? false, "engine_saved_validation_passed": validation.exitCode == 0,
            "source_count": sourceURLs.count,
            "artifacts": version.artifacts, "original_unchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("acceptance-result.json"), options: .atomic)
    }
}
