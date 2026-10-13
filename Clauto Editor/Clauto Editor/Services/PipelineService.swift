import Foundation

struct PipelineService: Sendable {
    var runner: any CommandRunning
    var disk: WorkflowRepository

    func execute(_ original: EditRun, project: Project, engine: URL, start: Int, stop: Int,
                 onEvent: @escaping @Sendable (StageEventRecord) async -> Void) async throws -> EditRun {
        guard original.projectID == project.id, (start == 1 && stop == 3) || (start == 4 && stop == 5) else { throw ProjectFailure.invalidProject }
        guard start == 1 ? original.state == .prepared : [.needsReview, .needsAssets, .failed].contains(original.state) else {
            throw WorkflowFailure.invalid("This run cannot resume from its current state. Start a new run instead.")
        }
        var run = original
        let settings = try await disk.settings(run, project: project, engine: engine)
        if start == 4 {
            let plan = try await disk.plan(run)
            guard plan.issues.isEmpty, run.approvedPlanHash == plan.hash else { throw WorkflowFailure.invalid("Confirm the graphic plan, including its facts and numbers, before rendering.") }
        }
        run.state = .running; try await disk.save(run)
        let recorder = EventRecorder()
        let modelCache = URL(fileURLWithPath: settings["model_cache"] ?? project.folder.appendingPathComponent("build/models").path)
        let environment = ["CLAUTO_PATHS": run.folder.appendingPathComponent("paths.json").path,
                           "CLAUTO_WHISPER_MODEL": project.manifest.whisperModel,
                           "HF_HOME": modelCache.appendingPathComponent("huggingface").path,
                           "TORCH_HOME": modelCache.appendingPathComponent("torch").path,
                           "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "CLAUTO_OFFLINE": "1"]
        do {
            let result = try await runner.run(ProcessCommand(executable: engine.appendingPathComponent("run"),
                arguments: ["run_pipeline.py", "--from", String(start), "--to", String(stop), "--progress", "json", "--preview", "--strict-assets",
                            "--project", "video\(project.id.uuidString.prefix(8))", "--aspect", project.manifest.aspect,
                            "--script", settings["approved_script"]!],
                directory: engine, environment: environment, timeout: .seconds(86_400)), onLine: { line in
                    try? await disk.appendLog(line, run: original)
                    if !line.isError {
                        do {
                            let parsed = try JSONDecoder().decode(StageEvent.self, from: Data(line.text.utf8))
                            guard (0...5).contains(parsed.stage) else { throw ProjectFailure.invalidProject }
                            let event = StageEventRecord(stage: parsed.stage, state: parsed.state.rawValue, detail: parsed.detail)
                            await recorder.append(event); await onEvent(event)
                        } catch { await recorder.invalidate() }
                    }
                })
            run.events += await recorder.events
            if result.cancelled { run.state = .cancelled; run.failure = "Run stopped; the previous cut is unchanged." }
            else if await recorder.invalid { run.state = .failed; run.failure = "The engine returned unreadable progress. Check Details and retry with the supported engine." }
            else if !result.succeeded {
                run.state = run.events.last?.stage == 4 ? .needsAssets : .failed
                run.failure = "The engine stopped. Resolve its reported missing input or read-back issue, then retry."
            } else {
                let completed = await recorder.events.filter { $0.state == "done" }.map(\.stage)
                guard completed == Array(start...stop), !(await recorder.events).contains(where: { $0.state == "fail" }) else { throw WorkflowFailure.invalid("The engine did not confirm every requested stage; this cut remains unverified.") }
                run.state = stop == 3 ? .needsReview : .complete
            }
        } catch { run.state = .failed; run.failure = error.localizedDescription }
        try await disk.save(run)
        return run
    }
}

private actor EventRecorder {
    var events: [StageEventRecord] = []
    var invalid = false
    func append(_ event: StageEventRecord) { events.append(event) }
    func invalidate() { invalid = true }
}
