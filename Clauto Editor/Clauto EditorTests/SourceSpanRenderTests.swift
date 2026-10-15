import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor FailingSourceRenderRunner: CommandRunning {
    func cancel() {}
    func run(_ command: ProcessCommand, onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        ProcessResult(exitCode: 28, output: "", error: "Simulated NAS write failure: No space left on device", cancelled: false)
    }
}

private actor SnapshotCancellingRunner: CommandRunning {
    private let base = ProcessRunner()
    private(set) var reachedSnapshot = false
    func cancel() async { await base.cancel() }
    private func observed(_ line: ProcessLine) async {
        if line.text.contains("source_snapshot_ready") {
            reachedSnapshot = true
            await base.cancel()
        }
    }
    func run(_ command: ProcessCommand, onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        try await base.run(command) { line in await self.observed(line); await onLine?(line) }
    }
}

struct SourceSpanRenderTests {
    private struct Fixture {
        let root: URL; let engine: URL; let permit: SyntheticSourceSpanFixture
        let repo: TranscriptReviewRepository; let review: TranscriptReviewSession; let ack: LocalSourceReviewAcknowledgement
    }
    private func fixture(root overrideRoot: URL? = nil) async throws -> Fixture {
        let root = overrideRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("clauto-span-render-\(UUID())")
        let engine = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let permit = try await SyntheticSourceSpanFixture.generate(root: root, engine: engine)
        let repo = TranscriptReviewRepository(), initial = try await repo.importCatalog(permit.catalogURL, project: permit.project)
        var draft = initial; try draft.state.move(initial.catalog.rows[2].id, to: 2)
        let review = try await repo.save(draft, expectedRevision: initial.state.revisionID, project: permit.project)
        _ = try await repo.acknowledgeSourceReview(expectedRevision: review.state.revisionID, project: permit.project, mappingsReviewed: true, orderAndNotesReviewed: true)
        let ack = try #require(try await repo.currentSourceAcknowledgement(expectedRevision: review.state.revisionID, project: permit.project))
        return .init(root: root, engine: engine, permit: permit, repo: repo, review: review, ack: ack)
    }
    private func render(_ f: Fixture, checkpoint: (@Sendable (SourceSpanRenderCheckpoint, URL) async throws -> Void)? = nil) async throws -> SyntheticSourceSpanRenderResult {
        try await SourceSpanRenderService(reviews: f.repo).renderSyntheticReview(fixture: f.permit,
            expectedRevision: f.review.state.revisionID, expectedAcknowledgementID: f.ack.id, engine: f.engine, onCheckpoint: checkpoint)
    }
    private func pointer(_ f: Fixture) -> URL { f.permit.project.folder.appendingPathComponent(".clauto/source-span-synthetic-current.json") }
    private func tool(_ executable: String, _ args: [String]) throws -> Data {
        let task = Process(), out = Pipe(), err = Pipe(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = args
        task.standardOutput = out; task.standardError = err; try task.run()
        let bytes = out.fileHandleForReading.readDataToEndOfFile(); let errors = err.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw WorkflowFailure.invalid(String(decoding: errors, as: UTF8.self)) }; return bytes
    }
    private func pcm(_ path: URL) throws -> Data {
        try tool("/opt/homebrew/bin/ffmpeg", ["-v","error","-nostdin","-i",path.path,"-map","0:a:0","-ac","1","-ar","48000","-f","s16le","-"])
    }

