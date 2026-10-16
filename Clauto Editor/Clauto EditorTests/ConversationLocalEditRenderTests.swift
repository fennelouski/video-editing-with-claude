import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@MainActor @Suite(.serialized) struct ConversationLocalEditRenderTests {
    private func parent(project: Project,engine: URL) async throws -> CutVersion {
        let disk = WorkflowRepository();var run = try await disk.prepare(project: project,engine: engine,label: "Synthetic composition parent")
        let fm = FileManager.default
        for name in ["plan","exports","roughcut"] { try fm.createDirectory(at: run.folder.appendingPathComponent(name),withIntermediateDirectories: true) }
        try Data(#"{"script":"script.md","cues":[],"issues":[],"unresolved":[]}"#.utf8).write(to: run.folder.appendingPathComponent("plan/video.plan.json"))
        let source = project.folder.appendingPathComponent("synthetic-originals/a.mov")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11"><resources>
        <format id="rOut" frameDuration="1001/24000s" width="1920" height="1080"/>
        <format id="rIn" frameDuration="1001/24000s" width="320" height="180"/>
        <asset id="rA" name="Synthetic color and tone" start="0s" duration="72072/24000s" hasVideo="1" hasAudio="1" audioSources="1" audioChannels="2" format="rIn"><media-rep kind="original-media" src="\(source.absoluteString)"/></asset>
        </resources><library><event name="Synthetic"><project name="Synthetic parent"><sequence format="rOut" duration="12012/24000s" tcStart="0s" tcFormat="NDF"><spine><asset-clip ref="rA" offset="0s" start="0s" duration="12012/24000s"/></spine></sequence></project></event></library></fcpxml>
        """
        try Data(xml.utf8).write(to: run.folder.appendingPathComponent("exports/video.fcpxml"))
        let evidence: [String:Any] = ["timeline":"video.fcpxml","sha256":TranscriptSourceMap.sha(Data(xml.utf8)),"problems":[],"schemaChecked":false]
        try JSONSerialization.data(withJSONObject: evidence).write(to: run.folder.appendingPathComponent("exports/video.validation.json"))
        try Data("Synthetic fixture text; not ASR evidence.".utf8).write(to: run.folder.appendingPathComponent("roughcut/a.heard.txt"))
        run.state = .complete;run.approvedPlanHash = try await disk.plan(run).hash
        return try await disk.snapshot(run,project: project)
    }

    @Test func submittedIdleCommandsExecuteTheActualLocalWorkerAndReopenItsVerifiedExport() async throws {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-local-job-render-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        var completed = false;defer { if completed { try? FileManager.default.removeItem(at: root) } else { print("SYNTHETIC_LOCAL_JOB_FAILURE_ROOT="+root.path) } }
        let fixture = try await SyntheticSourceSpanFixture.generate(root: root,engine: engine)
        let imported = try await ProjectRepository().add([fixture.project.folder.appendingPathComponent("synthetic-originals/a.mov")],to: fixture.project)
        let project = try await ProjectRepository().approveScript("Synthetic local job fixture only.",project: imported)
        let disk = WorkflowRepository(),version = try await parent(project: project,engine: engine)
        let source = try await disk.derivativeSource(version,project: project),parentBytes = try Data(contentsOf: source.timeline)
        let manifest = try Data(contentsOf: project.folder.appendingPathComponent("clauto-project.json"))
        let target = ConversationLocalEditTarget(projectID: project.id,versionID: version.id,versionNumber: version.number,
            timelineSHA256: source.timelineSHA256,engineVersion: source.engineVersion,duration: source.duration,aspect: "16:9",resolution: .fullHD)
        let text = "trim from 0.08341666666666667 to 0.41708333333333336 in portrait at 720p"
        var exported: DerivedCut?
        let updates = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.02,onExport: { exported = $0 })
        let conversation = LiveConversationController(project: project,clientLocator: { nil },localUpdates: updates,localTarget: { target })
        await conversation.load();conversation.edit(text)
        #expect(await conversation.submit())
        for _ in 0..<4000 {
            if exported != nil || updates.error != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let error = updates.error { throw WorkflowFailure.invalid(error) }
        let result = try #require(exported),jobs = ConversationLocalEditRepository(project: project)
        let terminal = try await jobs.load(),job = try #require(terminal.jobs.last)
        #expect(job.state == .succeeded && job.events.last?.exportID==result.id)
        #expect(conversation.document?.messages.first?.localEdit?.target==target && !conversation.connected)
        #expect(await conversation.flushForExit())
        #expect(result.request.aspect=="9:16" && result.request.resolution == .hd)
        #expect(try await disk.derivatives(project: project).contains { $0.id==result.id })
        let folder = try await disk.derivativeFolder(result.id,project: project)
        let recipe = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("derivative.json"))) as? [String:Any])
        // The production bridge verifies a full decode and hashes on reopen.
        // Assert its own persisted native request and independent container facts.
        let movie = folder.appendingPathComponent("review.mp4")
        let probe = try await ProcessRunner().run(.init(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),arguments: ["-v","error","-select_streams","v:0","-show_entries","stream=width,height,nb_frames","-of","json",movie.path],directory: engine),onLine: nil)
        #expect(probe.succeeded)
        let info = try #require(JSONSerialization.jsonObject(with: Data(probe.output.utf8)) as? [String:Any])
        let stream = try #require((info["streams"] as? [[String:Any]])?.first)
        #expect(stream["width"] as? Int==720 && stream["height"] as? Int==1280)
        #expect(stream["nb_frames"] as? String=="8")
        #expect(!recipe.isEmpty && result.parentTimelineSHA256==source.timelineSHA256)
        #expect(try Data(contentsOf: source.timeline)==parentBytes)
        #expect(try Data(contentsOf: project.folder.appendingPathComponent("clauto-project.json"))==manifest)
        #expect(try await disk.current(project: project)?.id==version.id)
        #expect(try await jobs.load().jobs.last?.request==job.request)
        completed = true
    }
}
