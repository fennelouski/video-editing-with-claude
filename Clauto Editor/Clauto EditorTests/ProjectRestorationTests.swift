import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct ProjectRestorationTests {
    private func fixture() async throws -> (URL, Project, Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-project-restore-" + UUID().uuidString)
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let repository = ProjectRepository()
        let first = try await repository.create(name: "First", root: root, engine: engine)
        let second = try await repository.create(name: "Second", root: root, engine: engine)
        return (root, first, second)
    }

    @Test func ordinaryRestoreUsesTheSavedProjectAndOlderPreferencesUseTheFirstAvailable() async throws {
        let (root, first, second) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let restored = try await RecentProjectRestoration.load([first.folder.path, second.folder.path]) { try await repository.open($0) }
        #expect(restored.projects.count == 2 && restored.unavailablePaths.isEmpty)
        #expect(restored.selection(id: second.id.uuidString, path: second.folder.path) == second.id)
        #expect(restored.selection(id: nil, path: nil) == first.id)
        #expect(restored.selection(id: second.id.uuidString, path: first.folder.path) == first.id)
    }

    @Test func unavailableDrivePathIsNotCreatedAndOtherProjectsCanStillOpen() async throws {
        let (root, first, second) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("Disconnected original project")
        let repository = ProjectRepository()
        let bytes = try Data(contentsOf: first.folder.appendingPathComponent("clauto-project.json"))
        let restored = try await RecentProjectRestoration.load([absent.path, second.folder.path, first.folder.path]) { try await repository.open($0) }
        #expect(restored.unavailablePaths == [absent.path])
        #expect(restored.selection(id: UUID().uuidString, path: absent.path) == second.id)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        #expect(try Data(contentsOf: first.folder.appendingPathComponent("clauto-project.json")) == bytes)
        let recent = RecentProjectRestoration.recentPaths(selected: second, projects: restored.projects,
            previous: [absent.path, first.folder.path, second.folder.path])
        #expect(recent == [second.folder.path, first.folder.path, absent.path])
    }

    @Test func aliasesAreDeduplicatedButSeparateSameIdentityCopiesAreRefused() async throws {
        let (root, first, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("Alias")
        let copy = root.appendingPathComponent("Copy")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.folder)
        try FileManager.default.copyItem(at: first.folder, to: copy)
        let originalBytes = try Data(contentsOf: first.folder.appendingPathComponent("clauto-project.json"))
        let repository = ProjectRepository()
        let restored = try await RecentProjectRestoration.load([first.folder.path, first.folder.path, alias.path, copy.path]) { try await repository.open($0) }
        #expect(restored.projects.count == 1 && restored.projects.first?.id == first.id)
        #expect(restored.unavailablePaths == [copy.path])
        #expect(try Data(contentsOf: copy.appendingPathComponent("clauto-project.json")) == originalBytes)
        #expect(try Data(contentsOf: first.folder.appendingPathComponent("clauto-project.json")) == originalBytes)
    }

    @Test func cancelledRestorationDoesNotTurnIntoAnUnavailableProjectResult() async throws {
        await #expect(throws: CancellationError.self) {
            try await RecentProjectRestoration.load(["/synthetic/not-opened"]) { _ in throw CancellationError() }
        }
    }

    @Test func tabsAreRestoredOnlyFromSupportedWorkspaceNames() {
        for value in ["Brief", "Files", "Transcript", "Cut", "Studio"] { #expect(RecentProjectRestoration.tab(value) == value) }
        #expect(RecentProjectRestoration.tab(nil) == "Brief")
        #expect(RecentProjectRestoration.tab("obsolete") == "Brief")
    }
}

#if !canImport(ClautoCore)
private actor ProjectRestorationGate {
    private var started = false
    private var work: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        started = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        await withCheckedContinuation { work = $0 }
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { work?.resume(); work = nil }
}

