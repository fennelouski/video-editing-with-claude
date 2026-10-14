import Foundation
import CryptoKit
import Darwin

actor TranscriptReviewRepository {
    private struct Head: Codable {
        var schemaVersion = 1
        var projectID: UUID
        var reviewID: UUID
        var revisionID: UUID
        var catalogSHA256: String
        var stateSHA256: String
    }
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .iso8601; return value
    }()
    private let decoder: JSONDecoder = {
        let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value
    }()

    func load(project: Project) throws -> TranscriptReviewSession? {
        try identity(project)
        guard fm.fileExists(atPath: try safe(".clauto/transcript-review.json", project: project).path) else { return nil }
        return try read(project: project).0
    }

    func importCatalog(_ source: URL, project: Project) throws -> TranscriptReviewSession {
        guard source.isFileURL else { throw WorkflowFailure.invalid("Choose a saved local transcript JSON file.") }
        let data = try boundedData(source)
        let catalog = try decode(TranscriptCatalog.self, data: data); try catalog.validate()
        let catalogSHA = Self.sha(data)
        return try locked(project: project) {
            let pointer = try safe(".clauto/transcript-review.json", project: project)
            if fm.fileExists(atPath: pointer.path) {
                let current = try read(project: project).0
                guard current.state.catalogSHA256 == catalogSHA else {
                    throw WorkflowFailure.invalid("This project already has a different transcript review. Its source and choices are preserved; use a separate project for another catalog.")
                }
                return current
            }
            let reviewID = UUID()
            let relative = base(reviewID)
            let folder = try safe(relative, project: project)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try data.write(to: safe(relative + "/source.json", project: project), options: .withoutOverwriting)
                let state = TranscriptReviewState(reviewID: reviewID, projectID: project.id, catalogSHA256: catalogSHA,
                    rowOrder: catalog.rows.sorted { $0.originalOrder < $1.originalOrder }.map(\.id),
                    decisions: Dictionary(uniqueKeysWithValues: catalog.rows.map { ($0.id, TranscriptRowDecision(row: $0)) }))
                let session = TranscriptReviewSession(catalog: catalog, state: state)
                try publish(session, project: project)
                return session
            } catch {
                // Only this newly created, project-owned copy is rolled back.
                try? fm.removeItem(at: folder); throw error
            }
        }
    }

    func save(_ draft: TranscriptReviewSession, expectedRevision: UUID, project: Project) throws -> TranscriptReviewSession {
        try locked(project: project) {
            let (current, head) = try read(project: project)
            guard current.state.revisionID == expectedRevision, draft.state.revisionID == expectedRevision,
                  draft.state.reviewID == current.state.reviewID else {
                throw WorkflowFailure.invalid("Another window changed this transcript review. Save a draft copy and reload before editing its latest choices.")
            }
            try draft.state.validate(catalog: current.catalog, projectID: project.id, catalogSHA256: current.state.catalogSHA256)
            if draft.state.rowOrder == current.state.rowOrder && draft.state.decisions == current.state.decisions { return current }
            var state = draft.state
            state.revisionID = UUID(); state.revisionNumber = current.state.revisionNumber + 1; state.saved = Date()
            state.undoTargetRevisionID = current.state.revisionID; state.undoTargetSHA256 = head.stateSHA256
            let next = TranscriptReviewSession(catalog: current.catalog, state: state)
            try publish(next, project: project); return next
        }
    }

    func undo(expectedRevision: UUID, project: Project) throws -> TranscriptReviewSession {
        try locked(project: project) {
            let (current, _) = try read(project: project)
            guard current.state.revisionID == expectedRevision else { throw WorkflowFailure.invalid("The review changed in another window. Reload before undoing.") }
            guard let target = current.state.undoTargetRevisionID, let expectedSHA = current.state.undoTargetSHA256 else { return current }
            let data = try boundedData(safe(revisionPath(current.state.reviewID, target), project: project))
            guard Self.sha(data) == expectedSHA else { throw WorkflowFailure.invalid("The previous transcript checkpoint changed. It cannot be restored safely.") }
            var state = try decode(TranscriptReviewState.self, data: data)
            try state.validate(catalog: current.catalog, projectID: project.id, catalogSHA256: current.state.catalogSHA256)
            guard state.reviewID == current.state.reviewID, state.revisionID == target else { throw ProjectFailure.invalidProject }
            state.revisionID = UUID(); state.revisionNumber = current.state.revisionNumber + 1; state.saved = Date()
            let next = TranscriptReviewSession(catalog: current.catalog, state: state)
            try publish(next, project: project); return next
        }
    }

    /// A review package is never script approval or instructions to render a cut.
    func export(expectedRevision: UUID, project: Project) throws -> URL {
        try locked(project: project) {
            let (session, head) = try read(project: project)
            guard session.state.revisionID == expectedRevision else { throw WorkflowFailure.invalid("The review changed. Reload it before exporting selections.") }
            let rows = session.rowsByID
            let annotations: [[String: Any]] = session.state.rowOrder.enumerated().map { offset, id in
                let row = rows[id]!, edit = session.state.decisions[id]!
                return ["physical_working_order": offset + 1, "id": id, "keep": edit.keep,
                    "source_id": row.sourceID, "source_sha256": row.sourceSHA256,
                    "first_word": row.firstWord, "last_word": row.lastWord, "start": row.start, "end": row.end,
                    "text": row.text, "Katie_notes": edit.comment, "Katie_requested_graphics": edit.graphicRequest,
                    "assistant_graphic_suggestions": row.assistantGraphics, "handwritten_asset_reference": edit.handwritingReference,
                    "uncertainty": row.uncertainty]
            }
            let selected = annotations.filter { $0["keep"] as? Bool == true }
            let object: [String: Any] = ["schema_version": 1, "dataset_sha256": session.catalog.datasetSHA256,
                "selection_imported": true, "human_identity_or_final_approval_asserted": false, "v7_narrative_locked": false,
                "ordered_selected_rows": selected, "all_row_annotations": annotations,
                "selected_rows": selected.count, "total_rows": annotations.count,
                "row_order_source": "native project review; explicit stable row-ID order",
                "source_bounds_review_required": session.selectedBoundsIssues,
                "catalog_file_sha256": head.catalogSHA256, "review_revision_sha256": head.stateSHA256,
                "review_revision_id": head.revisionID.uuidString, "media_bytes_reverified": false,
                "review_only": true, "applied_to_cut": false]
            let directory = try safe(base(head.reviewID) + "/exports", project: project)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = try safe(base(head.reviewID) + "/exports/selections-\(UUID()).json", project: project)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try writableSize(data)
            try data.write(to: destination, options: .withoutOverwriting)
            return destination
        }
    }

    func saveDraftCopy(_ draft: TranscriptReviewSession, project: Project) throws -> URL {
        try locked(project: project) {
            let (current, _) = try read(project: project)
            guard draft.state.reviewID == current.state.reviewID else { throw ProjectFailure.invalidProject }
            try draft.state.validate(catalog: current.catalog, projectID: project.id, catalogSHA256: current.state.catalogSHA256)
            let destination = try safe(base(current.state.reviewID) + "/pending-draft-\(UUID()).json", project: project)
            let data = try encoder.encode(draft.state); try writableSize(data)
            try data.write(to: destination, options: .withoutOverwriting)
            return destination
        }
    }

    private func read(project: Project) throws -> (TranscriptReviewSession, Head) {
        try identity(project)
        let head = try decode(Head.self, data: boundedData(safe(".clauto/transcript-review.json", project: project)))
        guard head.schemaVersion == 1, head.projectID == project.id,
              TranscriptCatalog.isSHA(head.catalogSHA256), TranscriptCatalog.isSHA(head.stateSHA256) else { throw ProjectFailure.invalidProject }
        let catalogData = try boundedData(safe(base(head.reviewID) + "/source.json", project: project))
        let stateData = try boundedData(safe(revisionPath(head.reviewID, head.revisionID), project: project))
        guard Self.sha(catalogData) == head.catalogSHA256, Self.sha(stateData) == head.stateSHA256 else {
            throw WorkflowFailure.invalid("Saved transcript bytes or choices changed outside this review. The original source binding cannot be silently replaced.")
        }
        let catalog = try decode(TranscriptCatalog.self, data: catalogData); try catalog.validate()
        let state = try decode(TranscriptReviewState.self, data: stateData)
        try state.validate(catalog: catalog, projectID: project.id, catalogSHA256: head.catalogSHA256)
        guard state.reviewID == head.reviewID, state.revisionID == head.revisionID else { throw ProjectFailure.invalidProject }
        return (.init(catalog: catalog, state: state), head)
    }

    private func publish(_ session: TranscriptReviewSession, project: Project) throws {
        let data = try encoder.encode(session.state)
        try writableSize(data)
        let revision = try safe(revisionPath(session.state.reviewID, session.state.revisionID), project: project)
        try data.write(to: revision, options: .withoutOverwriting)
        let head = Head(projectID: project.id, reviewID: session.state.reviewID, revisionID: session.state.revisionID,
                        catalogSHA256: session.state.catalogSHA256, stateSHA256: Self.sha(data))
        // A failed pointer publication leaves an unused immutable checkpoint, not
        // a partly replaced prior review. It can be inspected for recovery.
        try encoder.encode(head).write(to: safe(".clauto/transcript-review.json", project: project), options: .atomic)
    }

    private func locked<T>(project: Project, _ body: () throws -> T) throws -> T {
        try identity(project)
        let path = try safe(".clauto/transcript-review.lock", project: project)
        let fd = Darwin.open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkflowFailure.invalid("This project's transcript review cannot be locked for saving.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WorkflowFailure.invalid("Another window is saving this transcript review. Retry after it finishes.") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func identity(_ project: Project) throws {
        try ProjectRepository.validateDrive(project.folder)
        let manifest = try decoder.decode(ProjectManifest.self, from: boundedData(safe("clauto-project.json", project: project)))
        guard manifest.id == project.id, manifest.schemaVersion == 1 else { throw ProjectFailure.invalidProject }
    }
    private func safe(_ relative: String, project: Project) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw ProjectFailure.invalidProject }
        let root = project.folder.resolvingSymlinksInPath().standardizedFileURL
        var ancestor = root
        for component in relative.split(separator: "/") {
            ancestor = ancestor.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
            guard ancestor.path.hasPrefix(root.path + "/") else { throw ProjectFailure.invalidProject }
        }
        return project.folder.appendingPathComponent(relative)
    }
    private func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 64 * 1024 * 1024 else {
            throw WorkflowFailure.invalid("Choose a transcript or review file no larger than 64 MB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 * 1024 else { throw WorkflowFailure.invalid("The review file grew beyond its size limit.") }
        return data
    }
    private func writableSize(_ data: Data) throws {
        guard data.count <= 64 * 1024 * 1024 else {
            throw WorkflowFailure.invalid("The review exceeds its 64 MB file limit. Shorten a large comment or graphic request; the previous saved checkpoint remains unchanged.")
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        try TranscriptJSONKeys.validate(data)
        return try decoder.decode(type, from: data)
    }
    private func base(_ review: UUID) -> String { "notes/transcript-review/" + review.uuidString }
    private func revisionPath(_ review: UUID, _ revision: UUID) -> String { base(review) + "/revision-" + revision.uuidString + ".json" }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// JSONDecoder accepts duplicate keys. Reject ambiguous catalogs/checkpoints,
/// including escaped spellings of the same key, before decoding source identity.
private struct TranscriptJSONKeys {
    var bytes: [UInt8]
    var index = 0
    static func validate(_ data: Data) throws {
        var parser = Self(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw ProjectFailure.invalidProject }
    }
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) throws {
        space(); guard index < bytes.count, bytes[index] == byte else { throw ProjectFailure.invalidProject }; index += 1
    }
    mutating func string(key: Bool = false) throws -> String {
        space(); let start = index; try take(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { throw ProjectFailure.invalidProject }; index += 1 }
            else if byte == 34 {
                return key ? try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) : ""
            }
        }
        throw ProjectFailure.invalidProject
    }
    mutating func value(depth: Int) throws {
        space(); guard depth < 64, index < bytes.count else { throw ProjectFailure.invalidProject }
        switch bytes[index] {
        case 123:
            index += 1; space(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while true {
                let key = try string(key: true)
                guard keys.insert(key).inserted else { throw WorkflowFailure.invalid("The review JSON contains duplicate keys.") }
                try take(58); try value(depth: depth + 1); space()
                guard index < bytes.count else { throw ProjectFailure.invalidProject }
                if bytes[index] == 125 { index += 1; return }; try take(44)
            }
        case 91:
            index += 1; space()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); space(); guard index < bytes.count else { throw ProjectFailure.invalidProject }
                if bytes[index] == 93 { index += 1; return }; try take(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw ProjectFailure.invalidProject }
        }
    }
}
