import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct ProjectCatalogTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func bytes(in root: URL) throws -> [String: Data] {
        let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in paths where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return result
    }

    @Test func discoversUnopenedNativeProjectsWithoutTouchingAnyProjectOrMediaBytes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let pizza = try await repository.create(name: "Pizza", root: root, engine: root)
        let pan = try await repository.create(name: "Pan", root: root, engine: root)
        let sugar = try await repository.create(name: "Sugar", root: root, engine: root)
        try Data("synthetic original media".utf8).write(to: pan.folder.appendingPathComponent("footage/a-cam/original.mov"))
        let before = try bytes(in: root)
        let catalog = try await RecentProjectRestoration.discover(root: root, paths: [pizza.folder.path]) { try await repository.open($0) }
        #expect(Set(catalog.projects.map(\.id)) == [pizza.id, pan.id, sugar.id])
        #expect(catalog.projects.first?.id == pizza.id)
        #expect(catalog.issues.isEmpty && catalog.rootIssue == nil)
        #expect(try bytes(in: root) == before)
    }

    @Test func skipsExportFoldersAndNestedProjectsAndRejectsMalformedManifests() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let valid = try await repository.create(name: "Valid", root: root, engine: root)
        let exports = root.appendingPathComponent("Review Deliveries")
        let nested = try await repository.create(name: "Nested", root: exports, engine: root)
        let malformed = root.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{malformed".utf8).write(to: malformed.appendingPathComponent("clauto-project.json"))
        let before = try bytes(in: root)
        let catalog = try await RecentProjectRestoration.discover(root: root, paths: []) { try await repository.open($0) }
        #expect(catalog.projects.map(\.id) == [valid.id])
        #expect(!catalog.projects.contains { $0.id == nested.id })
        #expect(catalog.unavailablePaths == [malformed.path])
        #expect(catalog.issues.first?.detail.isEmpty == false)
        #expect(try bytes(in: root) == before)
    }

    @Test func deduplicatesAliasesAndRefusesSeparateCopiesWithoutChangingEither() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let original = try await repository.create(name: "Original", root: root, engine: root)
        let alias = root.appendingPathComponent("Alias"), copy = root.appendingPathComponent("Copy")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original.folder)
        try FileManager.default.copyItem(at: original.folder, to: copy)
        let catalog = try await RecentProjectRestoration.discover(root: root, paths: [original.folder.path, alias.path, original.folder.path]) { try await repository.open($0) }
        #expect(catalog.projects.count == 1 && catalog.projects.first?.id == original.id)
        #expect(catalog.unavailablePaths == [copy.path])
        #expect(RecentProjectRestoration.recentPaths(selected: original, projects: catalog.projects, previous: [alias.path, original.folder.path]) == [original.folder.path])
        #expect(try Data(contentsOf: copy.appendingPathComponent("clauto-project.json")) == Data(contentsOf: original.folder.appendingPathComponent("clauto-project.json")))
    }

    @Test func offlineRootRetainsNamedBookmarksAndRecentsWithoutCreatingTheDrive() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let original = try await repository.create(name: "Known project", root: root, engine: root)
        let bookmark = ProjectCatalogBookmark(original)
        let disconnected = root.appendingPathComponent("Disconnected")
        try FileManager.default.moveItem(at: original.folder, to: disconnected)
        let absentRoot = root.appendingPathComponent("Unmounted root")
        let catalog = try await RecentProjectRestoration.discover(root: absentRoot, paths: [bookmark.path], known: [bookmark]) { try await repository.open($0) }
        #expect(catalog.projects.isEmpty && catalog.unavailablePaths == [bookmark.path])
        #expect(catalog.rootIssue != nil && !FileManager.default.fileExists(atPath: absentRoot.path))
        let retained = ProjectCatalogBookmark.retaining(catalog.projects, previous: [bookmark])
        #expect(retained.first?.name == "Known project" && retained.first?.projectID == original.id)
        #expect(RecentProjectRestoration.recentPaths(selected: nil, projects: [], previous: [bookmark.path]) == [bookmark.path])
        try FileManager.default.moveItem(at: disconnected, to: original.folder)
        let recovered = try await RecentProjectRestoration.discover(root: root, paths: [bookmark.path], known: retained) { try await repository.open($0) }
        #expect(recovered.projects.map(\.id) == [original.id] && recovered.issues.isEmpty)
    }

    @Test func offlineOriginalCannotBeReplacedByADiscoveredCopyWithItsIdentity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let original = try await repository.create(name: "Original", root: root, engine: root)
        let bookmark = ProjectCatalogBookmark(original)
        let copy = root.appendingPathComponent("Copy")
        try FileManager.default.moveItem(at: original.folder, to: copy)
        let catalog = try await RecentProjectRestoration.discover(root: root, paths: [bookmark.path], known: [bookmark]) { try await repository.open($0) }
        #expect(catalog.projects.isEmpty)
        #expect(Set(catalog.unavailablePaths) == [bookmark.path, copy.path])
        #expect(ProjectCatalogBookmark.retaining([], previous: [bookmark]).first?.path == bookmark.path)
    }

    @Test func emptyRootStaysEmptyAndCancellationPropagates() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try await RecentProjectRestoration.discover(root: root, paths: []) { try await ProjectRepository().open($0) }
        #expect(catalog.projects.isEmpty && catalog.issues.isEmpty && catalog.rootIssue == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: CancellationError.self) {
            try await RecentProjectRestoration.discover(root: root, paths: [], open: { try await ProjectRepository().open($0) }, list: { _ in throw CancellationError() })
        }
    }
}

