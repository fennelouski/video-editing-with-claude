import Foundation
import Testing
import CryptoKit
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct TranscriptReviewTests {
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fixture() async throws -> (URL, Project, URL, TranscriptCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-transcripts-\(UUID())")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"), withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic transcript review", root: root, engine: engine)
        let sourceA = TranscriptSource(id: "clip_a", path: root.appendingPathComponent("A.mov").path,
            sourceSHA256: String(repeating: "a", count: 64), transcriptSHA256: String(repeating: "c", count: 64), duration: 3,
            words: [.init(word: "A", start: 0.1, end: 0.3), .init(word: "starter", start: 0.4, end: 0.8),
                    .init(word: "grows.", start: 0.9, end: 1.2), .init(word: "Slowly.", start: 2.1, end: 2.5)])
        let sourceB = TranscriptSource(id: "clip_b", path: root.appendingPathComponent("B.mov").path,
            sourceSHA256: String(repeating: "b", count: 64), transcriptSHA256: String(repeating: "d", count: 64), duration: 1.05,
            words: [.init(word: "Yeast", start: 0.1, end: 0.4), .init(word: "makes", start: 0.4, end: 0.6), .init(word: "gas.", start: 0.7, end: 1.1)])
        func row(_ source: TranscriptSource, _ first: Int, _ last: Int, _ order: Int) -> TranscriptRow {
            .init(id: source.id + String(format: "-w%05d-%05d-", first, last) + source.sourceSHA256.prefix(8),
                sourceID: source.id, sourceSHA256: source.sourceSHA256, firstWord: first, lastWord: last,
                start: source.words[first].start, end: source.words[last].end, inTimecode: "00:00:00:02", outTimecode: "00:00:01:05",
                text: source.words[first...last].map(\.word).joined(separator: " "), keep: true, notes: "",
                requestedGraphics: "", assistantGraphics: "Optional paper culture diagram.", handwrittenAsset: "",
                section: "Synthetic shoot", uncertainty: source.id == "clip_b" ? "Raw alignment crosses source bounds" : "", originalOrder: order)
        }
        let catalog = TranscriptCatalog(schemaVersion: 1, title: "Synthetic spoken story", datasetSHA256: String(repeating: "e", count: 64),
            sources: [sourceA, sourceB], rows: [row(sourceA, 0, 2, 1), row(sourceA, 3, 3, 2), row(sourceB, 0, 2, 3)])
        let url = root.appendingPathComponent("complete-transcript.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: url)
        return (root, project, url, catalog)
    }

    @Test func importsExactCatalogWithoutTouchingOriginalAndDeduplicates() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: input), repo = TranscriptReviewRepository()
        let session = try await repo.importCatalog(input, project: project)
        #expect(session.keptCount == 3)
        #expect(session.state.rowOrder == catalog.rows.map(\.id))
        #expect(session.state.catalogSHA256 == hash(bytes))
        let snapshot = project.folder.appendingPathComponent("notes/transcript-review/\(session.state.reviewID)/source.json")
        #expect(try Data(contentsOf: snapshot) == bytes)
        #expect(try Data(contentsOf: input) == bytes)
        #expect(try await repo.importCatalog(input, project: project).state.revisionID == session.state.revisionID)
        #expect(try await repo.load(project: project)?.state.revisionID == session.state.revisionID)
    }

    @Test func reorderExclusionAndAnnotationsSurviveReopenAndExport() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = TranscriptReviewRepository(), baseline = try await repo.importCatalog(input, project: project)
        var draft = baseline
        try draft.state.move(catalog.rows[2].id, to: 2) // Return to A after B; not representable as whole-clip order.
        draft.state.decisions[catalog.rows[0].id]!.keep = false
        draft.state.decisions[catalog.rows[0].id]!.comment = "Requested wording belongs here, never in speech."
        draft.state.decisions[catalog.rows[0].id]!.graphicRequest = "A requested title."
        draft.state.decisions[catalog.rows[0].id]!.handwritingReference = "Local artwork reference"
        let saved = try await repo.save(draft, expectedRevision: baseline.state.revisionID, project: project)
        let reopened = try #require(try await TranscriptReviewRepository().load(project: project))
        #expect(reopened.state.rowOrder == [catalog.rows[0].id, catalog.rows[2].id, catalog.rows[1].id])
        #expect(reopened.state.decisions == saved.state.decisions)
        #expect(reopened.catalog.rows[0].text == catalog.rows[0].text)
        let exported = try await repo.export(expectedRevision: saved.state.revisionID, project: project)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: exported)) as? [String: Any])
        let all = try #require(json["all_row_annotations"] as? [[String: Any]])
        let selected = try #require(json["ordered_selected_rows"] as? [[String: Any]])
        #expect(all.count == 3 && selected.count == 2)
        #expect(all[0]["keep"] as? Bool == false)
        #expect(all[0]["text"] as? String == catalog.rows[0].text)
        #expect(all[0]["Katie_notes"] as? String == draft.state.decisions[catalog.rows[0].id]!.comment)
        #expect(all[0]["Katie_requested_graphics"] as? String == "A requested title.")
        #expect(all[0]["assistant_graphic_suggestions"] as? String == catalog.rows[0].assistantGraphics)
        #expect(selected.map { $0["id"] as? String } == [catalog.rows[2].id, catalog.rows[1].id])
        #expect(json["source_bounds_review_required"] as? [String] == [catalog.rows[2].id])
        #expect(json["human_identity_or_final_approval_asserted"] as? Bool == false)
        #expect(json["applied_to_cut"] as? Bool == false)
        #expect(try await repo.export(expectedRevision: saved.state.revisionID, project: project) != exported)
    }

    @Test func undoKeepsEveryCheckpointAndWalksBackThroughEdits() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = TranscriptReviewRepository(), baseline = try await repo.importCatalog(input, project: project)
        var draft = baseline; draft.state.decisions[catalog.rows[0].id]!.keep = false
        let first = try await repo.save(draft, expectedRevision: baseline.state.revisionID, project: project)
        draft = first; try draft.state.move(catalog.rows[2].id, to: 1)
        let second = try await repo.save(draft, expectedRevision: first.state.revisionID, project: project)
        let preserved = project.folder.appendingPathComponent("notes/transcript-review/\(second.state.reviewID)/revision-\(second.state.revisionID).json")
        let secondBytes = try Data(contentsOf: preserved)
        let backOne = try await repo.undo(expectedRevision: second.state.revisionID, project: project)
        #expect(backOne.state.rowOrder == first.state.rowOrder)
        #expect(backOne.state.decisions == first.state.decisions)
        let backTwo = try await repo.undo(expectedRevision: backOne.state.revisionID, project: project)
        #expect(backTwo.state.decisions == baseline.state.decisions)
        #expect(backTwo.state.undoTargetRevisionID == nil)
        #expect(backTwo.state.revisionNumber == 4)
        #expect(try Data(contentsOf: preserved) == secondBytes)
    }

    @Test func staleWriterCannotOverwriteAnotherWindowAndDraftCopyDoesNotActivate() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = TranscriptReviewRepository(), baseline = try await repo.importCatalog(input, project: project)
        var first = baseline; first.state.decisions[catalog.rows[0].id]!.comment = "First writer"
        let saved = try await repo.save(first, expectedRevision: baseline.state.revisionID, project: project)
        var stale = baseline; stale.state.decisions[catalog.rows[0].id]!.comment = "Second writer"
        await #expect(throws: WorkflowFailure.self) { try await TranscriptReviewRepository().save(stale, expectedRevision: baseline.state.revisionID, project: project) }
        let backup = try await repo.saveDraftCopy(stale, project: project)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try await repo.load(project: project)?.state.revisionID == saved.state.revisionID)
    }

    @Test func changedCatalogBytesCannotSilentlyRebindStableRows() async throws {
        let (root, project, input, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = TranscriptReviewRepository(), baseline = try await repo.importCatalog(input, project: project)
        let original = try Data(contentsOf: input)
        let owned = project.folder.appendingPathComponent("notes/transcript-review/\(baseline.state.reviewID)/source.json")
        try (original + Data(" ".utf8)).write(to: owned)
        await #expect(throws: WorkflowFailure.self) { try await repo.load(project: project) }
        await #expect(throws: WorkflowFailure.self) { try await repo.importCatalog(input, project: project) }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func tamperedHistoricalCheckpointCannotBeUndone() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = TranscriptReviewRepository(), baseline = try await repo.importCatalog(input, project: project)
        var draft = baseline; draft.state.decisions[catalog.rows[0].id]!.keep = false
        let saved = try await repo.save(draft, expectedRevision: baseline.state.revisionID, project: project)
        let earlier = project.folder.appendingPathComponent("notes/transcript-review/\(baseline.state.reviewID)/revision-\(baseline.state.revisionID).json")
        try Data("{}".utf8).write(to: earlier)
        await #expect(throws: WorkflowFailure.self) { try await repo.undo(expectedRevision: saved.state.revisionID, project: project) }
        #expect(try await repo.load(project: project)?.state.revisionID == saved.state.revisionID)
    }

    @Test func invalidCatalogRowsAndAmbiguousKeysAreRejectedBeforePublication() async throws {
        let (root, project, input, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: input)
        let object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for operation in 0..<4 {
            var damaged = object
            var rows = try #require(damaged["rows"] as? [[String: Any]])
            switch operation {
            case 0: rows[0]["text"] = "Invented speech."
            case 1: rows.removeLast()
            case 2: rows[1]["id"] = rows[0]["id"]
            default: rows[0]["source_sha256"] = String(repeating: "0", count: 64)
            }
            damaged["rows"] = rows
            try JSONSerialization.data(withJSONObject: damaged).write(to: input)
            await #expect(throws: WorkflowFailure.self) { try await TranscriptReviewRepository().importCatalog(input, project: project) }
        }
        let text = String(decoding: original, as: UTF8.self)
        for key in ["schema_version", "schema_\\u0076ersion"] {
            try Data(("{\"" + key + "\":1," + text.dropFirst()).utf8).write(to: input)
            await #expect(throws: WorkflowFailure.self) { try await TranscriptReviewRepository().importCatalog(input, project: project) }
        }
        #expect(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent(".clauto/transcript-review.json").path))
    }

    @Test func cannotDeleteRowDecisionsOrMoveToAnInvalidPosition() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = TranscriptReviewRepository(), baseline = try await repo.importCatalog(input, project: project)
        var draft = baseline; draft.state.decisions.removeValue(forKey: catalog.rows[0].id)
        await #expect(throws: WorkflowFailure.self) { try await repo.save(draft, expectedRevision: baseline.state.revisionID, project: project) }
        draft = baseline
        #expect(throws: WorkflowFailure.self) { try draft.state.move(catalog.rows[0].id, to: 0) }
        #expect(draft.state.rowOrder == baseline.state.rowOrder)
        for id in draft.state.rowOrder { draft.state.decisions[id]!.keep = false }
        let saved = try await repo.save(draft, expectedRevision: baseline.state.revisionID, project: project)
        #expect(saved.keptCount == 0 && saved.state.rowOrder.count == 3)
        #expect(saved.selectedBoundsIssues.isEmpty)
    }

    @Test func noteDirectoryEscapeWritesNothingOutsideProject() async throws {
        let (root, project, input, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let notes = project.folder.appendingPathComponent("notes")
        try FileManager.default.removeItem(at: notes)
        try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: outside)
        await #expect(throws: ProjectFailure.self) { try await TranscriptReviewRepository().importCatalog(input, project: project) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func filtersRetainSourceIDsAndGlobalStoryPositions() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var session = try await TranscriptReviewRepository().importCatalog(input, project: project)
        try session.state.move(catalog.rows[2].id, to: 2)
        session.state.decisions[catalog.rows[0].id]!.keep = false
        session.state.decisions[catalog.rows[1].id]!.comment = "Special review comment"
        let kept = TranscriptDisplayRow.make(session: session, query: "", scope: .kept)
        #expect(kept.map(\.id) == [catalog.rows[2].id, catalog.rows[1].id])
        #expect(kept.map(\.position) == [2, 3])
        #expect(TranscriptDisplayRow.make(session: session, query: "Special", scope: .all).first?.id == catalog.rows[1].id)
        #expect(TranscriptDisplayRow.make(session: session, query: "clip_b", scope: .all).first?.id == catalog.rows[2].id)
    }

    @Test func oversizedChoicesCannotPublishAnUnreadableHeadOrBackup() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = TranscriptReviewRepository(), initial = try await repo.importCatalog(input, project: project)
        let pointer = project.folder.appendingPathComponent(".clauto/transcript-review.json")
        let originalHead = try Data(contentsOf: pointer)
        var draft = initial
        draft.state.decisions[catalog.rows[0].id]!.comment = String(repeating: "x", count: 65 * 1024 * 1024)
        await #expect(throws: WorkflowFailure.self) { try await repo.save(draft, expectedRevision: initial.state.revisionID, project: project) }
        await #expect(throws: WorkflowFailure.self) { try await repo.saveDraftCopy(draft, project: project) }
        #expect(try Data(contentsOf: pointer) == originalHead)
        #expect(try await repo.load(project: project)?.state.revisionID == initial.state.revisionID)
    }

    @Test func backwardsWordTimingIsRefusedAndTerminalOverrunRemainsFlagged() async throws {
        let (root, project, input, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: input)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var sources = try #require(object["sources"] as? [[String: Any]])
        var words = try #require(sources[0]["words"] as? [[String: Any]])
        words[0]["start"] = 2.0; words[0]["end"] = 2.2
        words[1]["start"] = 0.1; words[1]["end"] = 0.3
        sources[0]["words"] = words; object["sources"] = sources
        var rows = try #require(object["rows"] as? [[String: Any]])
        rows[0]["start"] = 2.0; object["rows"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: input)
        await #expect(throws: WorkflowFailure.self) { try await TranscriptReviewRepository().importCatalog(input, project: project) }
        try original.write(to: input)
        let session = try await TranscriptReviewRepository().importCatalog(input, project: project)
        #expect(session.selectedBoundsIssues.count == 1)
        #expect(session.catalog.sources[1].words.last!.end > session.catalog.sources[1].duration)
    }

    @Test @MainActor func queuedControllerEditsCaptureTheirProjectAndPersistLatestNotes() async throws {
        let (rootA, projectA, inputA, catalogA) = try await fixture()
        let (rootB, projectB, inputB, catalogB) = try await fixture()
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let a = TranscriptReviewController(project: projectA), b = TranscriptReviewController(project: projectB)
        await a.importCatalog(inputA); await b.importCatalog(inputB)
        a.change(catalogA.rows[0].id) { $0.comment = "First" }
        a.change(catalogA.rows[0].id) { $0.comment = "Latest project A comment"; $0.graphicRequest = "A's graphic" }
        b.change(catalogB.rows[0].id) { $0.comment = "Project B comment" }
        a.move(catalogA.rows[2].id, to: 1)
        #expect(await a.flush()); #expect(await b.flush())
        let savedA = try #require(try await TranscriptReviewRepository().load(project: projectA))
        let savedB = try #require(try await TranscriptReviewRepository().load(project: projectB))
        #expect(savedA.state.decisions[catalogA.rows[0].id]?.comment == "Latest project A comment")
        #expect(savedB.state.decisions[catalogB.rows[0].id]?.comment == "Project B comment")
        #expect(savedA.state.rowOrder.first == catalogA.rows[2].id)
        #expect(savedB.state.rowOrder == catalogB.rows.map(\.id))
    }

    @Test @MainActor func controllerConflictPreservesDraftBeforeReload() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = TranscriptReviewController(project: project), second = TranscriptReviewController(project: project)
        await first.importCatalog(input); await second.load()
        first.change(catalog.rows[0].id) { $0.comment = "Saved by first" }
        #expect(await first.flush())
        second.change(catalog.rows[0].id) { $0.comment = "Pending second draft" }
        #expect(await second.flush() == false)
        #expect(second.dirty && second.failure != nil)
        await second.saveDraftAndReload()
        let backup = try #require(second.recoveredDraftURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let preserved = try decoder.decode(TranscriptReviewState.self, from: Data(contentsOf: backup))
        #expect(preserved.decisions[catalog.rows[0].id]?.comment == "Pending second draft")
        #expect(second.session?.state.decisions[catalog.rows[0].id]?.comment == "Saved by first")
        #expect(second.dirty == false)
    }

    @Test @MainActor func exitFlushWaitsForPendingReviewChoices() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = TranscriptReviewController(project: project)
        await controller.importCatalog(input)
        controller.change(catalog.rows[0].id) { $0.comment = "Written immediately before quit" }
        #expect(controller.dirty)
        #expect(await TranscriptReviewExit.flush([controller]))
        let saved = try #require(try await TranscriptReviewRepository().load(project: project))
        #expect(saved.state.decisions[catalog.rows[0].id]?.comment == "Written immediately before quit")
        #expect(!controller.dirty && !controller.saving)
    }

    @Test @MainActor func exitRefusesUnsavedConflictButIgnoresAReadOnlyLoadError() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = TranscriptReviewController(project: project), stale = TranscriptReviewController(project: project)
        await first.importCatalog(input); await stale.load()
        first.change(catalog.rows[0].id) { $0.comment = "First writer" }
        #expect(await first.flush())
        stale.change(catalog.rows[0].id) { $0.comment = "Unsaved second writer" }
        #expect(await TranscriptReviewExit.flush([stale]) == false)
        #expect(stale.dirty)
        let readonly = TranscriptReviewController(project: project)
        readonly.failure = "Import was refused; there are no unsaved choices."
        #expect(await TranscriptReviewExit.flush([readonly]))
    }

    private func largeSyntheticCatalog(_ input: URL) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any])
        var rows = try #require(object["rows"] as? [[String: Any]])
        rows[0]["notes"] = String(repeating: "x", count: 2 * 1024 * 1024)
        object["rows"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: input)
    }

    @Test @MainActor func actualInFlightAutosaveRetainsLaterCommentKeepAndGraphicRequest() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try largeSyntheticCatalog(input)
        let controller = TranscriptReviewController(project: project)
        await controller.importCatalog(input)
        controller.change(catalog.rows[0].id) { $0.comment = "Submitted first" }
        let deadline = ContinuousClock.now + .seconds(5)
        while !controller.saving && ContinuousClock.now < deadline { await Task.yield() }
        try #require(controller.saving)
        controller.change(catalog.rows[0].id) { $0.comment = "Arrived during I/O"; $0.keep = false; $0.graphicRequest = "Later graphic request" }
        #expect(await controller.flush())
        let saved = try #require(try await TranscriptReviewRepository().load(project: project))
        #expect(saved.state.decisions[catalog.rows[0].id]?.comment == "Arrived during I/O")
        #expect(saved.state.decisions[catalog.rows[0].id]?.keep == false)
        #expect(saved.state.decisions[catalog.rows[0].id]?.graphicRequest == "Later graphic request")
        #expect(saved.state.revisionNumber == 2)
    }

    @Test @MainActor func exitWaitsForAnInFlightUndo() async throws {
        let (root, project, input, catalog) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try largeSyntheticCatalog(input)
        let controller = TranscriptReviewController(project: project)
        await controller.importCatalog(input)
        controller.change(catalog.rows[0].id) { $0.keep = false }
        #expect(await controller.flush())
        let undo = Task { await controller.undo() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !controller.loading && ContinuousClock.now < deadline { await Task.yield() }
        try #require(controller.loading)
        #expect(await TranscriptReviewExit.flush([controller]))
        #expect(controller.loading == false)
        await undo.value
        let saved = try #require(try await TranscriptReviewRepository().load(project: project))
        #expect(saved.state.decisions[catalog.rows[0].id]?.keep == true)
        #expect(saved.state.revisionNumber == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUTO_TRANSCRIPT_CATALOG"] != nil))
    func actualSavedCatalogLocalAcceptanceWithoutSheetOrMediaWrites() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(env["CLAUTO_TRANSCRIPT_CATALOG"]))
        let root = URL(fileURLWithPath: try #require(env["CLAUTO_TRANSCRIPT_ACCEPTANCE_ROOT"]))
        let engine = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let original = try Data(contentsOf: input), before = hash(original)
        let project = try await ProjectRepository().create(name: "Local QA transcript review", root: root, engine: engine)
        let repo = TranscriptReviewRepository(), initial = try await repo.importCatalog(input, project: project)
        #expect(initial.catalog.sources.count == 27)
        #expect(initial.catalog.rows.count == 914)
        #expect(initial.catalog.sources.reduce(0) { $0 + $1.words.count } == 11_900)
        var draft = initial
        let first = draft.state.rowOrder[0], last = try #require(draft.state.rowOrder.last)
        try draft.state.move(last, to: 1)
        draft.state.decisions[first]!.comment = "Synthetic QA comment — not Katie's selection."
        draft.state.decisions[first]!.graphicRequest = "Synthetic QA graphic request — not artwork approval."
        for id in draft.selectedBoundsIssues { draft.state.decisions[id]!.keep = false }
        let saved = try await repo.save(draft, expectedRevision: initial.state.revisionID, project: project)
        let reopened = try #require(try await TranscriptReviewRepository().load(project: project))
        #expect(reopened.state.rowOrder.first == last)
        #expect(reopened.state.decisions == saved.state.decisions)
        #expect(reopened.catalog.rows.map(\.text) == initial.catalog.rows.map(\.text))
        let selection = try await repo.export(expectedRevision: reopened.state.revisionID, project: project)
        let (map, mapURL) = try await repo.prepareSourceMap(expectedRevision: reopened.state.revisionID, project: project)
        #expect(map.spans.map(\.id) == reopened.state.rowOrder.filter { reopened.state.decisions[$0]!.keep })
        #expect(map.spans.allSatisfy { span in
            guard let row = reopened.rowsByID[span.id] else { return false }
            return span.sourceID == row.sourceID && span.sourceIn == row.start && span.sourceOut == row.end
        })
        #expect(map.reviewOnly && !map.appliedToCut)
        #expect(reopened.catalog.sources.allSatisfy { $0.originalTranscriptPath != nil })
        #expect(try await repo.currentSourceAcknowledgement(expectedRevision: reopened.state.revisionID, project: project) == nil)
        #expect(hash(try Data(contentsOf: input)) == before)
        let report: [String: Any] = ["project": project.folder.path, "catalog_sha256": before, "source_clips": 27,
            "rows": 914, "words": 11900, "source_catalog_unchanged": true, "row_order_and_notes_reopened": true,
            "selected_bounds_issues": reopened.selectedBoundsIssues, "selection_export": selection.path,
            "source_map": mapURL.path, "source_map_sha256": try map.sha256(), "source_map_spans": map.spans.count,
            "untrimmed_selection_seconds_not_cut_runtime": map.untrimmedSelectionSeconds,
            "source_map_original_coordinates_verified": true, "local_source_acknowledgement_recorded": false,
            "live_Sheet_accessed": false, "source_media_read_or_written": false, "cut_rendered_or_approved": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: project.folder.appendingPathComponent("TRANSCRIPT_ACCEPTANCE.json"), options: .withoutOverwriting)
        print("LOCAL_TRANSCRIPT_ACCEPTANCE=" + project.folder.path)
    }
}