@MainActor @Suite(.serialized) struct ProjectRestorationNativeStoreTests {
    @Test func ordinaryStoreRestoreSelectsAndReopensTheLastProjectWithoutLaunchOverrides() async throws {
        let suite = "clauto-project-store-restore-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let first = try await repository.create(name: "First", root: root, engine: root)
        let second = try await repository.create(name: "Second", root: root, engine: root)
        defaults.set([first.folder.path, second.folder.path], forKey: "ClautoRecentProjects")
        defaults.set(second.id.uuidString, forKey: "ClautoSelectedProjectID")
        defaults.set(second.folder.path, forKey: "ClautoSelectedProjectPath")
        defaults.set("Cut", forKey: "ClautoSelectedProjectTab")
        defaults.set("preserved", forKey: "UnrelatedPreference")
        let store = EditorStore(defaults: defaults)
        await store.restore()
        #expect(store.selectedID == second.id && store.projects.count == 2)
        #expect(store.initialProjectTab == "Cut")
        store.selectedID = first.id
        let reopened = EditorStore(defaults: defaults)
        await reopened.restore()
        #expect(reopened.selectedID == first.id)
        #expect(defaults.string(forKey: "UnrelatedPreference") == "preserved")
    }

    @Test func openingAnotherProjectDuringRestoreKeepsThatSelectionAndOfflineRecents() async throws {
        let suite = "clauto-project-store-steer-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let first = try await repository.create(name: "First", root: root, engine: root)
        let second = try await repository.create(name: "Second", root: root, engine: root)
        let unavailable = root.appendingPathComponent("Disconnected").path
        defaults.set([first.folder.path, unavailable], forKey: "ClautoRecentProjects")
        let store = EditorStore(defaults: defaults)
        // The opener models the explicit UI selection occurring during awaited
        // folder I/O, without a sleep, running window or microphone.
        await store.restore { url in
            await store.open(second.folder)
            return try await repository.open(url)
        }
        #expect(store.selectedID == second.id)
        #expect(defaults.stringArray(forKey: "ClautoRecentProjects")?.contains(unavailable) == true)
        #expect(store.notice == nil)
    }

    @Test func temporaryFallbackRetainsTheExplicitProjectForTheNextReconnect() async throws {
        let suite = "clauto-project-store-reconnect-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let first = try await repository.create(name: "Preferred", root: root, engine: root)
        let second = try await repository.create(name: "Available", root: root, engine: root)
        defaults.set([first.folder.path, second.folder.path], forKey: "ClautoRecentProjects")
        defaults.set(first.id.uuidString, forKey: "ClautoSelectedProjectID")
        defaults.set(first.folder.path, forKey: "ClautoSelectedProjectPath")
        let offline = root.appendingPathComponent("temporarily-offline")
        try FileManager.default.moveItem(at: first.folder, to: offline)
        let fallback = EditorStore(defaults: defaults)
        await fallback.restore()
        #expect(fallback.selectedID == second.id)
        #expect(defaults.string(forKey: "ClautoSelectedProjectID") == first.id.uuidString)
        #expect(defaults.string(forKey: "ClautoSelectedProjectPath") == first.folder.path)
        try FileManager.default.moveItem(at: offline, to: first.folder)
        let reconnected = EditorStore(defaults: defaults)
        await reconnected.restore()
        #expect(reconnected.selectedID == first.id)
    }

    @Test func failedExplicitOpenKeepsItsErrorWhenAnOlderRestoreFinishes() async throws {
        let suite = "clauto-project-store-error-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set([root.appendingPathComponent("Unavailable recent").path], forKey: "ClautoRecentProjects")
        let store = EditorStore(defaults: defaults), gate = ProjectRestorationGate()
        let pending = Task { await store.restore { url in
            await gate.hold()
            return try await ProjectRepository().open(url)
        } }
        await gate.waitStarted()
        await store.open(root.appendingPathComponent("New missing selection"))
        let actionableError = try #require(store.notice)
        await gate.release(); await pending.value
        #expect(store.notice == actionableError)
        #expect(store.selectedID == nil)
    }

    @Test func olderWindowRestoreCannotPublishAfterTheNewerRestoration() async throws {
        let suite = "clauto-project-store-overlap-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectRepository()
        let first = try await repository.create(name: "Earlier window", root: root, engine: root)
        let second = try await repository.create(name: "Later window", root: root, engine: root)
        defaults.set([first.folder.path], forKey: "ClautoRecentProjects")
        let store = EditorStore(defaults: defaults), gate = ProjectRestorationGate()
        let pending = Task { await store.restore { url in
            await gate.hold()
            return try await repository.open(url)
        } }
        await gate.waitStarted()
        defaults.set([second.folder.path], forKey: "ClautoRecentProjects")
        await store.restore()
        await gate.release(); await pending.value
        #expect(store.selectedID == second.id)
        #expect(store.projects.map(\.id) == [second.id])
    }
}
#endif
