import Foundation
import Observation
import Darwin

@MainActor @Observable
final class EditorStore {
    static let nasRoot = URL(fileURLWithPath: "/Volumes/Videos/Food Videos/Katie YouTube/Projects/Clauto Editor", isDirectory: true)
    var projects: [Project] = []
    var selectedID: UUID?
    var notice: String? { didSet { noticeTitle = "Needs attention" } }
    var noticeTitle = "Needs attention"
    var setupChecks: [SetupCheck] = []
    var runDetails: [UUID: String] = [:]
    var checking = false
    var working = false
    var checkSummaries: [UUID: String] = [:]
    var projectRoot: URL
    var engineRoot: URL
    var defaultExportResolution: ExportResolution
    var runs: [UUID: EditRun] = [:]
    var cutVersions: [UUID: [CutVersion]] = [:]
    var currentCuts: [UUID: CutVersion] = [:]
    var conversations: [UUID: [LocalMessage]] = [:]
    var cutFeedback: [UUID: [CutFeedback]] = [:]
    var derivedCuts: [UUID: [DerivedCut]] = [:]
    var exportingDerivativeProjectID: UUID?
    var derivativeDetails: [UUID: String] = [:]
    var missingPieces: [UUID: [MissingPiece]] = [:]
    var planReviews: [UUID: String] = [:]
    var runningProjectID: UUID?
    var exportingPDF = false
    @ObservationIgnored private let repository = ProjectRepository()
    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private let workflow = WorkflowRepository()
    @ObservationIgnored private let exporter = HandoffExportService()
    @ObservationIgnored private let derivativeRunner = ProcessRunner()
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recentKey = "ClautoRecentProjects"

