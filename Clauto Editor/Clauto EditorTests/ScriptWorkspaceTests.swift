import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct ScriptWorkspaceTests {
    private struct Fixture {
        let root: URL
        let project: Project
        let catalog: TranscriptCatalog
        let review: TranscriptReviewSession
        let preserve: Bool
        func cleanup() { if !preserve { try? FileManager.default.removeItem(at: root) } }
    }
    private func fixture(acceptance: Bool = false, missing: Bool = false, video: Bool = false) async throws -> Fixture {
        let evidence = acceptance ? ProcessInfo.processInfo.environment["CLAUTO_SCRIPT_ACCEPTANCE_ROOT"] : nil
        let root = evidence.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("clauto-script-\(UUID())")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"), withIntermediateDirectories: true)
        var project = try await ProjectRepository().create(name: "Synthetic Script QA", root: root, engine: engine)
        var sources: [TranscriptSource] = [], rows: [TranscriptRow] = []
        for id in ["a", "b"] {
            let url = root.appendingPathComponent(id + (video ? ".mov" : ".wav"))
            let samples = 144_000
            var wave = Data()
            func text(_ s: String) { wave.append(Data(s.utf8)) }
            func u16(_ n: Int) { var v = UInt16(n).littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
            func u32(_ n: Int) { var v = UInt32(n).littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
            text("RIFF"); u32(36 + samples * 2); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16); text("data"); u32(samples * 2)
            wave.append(Data(repeating: id == "a" ? 0 : 1, count: samples * 2))
            if video {
                let result = try await ProcessRunner().run(.init(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), arguments: ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=320x180:r=24000/1001", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "3.003", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-shortest", url.path], timeout: .seconds(20)))
                guard result.succeeded else { throw WorkflowFailure.invalid(result.error) }
            } else { try wave.write(to: url) }
            let words: [TranscriptWord] = id == "a" ? [.init(word: "Early.", start: 0.25, end: 0.5), .init(word: "Later.", start: 1.75, end: 2)] : [.init(word: "Middle.", start: 1, end: 1.25)]
            let snapshot = root.appendingPathComponent(id + ".words.json"), bytes = try JSONEncoder().encode(["words": words])
            try bytes.write(to: snapshot)
            let source = TranscriptSource(id: id, path: url.path, sourceSHA256: TranscriptSourceMap.sha(try Data(contentsOf: url)), transcriptSHA256: TranscriptSourceMap.sha(bytes), duration: 3, words: words, originalTranscriptPath: snapshot.path)
            sources.append(source)
            let relative = "footage/audio/" + url.lastPathComponent
            try FileManager.default.createSymbolicLink(at: project.folder.appendingPathComponent(relative), withDestinationURL: url)
            project.manifest.files.append(.init(name: url.lastPathComponent, group: .audio, relativePath: relative, originalPath: url.path, copied: false, needsRole: false))
            for (index, word) in words.enumerated() {
                rows.append(.init(id: id + String(format: "-w%05d-%05d-", index, index) + source.sourceSHA256.prefix(8), sourceID: id, sourceSHA256: source.sourceSHA256, firstWord: index, lastWord: index, start: word.start, end: word.end,
                    inTimecode: ReviewTimecode.label(frame: Int(word.start * 24000 / 1001)), outTimecode: ReviewTimecode.label(frame: Int(word.end * 24000 / 1001)), text: word.word,
                    keep: index == 0, notes: "", requestedGraphics: "", assistantGraphics: "", handwrittenAsset: "", section: "Synthetic recording", uncertainty: "Synthetic ASR; no real dialogue", originalOrder: rows.count + 1))
            }
        }
        if missing { project.manifest.files.append(.init(name: "Untranscribed B-roll.mov", group: .footage, relativePath: "footage/a-cam/missing.mov", originalPath: root.appendingPathComponent("missing.mov").path, copied: false, needsRole: false)) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project.manifest).write(to: project.folder.appendingPathComponent("clauto-project.json"), options: .atomic)
        let catalog = TranscriptCatalog(schemaVersion: 1, title: "Synthetic all-source catalog", datasetSHA256: String(repeating: "e", count: 64), sources: sources, rows: rows)
        let input = root.appendingPathComponent("catalog.json"); try JSONEncoder().encode(catalog).write(to: input)
        let review = try await TranscriptReviewRepository().importCatalog(input, project: project)
        return .init(root: root, project: project, catalog: catalog, review: review, preserve: evidence != nil)
    }
    private var author: ScriptProvenance { .init(author: "PRIVATE_AUTHOR_SENTINEL", model: "PRIVATE_MODEL_SENTINEL", origin: "Actual local test fixture") }
    private func state(_ fixture: Fixture, complete: Bool = true) throws -> ScriptWorkspaceState {
        var state = ScriptWorkspaceState(projectID: fixture.project.id, catalogSHA256: fixture.review.state.catalogSHA256, inventorySHA256: try ScriptSourceInventory.sha(fixture.project))
        if complete { state.reviewedRowIDs = Set(fixture.catalog.rows.map(\.id)) }
        return state
    }
    private func script(_ fixture: Fixture, reverse: Bool = false) -> ScriptVersion {
        let rows = reverse ? Array(fixture.catalog.rows.reversed()) : fixture.catalog.rows
        return .init(title: reverse ? "PRIVATE_REVERSED_TITLE" : "PRIVATE_TITLE", provenance: author, beats: rows.map { .init(kind: .passage, rowID: $0.id, heading: "Recorded explanation") })
    }
    private func reviewAll(_ repository: ScriptWorkspaceRepository, _ initial: ScriptWorkspaceSession) async throws -> ScriptWorkspaceSession {
        var session = initial
        for row in initial.catalog.rows { session = try await repository.update(project: initial.project, expectedRevision: session.state.revisionID, action: .reviewed(row.id, true)) }
        return session
    }

    @Test func fullSourceGateIncludesExcludedSpeechAndUncatalogedMedia() async throws {
        let f = try await fixture(missing: true); defer { f.cleanup() }
        var session = ScriptWorkspaceSession(project: f.project, catalog: f.catalog, state: try state(f, complete: false))
        #expect(f.review.keptCount < f.catalog.rows.count)
        #expect(throws: WorkflowFailure.self) { try ScriptWorkspaceAction.create("Test", author).apply(to: &session) }
        for row in f.catalog.rows { try ScriptWorkspaceAction.reviewed(row.id, true).apply(to: &session) }
        #expect(!session.coverageComplete)
        #expect(throws: WorkflowFailure.self) { try ScriptWorkspaceAction.create("Test", author).apply(to: &session) }
        try ScriptWorkspaceAction.disposition(session.missingSources[0].id, "Reviewed B-roll; no relevant speech").apply(to: &session)
        #expect(session.coverageComplete)
        try ScriptWorkspaceAction.create("Test", author).apply(to: &session)
        #expect(session.state.versions.count == 1)
    }

    @Test func blindProjectionHasNoAttributionAndRevealAndEditsWaitForScoreLock() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        var state = try state(f); state.versions = [script(f), script(f, reverse: true)]
        try state.startComparison(state.versions.map(\.id))
        let mapping = state.comparison!.entries
        let options = try state.blindOptions(catalog: f.catalog)
        let rendered = String(reflecting: options)
        #expect(!rendered.contains("PRIVATE_AUTHOR_SENTINEL")); #expect(!rendered.contains("PRIVATE_MODEL_SENTINEL")); #expect(!rendered.contains("PRIVATE_TITLE"))
        #expect(Set(options.map(\.label)) == ["Option 1", "Option 2"])
        #expect(throws: WorkflowFailure.self) { try state.revealAuthors() }
        #expect(throws: WorkflowFailure.self) { try state.lockScores() }
        #expect(throws: WorkflowFailure.self) { try state.editVersion(state.versions[0].id) { $0.title = "Changed" } }
        for entry in mapping { try state.score(entry.id, score: .init(clarity: 4, story: 3, coverage: 5)) }
        try state.lockScores(); try state.revealAuthors()
        #expect(state.comparison?.entries.map(\.versionID) == mapping.map(\.versionID))
        #expect(state.comparison?.authorsRevealed == true)
        #expect(throws: WorkflowFailure.self) { try state.score(mapping[0].id, score: .init(clarity: 1, story: 1, coverage: 1)) }
        #expect(state.comparison?.entries.first?.score.clarity == 4)
    }

    @Test func versionEditsAndSourceReviewInvalidateApprovalAndOldScores() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        var session = ScriptWorkspaceSession(project: f.project, catalog: f.catalog, state: try state(f))
        session.state.versions = [script(f), script(f, reverse: true)]
        let id = session.state.versions[0].id, other = session.state.versions[1]
        #expect(throws: WorkflowFailure.self) { try session.state.approve(id, catalog: f.catalog, missing: [], factsReviewed: true) }
        try session.state.startComparison(session.state.versions.map(\.id))
        for entry in session.state.comparison!.entries { try session.state.score(entry.id, score: .init(clarity: 5, story: 4, coverage: 4)) }
        try session.state.lockScores()
        try session.state.approve(id, catalog: f.catalog, missing: [], factsReviewed: true)
        #expect(session.state.approvalCurrent(session.state.versions[0]))
        try ScriptWorkspaceAction.move(id, session.state.versions[0].beats[0].id, 1).apply(to: &session)
        #expect(session.state.versions[0].approval == nil); #expect(!session.state.comparisonCurrent())
        #expect(session.state.versions[1] == other)
        #expect(throws: WorkflowFailure.self) { try session.state.approve(id, catalog: f.catalog, missing: [], factsReviewed: true) }
        try ScriptWorkspaceAction.reviewed(f.catalog.rows[0].id, false).apply(to: &session)
        #expect(!session.coverageComplete)
    }

    @Test func importRefusesInventedSpeechAndRetainsRealProvenanceAndPickups() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let original = script(f)
        let data = try ScriptInterchange.exportVersion(original, catalog: f.catalog)
        var imported = try ScriptInterchange.importVersion(data, catalog: f.catalog, provenance: author)
        #expect(imported.beats.map(\.rowID) == original.beats.map(\.rowID))
        #expect(imported.provenance.importedSHA256 == TranscriptSourceMap.sha(data)); #expect(!imported.provenance.identityVerified)
        #expect(imported.importedArtifact == data)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var sections = object["sections"] as! [[String: Any]], segments = sections[0]["segments"] as! [[String: Any]]
        segments[0]["spoken_text"] = "Invented replacement speech"; sections[0]["segments"] = segments; object["sections"] = sections
        #expect(throws: WorkflowFailure.self) { try ScriptInterchange.importVersion(JSONSerialization.data(withJSONObject: object), catalog: f.catalog, provenance: author) }
        imported.beats.append(.init(kind: .pickup, heading: "Missing step", unrecordedText: "Record the next step."))
        let roundtrip = try ScriptInterchange.importVersion(ScriptInterchange.exportVersion(imported, catalog: f.catalog), catalog: f.catalog, provenance: author)
        #expect(roundtrip.beats.last?.kind == .pickup); #expect(roundtrip.beats.last?.rowID == nil)
    }

    @Test func repositoryPersistsIndependentVersionsRejectsStaleWindowsAndAliases() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let repository = ScriptWorkspaceRepository()
        var session = try #require(try await repository.load(project: f.project))
        let stale = session.state.revisionID
        session = try await reviewAll(repository, session)
        await #expect(throws: WorkflowFailure.self) { try await repository.update(project: f.project, expectedRevision: stale, action: .create("Stale", author)) }
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .create("Original", author))
        let id = session.state.versions[0].id
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPassage(id, f.catalog.rows[0].id))
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .duplicate(id, "Alternative"))
        let copyID = session.state.versions[1].id
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPickup(copyID, "Explicit unrecorded line"))
        let reopened = try #require(try await ScriptWorkspaceRepository().load(project: f.project))
        #expect(reopened.state.versions[0].beats.count == 1); #expect(reopened.state.versions[1].beats.count == 2)
        #expect(reopened.state.versions[1].basedOnVersionID == id)
        let pointer = f.project.folder.appendingPathComponent(".clauto/script-workspace.json")
        try FileManager.default.removeItem(at: pointer)
        await #expect(throws: WorkflowFailure.self) { try await repository.load(project: f.project) }
        let target = f.root.appendingPathComponent("unrelated.json"); let sentinel = Data("unrelated sentinel".utf8); try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await repository.load(project: f.project) }
        #expect(try Data(contentsOf: target) == sentinel)
    }

    @Test func newMediaInvalidatesCoverageAndApprovals() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let repository = ScriptWorkspaceRepository(); var session = try #require(try await repository.load(project: f.project))
        session = try await reviewAll(repository, session)
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .create("One", author))
        let id = session.state.versions[0].id
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPassage(id, f.catalog.rows[0].id))
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .approve(id, true))
        #expect(session.state.approvalCurrent(session.state.versions[0]))
        var manifest = f.project.manifest
        manifest.files.append(.init(name: "New clip", group: .footage, relativePath: "footage/a-cam/new.mov", originalPath: f.root.appendingPathComponent("new.mov").path, copied: false, needsRole: false))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: f.project.folder.appendingPathComponent("clauto-project.json"), options: .atomic)
        let changed = try #require(try await repository.load(project: f.project))
        #expect(changed.state.versions[0].approval == nil); #expect(changed.state.reviewedRowIDs.isEmpty); #expect(!changed.coverageComplete)
        await #expect(throws: WorkflowFailure.self) { try await repository.assemble(project: f.project, expectedRevision: changed.state.revisionID, versionID: id) }
    }

    @Test func approvalPickupsAndChangedSourceBytesGateAssembly() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let repository = ScriptWorkspaceRepository(); var session = try #require(try await repository.load(project: f.project))
        session = try await reviewAll(repository, session)
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .create("One", author))
        let id = session.state.versions[0].id
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPassage(id, f.catalog.rows[0].id))
        await #expect(throws: WorkflowFailure.self) { try await repository.assemble(project: f.project, expectedRevision: session.state.revisionID, versionID: id) }
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPickup(id, "Unrecorded"))
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .approve(id, true))
        await #expect(throws: WorkflowFailure.self) { try await repository.assemble(project: f.project, expectedRevision: session.state.revisionID, versionID: id) }
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .remove(id, session.state.versions[0].beats.last!.id))
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .approve(id, true))
        // Even an unused source changed since all-source review.
        try Data("changed source".utf8).write(to: URL(fileURLWithPath: f.catalog.sources[1].path))
        await #expect(throws: WorkflowFailure.self) { try await repository.assemble(project: f.project, expectedRevision: session.state.revisionID, versionID: id) }
    }

    @Test func completeABAHandoffIsSeparateVerifiedFrameAccurateAndReloadable() async throws {
        let f = try await fixture(acceptance: true); defer { f.cleanup() }
        let repository = ScriptWorkspaceRepository(); var session = try #require(try await repository.load(project: f.project))
        let manifestBefore = try Data(contentsOf: f.project.folder.appendingPathComponent("clauto-project.json"))
        let cutSentinel = Data("existing current cut sentinel".utf8)
        try cutSentinel.write(to: f.project.folder.appendingPathComponent("cuts/current.json"))
        session = try await reviewAll(repository, session)
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .create("Source-linked A B A", author))
        let id = session.state.versions[0].id
        for i in [0, 2, 1] { session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPassage(id, f.catalog.rows[i].id)) }
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .approve(id, true))
        let output = try await repository.assemble(project: f.project, expectedRevision: session.state.revisionID, versionID: id)
        let handoff = try CreativeAssetFiles.decode(Data(contentsOf: output.appendingPathComponent("script-handoff.json")), as: ScriptTimelineHandoff.self)
        #expect(handoff.spans.map(\.sourceID) == ["a", "b", "a"])
        #expect(handoff.frameDurationNumerator == 1001 && handoff.frameDurationDenominator == 24000)
        #expect(handoff.spans.map(\.startFrame) == [5, 23, 41]); #expect(handoff.spans.map(\.endFrame) == [12, 30, 48])
        #expect(handoff.spans.map(\.timelineFrame) == [0, 7, 14])
        #expect(handoff.reviewOnly && !handoff.appliedToCut && !handoff.productionAuthorized)
        #expect(try Data(contentsOf: f.project.folder.appendingPathComponent("cuts/current.json")) == cutSentinel)
        #expect(try Data(contentsOf: f.project.folder.appendingPathComponent("clauto-project.json")) == manifestBefore)
        let original = try #require(try await TranscriptReviewRepository().load(project: f.project))
        #expect(original.state.revisionID == f.review.state.revisionID)
        let writer = try await repository.exportWriterPacket(project: f.project, expectedRevision: session.state.revisionID)
        #expect(FileManager.default.fileExists(atPath: writer.appendingPathComponent("transcript-catalog.json").path))
        #expect(throws: WorkflowFailure.self) { try TranscriptProductionGate.requireLegacyPipelineAllowed(project: f.project) }
        if f.preserve {
            try Data(output.path.utf8).write(to: f.root.appendingPathComponent("handoff-path.txt"))
            try Data(f.project.folder.path.utf8).write(to: f.root.appendingPathComponent("project-path.txt"))
            // Leave two real independent fixture versions ready for UI review.
            session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .duplicate(id, "Alternative order"))
            let alternative = session.state.versions[1].id
            session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .move(alternative, session.state.versions[1].beats[0].id, 1))
        }
    }

    @Test func pictureAssemblyUsesActualSourceDimensionsRateAndMonoAudio() async throws {
        let f = try await fixture(video: true); defer { f.cleanup() }
        let repository = ScriptWorkspaceRepository(); var session = try #require(try await repository.load(project: f.project))
        session = try await reviewAll(repository, session)
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .create("Picture assembly", author))
        let id = session.state.versions[0].id
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPassage(id, f.catalog.rows[0].id))
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .approve(id, true))
        let output = try await repository.assemble(project: f.project, expectedRevision: session.state.revisionID, versionID: id)
        let xml = try String(contentsOf: output.appendingPathComponent("assembly.fcpxml"), encoding: .utf8)
        #expect(xml.contains("width=\"320\" height=\"180\"")); #expect(xml.contains("frameDuration=\"1001/24000s\""))
        #expect(xml.contains("audioChannels=\"1\"")); #expect(xml.contains("hasVideo=\"1\" format=\"sourceFormat1\""))
    }

    @Test func assemblyHistorySharesProjectWithExternalLibrary3DAndHandwritingTools() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let library = f.root.appendingPathComponent("external-library"), font = library.appendingPathComponent("fonts/external.ttf")
        try FileManager.default.createDirectory(at: font.deletingLastPathComponent(), withIntermediateDirectories: true)
        let assetBytes = Data("external asset reference fixture; never rendered".utf8); try assetBytes.write(to: font)
        let project = try await ProjectRepository().useFolder(library, key: "assets", project: f.project)
        let graphics = GraphicStudioRepository(), fonts = FontStudioRepository(), sceneID = UUID(), fontID = UUID()
        let scene = try await graphics.create(project, id: sceneID, label: "Existing 3D scene", scene: .preset(.object))
        let handwriting = try await fonts.create(project, id: fontID, label: "Existing handwriting workspace")
        let manifestBefore = try Data(contentsOf: project.folder.appendingPathComponent("clauto-project.json"))
        let pathsBefore = try Data(contentsOf: project.folder.appendingPathComponent("paths.json"))
        let currentBefore = Data("existing cut stays current".utf8); try currentBefore.write(to: project.folder.appendingPathComponent("cuts/current.json"))
        let repository = ScriptWorkspaceRepository(); var session = try #require(try await repository.load(project: project))
        session = try await reviewAll(repository, session)
        session = try await repository.update(project: project, expectedRevision: session.state.revisionID, action: .create("Integrated assembly", author))
        let versionID = session.state.versions[0].id
        session = try await repository.update(project: project, expectedRevision: session.state.revisionID, action: .addPassage(versionID, f.catalog.rows[0].id))
        session = try await repository.update(project: project, expectedRevision: session.state.revisionID, action: .approve(versionID, true))
        let output = try await repository.assemble(project: project, expectedRevision: session.state.revisionID, versionID: versionID)
        let history = try await ScriptWorkspaceRepository().assemblies(project: project), entry = try #require(history.first)
        #expect(history.count == 1 && entry.record.projectID == project.id && entry.readyForReview)
        #expect(entry.record.versionID == versionID && project.folder.appendingPathComponent(entry.record.relativeFolder) == output)
        #expect(try await graphics.load(project, id: sceneID) == scene)
        #expect(try await fonts.load(project, id: fontID) == handwriting)
        #expect(try Data(contentsOf: project.folder.appendingPathComponent("clauto-project.json")) == manifestBefore)
        #expect(try Data(contentsOf: project.folder.appendingPathComponent("paths.json")) == pathsBefore)
        #expect(try Data(contentsOf: project.folder.appendingPathComponent("cuts/current.json")) == currentBefore)
        let reference = try #require(project.manifest.files.first { $0.name == font.lastPathComponent })
        #expect(!reference.copied)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: project.folder.appendingPathComponent(reference.relativePath).path) == font.path)
        #expect(try Data(contentsOf: font) == assetBytes)
    }

    @Test func assemblyHistoryRetainsEarlierRevisionAndRefusesTamperedTimeline() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let repository = ScriptWorkspaceRepository(); var session = try #require(try await repository.load(project: f.project))
        session = try await reviewAll(repository, session)
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .create("First assembly", author))
        let id = session.state.versions[0].id
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .addPassage(id, f.catalog.rows[0].id))
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .approve(id, true))
        let first = try await repository.assemble(project: f.project, expectedRevision: session.state.revisionID, versionID: id)
        let xml = try Data(contentsOf: first.appendingPathComponent("assembly.fcpxml"))
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .rename(id, "Revised assembly"))
        let historical = try await repository.assemblies(project: f.project)
        #expect(historical.count == 1 && !historical[0].scriptApprovalCurrent)
        session = try await repository.update(project: f.project, expectedRevision: session.state.revisionID, action: .approve(id, true))
        _ = try await repository.assemble(project: f.project, expectedRevision: session.state.revisionID, versionID: id)
        let history = try await repository.assemblies(project: f.project)
        #expect(history.count == 2 && !history[0].readyForReview && history[1].readyForReview)
        #expect(try Data(contentsOf: first.appendingPathComponent("assembly.fcpxml")) == xml)
        try (xml + Data("\n".utf8)).write(to: first.appendingPathComponent("assembly.fcpxml"))
        await #expect(throws: WorkflowFailure.self) { try await repository.assemblies(project: f.project) }
    }

    @Test @MainActor func scriptAndCutShareOneProjectControllerWithoutCrossRootRetargeting() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let registry = ScriptWorkspaceRegistry(), script = registry.controller(for: f.project)
        let reopened = try await ProjectRepository().open(f.project.folder)
        let cut = registry.controller(for: reopened)
        #expect(script === cut)
        await script.load()
        #expect(cut.session?.state.id == script.session?.state.id)
        var copy = f.project; copy.folder = f.root.appendingPathComponent("another-project-copy")
        #expect(registry.controller(for: copy) !== script)
    }

    @Test @MainActor func damagedHistoryDoesNotReportASavedScriptActionAsFailed() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let repository = ScriptWorkspaceRepository(), initial = try #require(try await repository.load(project: f.project))
        _ = try await reviewAll(repository, initial)
        let index = f.project.folder.appendingPathComponent(".clauto/script-assembly-history.json")
        let damaged = Data("damaged local history index".utf8); try damaged.write(to: index)
        let controller = ScriptWorkspaceController(project: f.project, repository: repository)
        await controller.load()
        #expect(controller.failure == nil && controller.assemblyFailure != nil)
        #expect(await controller.perform(.create("Saved exactly once", author)))
        #expect(controller.failure == nil && controller.assemblyFailure != nil)
        let saved = try #require(try await repository.load(project: f.project))
        #expect(saved.state.versions.count == 1 && saved.state.versions[0].title == "Saved exactly once")
        #expect(try Data(contentsOf: index) == damaged)
    }
}
