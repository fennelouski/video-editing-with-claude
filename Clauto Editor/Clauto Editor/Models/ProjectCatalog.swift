import Foundation

/// Presentation metadata only. Project data and media remain in their original
/// folders; a disconnected drive must not erase its entries from the sidebar.
struct ProjectCatalogBookmark: Codable, Identifiable, Sendable {
    var projectID: UUID
    var name: String
    var path: String
    var id: String { path }

    init(_ project: Project) {
        projectID = project.id; name = project.manifest.name; path = project.folder.path
    }

    static func requireOriginal(_ project: Project, among known: [Self]) throws {
        guard !known.contains(where: {
            $0.projectID == project.id && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL != project.folder.resolvingSymlinksInPath().standardizedFileURL
        }) else {
            throw WorkflowFailure.invalid("This folder shares an ID with a project already saved in the library. Reconnect the original project folder; this copy was not substituted for it.")
        }
    }

    static func retaining(_ projects: [Project], previous: [Self]) -> [Self] {
        var seenPaths = Set<String>(), seenIDs = Set<UUID>()
        return (projects.map(Self.init) + previous).filter {
            let path = URL(fileURLWithPath: $0.path).standardizedFileURL.path
            guard !seenPaths.contains(path), !seenIDs.contains($0.projectID) else { return false }
            seenPaths.insert(path); seenIDs.insert($0.projectID); return true
        }
    }
}

struct ProjectCatalogIssue: Identifiable, Sendable {
    var path: String
    var detail: String
    var id: String { path }
}

/// Shallow, read-only discovery. Only folders with a native project manifest are
/// candidates. The repository still validates every manifest before admission.
/// No media enumeration, project creation, repair, or workflow loading occurs.
actor ProjectCatalogDiscovery {
    func folders(in folder: URL) async throws -> [URL] {
        try Task.checkCancellation()
        try ProjectRepository.validateDrive(folder)
        let root = try SourceRenderDirectory.open(folder)
        let children = try FileManager.default.contentsOfDirectory(at: root.url,
            includingPropertiesForKeys: nil, options: [])
        var candidates: [URL] = []
        for child in children {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: child.appendingPathComponent("clauto-project.json").path) {
                // Directory enumeration may return /private/var while the
                // repository uses /var. Keep one canonical spelling throughout
                // discovery, saved paths and unavailable-entry presentation.
                candidates.append(child.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        try root.checkPath()
        return candidates.sorted { $0.path < $1.path }
    }
}

extension RecentProjectRestoration {
    static func discover(root: URL, paths: [String], known: [ProjectCatalogBookmark] = [],
                         open: @Sendable (URL) async throws -> Project,
                         list: @Sendable (URL) async throws -> [URL] = { try await ProjectCatalogDiscovery().folders(in: $0) }) async throws -> Self {
        var candidates: [URL] = [], rootIssue: String?
        do { candidates = try await list(root) }
        catch is CancellationError { throw CancellationError() }
        catch { rootIssue = error.localizedDescription }
        var restored = try await load(paths + candidates.map(\.path), known: known, open: open)
        restored.rootIssue = rootIssue
        return restored
    }
}
