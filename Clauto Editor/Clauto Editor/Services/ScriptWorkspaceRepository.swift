import Foundation

struct ScriptWorkspaceSession: Sendable {
    let project: Project
    let catalog: TranscriptCatalog
    var state: ScriptWorkspaceState
    var missingSources: [ProjectFile] { ScriptSourceInventory.missing(project, catalog: catalog) }
    var coverageComplete: Bool { state.coverageComplete(catalog: catalog, missing: missingSources) }
}

/// A separate, immutable assembly package. It references original media and
/// carries both requested word times and outward-rounded integer frame bounds.
/// No current-cut pointer, existing timeline, or media bytes are changed.
struct ScriptTimelineHandoff: Codable, Sendable {
    let schemaVersion: Int
    let projectID: UUID
    let workspaceID: UUID
    let versionID: UUID
    let revisionID: UUID
    let scriptSHA256: String
    let catalogSHA256: String
    let coverageSHA256: String
    let frameDurationNumerator: Int
    let frameDurationDenominator: Int
    let spans: [RenderedSourceSpan]
    let sources: [TranscriptSourceSpan]
    let approval: ScriptApproval
    let media: [VerifiedSourceMedia]
    let reviewOnly: Bool
    let appliedToCut: Bool
    let productionAuthorized: Bool
}