#if !canImport(ClautoCore)
@MainActor @Suite(.serialized) struct ProjectCatalogNativeStoreTests {
    private func root(_ suite: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath().standardizedFileURL
    }
    @Test func discoversRegistersSwitchesAndRefreshesWithoutLosingCutOrControllerState() async throws {
        let suite = "clauto-catalog-store-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try root(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "ClautoProjectsRoot")
        let repository = ProjectRepository()
        let pizza = try await repository.create(name: "Pizza", root: root, engine: root)
        let pan = try await repository.create(name: "Pan", root: root, engine: root)
        let sugar = try await repository.create(name: "Sugar", root: root, engine: root)
        defaults.set([pizza.folder.path], forKey: "ClautoRecentProjects")
        let store = EditorStore(defaults: defaults)
        await store.restore()
        #expect(Set(store.projects.map(\.id)) == [pizza.id, pan.id, sugar.id])
        #expect(Set(defaults.stringArray(forKey: "ClautoRecentProjects") ?? []) == [pizza.folder.path, pan.folder.path, sugar.folder.path])
        let panScript = store.scriptWorkspace(for: pan)
        let sugarScript = store.scriptWorkspace(for: sugar)
        store.selectedID = pan.id; store.rememberProjectTab("Script")
        let cut = CutVersion(number: 9, label: "Existing cut", engineVersion: "test", runID: UUID(), artifacts: [], approvedPlanHash: "test")
        let sugarCut = CutVersion(number: 3, label: "Sugar cut", engineVersion: "test", runID: UUID(), artifacts: [], approvedPlanHash: "test")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for (project, version) in [(pan, cut), (sugar, sugarCut)] {
            let folder = project.folder.appendingPathComponent("cuts/" + version.folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try encoder.encode(version).write(to: folder.appendingPathComponent("clauto-version.json"))
            try encoder.encode(version.id).write(to: project.folder.appendingPathComponent("cuts/current.json"))
        }
        let panPointer = try Data(contentsOf: pan.folder.appendingPathComponent("cuts/current.json"))
        let sugarPointer = try Data(contentsOf: sugar.folder.appendingPathComponent("cuts/current.json"))
        await store.loadWorkflow()
        #expect(store.currentCuts[pan.id]?.id == cut.id)
        store.selectedID = sugar.id; store.rememberProjectTab("Studio")
        await store.loadWorkflow()
        #expect(store.currentCuts[sugar.id]?.id == sugarCut.id)
        await store.restore()
        #expect(store.selectedID == sugar.id && store.initialProjectTab == "Studio")
        store.selectedID = pan.id
        #expect(store.initialProjectTab == "Script" && store.currentCuts[pan.id]?.id == cut.id)
        #expect(store.scriptWorkspace(for: pan) === panScript)
        #expect(store.scriptWorkspace(for: sugar) === sugarScript)
        #expect(try Data(contentsOf: pan.folder.appendingPathComponent("cuts/current.json")) == panPointer)
        #expect(try Data(contentsOf: sugar.folder.appendingPathComponent("cuts/current.json")) == sugarPointer)
        let reopened = EditorStore(defaults: defaults)
        await reopened.restore()
        #expect(reopened.selectedID == pan.id && reopened.initialProjectTab == "Script")
        let offline = root.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: root, to: offline)
        defer { try? FileManager.default.moveItem(at: offline, to: root) }
        await reopened.restore()
        #expect(reopened.projects.count == 3 && reopened.projectCatalogIssues.count == 3)
        let coldOffline = EditorStore(defaults: defaults)
        await coldOffline.restore()
        #expect(coldOffline.projects.isEmpty && coldOffline.unopenedProjectIssues.count == 3)
        #expect(Set(coldOffline.projectBookmarks.map(\.name)) == ["Pizza", "Pan", "Sugar"])
        #expect(defaults.stringArray(forKey: "ClautoRecentProjects")?.count == 3)
    }

    @Test func refreshKeepsAnUnsavedBriefAndOfflineIdentityCannotBeManuallyReplaced() async throws {
        let suite = "clauto-catalog-draft-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try root(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "ClautoProjectsRoot")
        let project = try await ProjectRepository().create(name: "Original", root: root, engine: root)
        let store = EditorStore(defaults: defaults)
        await store.restore()
        var brief = project.brief; brief.about = "Retained local draft"
        store.save(brief, for: project.id)
        await store.restore()
        #expect(store.selected?.brief.about == "Retained local draft")
        #expect(await store.flushReviewWorkForExit())
        let copy = root.appendingPathComponent("Separate copy")
        try FileManager.default.moveItem(at: project.folder, to: copy)
        let cold = EditorStore(defaults: defaults)
        await cold.restore(); await cold.open(copy)
        #expect(cold.projects.isEmpty && cold.selectedID == nil)
        #expect(cold.notice?.contains("shares an ID") == true)
        #expect(cold.projectBookmarks.first?.path == project.folder.path)
    }
}
#endif