    init(defaults: UserDefaults = .standard) {
        let env = ProcessInfo.processInfo.environment
        let preferences = env["CLAUTO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? defaults
        self.defaults = preferences
        defaultExportResolution = preferences.string(forKey: "ClautoDefaultExportResolution").flatMap(ExportResolution.init(rawValue:)) ?? .fullHD
        projectRoot = URL(fileURLWithPath: env["CLAUTO_PROJECTS_ROOT"] ?? preferences.string(forKey: "ClautoProjectsRoot") ?? Self.nasRoot.path, isDirectory: true)
        engineRoot = URL(fileURLWithPath: env["CLAUTO_ENGINE_ROOT"] ?? preferences.string(forKey: "ClautoEngineRoot") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clauto Editor/engine").path, isDirectory: true)
    }

    var selected: Project? { projects.first { $0.id == selectedID } }
    var details: String { selectedID.flatMap { runDetails[$0] } ?? "" }
    var checkSummary: String? { selectedID.flatMap { checkSummaries[$0] } }

    func restore() async {
        for path in defaults.stringArray(forKey: recentKey) ?? [] {
            do { let project = try await repository.open(URL(fileURLWithPath: path)); update(project) }
            catch { notice = "A recent project is unavailable. Reconnect its drive and use Open Project." }
        }
    }

    func create(_ name: String) async -> Bool {
        working = true; defer { working = false }
        do {
            let version = (try? String(contentsOf: engineRoot.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "development"
            let project = try await repository.create(name: name, root: projectRoot, engine: engineRoot, engineVersion: version, resolution: defaultExportResolution)
            update(project); selectedID = project.id; remember()
            return true
        } catch { notice = error.localizedDescription; return false }
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
        guard let project = selected, !working, runningProjectID != project.id else { return }
        working = true; defer { working = false }
        do {
            let referenceURLs = urls.filter { ["style_guide.md", "taste_principles.md"].contains($0.lastPathComponent.lowercased()) && (group == nil || group == .creativeReferences) }
            guard group != .creativeReferences || referenceURLs.count == urls.count else {
                throw WorkflowFailure.invalid("Choose style_guide.md and taste_principles.md for the project's creative references.")
            }
            let requests = try referenceURLs.map(CreativeReferenceImport.local)
            let otherURLs = urls.filter { !referenceURLs.contains($0) }
            var next = project
            if !otherURLs.isEmpty { next = try await repository.add(otherURLs, to: next, group: group, copy: copy) }
            if !requests.isEmpty { next = try await repository.addCreativeReferences(requests, to: next) }
            update(next)
        }
        catch { notice = error.localizedDescription }
    }

    func remove(_ file: ProjectFile) async {
        guard let project = selected, !working, runningProjectID != project.id else { return }
        working = true; defer { working = false }
        do { update(try await repository.remove(file, from: project)) } catch { notice = error.localizedDescription }
    }

    func assign(_ group: FileGroup, file: ProjectFile) async {
        guard let project = selected, !working, runningProjectID != project.id else { return }
        working = true; defer { working = false }
        do { update(try await repository.assign(group, to: file, project: project)) } catch { notice = error.localizedDescription }
    }

    func preferences(aspect: String? = nil, model: String? = nil) async {
        guard let project = selected, !working, runningProjectID != project.id else { return }
        working = true; defer { working = false }
        do { update(try await repository.preferences(aspect: aspect ?? project.manifest.aspect, model: model ?? project.manifest.whisperModel, project: project)) }
        catch { notice = error.localizedDescription }
    }

    func checkSetup() async {
        guard !checking, runningProjectID == nil else { return }
        checking = true; defer { checking = false }
        setupChecks = await SetupService(runner: runner).check(engine: engineRoot, projectsRoot: projectRoot)
    }

    func durationBounds(_ bounds: VideoDurationBounds, project: Project) async {
        guard !working, runningProjectID != project.id else { return }
        working = true; defer { working = false }
        do { update(try await repository.durationBounds(bounds, project: project)) }
        catch { notice = error.localizedDescription }
    }

    func exportResolution(_ resolution: ExportResolution, project: Project) async {
        guard !working, runningProjectID != project.id else { return }
        working = true; defer { working = false }
        do { update(try await repository.exportResolution(resolution, project: project)) }
        catch { notice = error.localizedDescription }
    }

    func setDefaultExportResolution(_ resolution: ExportResolution) {
        defaultExportResolution = resolution
        defaults.set(resolution.rawValue, forKey: "ClautoDefaultExportResolution")
    }

    func checkProject() async {
        guard let project = selected, !checking, runningProjectID == nil else { return }
        checking = true; checkSummaries[project.id] = nil; runDetails[project.id] = ""; defer { checking = false }
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
            runDetails[project.id] = result.output + result.error
            if result.cancelled { checkSummaries[project.id] = "Check stopped. Your files are unchanged."; return }
            let report = try JSONDecoder().decode(EnginePreflight.self, from: Data(result.output.utf8))
            guard report.ready == result.succeeded else { throw ProjectFailure.invalidProject }
            checkSummaries[project.id] = report.ready ? "Preflight passed. A cut has not been generated." : "Setup needs attention:\n" + report.problems.joined(separator: "\n")
        } catch { checkSummaries[project.id] = error.localizedDescription }
    }

    func cancel() async { await runner.cancel() }

    func loadWorkflow() async {
        guard let project = selected else { return }
        do {
            conversations[project.id] = try await workflow.messages(project: project)
            cutFeedback[project.id] = try await workflow.feedback(project: project)
            derivedCuts[project.id] = try await workflow.derivatives(project: project)
            cutVersions[project.id] = try await workflow.versions(project: project)
            currentCuts[project.id] = try await workflow.current(project: project)
            if runningProjectID != project.id, var run = try await workflow.recentRun(project: project) {
                if run.state == .running, kill(run.ownerProcessID, 0) != 0 {
                    run.state = .failed; run.failure = "The previous app session ended during this run. Start a new run; the previous cut is still available."
                    try await workflow.save(run)
                }
                runs[project.id] = run
                missingPieces[project.id] = (try? await workflow.missing(run)) ?? []
                planReviews[project.id] = (try? await workflow.plan(run).text) ?? ""
                runDetails[project.id] = (try? await workflow.logTail(run)) ?? ""
            }
        } catch { notice = error.localizedDescription }
    }

    func queueRequest(_ text: String) async -> Bool {
        guard let project = selected else { return false }
        do { conversations[project.id] = try await workflow.queue(text, project: project); return true }
        catch { notice = error.localizedDescription; return false }
    }

    func addFeedback(_ text: String, start: Double, end: Double?, version: CutVersion, project: Project) async -> Bool {
        do { cutFeedback[project.id] = try await workflow.addFeedback(text, start: start, end: end, version: version, project: project); return true }
        catch { notice = error.localizedDescription; return false }
    }

    func resolveFeedback(_ id: UUID, resolved: Bool, project: Project) async {
        do { cutFeedback[project.id] = try await workflow.resolveFeedback(id, resolved: resolved, project: project) }
        catch { notice = error.localizedDescription }
    }

    func useProjectFolder(_ folder: URL, key: String) async {
        guard let project = selected, runningProjectID == nil else { return }
        do { update(try await repository.useFolder(folder, key: key, project: project)) }
        catch { notice = error.localizedDescription }
    }

    func approveScript(_ text: String) async {
        guard let project = selected, runningProjectID == nil else { return }
        do {
            try await repository.approveScript(text, project: project)
            notice = "Approved script saved. New runs will use it."; noticeTitle = "Script saved"
        }
        catch { notice = error.localizedDescription }
    }

    func beginCut(label: String, primaryID: UUID? = nil, narrationIDs: [UUID] = []) async {
        guard let chosen = selected, runningProjectID == nil, exportingDerivativeProjectID == nil, !checking else { return }
        runningProjectID = chosen.id; defer { runningProjectID = nil }
        do {
            if let save = saves[chosen.id] { await save.value }
            let project = try await repository.open(chosen.folder)
            let run = try await workflow.prepare(project: project, engine: engineRoot, label: label, primaryID: primaryID, narrationIDs: narrationIDs)
            runs[project.id] = run
            await execute(run, project: project, start: 1, stop: 3)
        } catch { notice = error.localizedDescription }
    }

    func continueCut(approve: Bool) async {
        guard let project = selected, var run = runs[project.id], runningProjectID == nil, !checking else { return }
        guard [.needsReview, .needsAssets, .failed].contains(run.state) else { return }
        runningProjectID = project.id; defer { runningProjectID = nil }
        do {
            let plan = try await workflow.plan(run)
            guard plan.issues.isEmpty else { throw WorkflowFailure.invalid("Resolve the plan's timing or cue issues before rendering: " + plan.issues.joined(separator: "; ")) }
            if approve { run.approvedPlanHash = plan.hash }
            await execute(run, project: project, start: 4, stop: 5)
        } catch { notice = error.localizedDescription }
    }

    private func execute(_ run: EditRun, project: Project, start: Int, stop: Int) async {
        do {
            let result = try await PipelineService(runner: runner, disk: workflow).execute(run, project: project, engine: engineRoot, start: start, stop: stop) { event in
                await MainActor.run {
                    var progress = self.runs[project.id] ?? run
                    progress.state = .running; progress.events.append(event); self.runs[project.id] = progress
                }
            }
            runs[project.id] = result
            if result.state == .complete {
                do { _ = try await workflow.snapshot(result, project: project) }
                catch {
                    var failed = result; failed.state = .failed; failed.failure = error.localizedDescription
                    runs[project.id] = failed; try await workflow.save(failed); throw error
                }
                cutVersions[project.id] = try await workflow.versions(project: project)
                currentCuts[project.id] = try await workflow.current(project: project)
            }
            missingPieces[project.id] = (try? await workflow.missing(result)) ?? []
            planReviews[project.id] = (try? await workflow.plan(result).text) ?? ""
            runDetails[project.id] = (try? await workflow.logTail(result)) ?? ""
        } catch { notice = error.localizedDescription }
    }

    func satisfy(_ piece: MissingPiece, urls: [URL]) async {
        guard let project = selected, let run = runs[project.id], runningProjectID == nil else { return }
        do { try await workflow.satisfy(piece, urls: urls, run: run) }
        catch { notice = error.localizedDescription }
    }

    func restoreCut(_ version: CutVersion) async {
        guard let project = selected, runningProjectID == nil else { return }
        do { try await workflow.restore(version, project: project); currentCuts[project.id] = version }
        catch { notice = error.localizedDescription }
    }

    func exportHandoff(_ version: CutVersion) async -> URL? {
        guard let project = selected, !exportingPDF else { return nil }
        exportingPDF = true; defer { exportingPDF = false }
        do {
            let report = try await workflow.handoffReport(version, project: project)
            return try await exporter.export(report, project: project, version: version)
        }
        catch { notice = error.localizedDescription; return nil }
    }

    func setFolders(projects: URL? = nil, engine: URL? = nil) {
        if let projects { projectRoot = projects; defaults.set(projects.path, forKey: "ClautoProjectsRoot") }
        if let engine { engineRoot = engine; defaults.set(engine.path, forKey: "ClautoEngineRoot") }
        setupChecks = []
    }

    func exportDerivative(_ request: DerivativeRequest, version: CutVersion, project: Project) async {
        guard exportingDerivativeProjectID == nil, runningProjectID == nil else { return }
        exportingDerivativeProjectID = project.id; defer { exportingDerivativeProjectID = nil }
        derivativeDetails[project.id] = "Preparing a local export from saved v\(version.number)…"
        do {
            _ = try await DerivativeService(runner: derivativeRunner, disk: workflow).export(request, version: version, project: project, engine: engineRoot) { [weak self] line in
                guard let store = self else { return }
                await store.appendDerivativeLine(line, projectID: project.id)
            }
            derivedCuts[project.id] = try await workflow.derivatives(project: project)
        } catch { notice = error.localizedDescription }
    }

    func cancelDerivative() async { await derivativeRunner.cancel() }

    private func appendDerivativeLine(_ line: ProcessLine, projectID: UUID) {
        let previous = derivativeDetails[projectID] ?? ""
        derivativeDetails[projectID] = String((previous + "\n" + line.text).suffix(20_000))
    }

    private func update(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        else { projects.append(project) }
    }
    private func remember() { defaults.set(projects.map { $0.folder.path }, forKey: recentKey) }
}