    @Test func realSyntheticABAAssemblyHasExactOriginalAudioRangesFramesAndEditableTimeline() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let project = f.permit.project
        let originals = Dictionary(uniqueKeysWithValues: f.review.catalog.sources.map { ($0.id, $0.sourceSHA256) })
        let cutPointer = project.folder.appendingPathComponent("cuts/current.json"), priorCut = Data("Existing-cut-sentinel".utf8)
        try priorCut.write(to: cutPointer)
        let result = try await render(f)
        #expect(result.totalFrames == 36 && result.audioSamples == 72_072 && result.schemaChecked)
        #expect(!result.productionAuthorized && !result.appliedToCut)
        #expect(result.sourceByteStrategy == SyntheticSourceByteContract.strategy)
        #expect(result.sourceBytes.count == 2 && result.sourceBytes.values.allSatisfy { $0.readOnly && $0.unlinked && $0.byteCount <= SyntheticSourceByteContract.sourceLimit })
        let proof = try JSONDecoder().decode(SourceSpanWorkerReceipt.self, from: Data(contentsOf: result.folder.appendingPathComponent("render-proof.json")))
        #expect(proof.spans.map(\.sourceID) == ["a", "b", "a"])
        #expect(proof.spans.map(\.startFrame) == [6,24,42]); #expect(proof.spans.map(\.endFrame) == [18,36,54])
        #expect(proof.spans.map(\.timelineFrame) == [0,12,24])
        let output = try pcm(result.folder.appendingPathComponent("review.mov"))
        let sourcePCM = try Dictionary(uniqueKeysWithValues: f.review.catalog.sources.map { ($0.id, try pcm(URL(fileURLWithPath: $0.path))) })
        var expected = Data()
        for span in proof.spans { expected.append(sourcePCM[span.sourceID]!.subdata(in: span.startSample*2..<span.endSample*2)) }
        #expect(output == expected, "Every output sample must follow the ordered selected original ranges without padding or retiming.")
        let pixels = try tool("/opt/homebrew/bin/ffmpeg", ["-v","error","-nostdin","-i",result.folder.appendingPathComponent("review.mov").path,
            "-vf","select=eq(n\\,6)+eq(n\\,18)+eq(n\\,30)","-fps_mode","vfr","-pix_fmt","rgb24","-f","rawvideo","-"])
        #expect(pixels.count == 129_600)
        if pixels.count == 160 * 90 * 3 * 3 {
            for (index,channel) in [0,1,2].enumerated() {
                let at = index * 160*90*3 + (45*160+80)*3, value = Int(pixels[at+channel])
                #expect((0..<3).filter { $0 != channel }.allSatisfy { value > Int(pixels[at+$0]) + 70 })
            }
        }
        for source in f.review.catalog.sources { #expect(TranscriptSourceMap.sha(try Data(contentsOf: URL(fileURLWithPath: source.path))) == originals[source.id]) }
        #expect(try Data(contentsOf: cutPointer) == priorCut)
        #expect(FileManager.default.fileExists(atPath: pointer(f).path))
        #expect(throws: WorkflowFailure.self) { try TranscriptProductionGate.requireLegacyPipelineAllowed(project: project) }
    }