actor ScriptWorkspaceRepository {
    private struct Head: Codable { let revisionID: UUID; let sha256: String }
    private let transcriptRepository = TranscriptReviewRepository()
    private let projectRepository = ProjectRepository()

    func load(project: Project) async throws -> ScriptWorkspaceSession? {
        let fresh = try await projectRepository.open(project.folder)
        try requireSame(project, fresh)
        guard let transcript = try await transcriptRepository.load(project: fresh) else { return nil }
        let lease = try ProjectMutationLease.acquire(fresh); defer { withExtendedLifetime(lease) {} }
        let session = try read(project: fresh, transcript: transcript, root: lease.root)
        if !(try CreativeAssetFiles.exists("script-workspace.json", in: lease.root.child(".clauto"))) {
            try publish(session.state, root: lease.root)
        }
        return session
    }

    /// Each user action is a transaction against an exact saved revision. Views
    /// cannot submit a replacement workspace that forges approvals or scores.
    func update(project: Project, expectedRevision: UUID?, action: ScriptWorkspaceAction) async throws -> ScriptWorkspaceSession {
        let fresh = try await projectRepository.open(project.folder); try requireSame(project, fresh)
        guard let transcript = try await transcriptRepository.load(project: fresh) else {
            throw WorkflowFailure.invalid("Import the complete source transcript catalog in Transcript before writing a script.")
        }
        let lease = try ProjectMutationLease.acquire(fresh); defer { withExtendedLifetime(lease) {} }
        var session = try read(project: fresh, transcript: transcript, root: lease.root)
        let metadata = try lease.root.child(".clauto", create: true)
        let exists = try CreativeAssetFiles.exists("script-workspace.json", in: metadata)
        guard expectedRevision == session.state.revisionID || (!exists && expectedRevision == nil) else {
            throw WorkflowFailure.invalid("Another window changed this script workspace. Reload before retrying; its saved versions are preserved.")
        }
        try action.apply(to: &session)
        try session.state.validate(catalog: session.catalog, projectID: fresh.id)
        session.state.revisionID = UUID()
        try publish(session.state, root: lease.root)
        return session
    }

    private func read(project: Project, transcript: TranscriptReviewSession, root: SourceRenderDirectory) throws -> ScriptWorkspaceSession {
        let metadata = try root.child(".clauto")
        var state: ScriptWorkspaceState
        if try CreativeAssetFiles.exists("script-workspace.json", in: metadata) {
            let head = try CreativeAssetFiles.decode(metadata.read("script-workspace.json", limit: 16_384), as: Head.self)
            let bytes = try metadata.child("script-workspace").child(head.revisionID.uuidString).read("workspace.json")
            guard TranscriptSourceMap.sha(bytes) == head.sha256 else { throw ProjectFailure.invalidProject }
            state = try CreativeAssetFiles.decode(bytes, as: ScriptWorkspaceState.self)
            guard state.revisionID == head.revisionID, state.catalogSHA256 == transcript.state.catalogSHA256 else {
                throw WorkflowFailure.invalid("The script's transcript catalog changed. Its prior drafts remain saved; restore that catalog before continuing.")
            }
            let inventory = try ScriptSourceInventory.sha(project)
            if state.inventorySHA256 != inventory {
                state.inventorySHA256 = inventory; state.nonTranscriptDispositions = [:]
                state.reviewedRowIDs = []; state.invalidateApprovals()
                // A locked comparison remains historical and stale. An unfinished
                // one is cancelled so changed source coverage can be reviewed.
                if state.reviewInProgress { state.comparison = nil }
            }
        } else {
            guard !(try CreativeAssetFiles.exists("script-workspace-required.json", in: metadata)) else {
                throw WorkflowFailure.invalid("This script workspace's current checkpoint is missing. Its saved revisions are preserved; restore its metadata before continuing.")
            }
            state = .init(projectID: project.id, catalogSHA256: transcript.state.catalogSHA256, inventorySHA256: try ScriptSourceInventory.sha(project))
        }
        try state.validate(catalog: transcript.catalog, projectID: project.id)
        return .init(project: project, catalog: transcript.catalog, state: state)
    }

    private func publish(_ state: ScriptWorkspaceState, root: SourceRenderDirectory) throws {
        let metadata = try root.child(".clauto", create: true)
        if !(try CreativeAssetFiles.exists("script-workspace-required.json", in: metadata)) {
            try metadata.writeNew(Data("{\"script_first_review_required\":true}".utf8), name: "script-workspace-required.json")
        }
        let bytes = try CreativeAssetFiles.encoder().encode(state)
        let parent = try metadata.child("script-workspace", create: true)
        _ = try CreativeAssetFiles.publish(["workspace.json": bytes], to: state.revisionID, in: parent)
        try root.checkPath(); try metadata.checkPath()
        try metadata.replacePointer(CreativeAssetFiles.encoder().encode(Head(revisionID: state.revisionID, sha256: TranscriptSourceMap.sha(bytes))), name: "script-workspace.json")
    }

    /// A local writer packet is a real interchange, not a simulated AI result.
    /// The caller may use any authorized writer and import its source-bound JSON.
    func exportWriterPacket(project: Project, expectedRevision: UUID) async throws -> URL {
        guard let session = try await load(project: project), session.state.revisionID == expectedRevision, session.coverageComplete else {
            throw WorkflowFailure.invalid("Review the complete source transcript and uncovered media before exporting a writer packet.")
        }
        let prompt = """
        Write an independent script using only these recorded transcript passages. Return JSON with schema_version:1, title, sections:[{title,segments:[{source_id,source_sha256,transcript_sha256,first_word,last_word,spoken_text}]}], pickups:[{id,description}].
        Every recorded segment must match one entire catalog row and its exact spoken text. Order rows into a story. Do not rewrite recorded speech, invent footage, scientific claims, or padding. Put all proposed new wording in pickups. Read every supplied source before drafting. List uncertain facts separately in your response notes for human review. Do not include your author or model name in the script text; preserve it separately for private provenance. No timeline work is authorized by this packet.
        """
        return try await exportFiles(["transcript-catalog.json": JSONEncoder().encode(session.catalog),
            "engine-sources.json": ScriptInterchange.exportSources(session.catalog), "writer-instructions.txt": Data(prompt.utf8)], session: session)
    }

    func assemble(project: Project, expectedRevision: UUID, versionID: UUID) async throws -> URL {
        guard let initial = try await load(project: project), initial.state.revisionID == expectedRevision,
              let version = initial.state.versions.first(where: { $0.id == versionID }), initial.state.approvalCurrent(version), initial.coverageComplete else {
            throw WorkflowFailure.invalid("Approve the current script after full-source review before preparing an assembly candidate.")
        }
        guard !version.beats.contains(where: { $0.kind == .pickup }) else {
            throw WorkflowFailure.invalid("This approved script still contains unrecorded pickups. Record and transcribe them, or remove them in a new script revision and approve again.")
        }
        let map = try sourceMap(version, session: initial)
        var verified: [VerifiedSourceMedia] = []
        // Bind even unused transcript sources. A changed all-source input cannot
        // silently retain an approval just because its words were not selected.
        for source in initial.catalog.sources {
            verified.append(try await SourceMediaVerifier().verify(source))
        }
        let frames = try SourceSpanFrameGrid.compile(map, media: verified)
        let handoff = ScriptTimelineHandoff(schemaVersion: 1, projectID: project.id, workspaceID: initial.state.id,
            versionID: version.id, revisionID: version.revisionID, scriptSHA256: try version.contentSHA256(),
            catalogSHA256: initial.state.catalogSHA256, coverageSHA256: try initial.state.coverageSHA256(),
            frameDurationNumerator: 1001, frameDurationDenominator: 24000, spans: frames, sources: map.spans,
            approval: version.approval!, media: verified, reviewOnly: true, appliedToCut: false, productionAuthorized: false)
        let engineScript = try scriptInterchange(version, catalog: initial.catalog)
        let xml = try await ScriptAssemblyXML.make(handoff, title: version.title, project: initial.project)
        return try await exportFiles(["script-handoff.json": CreativeAssetFiles.encoder().encode(handoff),
            "source-map.json": map.encoded(), "engine-script.json": engineScript, "engine-sources.json": ScriptInterchange.exportSources(initial.catalog),
            "assembly.fcpxml": Data(xml.utf8)], session: initial, media: verified)
    }

    private func exportFiles(_ files: [String: Data], session: ScriptWorkspaceSession, media: [VerifiedSourceMedia] = []) async throws -> URL {
        let fresh = try await projectRepository.open(session.project.folder); try requireSame(session.project, fresh)
        guard let transcript = try await transcriptRepository.load(project: fresh) else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(fresh); defer { withExtendedLifetime(lease) {} }
        let latest = try read(project: fresh, transcript: transcript, root: lease.root)
        guard latest.state.revisionID == session.state.revisionID,
              (try latest.state.coverageSHA256()) == (try session.state.coverageSHA256()) else {
            throw WorkflowFailure.invalid("The script or source coverage changed while preparing this package. Reload and prepare the current revision.")
        }
        for value in media { try SourceMediaVerifier.checkCurrent(value) }
        let parent = try lease.root.child("script", create: true).child("workspace-exports", create: true)
        return try CreativeAssetFiles.publish(files, to: UUID(), in: parent).url
    }

    private func requireSame(_ expected: Project, _ current: Project) throws {
        guard ProjectPresentationState.sameRoot(expected, current) else { throw ProjectFailure.invalidProject }
    }

    func sourceMap(_ version: ScriptVersion, session: ScriptWorkspaceSession) throws -> TranscriptSourceMap {
        let selected = version.beats.compactMap(\.rowID)
        let selectedSet = Set(selected)
        let order = selected + session.catalog.rows.filter { !selectedSet.contains($0.id) }.map(\.id)
        let decisions = Dictionary(uniqueKeysWithValues: session.catalog.rows.map { row in
            var decision = TranscriptRowDecision(row: row); decision.keep = selectedSet.contains(row.id)
            return (row.id, decision)
        })
        let state = TranscriptReviewState(reviewID: session.state.id, projectID: session.project.id,
            catalogSHA256: session.state.catalogSHA256, revisionID: version.revisionID, rowOrder: order, decisions: decisions)
        return try TranscriptSourceMap.compile(.init(session: .init(catalog: session.catalog, state: state), revisionSHA256: version.contentSHA256()))
    }

    private func scriptInterchange(_ version: ScriptVersion, catalog: TranscriptCatalog) throws -> Data {
        try ScriptInterchange.exportVersion(version, catalog: catalog)
    }
}

