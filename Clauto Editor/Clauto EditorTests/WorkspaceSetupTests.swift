import Foundation
import Testing
import Darwin
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private func setupJSON(version: [Int] = [3,12,15],brokenScript: String? = nil) -> String {
    var scripts = Dictionary(uniqueKeysWithValues: (SetupService.exportScripts+SetupService.fontScripts).map { ($0,true) })
    if let brokenScript { scripts[brokenScript] = false }
    return String(data: try! JSONSerialization.data(withJSONObject: ["version":version,"syntax":scripts,"modules":Dictionary(uniqueKeysWithValues: SetupService.fontModules.map { ($0,true) })],options: [.sortedKeys]),encoding: .utf8)!
}
private let goodSetupJSON = setupJSON()
private actor SetupRunnerFixture: CommandRunning {
    var commands: [ProcessCommand] = []
    var reply: String
    var fail = false
    var held = false
    var cancelled = false
    var gate: CheckedContinuation<Void,Never>?
    init(_ reply: String = goodSetupJSON,held: Bool = false,fail: Bool = false) { self.reply = reply;self.held = held;self.fail = fail }
    func run(_ command: ProcessCommand,onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        commands.append(command)
        if held { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        if fail { throw ProjectFailure.invalidProject }
        return .init(exitCode: 0,output: command.arguments.contains("-c") ? reply : command.executable.lastPathComponent+" version fixture",error: "",cancelled: false)
    }
    func waitStarted() async throws {
        let clock = ContinuousClock(),deadline = ContinuousClock.now + .seconds(3)
        while commands.isEmpty {
            guard clock.now < deadline else { throw WorkflowFailure.invalid("Fixture did not reach its tool probe.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() { held = false;gate?.resume();gate = nil }
    func cancel() { cancelled = true;release() }
}

private struct SetupFixture {
    let root: URL
    let projects: URL
    let engine: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Clauto Setup "+UUID().uuidString,isDirectory: true).resolvingSymlinksInPath()
        projects = root.appendingPathComponent("Project Drive/Clauto Projects")
        engine = root.appendingPathComponent("Installed Engine")
        for name in ["run",".venv/bin/python","scripts/timeline_derivatives.py","scripts/config.py","scripts/fcpxml.py","scripts/duration_bounds.py","scripts/graphic_scene_cue.py","scripts/offline_run.py","scripts/cli.py","scripts/tools/custom_font_studio.py","scripts/tools/trace.py","ENGINE_VERSION"] {
            let p = engine.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: p.deletingLastPathComponent(),withIntermediateDirectories: true)
            try Data("# synthetic fixture\n".utf8).write(to: p)
            if name == "run" || name.hasSuffix("/python") { try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath: p.path) }
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct WorkspaceSetupTests {
    @Test func prepareMissingFolderIsIdempotentAndPreservesExistingFiles() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let service = WorkspacePreparation()
        let first = try await service.prepare(f.projects)
        let original = f.projects.appendingPathComponent("original footage MOV")
        try Data("preserve originals".utf8).write(to: original)
        let second = try await service.prepare(f.projects)
        #expect(first.identity == second.identity)
        #expect(try Data(contentsOf: original) == Data("preserve originals".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.projects.path) == ["original footage MOV"])
    }
    @Test func missingDisconnectedVolumeIsNotCreated() async throws {
        let root = URL(fileURLWithPath: "/Volumes/Clauto-absent-"+UUID().uuidString+"/Projects")
        await #expect(throws: (any Error).self) { try await WorkspacePreparation().prepare(root) }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path))
    }
    @Test func canonicalRootAndFileComponentsAreRefused() async throws {
        await #expect(throws: (any Error).self) { try await WorkspacePreparation().prepare(URL(fileURLWithPath: "/")) }
        let f = try SetupFixture();defer { f.remove() }
        let file = f.root.appendingPathComponent("not a folder");try Data("unchanged".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await WorkspacePreparation().prepare(file.appendingPathComponent("Projects")) }
        #expect(try String(contentsOf: file,encoding: .utf8) == "unchanged")
    }
    @Test func noEngineStillOffersReviewAndNeverRunsInstallOrAccountCommands() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let runner = SetupRunnerFixture()
        let rows = try await SetupService(runner: runner,locate: { _ in nil }).check(engine: f.root.appendingPathComponent("missing"),projectsRoot: f.projects)
        #expect(rows.first { $0.id == "review" }?.state == .ready)
        #expect(rows.first { $0.id == "engine" }?.state == .needsAttention)
        #expect(rows.first { $0.id == "folders" }?.state == .needsAttention)
        #expect(rows.first { $0.id == "signin" }?.state == .notChecked)
        #expect(await runner.commands.isEmpty)
    }
    @Test func engineAndCapabilityChecksUseExactVenvAndBothVideoTools() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let prepared = try await WorkspacePreparation().prepare(f.projects)
        let runner = SetupRunnerFixture()
        let rows = try await SetupService(runner: runner,locate: { URL(fileURLWithPath: "/fixture/"+$0) }).check(engine: f.engine,projectsRoot: f.projects,prepared: prepared)
        for id in ["engine","exports","fonts","folders"] { #expect(rows.first { $0.id == id }?.state == .ready) }
        let commands = await runner.commands
        #expect(commands.count == 3)
        #expect(commands[0].executable == f.engine.appendingPathComponent(".venv/bin/python"))
        #expect(commands[0].arguments.prefix(3) == ["-I","-B","-c"])
        #expect(commands[0].environment["HF_HUB_OFFLINE"] == "1")
        #expect(commands.dropFirst().map(\.executable.lastPathComponent) == ["ffmpeg","ffprobe"])
    }
    @Test func existenceAloneAndOldPythonAreNotReady() async throws {
        let f = try SetupFixture();defer { f.remove() }
        for reply in ["",goodSetupJSON.replacingOccurrences(of: "[3,12,15]",with: "[3,11,9]"),setupJSON(brokenScript: SetupService.exportScripts[0]),#"{"version":[3,12,0],"syntax":true,"syntax":false,"modules":{}}"#] {
            let rows = try await SetupService(runner: SetupRunnerFixture(reply),locate: { _ in nil }).check(engine: f.engine,projectsRoot: f.projects)
            #expect(rows.first { $0.id == "engine" }?.state == .needsAttention)
            #expect(rows.first { $0.id == "exports" }?.state == .needsAttention)
        }
    }
    @Test func fontLibraryFailureDoesNotDisableOtherCapabilities() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let reply = goodSetupJSON.replacingOccurrences(of: #""brotli":true"#,with: #""brotli":false"#)
        let rows = try await SetupService(runner: SetupRunnerFixture(reply),locate: { URL(fileURLWithPath: "/fixture/"+$0) }).check(engine: f.engine,projectsRoot: f.projects)
        #expect(rows.first { $0.id == "fonts" }?.state == .needsAttention)
        #expect(rows.first { $0.id == "exports" }?.state == .ready)
    }
    @Test func failedExecutableStillRetainsPreparedFolderAndRetryPath() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let prepared = try await WorkspacePreparation().prepare(f.projects)
        let rows = try await SetupService(runner: SetupRunnerFixture(fail: true),locate: { URL(fileURLWithPath: "/fixture/"+$0) }).check(engine: f.engine,projectsRoot: f.projects,prepared: prepared)
        #expect(rows.first { $0.id == "folders" }?.state == .ready)
        #expect(rows.first { $0.id == "engine" }?.state == .needsAttention)
        #expect(rows.first { $0.id == "exports" }?.state == .needsAttention)
    }
    @Test func stalePreparedIdentityDoesNotBlessReplacementFolder() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let prepared = try await WorkspacePreparation().prepare(f.projects)
        try FileManager.default.moveItem(at: f.projects,to: f.projects.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: f.projects,withIntermediateDirectories: false)
        let rows = try await SetupService(runner: SetupRunnerFixture(),locate: { _ in nil }).check(engine: f.engine,projectsRoot: f.projects,prepared: prepared)
        #expect(rows.first { $0.id == "folders" }?.state == .needsAttention)
    }
    @Test @MainActor func folderChangeSuppressesLateCheckAndRetainsPhysicalSlot() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let runner = SetupRunnerFixture(held: true)
        let controller = WorkspaceSetupController(service: .init(runner: runner,locate: { _ in nil }))
        let first = Task { await controller.run(engine: f.engine,projects: f.projects,prepare: false) }
        try await runner.waitStarted();controller.invalidate()
        #expect(controller.busy)
        await controller.run(engine: f.engine,projects: f.root.appendingPathComponent("other"),prepare: true)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("other").path))
        await runner.release();await first.value
        #expect(!controller.busy && controller.checks.isEmpty && controller.prepared == nil)
    }
    @Test @MainActor func cancelJoinsAndPreventsFollowingToolChecks() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let runner = SetupRunnerFixture(held: true)
        let controller = WorkspaceSetupController(service: .init(runner: runner,locate: { URL(fileURLWithPath: "/fixture/"+$0) }))
        let first = Task { await controller.run(engine: f.engine,projects: f.projects,prepare: true) }
        try await runner.waitStarted()
        let stop = Task { await controller.stopAndWait() }
        while !controller.stopping { await Task.yield() };#expect(controller.busy)
        await runner.release();await stop.value;await first.value
        #expect(await runner.commands.count == 1)
        #expect(controller.checks.isEmpty && controller.prepared == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.projects.path).isEmpty)
    }
    @Test func replacingEngineDuringProbeRefusesItsReadiness() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let runner = SetupRunnerFixture(held: true)
        let operation = Task { try await SetupService(runner: runner,locate: { _ in nil }).check(engine: f.engine,projectsRoot: f.projects) }
        try await runner.waitStarted()
        try FileManager.default.moveItem(at: f.engine,to: f.engine.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: f.engine,withIntermediateDirectories: false)
        await runner.release()
        let rows = try await operation.value
        #expect(rows.first { $0.id == "engine" }?.state == .needsAttention)
        #expect(rows.first { $0.id == "fonts" }?.state == .needsAttention)
    }
    @Test func actualIsolatedPythonProbeReturnsStructuredLocalObservations() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let result = try await ProcessRunner().run(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I","-B","-c",SetupService.pythonProbe,f.engine.path],environment: ["HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1"],timeout: .seconds(20)))
        #expect(result.succeeded)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String:Any])
        #expect((object["syntax"] as? [String:Bool])?.values.allSatisfy { $0 } == true)
        #expect((object["version"] as? [Int])?.count == 3)
        #expect((object["modules"] as? [String:Bool])?.count == SetupService.fontModules.count)
        let names = try FileManager.default.subpathsOfDirectory(atPath: f.engine.path)
        #expect(!names.contains(where: { $0.contains("__pycache__") }))
    }
    @Test func cancelledPreparationCreatesNoFolder() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            try Task.checkCancellation()
            return try await WorkspacePreparation().prepare(f.projects)
        }
        task.cancel();gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: f.projects.path))
    }

    @Test func absentOrBrokenFontScriptDoesNotChangeExportReadiness() async throws {
        for missing in [false,true] {
            let f = try SetupFixture();defer { f.remove() }
            let font = f.engine.appendingPathComponent(SetupService.fontScript)
            if missing { try FileManager.default.removeItem(at: font) }
            else { try Data("this is invalid Python [".utf8).write(to: font) }
            let rows = try await SetupService(runner: SetupRunnerFixture(setupJSON(brokenScript: SetupService.fontScript)),locate: { URL(fileURLWithPath: "/fixture/"+$0) }).check(engine: f.engine,projectsRoot: f.projects)
            #expect(rows.first { $0.id == "exports" }?.state == .ready)
            #expect(rows.first { $0.id == "fonts" }?.state == .needsAttention)
        }
    }
    @Test func changedScriptInsideSameEngineInvalidatesOnlyItsCapability() async throws {
        for name in [SetupService.exportScripts[0],SetupService.fontScript,"scripts/tools/trace.py","ENGINE_VERSION",".venv/bin/python"] {
            let f = try SetupFixture();defer { f.remove() }
            let runner = SetupRunnerFixture(held: true)
            let task = Task { try await SetupService(runner: runner,locate: { URL(fileURLWithPath: "/fixture/"+$0) }).check(engine: f.engine,projectsRoot: f.projects) }
            try await runner.waitStarted()
            try Data("# changed after probe started\n".utf8).write(to: f.engine.appendingPathComponent(name))
            await runner.release()
            let rows = try await task.value
            #expect(rows.first { $0.id == ((SetupService.fontScripts+["ENGINE_VERSION"]).contains(name) ? "fonts" : "exports") }?.state == .needsAttention)
            if (SetupService.fontScripts+["ENGINE_VERSION"]).contains(name) { #expect(rows.first { $0.id == "exports" }?.state == .ready) }
        }
    }
    @Test @MainActor func exitPauseRejectsSetupUntilKeepEditingResumes() async throws {
        let f = try SetupFixture();defer { f.remove() }
        let runner = SetupRunnerFixture()
        let controller = WorkspaceSetupController(service: .init(runner: runner,locate: { _ in nil }))
        let saveGate = AsyncStream<Void>.makeStream()
        defer { saveGate.continuation.finish() }
        let exit = Task {
            await controller.pauseForExit()
            for await _ in saveGate.stream { break }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !controller.pausedForExit {
            guard ContinuousClock.now < deadline else { throw ProjectFailure.invalidProject }
            await Task.yield()
        }
        // A later unrelated save remains held after setup's own task joined.
        await controller.run(engine: f.engine,projects: f.projects,prepare: true)
        #expect(!FileManager.default.fileExists(atPath: f.projects.path))
        #expect(await runner.commands.isEmpty)
        saveGate.continuation.finish();await exit.value
        controller.resumeAfterCancelledExit()
        await controller.run(engine: f.engine,projects: f.projects,prepare: true)
        #expect(controller.checks.first { $0.id == "folders" }?.state == .ready)
    }

    @Test func fontBuildRequiresItsHelperAndNonemptyBoundedVersion() async throws {
        for fault in ["missing helper","broken helper","symlink helper","missing version","empty version","oversize version"] {
            let f = try SetupFixture();defer { f.remove() }
            let helper = f.engine.appendingPathComponent("scripts/tools/trace.py"),version = f.engine.appendingPathComponent("ENGINE_VERSION")
            switch fault {
            case "missing helper": try FileManager.default.removeItem(at: helper)
            case "broken helper": try Data("invalid [ python".utf8).write(to: helper)
            case "symlink helper":
                let target = f.engine.appendingPathComponent("trace-target.py")
                try FileManager.default.moveItem(at: helper,to: target)
                try FileManager.default.createSymbolicLink(at: helper,withDestinationURL: target)
            case "missing version": try FileManager.default.removeItem(at: version)
            case "empty version": try Data(" \n".utf8).write(to: version)
            default: try Data(repeating: 0x61,count: 1025).write(to: version)
            }
            let reply = setupJSON(brokenScript: ["missing helper","broken helper"].contains(fault) ? "scripts/tools/trace.py" : nil)
            let rows = try await SetupService(runner: SetupRunnerFixture(reply),locate: { URL(fileURLWithPath: "/fixture/"+$0) }).check(engine: f.engine,projectsRoot: f.projects)
            #expect(rows.first { $0.id == "fonts" }?.state == .needsAttention)
            #expect(rows.first { $0.id == "exports" }?.state == .ready)
        }
    }

}