    @Test func staleReviewAndReplacementAcknowledgementNeverReplaceCurrentSyntheticPreview() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await render(f); let before = try Data(contentsOf: pointer(f))
        await #expect(throws: WorkflowFailure.self) {
            try await render(f) { phase, _ in
                if case .beforePublication = phase {
                    _ = try await f.repo.acknowledgeSourceReview(expectedRevision: f.review.state.revisionID, project: f.permit.project, mappingsReviewed: true, orderAndNotesReviewed: true)
                }
            }
        }
        #expect(try Data(contentsOf: pointer(f)) == before)
        let newAck = try #require(try await f.repo.currentSourceAcknowledgement(expectedRevision: f.review.state.revisionID, project: f.permit.project))
        await #expect(throws: WorkflowFailure.self) {
            try await SourceSpanRenderService(reviews: f.repo).renderSyntheticReview(fixture: f.permit, expectedRevision: f.review.state.revisionID,
                expectedAcknowledgementID: newAck.id, engine: f.engine) { phase, _ in
                if case .beforePublication = phase {
                    var draft = f.review; draft.state.decisions[draft.state.rowOrder[0]]!.comment = "Later synthetic review"
                    _ = try await f.repo.save(draft, expectedRevision: f.review.state.revisionID, project: f.permit.project)
                }
            }
        }
        #expect(try Data(contentsOf: pointer(f)) == before)
    }

    @Test func concurrentSyntheticRendersKeepDistinctBundlesAndExactSourceByteReceipts() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        async let first = render(f)
        async let second = render(f)
        let (a, b) = try await (first, second)
        #expect(a.id != b.id && a.folder != b.folder)
        #expect(a.sourceBytes == b.sourceBytes && a.sourceByteStrategy == SyntheticSourceByteContract.strategy)
        #expect(a.artifactsSHA256["review.mov"] == b.artifactsSHA256["review.mov"])
        let current = try JSONDecoder().decode(SyntheticSourceSpanRenderResult.self, from: Data(contentsOf: pointer(f)))
        #expect([a.id,b.id].contains(current.id))
        #expect(try pcm(a.folder.appendingPathComponent("review.mov")) == pcm(b.folder.appendingPathComponent("review.mov")))
    }

    @Test func cancellationDuringPrivateSnapshotWorkerPreservesPriorCurrent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await render(f); let before = try Data(contentsOf: pointer(f))
        let runner = SnapshotCancellingRunner()
        await #expect(throws: WorkflowFailure.self) {
            try await SourceSpanRenderService(runner: runner, reviews: f.repo).renderSyntheticReview(fixture: f.permit,
                expectedRevision: f.review.state.revisionID, expectedAcknowledgementID: f.ack.id, engine: f.engine)
        }
        #expect(await runner.reachedSnapshot)
        #expect(try Data(contentsOf: pointer(f)) == before)
        let build = f.permit.project.folder.appendingPathComponent("build/source-span-reviews")
        let files = FileManager.default.enumerator(at: build, includingPropertiesForKeys: nil)!
        #expect(!files.compactMap { $0 as? URL }.contains { $0.lastPathComponent.hasPrefix(".source-snapshot-") })
    }

    @Test func missingOrRehashedWrongSnapshotReceiptCannotReplaceCurrent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await render(f); let before = try Data(contentsOf: pointer(f))
        for mode in 0..<5 {
            await #expect(throws: (any Error).self) {
                try await render(f) { phase, stage in
                    if case .workerFinished = phase {
                        let url = stage.appendingPathComponent("render-proof.json")
                        var proof = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                        if mode == 0 { proof.removeValue(forKey: "sourceBytes") }
                        else {
                            var sources = proof["sourceBytes"] as! [String: [String: Any]]
                            if mode == 1 { sources["a"]!["sha256"] = String(repeating: "0", count: 64) }
                            if mode == 2 { sources["a"]!["byteCount"] = SyntheticSourceByteContract.sourceLimit + 1 }
                            if mode == 3 { sources["a"]!["unlinked"] = false }
                            if mode == 4 { sources["a"]!["readOnly"] = false }
                            proof["sourceBytes"] = sources
                        }
                        try JSONSerialization.data(withJSONObject: proof).write(to: url)
                    }
                }
            }
            #expect(try Data(contentsOf: pointer(f)) == before)
        }
    }

    @Test func missingChangedSourcesAndUnacknowledgedReviewCannotRender() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: WorkflowFailure.self) {
            try await SourceSpanRenderService(reviews: f.repo).renderSyntheticReview(fixture: f.permit, expectedRevision: f.review.state.revisionID,
                expectedAcknowledgementID: UUID(), engine: f.engine)
        }
        let url = URL(fileURLWithPath: f.review.catalog.sources[0].path), bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        await #expect(throws: WorkflowFailure.self) { try await render(f) }
        try bytes.write(to: url)
        await #expect(throws: WorkflowFailure.self) { try await render(f) } // Same bytes/new inode invalidates acknowledgment.
        #expect(!FileManager.default.fileExists(atPath: pointer(f).path))
        try Data("changed media".utf8).write(to: url)
        await #expect(throws: WorkflowFailure.self) { try await render(f) }
    }

    @Test func cancellationAndPublicationCollisionPreservePriorCurrentAndForeignSentinel() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await render(f); let before = try Data(contentsOf: pointer(f))
        let checking = Task {
            try await render(f) { phase, _ in
                if case .beforePublication = phase { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await checking.value }
        #expect(try Data(contentsOf: pointer(f)) == before)
        await #expect(throws: WorkflowFailure.self) {
            try await render(f) { phase, stage in
                if case .beforePublication = phase {
                    let destination = stage.deletingLastPathComponent().appendingPathComponent(String(stage.lastPathComponent.dropFirst(".pending-".count)))
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try Data("Do not replace".utf8).write(to: destination.appendingPathComponent("sentinel"))
                }
            }
        }
        #expect(try Data(contentsOf: pointer(f)) == before)
    }

    @Test func simulatedNASDisconnectAndDestinationSwapCannotWriteIntoReplacementFolder() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await render(f); let before = try Data(contentsOf: pointer(f))
        let displaced = f.root.appendingPathComponent("disconnected-project")
        await #expect(throws: (any Error).self) {
            try await render(f) { phase, _ in
                if case .workerFinished = phase {
                    try FileManager.default.moveItem(at: f.permit.project.folder, to: displaced)
                    try FileManager.default.createDirectory(at: f.permit.project.folder, withIntermediateDirectories: false)
                    try Data("Foreign replacement".utf8).write(to: f.permit.project.folder.appendingPathComponent("sentinel"))
                }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.permit.project.folder.path) == ["sentinel"])
        #expect(try Data(contentsOf: displaced.appendingPathComponent(".clauto/source-span-synthetic-current.json")) == before)
    }

    @Test func failedEncoderOrWriteRetainsIncompleteEvidenceAndCurrentBytes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await render(f); let before = try Data(contentsOf: pointer(f))
        await #expect(throws: WorkflowFailure.self) {
            try await SourceSpanRenderService(runner: FailingSourceRenderRunner(), reviews: f.repo).renderSyntheticReview(fixture: f.permit,
                expectedRevision: f.review.state.revisionID, expectedAcknowledgementID: f.ack.id, engine: f.engine)
        }
        #expect(try Data(contentsOf: pointer(f)) == before)
        await #expect(throws: WorkflowFailure.self) {
            try await render(f) { phase, stage in
                if case .inputFrozen = phase { try Data("Exclusive-file collision".utf8).write(to: stage.appendingPathComponent("part-00000.mov")) }
            }
        }
        #expect(try Data(contentsOf: pointer(f)) == before)
    }
    @Test func rehashedWrongTimelineAndSwappedStagingCannotPublish() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await render(f); let before = try Data(contentsOf: pointer(f))
        for mode in 0..<3 {
            await #expect(throws: (any Error).self) {
                try await render(f) { phase, stage in
                    if case .workerFinished = phase {
                        let xmlURL = stage.appendingPathComponent("timeline.fcpxml")
                        let xml = try XMLDocument(contentsOf: xmlURL, options: .nodeLoadExternalEntitiesNever)
                        if mode == 0 {
                            let format = try #require(try xml.nodes(forXPath: "/fcpxml/resources/format").first as? XMLElement)
                            format.attribute(forName: "frameDuration")?.stringValue = "1/30s"
                        } else if mode == 1 {
                            let asset = try #require(try xml.nodes(forXPath: "/fcpxml/resources/asset").first as? XMLElement)
                            let extra = XMLElement(name: "media-rep"); extra.addAttribute(XMLNode.attribute(withName: "kind", stringValue: "proxy-media") as! XMLNode)
                            extra.addAttribute(XMLNode.attribute(withName: "src", stringValue: "https://example.invalid/untrusted.mov") as! XMLNode); asset.addChild(extra)
                        } else {
                            let clip = try #require(try xml.nodes(forXPath: "//spine/asset-clip").first as? XMLElement)
                            clip.addChild(XMLElement(name: "gap"))
                        }
                        let changed = xml.xmlData; try changed.write(to: xmlURL)
                        let proofURL = stage.appendingPathComponent("render-proof.json")
                        var proof = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: proofURL)) as? [String: Any])
                        var hashes = proof["artifactsSHA256"] as! [String: String]; hashes["timeline.fcpxml"] = TranscriptSourceMap.sha(changed); proof["artifactsSHA256"] = hashes
                        try JSONSerialization.data(withJSONObject: proof).write(to: proofURL)
                    }
                }
            }
            #expect(try Data(contentsOf: pointer(f)) == before)
        }
        await #expect(throws: (any Error).self) {
            try await render(f) { phase, stage in
                if case .beforePublication = phase {
                    let owned = stage.deletingLastPathComponent().appendingPathComponent("displaced-" + stage.lastPathComponent)
                    try FileManager.default.moveItem(at: stage, to: owned)
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                    try Data("Foreign sentinel".utf8).write(to: stage.appendingPathComponent("sentinel"))
                }
            }
        }
        #expect(try Data(contentsOf: pointer(f)) == before)
    }

    @Test func alteredFixtureAndFrozenInputAliasRefuseRendering() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: WorkflowFailure.self) {
            try await render(f) { phase, stage in
                if case .inputFrozen = phase {
                    let request = stage.appendingPathComponent("input.json"), bytes = try Data(contentsOf: request)
                    let other = stage.appendingPathComponent("same-bytes.json"); try bytes.write(to: other)
                    try FileManager.default.removeItem(at: request); try FileManager.default.createSymbolicLink(at: request, withDestinationURL: other)
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: pointer(f).path))
        let manifest = f.permit.project.folder.appendingPathComponent(".clauto/source-span-synthetic-fixture.json")
        try (Data(contentsOf: manifest) + Data(" ".utf8)).write(to: manifest)
        await #expect(throws: WorkflowFailure.self) { try await render(f) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_SOURCE_RENDER_ACCEPTANCE_ROOT"] != nil))
    func durableSyntheticNASSourceSpanAcceptance() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLAUTO_SOURCE_RENDER_ACCEPTANCE_ROOT"]))
        let f = try await fixture(root: root)
        if ProcessInfo.processInfo.environment["CLAUTO_SOURCE_BYTE_EXPECT_ISOLATION_BLOCK"] == "1" {
            let prior = Data("Prior-synthetic-current-sentinel".utf8), cut = Data("Prior-production-cut-sentinel".utf8)
            let cutURL = f.permit.project.folder.appendingPathComponent("cuts/current.json")
            try prior.write(to: pointer(f), options: .withoutOverwriting)
            try cut.write(to: cutURL, options: .withoutOverwriting)
            do {
                _ = try await render(f)
                throw WorkflowFailure.invalid("The expected NAS isolation refusal did not occur.")
            } catch {
                guard error.localizedDescription.contains("Filesystem cannot isolate an unlinked source snapshot") else { throw error }
            }
            let currentAfter = try Data(contentsOf: pointer(f)), cutAfter = try Data(contentsOf: cutURL)
            try #require(currentAfter == prior && cutAfter == cut)
            let preserved = f.review.catalog.sources.allSatisfy { source in (try? TranscriptSourceMap.sha(Data(contentsOf: URL(fileURLWithPath: source.path)))) == source.sourceSHA256 }
            try #require(preserved)
            let report: [String: Any] = ["synthetic_only": true, "project": f.permit.project.folder.path,
                "nas_rendering_blocked": true, "reason": "zero-link snapshot attestation unsupported",
                "source_snapshot_media_bytes_copied": 0, "prior_current_preserved": true, "prior_production_cut_preserved": true,
                "source_hashes_unchanged": preserved, "production_authorized": false, "applied_to_cut": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: f.permit.project.folder.appendingPathComponent("SOURCE_BYTE_CAPABILITY_BLOCK.json"), options: .withoutOverwriting)
            print("SYNTHETIC_SOURCE_BYTE_CAPABILITY_BLOCK=" + f.permit.project.folder.path)
            return
        }
        let result = try await render(f)
        let proof = try JSONDecoder().decode(SourceSpanWorkerReceipt.self, from: Data(contentsOf: result.folder.appendingPathComponent("render-proof.json")))
        let output = try pcm(result.folder.appendingPathComponent("review.mov"))
        let originals = try Dictionary(uniqueKeysWithValues: f.review.catalog.sources.map { ($0.id, try pcm(URL(fileURLWithPath: $0.path))) })
        var expected = Data()
        for span in proof.spans { expected.append(originals[span.sourceID]!.subdata(in: span.startSample*2..<span.endSample*2)) }
        try #require(output == expected)
        try #require(result.totalFrames == 36 && result.audioSamples == 72072 && result.schemaChecked)
        try #require(result.sourceByteStrategy == SyntheticSourceByteContract.strategy && result.sourceBytes.count == 2)
        let sourceByteCount = result.sourceBytes.values.reduce(0) { $0 + $1.byteCount }
        try #require(sourceByteCount <= SyntheticSourceByteContract.jobLimit && result.sourceBytes.values.allSatisfy { $0.readOnly && $0.unlinked })
        let sourcePreserved = f.review.catalog.sources.allSatisfy { source in (try? TranscriptSourceMap.sha(Data(contentsOf: URL(fileURLWithPath: source.path)))) == source.sourceSHA256 }
        try #require(sourcePreserved)
        let currentBeforeCollision = try Data(contentsOf: pointer(f))
        await #expect(throws: WorkflowFailure.self) {
            try await render(f) { phase, stage in
                if case .beforePublication = phase {
                    let destination = stage.deletingLastPathComponent().appendingPathComponent(String(stage.lastPathComponent.dropFirst(".pending-".count)))
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try Data("Existing synthetic NAS target".utf8).write(to: destination.appendingPathComponent("sentinel"))
                }
            }
        }
        try #require(Data(contentsOf: pointer(f)) == currentBeforeCollision)
        let report: [String: Any] = ["synthetic_only": true, "project": f.permit.project.folder.path, "bundle": result.folder.path,
            "source_ids_in_order": proof.spans.map(\.sourceID), "stable_row_ids": proof.spans.map(\.id),
            "source_in_frames": proof.spans.map(\.startFrame), "source_out_frames_exclusive": proof.spans.map(\.endFrame),
            "frames": result.totalFrames, "audio_samples": result.audioSamples, "actual_pcm_equals_selected_original_slices": true,
            "source_hashes_unchanged": sourcePreserved,
            "source_byte_strategy": result.sourceByteStrategy, "source_snapshot_total_bytes": sourceByteCount,
            "snapshot_handles_readonly_and_unlinked": true,
            "installed_fcpxml_schema_passed": result.schemaChecked, "native_current_pointer_published": true, "bundle_publication": result.bundlePublication, "existing_target_collision_preserved_current": true,
            "production_authorized": false, "applied_to_cut": false, "private_footage_used": false, "live_sheet_accessed": false,
            "fcpxml_sha256": proof.artifactsSHA256["timeline.fcpxml"]!, "review_movie_sha256": proof.artifactsSHA256["review.mov"]!]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: f.permit.project.folder.appendingPathComponent("SOURCE_SPAN_ACCEPTANCE.json"), options: .withoutOverwriting)
        print("SYNTHETIC_SOURCE_SPAN_ACCEPTANCE=" + f.permit.project.folder.path)
    }

}
