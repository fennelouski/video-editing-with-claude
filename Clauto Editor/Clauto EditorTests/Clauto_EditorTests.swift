import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor Lines {
    var values: [ProcessLine] = []
    func append(_ line: ProcessLine) { values.append(line) }
}

struct ProcessRunnerTests {
    @Test func finderEnvironmentAndLiteralArguments() async throws {
        let environment = ProcessRunner.environment(overrides: ["CLAUTO_PATHS": "/NAS folder/paths.json"])
        #expect(environment["PATH"]!.hasPrefix("/opt/homebrew/bin:"))
        #expect(environment["CLAUTO_PATHS"] == "/NAS folder/paths.json")
        #expect(environment["PYTHONDONTWRITEBYTECODE"] == "1")
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "$(touch /tmp/clauto-should-never-exist); footage : pizza.MOV"]))
        #expect(result.succeeded)
        #expect(result.output == "$(touch /tmp/clauto-should-never-exist); footage : pizza.MOV")
    }

    @Test func drainsBothPipesAndBoundsOutput() async throws {
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; sys.stdout.write('x'*350000); sys.stderr.write('y'*350000)"]))
        #expect(result.succeeded)
        #expect(result.output.count == 262_144)
        #expect(result.error.count == 262_144)
    }

    @Test func streamsCompleteUnicodeLines() async throws {
        let lines = Lines()
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s\n", "pizza 🍕", "done"]), onLine: { await lines.append($0) })
        #expect(result.succeeded)
        #expect(await lines.values.map(\.text) == ["pizza 🍕", "done"])
    }

    @Test func streamedLineTruncationIsReportedWithoutContaminatingTheFollowingLine() async throws {
        let lines = Lines()
        let result = try await ProcessRunner().run(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c","import sys,time; sys.stdout.write('x'*350000); sys.stdout.flush(); time.sleep(0.05); sys.stdout.write('\\ncomplete 🥖\\n')"]),onLine: { await lines.append($0) })
        let received = await lines.values
        #expect(result.succeeded && received.count == 2)
        #expect(received.first?.truncated == true && received.last?.truncated == false)
        #expect(received.last?.text == "complete 🥖")
    }

    @Test func timeoutCancelsWithoutHanging() async throws {
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], timeout: .milliseconds(100)))
        #expect(result.cancelled)
        #expect(!result.succeeded)
    }

    @Test func missingExecutableCanBeRetried() async throws {
        let runner = ProcessRunner()
        await #expect(throws: (any Error).self) {
            try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/no-clauto-executable")))
        }
        #expect(try await runner.run(ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/true"))).succeeded)
    }

    @Test func realFFmpegFromExplicitPATH() async throws {
        guard let ffmpeg = ProcessRunner.executable("ffmpeg") else { Issue.record("ffmpeg required for local M0 acceptance"); return }
        let result = try await ProcessRunner().run(ProcessCommand(executable: ffmpeg, arguments: ["-version"]))
        #expect(result.succeeded)
        #expect(result.output.contains("ffmpeg version"))
    }
}