enum ScriptWorkspaceAction: Sendable {
    case reviewed(String, Bool), disposition(UUID, String)
    case create(String, ScriptProvenance), duplicate(UUID, String), importScript(Data, ScriptProvenance, String)
    case addPassage(UUID, String), addPickup(UUID, String), editBeat(UUID, UUID, String, String, String), move(UUID, UUID, Int), remove(UUID, UUID), rename(UUID, String)
    case compare([UUID]), score(UUID, ScriptScore), lockScores, reveal, cancelComparison
    case approve(UUID, Bool)

    func apply(to session: inout ScriptWorkspaceSession) throws {
        switch self {
        case let .reviewed(row, reviewed):
            try session.state.requireEditing()
            guard session.catalog.rows.contains(where: { $0.id == row }) else { throw ProjectFailure.invalidProject }
            if reviewed { session.state.reviewedRowIDs.insert(row) } else { session.state.reviewedRowIDs.remove(row) }
            session.state.invalidateApprovals()
        case let .disposition(id, note):
            try session.state.requireEditing()
            guard session.missingSources.contains(where: { $0.id == id }), note.count <= 20_000 else { throw ProjectFailure.invalidProject }
            session.state.nonTranscriptDispositions[id] = note; session.state.invalidateApprovals()
        case let .create(title, provenance):
            try session.state.requireEditing(); try requireCoverage(session)
            session.state.versions.append(.init(title: title, provenance: provenance)); session.state.invalidateApprovals()
        case let .duplicate(id, title):
            try session.state.requireEditing(); try requireCoverage(session)
            guard let original = session.state.versions.first(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }
            session.state.versions.append(.init(title: title, provenance: .init(author: "Local editor", model: "", origin: "Explicit copy of a saved script"), basedOnVersionID: original.id, beats: original.beats))
            session.state.invalidateApprovals()
        case let .importScript(bytes, provenance, title):
            try session.state.requireEditing(); try requireCoverage(session)
            var version = try ScriptInterchange.importVersion(bytes, catalog: session.catalog, provenance: provenance)
            version.title = title; session.state.versions.append(version); session.state.invalidateApprovals()
        case let .addPassage(id, row):
            try requireCoverage(session)
            guard let source = session.catalog.rows.first(where: { $0.id == row }) else { throw ProjectFailure.invalidProject }
            try session.state.editVersion(id) { $0.beats.append(.init(kind: .passage, rowID: row, heading: source.section)) }
        case let .addPickup(id, text):
            try session.state.editVersion(id) { $0.beats.append(.init(kind: .pickup, heading: "Pickup", unrecordedText: text)) }
        case let .editBeat(id, beatID, heading, notes, text):
            try session.state.editVersion(id) { version in
                guard let i = version.beats.firstIndex(where: { $0.id == beatID }) else { throw ProjectFailure.invalidProject }
                version.beats[i].heading = heading; version.beats[i].notes = notes
                if version.beats[i].kind == .pickup { version.beats[i].unrecordedText = text }
            }
        case let .move(id, beatID, delta):
            try session.state.editVersion(id) { version in
                guard let i = version.beats.firstIndex(where: { $0.id == beatID }), version.beats.indices.contains(i + delta) else { return }
                version.beats.swapAt(i, i + delta)
            }
        case let .remove(id, beatID): try session.state.editVersion(id) { $0.beats.removeAll { $0.id == beatID } }
        case let .rename(id, title): try session.state.editVersion(id) { $0.title = title }
        case let .compare(ids): try requireCoverage(session); try session.state.startComparison(ids)
        case let .score(id, score): try session.state.score(id, score: score)
        case .lockScores: try session.state.lockScores()
        case .reveal: try session.state.revealAuthors()
        case .cancelComparison: session.state.comparison = nil; session.state.invalidateApprovals()
        case let .approve(id, facts): try session.state.approve(id, catalog: session.catalog, missing: session.missingSources, factsReviewed: facts)
        }
    }
    private func requireCoverage(_ session: ScriptWorkspaceSession) throws {
        guard session.coverageComplete else { throw WorkflowFailure.invalid("Review every source passage and record a disposition for uncovered media before drafting or comparing scripts.") }
    }
}
