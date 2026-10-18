import Foundation
import Observation
import Darwin

@MainActor @Observable
final class EditorStore {
    static let nasRoot = URL(fileURLWithPath: "/Volumes/Videos/Food Videos/Katie YouTube/Projects/Clauto Editor", isDirectory: true)
    var projects: [Project] = []
    var selectedID: UUID? {
        didSet {
            selectionGeneration &+= 1
            guard !restoringSelection, let project = selected else { return }
            defaults.set(project.id.uuidString, forKey: "ClautoSelectedProjectID")
            defaults.set(project.folder.path, forKey: "ClautoSelectedProjectPath")
        }
    }
    var notice: String? { didSet { noticeTitle = "Needs attention" } }
    var noticeTitle = "Needs attention"
    let workspaceSetup = WorkspaceSetupController()
    var setupChecks: [SetupCheck] { workspaceSetup.checks }
    var runDetails: [UUID: String] = [:]
    private var checkingProject = false
    var checking: Bool { workspaceSetup.busy || checkingProject }
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
    var transcriptReviews: [UUID: TranscriptReviewController] = [:]
    var voiceReviews: [UUID: VoiceReviewController] = [:]
    var frameComments: [UUID: FrameCommentController] = [:]
    var graphicStudios: [UUID: GraphicStudioController] = [:]
    func graphicStudio(for project: Project) -> GraphicStudioController {
        if let current = graphicStudios[project.id] { return current }
        let next = GraphicStudioController(project: project);graphicStudios[project.id] = next;return next
    }
    var fontStudios: [UUID: FontStudioController] = [:]
    func fontStudio(for project: Project) -> FontStudioController {
        if let current = fontStudios[project.id] { return current }
        let next = FontStudioController(project: project,engine: engineRoot);fontStudios[project.id] = next;return next
    }
    var cutoutStudios: [UUID: CutoutStudioController] = [:]
    func cutoutStudio(for project: Project) -> CutoutStudioController {
        if let current = cutoutStudios[project.id] { return current }
        let next = CutoutStudioController(project: project); cutoutStudios[project.id] = next; return next
    }
    var liveConversations: [UUID: LiveConversationController] = [:]
    func liveConversation(for project: Project) -> LiveConversationController {
        if let current = liveConversations[project.id] { return current }
        let updates = ConversationLocalEditController(project: project,engine: engineRoot,
            admit: { [weak self] owner in
                guard let self,self.exportingDerivativeProjectID==nil,self.runningProjectID==nil,!self.checking,!self.working else { return false }
                self.localExportOwner = (owner,project.id);self.exportingDerivativeProjectID = project.id;return true
            },release: { [weak self] owner in
                guard let self,self.localExportOwner?.0==owner else { return }
                self.localExportOwner = nil;self.exportingDerivativeProjectID = nil
            },onExport: { [weak self] result in
                guard let self else { return }
                if !(self.derivedCuts[project.id] ?? []).contains(where: { $0.id==result.id }) { self.derivedCuts[project.id,default: []].append(result) }
            })
        let next = LiveConversationController(project: project,localUpdates: updates,localTarget: { [weak self] in
            guard let self else { throw ProjectFailure.invalidProject }
            let storedVersion = self.currentCuts[project.id]
            let version: CutVersion?
            if let storedVersion { version = storedVersion } else { version = try await self.workflow.current(project: project) }
            guard let version else {
                throw WorkflowFailure.invalid("Create or select a saved cut in this project first.")
            }
            let source = try await self.workflow.derivativeSource(version,project: project)
            return .init(projectID: project.id,versionID: version.id,versionNumber: version.number,timelineSHA256: source.timelineSHA256,
                engineVersion: source.engineVersion,duration: source.duration,aspect: version.aspect ?? project.manifest.aspect,
                resolution: version.exportResolution ?? project.manifest.exportResolution ?? self.defaultExportResolution)
        })
        liveConversations[project.id] = next;return next
    }
    var reviewPlayers: [UUID: ReviewPlayerSession] = [:]
    func reviewPlayer(project: Project,version: CutVersion,url: URL,ownerID: UUID) -> ReviewPlayerSession {
        if let session = reviewPlayers.values.first(where: { $0.ownerID == ownerID && $0.version.id == version.id && $0.project.id == project.id && $0.url == url }) { return session }
        let session = ReviewPlayerSession(project: project,version: version,url: url,store: self,ownerID: ownerID)
        reviewPlayers[session.id] = session; return session
    }
    let playbackPreferences: ReviewPlaybackPreferences
    @ObservationIgnored private let voiceProvider = DictateReviewAdapter()
    @ObservationIgnored private let regionDictationAdmission = RegionDictationAdmission()
    @ObservationIgnored private let repository = ProjectRepository()
    @ObservationIgnored private let runner = ProcessRunner()
    @ObservationIgnored private let workflow = WorkflowRepository()
    @ObservationIgnored private let exporter = HandoffExportService()
    @ObservationIgnored private let derivativeRunner = ProcessRunner()
    @ObservationIgnored private var localExportOwner: (UUID,UUID)?
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var presentationState = ProjectPresentationState()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let recentKey = "ClautoRecentProjects"
    @ObservationIgnored private var selectionGeneration: UInt64 = 0
    @ObservationIgnored private var restorationID: UUID?
    @ObservationIgnored private var restoringSelection = false

