import Foundation
import Testing
import CryptoKit
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct TranscriptSourceMapTests {
    private struct Fixture {
        let root: URL; let project: Project; let input: URL; let catalog: TranscriptCatalog
    }
    private func sha(_ data: Data) -> String { TranscriptSourceMap.sha(data) }
    /// A real local PCM file lets AVFoundation test media, not a mocked probe.
    private func wave(_ url: URL, value: UInt8, samples: Int = 240_000) throws {
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { var v = UInt16(value).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + samples * 2); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(48_000); u32(96_000); u16(2); u16(16); text("data"); u32(samples * 2)
        data.append(Data(repeating: value, count: samples * 2)); try data.write(to: url)
    }
    private func fixture(large: Bool = false, transcript: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-source-map-\(UUID())")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"), withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic source maps", root: root, engine: engine)
        var sources: [TranscriptSource] = []
        for (id, value) in [("a", UInt8(0)), ("b", UInt8(1))] {
            let url = root.appendingPathComponent(id + ".wav")
            try wave(url, value: value, samples: large && id == "a" ? 32_000_000 : 240_000)
            let words: [TranscriptWord] = id == "a" ? [.init(word: "First.", start: 0.1, end: 0.5), .init(word: "Return.", start: 2.1, end: 2.5)] : [.init(word: "Middle.", start: 1.1, end: 1.6)]
            let data = try JSONEncoder().encode(["words": words]), snapshot = root.appendingPathComponent(id + ".words.json")
            try data.write(to: snapshot)
            sources.append(.init(id: id, path: url.path, sourceSHA256: sha(try Data(contentsOf: url)), transcriptSHA256: sha(data),
                duration: large && id == "a" ? 32_000_000.0 / 48_000 : 5, words: words, originalTranscriptPath: transcript ? snapshot.path : nil))
        }
        var rows: [TranscriptRow] = []
        for source in sources {
            for (index, word) in source.words.enumerated() {
                rows.append(.init(id: source.id + String(format: "-w%05d-%05d-", index, index) + source.sourceSHA256.prefix(8),
                    sourceID: source.id, sourceSHA256: source.sourceSHA256, firstWord: index, lastWord: index,
                    start: word.start, end: word.end, inTimecode: "00:00:00:00", outTimecode: "00:00:01:00", text: word.word,
                    keep: true, notes: "", requestedGraphics: "", assistantGraphics: "", handwrittenAsset: "", section: "Synthetic", uncertainty: "", originalOrder: rows.count + 1))
            }
        }
        let catalog = TranscriptCatalog(schemaVersion: 1, title: "Synthetic", datasetSHA256: String(repeating: "e", count: 64), sources: sources, rows: rows)
        let input = root.appendingPathComponent("catalog.json"); try JSONEncoder().encode(catalog).write(to: input)
        return Fixture(root: root, project: project, input: input, catalog: catalog)
    }

    @Test func reorderedABARemainsOriginalClipCoordinatesAndHalfOpenBoundaries() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = TranscriptReviewRepository(), first = try await repo.importCatalog(f.input, project: f.project)
        var draft = first; try draft.state.move(f.catalog.rows[2].id, to: 2)
        let saved = try await repo.save(draft, expectedRevision: first.state.revisionID, project: f.project)
        let (map, url) = try await repo.prepareSourceMap(expectedRevision: saved.state.revisionID, project: f.project)
        #expect(map.spans.map(\.sourceID) == ["a", "b", "a"])
        #expect(map.spans.map(\.sourceIn) == [0.1, 1.1, 2.1])
        #expect(map.location(at: 0)?.sourceSeconds == 0.1)
        #expect(map.location(at: map.spans[1].selectionIn)?.span.sourceID == "b")
        #expect(map.location(at: map.spans[2].selectionIn)?.sourceSeconds == 2.1)
        #expect(map.location(at: map.untrimmedSelectionSeconds) == nil)
        #expect(map.location(at: -.infinity) == nil); #expect(map.location(at: .nan) == nil)
        #expect(map.reviewOnly && !map.appliedToCut)
        #expect(sha(try Data(contentsOf: url)) == (try map.sha256()))
        let playback = try await repo.verifySource(rowID: f.catalog.rows[1].id, expectedRevision: saved.state.revisionID, project: f.project)
        #expect(playback.span.sourceID == "a" && playback.span.sourceIn == 2.1)
        #expect(playback.media.transcriptSnapshotVerified)
        try await repo.validatePlayback(playback, project: f.project)
    }

    @Test func missingWrongHashReplacedMediaAndTranscriptChangesAreRejected() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = TranscriptReviewRepository(), session = try await repo.importCatalog(f.input, project: f.project)
        let playback = try await repo.verifySource(rowID: f.catalog.rows[0].id, expectedRevision: session.state.revisionID, project: f.project)
        let url = URL(fileURLWithPath: f.catalog.sources[0].path), bytes = try Data(contentsOf: url)
        try bytes.write(to: url, options: .atomic) // Identical bytes, different inode still invalidates the receipt.
        #expect(throws: WorkflowFailure.self) { try SourceMediaVerifier.checkCurrent(playback.media) }
        let refreshed = try await repo.verifySource(rowID: f.catalog.rows[0].id, expectedRevision: session.state.revisionID, project: f.project)
        try Data("changed snapshot".utf8).write(to: URL(fileURLWithPath: f.catalog.sources[0].originalTranscriptPath!))
        await #expect(throws: WorkflowFailure.self) { try await repo.validatePlayback(refreshed, project: f.project) }
        await #expect(throws: WorkflowFailure.self) { try await repo.verifySource(rowID: f.catalog.rows[0].id, expectedRevision: session.state.revisionID, project: f.project) }
        try wave(url, value: 9)
        await #expect(throws: WorkflowFailure.self) { try await SourceMediaVerifier().verify(f.catalog.sources[0]) }
        try FileManager.default.removeItem(at: url)
        await #expect(throws: WorkflowFailure.self) { try await SourceMediaVerifier().verify(f.catalog.sources[0]) }
    }

    @Test func explicitAcknowledgementIsRevisionBoundAndCannotUnlockRendering() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = TranscriptReviewRepository(), session = try await repo.importCatalog(f.input, project: f.project)
        await #expect(throws: WorkflowFailure.self) { try await repo.acknowledgeSourceReview(expectedRevision: session.state.revisionID, project: f.project, mappingsReviewed: false, orderAndNotesReviewed: true) }
        _ = try await repo.export(expectedRevision: session.state.revisionID, project: f.project)
        #expect(try await repo.currentSourceAcknowledgement(expectedRevision: session.state.revisionID, project: f.project) == nil)
        let url = try await repo.acknowledgeSourceReview(expectedRevision: session.state.revisionID, project: f.project, mappingsReviewed: true, orderAndNotesReviewed: true)
        let receipt = try #require(try await repo.currentSourceAcknowledgement(expectedRevision: session.state.revisionID, project: f.project))
        #expect(receipt.sourceMappingsReviewed && receipt.recordedSpeechOrderAndNotesReviewed)
        #expect(!receipt.appliedToCut && !receipt.renderingAuthorized && !receipt.humanIdentityVerified && !receipt.pairedEditorialApproval && !receipt.humanFactApproval)
        #expect(throws: WorkflowFailure.self) { try TranscriptProductionGate.requireLegacyPipelineAllowed(project: f.project) }
        var draft = session; draft.state.decisions[f.catalog.rows[0].id]!.comment = "New note"
        let next = try await repo.save(draft, expectedRevision: session.state.revisionID, project: f.project)
        #expect(try await repo.currentSourceAcknowledgement(expectedRevision: next.state.revisionID, project: f.project) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: WorkflowFailure.self) { try await repo.prepareSourceMap(expectedRevision: session.state.revisionID, project: f.project) }
    }

    @Test func emptySelectionAndAbsentTranscriptCannotQualify() async throws {
        let f = try await fixture(transcript: false); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = TranscriptReviewRepository(), session = try await repo.importCatalog(f.input, project: f.project)
        #expect(try await repo.verifySource(rowID: f.catalog.rows[0].id, expectedRevision: session.state.revisionID, project: f.project).media.transcriptSnapshotVerified == false)
        await #expect(throws: WorkflowFailure.self) { try await repo.acknowledgeSourceReview(expectedRevision: session.state.revisionID, project: f.project, mappingsReviewed: true, orderAndNotesReviewed: true) }
        var draft = session
        for id in draft.state.rowOrder { draft.state.decisions[id]!.keep = false }
        let saved = try await repo.save(draft, expectedRevision: session.state.revisionID, project: f.project)
        await #expect(throws: WorkflowFailure.self) { try await repo.prepareSourceMap(expectedRevision: saved.state.revisionID, project: f.project) }
        await #expect(throws: WorkflowFailure.self) { try await repo.acknowledgeSourceReview(expectedRevision: saved.state.revisionID, project: f.project, mappingsReviewed: true, orderAndNotesReviewed: true) }
    }

    @Test func sourceAssociationSurvivesHeadLossAndBlocksPrepareResumeAndSnapshot() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let engine = f.root.appendingPathComponent("engine"), projectRepo = ProjectRepository(), workflow = WorkflowRepository()
        try f.project.manifest.engineVersion.write(to: engine.appendingPathComponent("ENGINE_VERSION"), atomically: true, encoding: .utf8)
        // Prepare only: the synthetic legacy run must be valid before intake, not
        // already invalid for an unrelated missing-file/identity reason.
        let clip = f.root.appendingPathComponent("Synthetic narration.MOV")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: f.catalog.sources[0].path), to: clip)
        let project = try await projectRepo.add([clip], to: f.project)
        try await projectRepo.approveScript("Synthetic source-review gate fixture.", project: project)
        let oldRun = try await workflow.prepare(project: project, engine: engine, label: "Before transcript intake")
        _ = try await workflow.settings(oldRun, project: project, engine: engine)
        let frozenPaths = try Data(contentsOf: oldRun.folder.appendingPathComponent("paths.json"))
        _ = try await TranscriptReviewRepository().importCatalog(f.input, project: project)
        try FileManager.default.removeItem(at: project.folder.appendingPathComponent(".clauto/transcript-review.json"))
        try FileManager.default.removeItem(at: project.folder.appendingPathComponent("notes/transcript-review"))
        do {
            _ = try await workflow.prepare(project: project, engine: engine, label: "Must not render")
            Issue.record("Transcript intake must block a new legacy whole-clip run.")
        } catch { #expect(error.localizedDescription.contains("Transcript choices remain")) }
        do {
            _ = try await workflow.settings(oldRun, project: project, engine: engine)
            Issue.record("Transcript intake must block resuming the legacy run.")
        } catch { #expect(error.localizedDescription.contains("Transcript choices remain")) }
        do {
            _ = try await workflow.snapshot(oldRun, project: project)
            Issue.record("Transcript intake must block a legacy cut snapshot.")
        } catch { #expect(error.localizedDescription.contains("Transcript choices remain")) }
        #expect(try Data(contentsOf: oldRun.folder.appendingPathComponent("paths.json")) == frozenPaths)
    }

    @Test @MainActor func editDuringVerificationDiscardsStalePreview() async throws {
        let f = try await fixture(large: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = TranscriptReviewRepository(), session = try await repo.importCatalog(f.input, project: f.project)
        var draft = session; draft.state.decisions[f.catalog.rows[0].id]!.keep = false
        let changed = draft, writer = TranscriptReviewRepository()
        await #expect(throws: WorkflowFailure.self) {
            try await repo.verifySource(rowID: f.catalog.rows[0].id, expectedRevision: session.state.revisionID, project: f.project) { read, _ in
                if read == 1024 * 1024 {
                    _ = try await writer.save(changed, expectedRevision: session.state.revisionID, project: f.project)
                }
            }
        }
        #expect(try await repo.load(project: f.project)?.state.decisions[f.catalog.rows[0].id]?.keep == false)
    }
    @Test @MainActor func controllerRecoversAfterReconnectAndRefusesDelayedAcknowledgement() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let controller = TranscriptReviewController(project: f.project)
        await controller.importCatalog(f.input)
        let row = f.catalog.rows[0], url = URL(fileURLWithPath: f.catalog.sources[0].path), bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        await controller.verifySource(row.id)
        #expect(controller.failure != nil && controller.sourcePlayback == nil && !controller.dirty)
        try bytes.write(to: url)
        await controller.verifySource(row.id)
        #expect(controller.failure == nil && controller.sourcePlayback != nil)
        let clickedRevision = try #require(controller.session?.state.revisionID), clickedGeneration = controller.generationForDisplay
        controller.change(row.id) { $0.comment = "An edit after the click" }
        #expect(controller.sourcePlayback == nil)
        _ = await controller.flush()
        await controller.acknowledgeSources(expectedRevision: clickedRevision, expectedGeneration: clickedGeneration, mappingsReviewed: true, orderAndNotesReviewed: true)
        #expect(controller.sourceAcknowledgement == nil && controller.failure != nil)
        let current = try #require(controller.session)
        await controller.acknowledgeSources(expectedRevision: current.state.revisionID, expectedGeneration: controller.generationForDisplay, mappingsReviewed: true, orderAndNotesReviewed: true)
        #expect(controller.sourceAcknowledgement != nil && controller.failure == nil)
    }

    @Test func duplicateMediaIdentitiesAndInteriorWordOverrunCannotProduceAMap() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.input)) as? [String: Any])
        for mode in 0..<3 {
            var object = original, sources = original["sources"] as! [[String: Any]], rows = original["rows"] as! [[String: Any]]
            if mode == 0 { sources[1]["source_id"] = sources[0]["source_id"] }
            else if mode == 1 {
                sources[1]["source_sha256"] = sources[0]["source_sha256"]
                rows[2]["source_sha256"] = sources[0]["source_sha256"]
                rows[2]["id"] = "b-w00000-00000-" + f.catalog.sources[0].sourceSHA256.prefix(8)
            } else {
                var words = sources[0]["words"] as! [[String: Any]]
                words[0]["end"] = 3.0; sources[0]["words"] = words
                rows[0]["last_word"] = 1; rows[0]["end"] = 2.5; rows[0]["text"] = "First. Return."
                rows[0]["id"] = "a-w00000-00001-" + f.catalog.sources[0].sourceSHA256.prefix(8)
                rows.remove(at: 1); rows[1]["original_order"] = 2
            }
            object["sources"] = sources; object["rows"] = rows
            let data = try JSONSerialization.data(withJSONObject: object), catalog = try JSONDecoder().decode(TranscriptCatalog.self, from: data)
            if mode == 0 { #expect(throws: WorkflowFailure.self) { try catalog.validate() }; continue }
            try catalog.validate()
            let state = TranscriptReviewState(reviewID: UUID(), projectID: f.project.id, catalogSHA256: sha(data),
                rowOrder: catalog.rows.map(\.id), decisions: Dictionary(uniqueKeysWithValues: catalog.rows.map { ($0.id, TranscriptRowDecision(row: $0)) }))
            let bound = TranscriptBoundReview(session: .init(catalog: catalog, state: state), revisionSHA256: String(repeating: "f", count: 64))
            #expect(throws: WorkflowFailure.self) { try TranscriptSourceMap.compile(bound) }
        }
    }

    @Test func damagedReceiptAndMapCannotAssertApprovalEvenWithRehashedPointer() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = TranscriptReviewRepository(), session = try await repo.importCatalog(f.input, project: f.project)
        let receiptURL = try await repo.acknowledgeSourceReview(expectedRevision: session.state.revisionID, project: f.project, mappingsReviewed: true, orderAndNotesReviewed: true)
        let pointerURL = f.project.folder.appendingPathComponent("notes/transcript-review/\(session.state.reviewID)/source-review-current.json")
        let receiptBytes = try Data(contentsOf: receiptURL), pointerBytes = try Data(contentsOf: pointerURL)
        var pointer = try #require(JSONSerialization.jsonObject(with: pointerBytes) as? [String: Any])
        var object = try #require(JSONSerialization.jsonObject(with: receiptBytes) as? [String: Any]); object["renderingAuthorized"] = true
        let damaged = try JSONSerialization.data(withJSONObject: object)
        try damaged.write(to: receiptURL); pointer["receiptSHA256"] = sha(damaged)
        try JSONSerialization.data(withJSONObject: pointer).write(to: pointerURL)
        await #expect(throws: ProjectFailure.self) { try await repo.currentSourceAcknowledgement(expectedRevision: session.state.revisionID, project: f.project) }
        try receiptBytes.write(to: receiptURL); try pointerBytes.write(to: pointerURL)
        let mapURL = f.project.folder.appendingPathComponent(pointer["mapPath"] as! String)
        var map = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: mapURL)) as? [String: Any])
        var spans = map["spans"] as! [[String: Any]]; spans[0]["sourceIn"] = 0.2; map["spans"] = spans
        let changedMap = try JSONSerialization.data(withJSONObject: map); try changedMap.write(to: mapURL)
        pointer["mapSHA256"] = sha(changedMap); pointer["receiptSHA256"] = sha(receiptBytes)
        try JSONSerialization.data(withJSONObject: pointer).write(to: pointerURL)
        await #expect(throws: WorkflowFailure.self) { try await repo.currentSourceAcknowledgement(expectedRevision: session.state.revisionID, project: f.project) }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func delayedAudioAndActualMediaDurationRejectUncoveredSelections() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let delayed = f.root.appendingPathComponent("delayed.mov"), process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "color=c=black:s=16x16:r=10:d=5", "-itsoffset", "1", "-i", f.catalog.sources[0].path,
                             "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-c:a", "pcm_s16le", "-t", "5", delayed.path]
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        let source = TranscriptSource(id: "delayed", path: delayed.path, sourceSHA256: sha(try Data(contentsOf: delayed)),
            transcriptSHA256: f.catalog.sources[0].transcriptSHA256, duration: 9, words: f.catalog.sources[0].words)
        let checked = try await SourceMediaVerifier().verify(source)
        func span(_ start: Double, _ end: Double) -> TranscriptSourceSpan {
            .init(id: "test", sourceID: source.id, sourcePath: source.path, sourceSHA256: source.sourceSHA256,
                transcriptSHA256: source.transcriptSHA256, firstWord: 0, lastWord: 0, sourceIn: start, sourceOut: end, selectionIn: 0, selectionOut: end-start)
        }
        #expect(checked.audioRanges.allSatisfy { $0.start >= 1 })
        #expect(throws: WorkflowFailure.self) { try checked.validate(span: span(0.1, 0.5)) }
        try checked.validate(span: span(1.1, 1.6))
        #expect(throws: WorkflowFailure.self) { try checked.validate(span: span(4.8, 5.2)) }
        #expect(throws: WorkflowFailure.self) { try checked.validate(span: span(.nan, 2)) }
        #expect(throws: WorkflowFailure.self) { try checked.validate(span: span(2, 2)) }
    }

    @Test func fileMutationDuringHashIsRejectedAndAliasesCannotRetargetReceipts() async throws {
        let f = try await fixture(large: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = URL(fileURLWithPath: f.catalog.sources[0].path)
        // Deterministic real-I/O fault: alter an unread byte after hashing has begun.
        await #expect(throws: WorkflowFailure.self) {
            try await SourceMediaVerifier().verify(f.catalog.sources[0]) { read, _ in
                if read == 1024 * 1024, let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.seek(toOffset: 2 * 1024 * 1024); try? handle.write(contentsOf: Data([7])); try? handle.close()
                }
            }
        }
        let b = f.catalog.sources[1], original = URL(fileURLWithPath: b.originalTranscriptPath!)
        let alias = f.root.appendingPathComponent("transcript-alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        var source = b; source.originalTranscriptPath = alias.path
        let media = try await SourceMediaVerifier().verify(source)
        let sameBytes = f.root.appendingPathComponent("other.words.json"); try Data(contentsOf: original).write(to: sameBytes)
        try FileManager.default.removeItem(at: alias); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sameBytes)
        #expect(throws: WorkflowFailure.self) { try SourceMediaVerifier.checkCurrent(media) }
    }

    @Test func unreadableAssociationMetadataNeverPermitsLegacyRendering() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let metadata = f.project.folder.appendingPathComponent(".clauto")
        try FileManager.default.removeItem(at: metadata); try Data("damaged metadata".utf8).write(to: metadata)
        #expect(throws: WorkflowFailure.self) { try TranscriptProductionGate.requireLegacyPipelineAllowed(project: f.project) }
    }

    @Test func loadedReceiptAndPlaybackCannotRebindOriginalTranscriptToAnotherCopy() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let repo = TranscriptReviewRepository(), session = try await repo.importCatalog(f.input, project: f.project)
        let url = try await repo.acknowledgeSourceReview(expectedRevision: session.state.revisionID, project: f.project, mappingsReviewed: true, orderAndNotesReviewed: true)
        var source = f.catalog.sources[0]
        let alternate = f.root.appendingPathComponent("alternate.words.json")
        try Data(contentsOf: URL(fileURLWithPath: source.originalTranscriptPath!)).write(to: alternate)
        source.originalTranscriptPath = alternate.path
        let verified = try await SourceMediaVerifier().verify(source)
        let (map, _) = try await repo.prepareSourceMap(expectedRevision: session.state.revisionID, project: f.project)
        let ticket = VerifiedSourcePlayback(projectID: f.project.id, reviewID: map.reviewID, revisionID: map.revisionID,
            revisionSHA256: map.revisionSHA256, catalogSHA256: map.catalogSHA256, span: map.spans[0], media: verified)
        await #expect(throws: WorkflowFailure.self) { try await repo.validatePlayback(ticket, project: f.project) }
        var receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var media = receipt["media"] as! [[String: Any]]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        media[0] = try #require(JSONSerialization.jsonObject(with: encoder.encode(verified)) as? [String: Any]); receipt["media"] = media
        let bytes = try JSONSerialization.data(withJSONObject: receipt); try bytes.write(to: url)
        let pointerURL = f.project.folder.appendingPathComponent("notes/transcript-review/\(session.state.reviewID)/source-review-current.json")
        var pointer = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as? [String: Any])
        pointer["receiptSHA256"] = sha(bytes); try JSONSerialization.data(withJSONObject: pointer).write(to: pointerURL)
        await #expect(throws: WorkflowFailure.self) { try await repo.currentSourceAcknowledgement(expectedRevision: session.state.revisionID, project: f.project) }
    }

    @Test func danglingAssociationAncestorAndWrongOriginalWordsAreRejected() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let metadata = f.project.folder.appendingPathComponent(".clauto")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: f.project.folder.appendingPathComponent("missing-metadata"))
        #expect(throws: WorkflowFailure.self) { try TranscriptProductionGate.requireLegacyPipelineAllowed(project: f.project) }
        var source = f.catalog.sources[0]
        let wrong = try JSONEncoder().encode(["words": [TranscriptWord(word: "Different.", start: 0.1, end: 0.5)]])
        let url = URL(fileURLWithPath: source.originalTranscriptPath!); try wrong.write(to: url)
        source = .init(id: source.id, path: source.path, sourceSHA256: source.sourceSHA256,
            transcriptSHA256: sha(wrong), duration: source.duration, words: source.words, originalTranscriptPath: source.originalTranscriptPath)
        await #expect(throws: WorkflowFailure.self) { try await SourceMediaVerifier().verify(source) }
    }

}
