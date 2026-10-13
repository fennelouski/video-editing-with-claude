import Foundation
import Observation

@MainActor @Observable
final class EditorStore {
    static let nasRoot = URL(fileURLWithPath: "/Volumes/Videos/Food Videos/Katie YouTube/Projects/Clauto Editor", isDirectory: true)
    var projects: [Project] = []
    var selectedID: UUID?
    var notice: String?
    var setupChecks: [SetupCheck] = []
    var details = ""
    var checking = false
    var working = false
    var checkSummary: String?
    var projectRoot: URL
    var engineRoot: URL
    @ObservationIgnored private let repository = ProjectRepository()
    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recentKey = "ClautoRecentProjects"

    init(defaults: UserDefaults = .standard) {
        let env = ProcessInfo.processInfo.environment
        let preferences = env["CLAUTO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? defaults
        self.defaults = preferences
        projectRoot = URL(fileURLWithPath: env["CLAUTO_PROJECTS_ROOT"] ?? preferences.string(forKey: "ClautoProjectsRoot") ?? Self.nasRoot.path, isDirectory: true)
        engineRoot = URL(fileURLWithPath: env["CLAUTO_ENGINE_ROOT"] ?? preferences.string(forKey: "ClautoEngineRoot") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clauto Editor/engine").path, isDirectory: true)
    }

    var selected: Project? { projects.first { $0.id == selectedID } }

    func restore() async {
        for path in defaults.stringArray(forKey: recentKey) ?? [] {
            do { let project = try await repository.open(URL(fileURLWithPath: path)); update(project) }
            catch { notice = "A recent project is unavailable. Reconnect its drive and use Open Project." }
        }
    }

    func create(_ name: String) async {
        working = true; defer { working = false }
        do {
            let version = (try? String(contentsOf: engineRoot.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "development"
            let project = try await repository.create(name: name, root: projectRoot, engine: engineRoot, engineVersion: version)
            update(project); selectedID = project.id; remember()
        } catch { notice = error.localizedDescription }
    }

    func open(_ folder: URL) async {
        do { let project = try await repository.open(folder); update(project); selectedID = project.id; remember() }
        catch { notice = error.localizedDescription }
    }

    func save(_ brief: Brief, for id: UUID) {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        project.brief = brief; update(project)
        saves[id]?.cancel()
        saves[id] = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let saved = try await repository.saveBrief(brief, project: project)
                // The disk write may finish while a newer edit is pending; leave its draft alone.
                if projects.first(where: { $0.id == id })?.brief == brief { update(saved) }
            } catch is CancellationError { }
            catch { notice = "Your brief could not be saved. \(error.localizedDescription)" }
        }
    }

    func intake(_ urls: [URL], group: FileGroup? = nil, copy: Bool = false) async {
        guard let project = selected, !working else { return }
        working = true; defer { working = false }
        do { update(try await repository.add(urls, to: project, group: group, copy: copy)) }
        catch { notice = error.localizedDescription }
    }

    func remove(_ file: ProjectFile) async {
        guard let project = selected, !working else { return }
        working = true; defer { working = false }
        do { update(try await repository.remove(file, from: project)) } catch { notice = error.localizedDescription }
    }

    func assign(_ group: FileGroup, file: ProjectFile) async {
        guard let project = selected, !working else { return }
        working = true; defer { working = false }
        do { update(try await repository.assign(group, to: file, project: project)) } catch { notice = error.localizedDescription }
    }

    func preferences(aspect: String? = nil, model: String? = nil) async {
        guard let project = selected, !working else { return }
        working = true; defer { working = false }
        do { update(try await repository.preferences(aspect: aspect ?? project.manifest.aspect, model: model ?? project.manifest.whisperModel, project: project)) }
        catch { notice = error.localizedDescription }
    }

    func checkSetup() async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        setupChecks = await SetupService(runner: runner).check(engine: engineRoot, projectsRoot: projectRoot)
    }

    func checkProject() async {
        guard let project = selected, !checking else { return }
        checking = true; checkSummary = nil; details = ""; defer { checking = false }
        do {
            try ProjectRepository.validateDrive(project.folder)
            let missing = project.manifest.files.filter {
                !FileManager.default.fileExists(atPath: project.folder.appendingPathComponent($0.relativePath).path)
            }
            guard missing.isEmpty else { throw ProjectFailure.missingFile(missing.map(\.name).joined(separator: ", ")) }
            if project.manifest.files.contains(where: { URL(fileURLWithPath: $0.name).pathExtension.lowercased() == "insv" }) {
                throw ProjectFailure.unsupportedCamera
            }
            let result = try await runner.run(ProcessCommand(executable: engineRoot.appendingPathComponent("run"),
                arguments: ["run_pipeline.py", "--dry-run", "--json"], directory: engineRoot,
                environment: ["CLAUTO_PATHS": project.folder.appendingPathComponent("paths.json").path,
                              "CLAUTO_WHISPER_MODEL": project.manifest.whisperModel,
                              "HF_HOME": projectRoot.deletingLastPathComponent().appendingPathComponent("Models/huggingface").path,
                              "TORCH_HOME": projectRoot.deletingLastPathComponent().appendingPathComponent("Models/torch").path]), onLine: nil)
            details = result.output + result.error
            if result.cancelled { checkSummary = "Check stopped. Your files are unchanged."; return }
            let report = try JSONDecoder().decode(EnginePreflight.self, from: Data(result.output.utf8))
            guard report.ready == result.succeeded else { throw ProjectFailure.invalidProject }
            checkSummary = report.ready ? "Preflight passed. A cut has not been generated." : "Setup needs attention:\n" + report.problems.joined(separator: "\n")
        } catch { checkSummary = error.localizedDescription }
    }

    func cancel() async { await runner.cancel() }

    func setFolders(projects: URL? = nil, engine: URL? = nil) {
        if let projects { projectRoot = projects; defaults.set(projects.path, forKey: "ClautoProjectsRoot") }
        if let engine { engineRoot = engine; defaults.set(engine.path, forKey: "ClautoEngineRoot") }
        setupChecks = []
    }

    private func update(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.append(project) }
    }
    private func remember() { defaults.set(projects.map { $0.folder.path }, forKey: recentKey) }
}