    init(defaults: UserDefaults = .standard) {
        let env = ProcessInfo.processInfo.environment
        let preferences = env["CLAUTO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? defaults
        self.defaults = preferences
        playbackPreferences = ReviewPlaybackPreferences(defaults: preferences)
        defaultExportResolution = preferences.string(forKey: "ClautoDefaultExportResolution").flatMap(ExportResolution.init(rawValue:)) ?? .fullHD
        projectRoot = URL(fileURLWithPath: env["CLAUTO_PROJECTS_ROOT"] ?? preferences.string(forKey: "ClautoProjectsRoot") ?? Self.nasRoot.path, isDirectory: true)
        engineRoot = URL(fileURLWithPath: env["CLAUTO_ENGINE_ROOT"] ?? preferences.string(forKey: "ClautoEngineRoot") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clauto Editor/engine").path, isDirectory: true)
    }

    var selected: Project? { projects.first { $0.id == selectedID } }
    var details: String { selectedID.flatMap { runDetails[$0] } ?? "" }
    var checkSummary: String? { selectedID.flatMap { checkSummaries[$0] } }

    func transcriptReview(for project: Project) -> TranscriptReviewController {
        if let existing = transcriptReviews[project.id] { return existing }
        let controller = TranscriptReviewController(project: project)
        transcriptReviews[project.id] = controller
        return controller
    }

    func voiceReview(for project: Project) -> VoiceReviewController? {
        if let existing = voiceReviews[project.id] { return existing }
        do {
            let controller = try VoiceReviewController(project: project, provider: voiceProvider, defaults: defaults)
            voiceReviews[project.id] = controller; return controller
        } catch { notice = error.localizedDescription; return nil }
    }

    func frameComment(for project: Project) -> FrameCommentController {
        if let controller = frameComments[project.id] { return controller }
        let dictation = RegionDictationController(project: project,provider: voiceProvider,admission: regionDictationAdmission) { [weak self] in
            guard let self else { return false }
            for voice in self.voiceReviews.values { if !(await voice.relinquishMicrophoneForRegion()) { return false } }
            return true
        }
        let controller = FrameCommentController(project: project,peopleDetector: LocalFramePeopleDetector(),dictation: dictation)
        frameComments[project.id] = controller; return controller
    }

    func playbackTarget(version: CutVersion, project: Project) async throws -> VoiceReviewTarget {
        try await workflow.voiceReviewTarget(version,project: project)
    }

    func bindVoiceReview(version: CutVersion, project: Project, token: UUID, sampler: @escaping @MainActor () -> VoiceLivePlayhead) async {
        guard let controller = voiceReview(for: project) else { return }
        await controller.load()
        do { await controller.attach(try await workflow.voiceReviewTarget(version, project: project), token: token, sampler: sampler) }
        catch { controller.error = error.localizedDescription }
    }

    func recordReviewLaunch(version: CutVersion, project: Project, playerSeconds: Double) async {
        guard ProcessInfo.processInfo.environment["CLAUTO_VERIFY_REVIEW_LAUNCH"] == "1" else { return }
        do {
            let target = try await workflow.voiceReviewTarget(version,project: project)
            let root = try SourceRenderDirectory.open(project.folder)
            let evidence: [String:Any] = ["kind":"native_review_launch","processID":ProcessInfo.processInfo.processIdentifier,
                "bundlePath":Bundle.main.bundleURL.path,"engineRoot":engineRoot.path,"projectPath":project.folder.path,
                "versionID":version.id.uuidString,"versionNumber":version.number,"previewSHA256":target.preview.sha256,
                "previewPath":try VoiceReviewProvenance.url(target.preview.relativePath,project: project).path,
                "duration":target.duration,"playerReady":true,"playerSeconds":playerSeconds,"microphoneStarted":false]
            try root.child(".clauto").writeNew(JSONSerialization.data(withJSONObject: evidence,options: [.sortedKeys]),name: "review-launch-"+UUID().uuidString+".json")
        } catch { notice = error.localizedDescription }
    }

    var hasPendingReviewWork: Bool { workspaceSetup.busy || graphicStudios.values.contains(where: \.hasPendingWork) || fontStudios.values.contains(where: \.hasPendingWork) || cutoutStudios.values.contains(where: \.hasPendingWork) || liveConversations.values.contains(where: \.hasPendingWork) || working || exportingDerivativeProjectID != nil || presentationState.hasUnsavedBriefs || hasPendingTranscriptSaves || voiceReviews.values.contains(where: \.hasPendingWork) || frameComments.values.contains(where: \.hasPendingWork) }

    func flushReviewWorkForExit() async -> Bool {
        await workspaceSetup.pauseForExit()
        // Retry retained Brief drafts, then wait for their actual acknowledgements.
        for project in projects {
            if let brief = presentationState.pendingBrief(for: project) { save(brief,for: project.id) }
        }
        for task in Array(saves.values) { await task.value }
        var voicesSaved = true
        for controller in graphicStudios.values { if !(await controller.flushForExit()) { voicesSaved = false } }
        for controller in fontStudios.values { if !(await controller.flushForExit()) { voicesSaved = false } }
        for controller in cutoutStudios.values { if !(await controller.flushForExit()) { voicesSaved = false } }
        for controller in liveConversations.values { if !(await controller.flushForExit()) { voicesSaved = false } }
        for controller in frameComments.values { if !(await controller.flushForExit()) { voicesSaved = false } }
        for controller in voiceReviews.values { if !(await controller.flushForExit()) { voicesSaved = false } }
        return await flushTranscriptReviewsForExit() && voicesSaved && !presentationState.hasUnsavedBriefs && !working && exportingDerivativeProjectID==nil
    }

    func resumeReviewWorkAfterCancelledExit() {
        workspaceSetup.resumeAfterCancelledExit()
        for controller in voiceReviews.values { controller.resumeAfterCancelledExit() }
        for controller in liveConversations.values { controller.localUpdates?.resume() }
    }

    var hasPendingTranscriptSaves: Bool { transcriptReviews.values.contains { $0.dirty || $0.saving || $0.loading } }

    func flushTranscriptReviewsForExit() async -> Bool {
        await TranscriptReviewExit.flush(Array(transcriptReviews.values))
    }

    var initialProjectTab: String {
        RecentProjectRestoration.tab(ProcessInfo.processInfo.environment["CLAUTO_PROJECT_TAB"]
            ?? defaults.string(forKey: "ClautoSelectedProjectTab"))
    }

    func rememberProjectTab(_ value: String) {
        defaults.set(RecentProjectRestoration.tab(value), forKey: "ClautoSelectedProjectTab")
    }

    func restore(openProject: @Sendable (URL) async throws -> Project = { try await ProjectRepository().open($0) }) async {
        let operation = UUID(), generation = selectionGeneration
        restorationID = operation
        let preferredID = defaults.string(forKey: "ClautoSelectedProjectID")
        let preferredPath = defaults.string(forKey: "ClautoSelectedProjectPath")
        do {
            let restored = try await RecentProjectRestoration.load(defaults.stringArray(forKey: recentKey) ?? [], open: openProject)
            guard restorationID == operation else { return }
            try Task.checkCancellation()
            var unavailable = restored.unavailablePaths
            var admitted = RecentProjectRestoration()
            for project in restored.projects {
                do {
                    try ProjectPresentationState.requireUnambiguousOpen(project, among: projects)
                    update(project); admitted.projects.append(project)
                } catch { unavailable.append(project.folder.path) }
            }
            // A user selecting/opening another project during I/O owns that
            // selection. Neither a slower restore nor a second window steals it.
            if selectionGeneration == generation {
                if selected == nil {
                    // A temporary fallback must not replace the last explicit
                    // choice; it may become available after reconnecting a drive.
                    restoringSelection = true
                    selectedID = admitted.selection(id: preferredID, path: preferredPath)
                    restoringSelection = false
                }
                if !unavailable.isEmpty {
                    notice = "\(unavailable.count) recent project\(unavailable.count == 1 ? " is" : "s are") unavailable. Reconnect the project drive or choose its folder again. Your projects stay in Recents."
                }
            }
        } catch is CancellationError { }
        catch { if restorationID == operation && selectionGeneration == generation { notice = error.localizedDescription } }
    }

    func create(_ name: String) async -> Bool {
        selectionGeneration &+= 1
        working = true; defer { working = false }
        do {
            let version = (try? String(contentsOf: engineRoot.appendingPathComponent("ENGINE_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "development"
            let project = try await repository.create(name: name, root: projectRoot, engine: engineRoot, engineVersion: version, resolution: defaultExportResolution)
            update(project); selectedID = project.id; remember()
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func open(_ folder: URL) async {
        // Opening is newer user intent even when it fails before selection.
        // An older restoration must not replace this action's error or choose
        // a different project behind it.
        selectionGeneration &+= 1
        do { let project = try await repository.open(folder); try ProjectPresentationState.requireUnambiguousOpen(project,among: projects); update(project); selectedID = project.id; remember() }
        catch { notice = error.localizedDescription }
    }

    func save(_ brief: Brief, for id: UUID) {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        let token = presentationState.submit(brief,for: project)
        project.brief = brief; update(project)
        saves[id]?.cancel()
        saves[id] = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let saved = try await repository.saveBrief(brief, project: project)
                // Old acknowledgements cannot clear a newer local draft or roll
                // back a later manifest response. Failed drafts remain owned.
                if presentationState.acknowledge(token,for: project) { saves.removeValue(forKey: id) }
                update(saved)
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
        guard !checking, runningProjectID == nil, exportingDerivativeProjectID == nil, !working else { return }
        await workspaceSetup.run(engine: engineRoot,projects: projectRoot,prepare: false)
    }

    func prepareWorkspace() async {
        guard !checking, runningProjectID == nil, exportingDerivativeProjectID == nil, !working else { return }
        let requested = projectRoot
        await workspaceSetup.run(engine: engineRoot,projects: requested,prepare: true)
        if projectRoot == requested, workspaceSetup.checks.first(where: { $0.id == "folders" })?.state == .ready {
            defaults.set(requested.path,forKey: "ClautoProjectsRoot")
        }
    }

    var needsFirstWorkspaceSetup: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CLAUTO_PROJECTS_ROOT"] == nil && defaults.string(forKey: "ClautoProjectsRoot") == nil
            && (defaults.stringArray(forKey: recentKey) ?? []).isEmpty
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
        guard let project = selected, !checking, runningProjectID == nil, exportingDerivativeProjectID == nil, !working else { return }
        checkingProject = true; checkSummaries[project.id] = nil; runDetails[project.id] = ""; defer { checkingProject = false }
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

    func approveScript(_ text: String, project: Project) async {
        guard runningProjectID == nil, !working else { return }
        working = true; defer { working = false }
        do {
            update(try await repository.approveScript(text, project: project))
            notice = "New cuts will use this saved script. Earlier versions keep their scripts."; noticeTitle = "Script saved"
        }
        catch { notice = error.localizedDescription }
    }
    func selectScript(_ file: ProjectFile,project: Project) async {
        guard runningProjectID == nil, !working else { return }
        working = true; defer { working = false }
        do {
            update(try await repository.selectScript(file,project: project))
            notice = "New cuts will use a saved copy of \(file.name). Earlier versions keep their scripts."; noticeTitle = "Script selected"
        } catch { notice = error.localizedDescription }
    }
    func replaceScript(_ file: ProjectFile,with source: URL,project: Project) async {
        guard runningProjectID == nil, !working else { notice = "Wait for the current update before replacing this script."; return }
        working = true; defer { working = false }
        do {
            update(try await repository.replaceScript(file,with: source,project: project))
            notice = "New cuts will use the replacement script. Previous copies and cut inputs are retained."; noticeTitle = "Script replaced"
        } catch { notice = error.localizedDescription }
    }

    func beginCut(label: String, primaryID: UUID? = nil, narrationIDs: [UUID] = []) async {
        guard let chosen = selected, runningProjectID == nil, exportingDerivativeProjectID == nil, !checking, !working else { return }
        runningProjectID = chosen.id; defer { runningProjectID = nil }
        do {
            if let save = saves[chosen.id] { await save.value }
            let project = try await repository.open(chosen.folder)
            // Reopening after an awaited save must retain the originally chosen
            // physical project, rather than blessing a replacement at its path.
            try presentationState.requireCutInput(project,chosen: chosen)
            let run = try await workflow.prepare(project: project, engine: engineRoot, label: label, primaryID: primaryID, narrationIDs: narrationIDs)
            runs[project.id] = run
            await execute(run, project: project, start: 1, stop: 3)
        } catch { notice = error.localizedDescription }
    }

    func continueCut(approve: Bool) async {
        guard let project = selected, var run = runs[project.id], runningProjectID == nil, exportingDerivativeProjectID == nil, !checking, !working else { return }
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
        workspaceSetup.invalidate()
    }

    func exportDerivative(_ request: DerivativeRequest, version: CutVersion, project: Project) async {
        guard exportingDerivativeProjectID == nil, runningProjectID == nil, !checking, !working else { return }
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

    func cancelDerivative() async {
        if let owner = localExportOwner,let updates = liveConversations[owner.1]?.localUpdates { updates.stopCurrent() }
        else { await derivativeRunner.cancel() }
    }

    private func appendDerivativeLine(_ line: ProcessLine, projectID: UUID) {
        let previous = derivativeDetails[projectID] ?? ""
        derivativeDetails[projectID] = String((previous + "\n" + line.text).suffix(20_000))
    }

    private func update(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = presentationState.present(project,over: projects[index]) }
        else { projects.append(presentationState.present(project,over: nil)) }
    }
    private func remember() {
        defaults.set(RecentProjectRestoration.recentPaths(selected: selected, projects: projects,
            previous: defaults.stringArray(forKey: recentKey) ?? []), forKey: recentKey)
    }
}