struct ProjectRepositoryTests {
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func mixedIntakePreservesOriginalsAndRoundTrips() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository()
        var project = try await repo.create(name: "Pizza test", root: root.appendingPathComponent("projects"), engine: root.appendingPathComponent("engine"))
        var urls: [URL] = []
        for filename in ["clip.MOV", "voice.WAV", "image.JPEG", "script.md", "comments.docx"] {
            let file = root.appendingPathComponent(filename)
            try Data("synthetic \(filename)".utf8).write(to: file); urls.append(file)
        }
        project = try await repo.add(urls, to: project)
        #expect(project.manifest.files.map(\.group) == [.footage, .audio, .graphics, .scripts, .scripts])
        for file in project.manifest.files {
            let reference = project.folder.appendingPathComponent(file.relativePath)
            #expect(try Data(contentsOf: reference) == Data(contentsOf: URL(fileURLWithPath: file.originalPath)))
            let linked = try reference.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            #expect(linked == !file.copied)
        }
        var brief = Brief(); brief.about = "Synthetic pizza"; brief.music = "Quiet intro and outro, with fades"
        project = try await repo.saveBrief(brief, project: project)
        let reopened = try await repo.open(project.folder)
        #expect(reopened.manifest.files.count == 5)
        #expect(reopened.brief == brief)
        let audio = try #require(project.manifest.files.first { $0.group == .audio })
        project = try await repo.assign(.music, to: audio, project: project)
        #expect(project.manifest.files.first { $0.id == audio.id }?.group == .music)
        let media = project.manifest.files[0]
        project = try await repo.remove(media, from: project)
        #expect(FileManager.default.fileExists(atPath: media.originalPath))
        #expect(project.manifest.files.count == 4)
    }

    @Test func failedBatchRollsBackOnlyNewReferences() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository()
        let project = try await repo.create(name: "Rollback", root: root, engine: root)
        let source = root.appendingPathComponent("clip.mov"); try Data("original".utf8).write(to: source)
        await #expect(throws: (any Error).self) { try await repo.add([source, root.appendingPathComponent("missing.mov")], to: project) }
        #expect(try await repo.open(project.folder).manifest.files.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.folder.appendingPathComponent("footage/a-cam").path).isEmpty)
        #expect(try Data(contentsOf: source) == Data("original".utf8))
    }

    @Test func staleBriefSnapshotDoesNotLoseAddedFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository()
        let stale = try await repo.create(name: "Race", root: root, engine: root)
        let file = root.appendingPathComponent("new.mov"); try Data("original".utf8).write(to: file)
        _ = try await repo.add([file], to: stale)
        var brief = Brief(); brief.about = "Changed while adding media"
        _ = try await repo.saveBrief(brief, project: stale)
        #expect(try await repo.open(stale.folder).manifest.files.count == 1)
    }

    @Test func duplicateNamesDoNotOverwriteProjectsAndMissingNASIsRefused() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository()
        let one = try await repo.create(name: "Pizza", root: root, engine: root)
        let two = try await repo.create(name: "Pizza", root: root, engine: root)
        #expect(one.folder != two.folder)
        await #expect(throws: ProjectFailure.self) { try await repo.create(name: "../escape", root: root, engine: root) }
        await #expect(throws: ProjectFailure.self) { try await repo.create(name: "Pizza", root: URL(fileURLWithPath: "/Volumes/Clauto-Missing-Test-Drive/projects"), engine: root) }
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/Clauto-Missing-Test-Drive"))
    }

    @Test func tamperedReferenceCannotDeleteOutsideProject() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository()
        let project = try await repo.create(name: "Safety", root: root, engine: root)
        let file = ProjectFile(name: "outside.mov", group: .footage, relativePath: "footage/../../outside.mov", originalPath: root.path, copied: false, needsRole: false)
        await #expect(throws: ProjectFailure.self) { try await repo.remove(file, from: project) }
    }

    @Test func folderIntakePreferencesAndEditedScriptRemoval() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = ProjectRepository()
        var project = try await repo.create(name: "Folders", root: root.appendingPathComponent("projects"), engine: root)
        let sourceFolder = root.appendingPathComponent("camera folder")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: sourceFolder.appendingPathComponent("MVI_0001.MOV"))
        try Data("script".utf8).write(to: sourceFolder.appendingPathComponent("notes.md"))
        try Data("never execute".utf8).write(to: sourceFolder.appendingPathComponent("install.command"))
        project = try await repo.add([sourceFolder], to: project)
        #expect(project.manifest.files.count == 2)
        project = try await repo.preferences(aspect: "9:16", model: "small", project: project)
        let reopened = try await repo.open(project.folder)
        #expect(reopened.manifest.aspect == "9:16")
        #expect(reopened.manifest.whisperModel == "small")
        let script = try #require(project.manifest.files.first { $0.group == .scripts })
        let edited = Data("my edited script".utf8)
        try edited.write(to: project.folder.appendingPathComponent(script.relativePath))
        _ = try await repo.remove(script, from: project)
        let preserved = try FileManager.default.contentsOfDirectory(at: project.folder.appendingPathComponent("removed-files"), includingPropertiesForKeys: nil)
        #expect(preserved.count == 1)
        #expect(try Data(contentsOf: preserved[0]) == edited)
        #expect(try Data(contentsOf: sourceFolder.appendingPathComponent("notes.md")) == Data("script".utf8))
    }
}

struct ParserTests {
    @Test func progressParserRejectsUnknownStates() throws {
        let decoder = JSONDecoder()
        let good = Data(#"{"stage":4,"state":"fail","detail":"Drop a scanned texture."}"#.utf8)
        #expect(try decoder.decode(StageEvent.self, from: good).state == .fail)
        let bad = Data(#"{"stage":4,"state":"looks-good","detail":"unknown"}"#.utf8)
        #expect(throws: (any Error).self) { try decoder.decode(StageEvent.self, from: bad) }
    }
    @Test func fileTypesCaseFoldAndDoNotExecuteUnknownFiles() {
        #expect(FileGroup.classify(URL(fileURLWithPath: "Clip.MOV")) == .footage)
        #expect(FileGroup.classify(URL(fileURLWithPath: "notes.DOCX")) == .scripts)
        #expect(FileGroup.classify(URL(fileURLWithPath: "run.command")) == .other)
    }
}
