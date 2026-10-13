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
    init(failStage: Int? = nil, malformed: Bool = false) { self.failStage = failStage; self.malformed = malformed }
    func cancel() {}
    func run(_ command: ProcessCommand, onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        commands.append(command)
        let start = Int(command.arguments[command.arguments.firstIndex(of: "--from")! + 1])!
        let stop = Int(command.arguments[command.arguments.firstIndex(of: "--to")! + 1])!
        for stage in start...stop {
            await onLine?(ProcessLine(text: "{\"stage\":\(stage),\"state\":\"start\",\"detail\":\"Synthetic fixture\"}", isError: false))
            if stage == failStage {
                await onLine?(ProcessLine(text: "{\"stage\":\(stage),\"state\":\"fail\",\"detail\":\"Missing fixture\"}", isError: false))
                return ProcessResult(exitCode: 3, output: "", error: "", cancelled: false)
            }
            await onLine?(ProcessLine(text: malformed ? "unrecognized response" : "{\"stage\":\(stage),\"state\":\"done\",\"detail\":\"Synthetic fixture\"}", isError: false))
        }
        return ProcessResult(exitCode: 0, output: "", error: "", cancelled: false)
    }
}

struct WorkflowTests {
    private func fixture() async throws -> (URL, URL, Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-workflow-\(UUID())")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"), withIntermediateDirectories: true)
        try "0.1.0-dev".write(to: engine.appendingPathComponent("ENGINE_VERSION"), atomically: true, encoding: .utf8)
        let repo = ProjectRepository()
        var project = try await repo.create(name: "Synthetic", root: root.appendingPathComponent("projects"), engine: engine, engineVersion: "0.1.0-dev")
        let clip = root.appendingPathComponent("clip.MOV")
        try Data("synthetic-original".utf8).write(to: clip)
        project = try await repo.add([clip], to: project)
        try await repo.approveScript("Hello. [[NOTE: fixture]]", project: project)
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
        let child = "import os,signal,sys,time; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(30)"
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
        let child = "import os,signal,sys,time; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(30)"
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
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.moveItem(at: project.folder.appendingPathComponent("script/script.md"), to: project.folder.appendingPathComponent("script/APPROVED.MD"))
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
