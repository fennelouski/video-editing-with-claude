import Foundation
import AVFoundation

enum SourceSpanRenderCheckpoint: Sendable { case inputFrozen, workerFinished, beforePublication }

struct SourceSpanRenderService: Sendable {
    var runner: any CommandRunning = ProcessRunner()
    var reviews = TranscriptReviewRepository()

    /// QA-only entry point. The factory-issued permit cannot be reconstructed from
    /// an imported JSON flag, and this service never writes cuts/current.json.
    func renderSyntheticReview(fixture: SyntheticSourceSpanFixture, expectedRevision: UUID, expectedAcknowledgementID: UUID,
        engine: URL, onCheckpoint: (@Sendable (SourceSpanRenderCheckpoint, URL) async throws -> Void)? = nil) async throws -> SyntheticSourceSpanRenderResult {
        let project = fixture.project
        let initial = try await reviews.syntheticRenderSnapshot(expectedRevision: expectedRevision, expectedAcknowledgementID: expectedAcknowledgementID, project: project)
        let bound = try await reviews.bound(expectedRevision: expectedRevision, project: project)
        let root = try fixture.validate(map: initial.map, catalog: bound.session.catalog)
        let metadata = try root.child(".clauto"), build = try root.child("build")
        let outputRoot = try build.child("source-span-reviews", create: true)
        let runID = UUID(), pendingName = ".pending-" + runID.uuidString
        let staging = try outputRoot.child(pendingName, create: true, exclusive: true)
        do {
            var media: [VerifiedSourceMedia] = []
            for source in bound.session.catalog.sources {
                // Early refusal only: the worker's actual media validation and
                // rendering both consume its bounded private byte snapshot.
                let verified = try await SourceMediaVerifier().verify(source)
                try verified.validate(source: source); media.append(verified)
            }
            let current = try await reviews.syntheticRenderSnapshot(expectedRevision: expectedRevision, expectedAcknowledgementID: expectedAcknowledgementID, project: project)
            guard current.map == initial.map, current.acknowledgementSHA256 == initial.acknowledgementSHA256 else { throw WorkflowFailure.invalid("The review acknowledgment changed while original media was being verified.") }
            let spans = try SourceSpanFrameGrid.compile(initial.map, media: media)
            let input = SourceSpanRenderInput(projectPath: root.url.path, projectIdentity: root.identity,
                stagingPath: staging.url.path, stagingIdentity: staging.identity, fixtureID: fixture.fixtureID,
                fixtureManifestPath: metadata.url.appendingPathComponent("source-span-synthetic-fixture.json").path,
                fixtureManifestSHA256: fixture.manifestSHA256, map: initial.map,
                acknowledgementID: initial.acknowledgement.id, acknowledgementSHA256: initial.acknowledgementSHA256,
                mapSHA256: try initial.map.sha256(), spans: spans)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(input), inputSHA = TranscriptSourceMap.sha(bytes)
            try staging.writeNew(bytes, name: "input.json")
            try staging.writeNew(initial.map.encoded(), name: "source-map.json")
            let script = engine.appendingPathComponent("scripts/render_transcript_spans.py")
            let workerSHA = TranscriptSourceMap.sha(try Data(contentsOf: script))
            try await onCheckpoint?(.inputFrozen, staging.url)
            try root.checkPath(); try staging.checkPath()
            for verified in media { try SourceMediaVerifier.checkCurrent(verified) }
            let result = try await runner.run(ProcessCommand(executable: engine.appendingPathComponent("run"),
                arguments: ["render_transcript_spans.py", "--render-synthetic", staging.url.appendingPathComponent("input.json").path, "--input-sha256", inputSHA,
                            "--input-directory-device", String(staging.identity.device), "--input-directory-inode", String(staging.identity.inode)],
                directory: engine, environment: ["CLAUTO_OFFLINE": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"], timeout: .seconds(120)), onLine: nil)
            guard result.succeeded else { throw WorkflowFailure.invalid(result.cancelled ? "Synthetic render cancelled; the previous current preview is preserved." : "Synthetic render failed; the previous current preview is preserved. " + result.output + result.error) }
            try await onCheckpoint?(.workerFinished, staging.url)
            try Task.checkCancellation()
            try root.checkPath(); try staging.checkPath()
            guard TranscriptSourceMap.sha(try Data(contentsOf: script)) == workerSHA else { throw WorkflowFailure.invalid("The deterministic render worker changed during this job.") }
            let proofBytes = try staging.read("render-proof.json")
            try TranscriptJSONKeys.validate(proofBytes)
            let proof = try JSONDecoder().decode(SourceSpanWorkerReceipt.self, from: proofBytes)
            let frames = spans.reduce(0) { $0 + $1.frames }
            guard proof.schemaVersion == 1, proof.purpose == "synthetic_source_span_acceptance", !proof.productionAuthorized,
                proof.inputSHA256 == inputSHA, proof.fixtureID == fixture.fixtureID, proof.mapSHA256 == (try initial.map.sha256()),
                proof.acknowledgementID == initial.acknowledgement.id, proof.acknowledgementSHA256 == initial.acknowledgementSHA256,
                proof.spans == spans, proof.totalFrames == frames, proof.audioSamples == frames * SourceSpanFrameGrid.samplesPerFrame,
                proof.fullDecodePassed, Set(proof.artifactsSHA256.keys) == ["review.mov", "timeline.fcpxml"] else {
                throw WorkflowFailure.invalid("The synthetic render receipt does not match the frozen stable-ID selections.")
            }
            guard proof.sourceByteStrategy == SyntheticSourceByteContract.strategy,
                proof.sourceBytes.count == 2,
                Set(proof.sourceBytes.keys) == Set(fixture.manifest.sources.map(\.sourceID)),
                proof.sourceBytes.values.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= SyntheticSourceByteContract.sourceLimit }),
                proof.sourceBytes.values.reduce(0, { $0 + $1.byteCount }) <= SyntheticSourceByteContract.jobLimit else {
                throw WorkflowFailure.invalid("The synthetic source-byte transport is missing or exceeds its job limit.")
            }
            for source in fixture.manifest.sources {
                guard let bytes = proof.sourceBytes[source.sourceID], let checked = media.first(where: { $0.sourceID == source.sourceID }),
                    bytes.sha256 == source.sourceSHA256, bytes.byteCount > 0, bytes.byteCount <= SyntheticSourceByteContract.sourceLimit,
                    Int64(bytes.byteCount) == checked.signature.size, bytes.readOnly, bytes.unlinked else {
                    throw WorkflowFailure.invalid("The render did not validate and consume the exact private synthetic source bytes.")
                }
            }
            for name in ["review.mov", "timeline.fcpxml"] {
                guard TranscriptSourceMap.sha(try staging.read(name)) == proof.artifactsSHA256[name] else { throw WorkflowFailure.invalid("A required rendered artifact is missing or changed.") }
            }
            try validateTimeline(staging.read("timeline.fcpxml"), spans: spans, fixture: fixture)
            let duration = try await SourceMediaVerifier.asset(at: staging.url.appendingPathComponent("review.mov")).load(.duration).seconds
            guard duration.isFinite, abs(duration - Double(frames * 1001) / 24000) <= 1.0 / 48000 else { throw WorkflowFailure.invalid("The actual synthetic preview duration differs from the frame/sample plan.") }
            for verified in media { try SourceMediaVerifier.checkCurrent(verified) }
            try await onCheckpoint?(.beforePublication, staging.url)
            return try await reviews.commitSyntheticRender(initial, project: project, fixture: fixture, root: root,
                metadata: metadata, outputRoot: outputRoot, staging: staging, pendingName: pendingName, runID: runID,
                inputSHA256: inputSHA, proof: proof, proofSHA256: TranscriptSourceMap.sha(proofBytes))
        } catch {
            // Descriptor-relative exclusive evidence only. Never recursively delete
            // a path that could have been swapped into somebody else's directory.
            let failure = try? JSONSerialization.data(withJSONObject: ["state": "incomplete", "production_authorized": false,
                "applied_to_cut": false, "detail": error.localizedDescription], options: [.sortedKeys])
            if let failure { try? staging.writeNew(failure, name: "failure.json") }
            throw error
        }
    }

    private func validateTimeline(_ data: Data, spans: [RenderedSourceSpan], fixture: SyntheticSourceSpanFixture) throws {
        let doc = try XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever)
        guard doc.rootElement()?.name == "fcpxml", doc.rootElement()?.attribute(forName: "version")?.stringValue == "1.13" else { throw ProjectFailure.invalidProject }
        func elements(_ node: XMLNode) -> [XMLElement] { (node.children ?? []).compactMap { $0 as? XMLElement } }
        func attributes(_ element: XMLElement) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (element.attributes ?? []).map { ($0.name ?? "", $0.stringValue ?? "") })
        }
        guard let root = doc.rootElement(), attributes(root) == ["version": "1.13"] else { throw ProjectFailure.invalidProject }
        let top = elements(root)
        guard top.count == 2, top[0].name == "resources", top[1].name == "library",
              attributes(top[0]).isEmpty, attributes(top[1]).isEmpty else { throw ProjectFailure.invalidProject }
        let resources = elements(top[0])
        guard resources.count == fixture.manifest.sources.count + 1, resources[0].name == "format",
              attributes(resources[0]) == ["id": "rFormat", "frameDuration": "1001/24000s", "width": "160", "height": "90", "colorSpace": "1-1-1 (Rec. 709)"],
              elements(resources[0]).isEmpty else { throw ProjectFailure.invalidProject }
        var refs: [String: String] = [:]
        for asset in resources.dropFirst() {
            guard asset.name == "asset", let ref = asset.attribute(forName: "id")?.stringValue, refs[ref] == nil,
                let id = asset.attribute(forName: "name")?.stringValue,
                let source = fixture.manifest.sources.first(where: { $0.sourceID == id }), !refs.values.contains(id),
                attributes(asset) == ["id": ref, "name": id, "start": "0s", "duration": "3003/1000s", "hasVideo": "1", "hasAudio": "1", "format": "rFormat", "audioSources": "1", "audioChannels": "1", "audioRate": "48000"] else { throw ProjectFailure.invalidProject }
            let reps = elements(asset)
            guard reps.count == 1, reps[0].name == "media-rep", elements(reps[0]).isEmpty,
                Set(attributes(reps[0]).keys) == ["kind", "src"], reps[0].attribute(forName: "kind")?.stringValue == "original-media",
                let uri = reps[0].attribute(forName: "src")?.stringValue,
                URL(string: uri) == fixture.project.folder.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(source.mediaRelativePath) else { throw ProjectFailure.invalidProject }
            refs[ref] = id
        }
        let events = elements(top[1])
        guard events.count == 1, events[0].name == "event", attributes(events[0]) == ["name": "Synthetic source-span QA"] else { throw ProjectFailure.invalidProject }
        let projects = elements(events[0])
        guard projects.count == 1, projects[0].name == "project", attributes(projects[0]) == ["name": "Synthetic source review"] else { throw ProjectFailure.invalidProject }
        let sequences = elements(projects[0])
        guard sequences.count == 1, sequences[0].name == "sequence",
            Set(attributes(sequences[0]).keys) == ["format", "duration", "tcStart", "tcFormat", "audioLayout", "audioRate"],
            sequences[0].attribute(forName: "format")?.stringValue == "rFormat",
            sequences[0].attribute(forName: "tcStart")?.stringValue == "0s", sequences[0].attribute(forName: "tcFormat")?.stringValue == "NDF",
            sequences[0].attribute(forName: "audioLayout")?.stringValue == "mono", sequences[0].attribute(forName: "audioRate")?.stringValue == "48k",
            try frames(sequences[0].attribute(forName: "duration")?.stringValue) == spans.reduce(0, { $0 + $1.frames }) else { throw ProjectFailure.invalidProject }
        let spines = elements(sequences[0])
        guard spines.count == 1, spines[0].name == "spine", attributes(spines[0]).isEmpty else { throw ProjectFailure.invalidProject }
        let clips = elements(spines[0])
        guard clips.count == spans.count else { throw ProjectFailure.invalidProject }
        for (clip, span) in zip(clips, spans) {
            guard clip.name == "asset-clip", elements(clip).isEmpty,
                Set(attributes(clip).keys) == ["name", "ref", "offset", "start", "duration", "audioRole"],
                clip.attribute(forName: "audioRole")?.stringValue == "dialogue", clip.attribute(forName: "name")?.stringValue == span.id,
                clip.attribute(forName: "ref").flatMap({ refs[$0.stringValue ?? ""] }) == span.sourceID,
                try frames(clip.attribute(forName: "start")?.stringValue) == span.startFrame,
                try frames(clip.attribute(forName: "duration")?.stringValue) == span.frames,
                try frames(clip.attribute(forName: "offset")?.stringValue) == span.timelineFrame else { throw ProjectFailure.invalidProject }
        }
    }

    private func frames(_ text: String?) throws -> Int {
        guard let text, text.hasSuffix("s") else { throw ProjectFailure.invalidProject }
        let parts = text.dropLast().split(separator: "/")
        guard (1...2).contains(parts.count), let num = Double(parts[0]), let den = parts.count == 2 ? Double(parts[1]) : 1,
              num.isFinite, den.isFinite, den > 0 else { throw ProjectFailure.invalidProject }
        let value = num / den * 24000 / 1001
        guard value >= 0, value < Double(Int.max), abs(value - value.rounded()) <= 0.0000001 else { throw ProjectFailure.invalidProject }
        return Int(value.rounded())
    }
}
